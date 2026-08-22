defmodule BillingCoreWeb.CreditClosesTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.CreditsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{ERP, Repo}
  alias BillingCore.Credits.Close.Close, as: CreditClose
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.ERP.FakeERP

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    ctx = credit_context_fixture(roles: [:finance_operator, :billing_admin])

    {:ok, connection} =
      ERP.create_connection(ctx.scope, %{provider: "fake", secret_reference: "x"})

    {:ok, _connection} = ERP.validate_connection(ctx.scope, connection)

    %{ctx: ctx, fake: fake, path: "/teams/#{ctx.team.id}/credit-closes"}
  end

  test "policy setup, generation, approval, posting, reconciliation, and period close",
       %{conn: conn, ctx: ctx, path: path} do
    grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 8_000})
    conn = log_in_user(conn, ctx.scope.user)

    {:ok, view, _html} = live(conn, path)

    # No policy yet: the index asks for one and offers no generate form.
    assert has_element?(view, "#close-policy-form")
    refute has_element?(view, "#generate-close-form")

    view
    |> form("#close-policy-form", %{
      "policy" => %{
        "journal_number" => "1",
        "liability_account_number" => "2990",
        "default_offset_account_number" => "5890"
      }
    })
    |> render_submit()

    assert has_element?(view, "#generate-close-form")

    # Generate freezes the close and navigates to its detail page.
    result =
      view
      |> form("#generate-close-form", %{
        "close" => %{
          "period_date" => Date.to_iso8601(Date.utc_today()),
          "currency" => "DKK",
          "bootstrap_opening" => "0.00"
        }
      })
      |> render_submit()

    {:ok, view, html} = follow_redirect(result, conn)
    assert html =~ "Credit close"
    assert has_element?(view, "#close-state", "ready")
    assert has_element?(view, "#close-amounts")
    assert has_element?(view, "#close-movements")
    assert has_element?(view, "#download-pdf_summary")

    close = Repo.one!(CreditClose)
    assert close.closing_minor == 8_000

    # Approve the exact report hash.
    view
    |> form("#approve-close-form", %{"approval" => %{"reason" => "monthly review"}})
    |> render_submit()

    assert has_element?(view, "#close-state", "approved")
    assert has_element?(view, "#close-approval", "monthly review")

    # Post: durable operation → provider voucher → attachment → read-back.
    view |> element("#post-close") |> render_click()
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    view |> element("#refresh-close") |> render_click()
    assert has_element?(view, "#close-state", "reconciled")
    assert has_element?(view, "#close-posting-status")
    assert has_element?(view, "#download-erp_voucher")
    assert has_element?(view, "#download-reconciliation")

    # Accept the period.
    view |> element("#close-period") |> render_click()
    assert has_element?(view, "#close-state", "closed")
  end

  test "report downloads serve the exact stored bytes", %{conn: conn, ctx: ctx} do
    close = generated_close(ctx)
    conn = log_in_user(conn, ctx.scope.user)

    conn = get(conn, "/teams/#{ctx.team.id}/credit-closes/#{close.id}/report/pdf_summary")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"
    assert conn.resp_body =~ "%PDF-"

    {:ok, evidence} = CloseWorkflow.report(ctx.scope, close.id, :pdf_summary)
    assert conn.resp_body == evidence.bytes
  end

  test "each evidence file downloads with its content type and extension", %{conn: conn, ctx: ctx} do
    close = generated_close(ctx)
    base = "/teams/#{ctx.team.id}/credit-closes/#{close.id}/report"

    json_conn = conn |> log_in_user(ctx.scope.user) |> get("#{base}/canonical_json")
    assert response(json_conn, 200)
    assert get_resp_header(json_conn, "content-type") |> hd() =~ "application/json"
    assert get_resp_header(json_conn, "content-disposition") |> hd() =~ "canonical_json.json"

    csv_conn = conn |> log_in_user(ctx.scope.user) |> get("#{base}/csv_detail")
    assert response(csv_conn, 200)
    assert get_resp_header(csv_conn, "content-type") |> hd() =~ "text/csv"
    assert get_resp_header(csv_conn, "content-disposition") |> hd() =~ "csv_detail.csv"

    # "text/plain" and the "bin" fallback extensions are defensive: every
    # evidence writer today stores application/json, text/csv, or
    # application/pdf, so those clauses stay untestable without fabricating
    # rows the system never produces.
  end

  test "an unknown evidence type leaks nothing", %{conn: conn, ctx: ctx} do
    close = generated_close(ctx)

    conn =
      conn
      |> log_in_user(ctx.scope.user)
      |> get("/teams/#{ctx.team.id}/credit-closes/#{close.id}/report/passwords")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
  end

  test "policy and generation failures surface as flashes, not crashes",
       %{conn: conn, ctx: ctx, path: path} do
    conn = log_in_user(conn, ctx.scope.user)
    {:ok, view, _html} = live(conn, path)

    # Invalid policy input renders the changeset message (BC-US-163).
    view
    |> form("#close-policy-form", %{
      "policy" => %{
        "journal_number" => "",
        "liability_account_number" => "",
        "default_offset_account_number" => ""
      }
    })
    |> render_submit()

    assert render(view) =~ "can&#39;t be blank"

    # Without any policy, generation is refused with precise guidance. The
    # form is not rendered, so the event arrives directly.
    html =
      render_submit(view, "generate_close", %{
        "close" => %{
          "period_date" => Date.to_iso8601(Date.utc_today()),
          "currency" => "DKK",
          "bootstrap_opening" => "0.00"
        }
      })

    assert html =~ "Create a posting policy first."

    # Create a valid policy effective from this month.
    view
    |> form("#close-policy-form", %{
      "policy" => %{
        "journal_number" => "1",
        "liability_account_number" => "2990",
        "default_offset_account_number" => "5890"
      }
    })
    |> render_submit()

    assert has_element?(view, "#generate-close-form")

    # A garbled opening balance is rejected before anything freezes.
    html =
      view
      |> form("#generate-close-form", %{
        "close" => %{
          "period_date" => Date.to_iso8601(Date.utc_today()),
          "currency" => "DKK",
          "bootstrap_opening" => "not-a-number"
        }
      })
      |> render_submit()

    assert html =~ "Enter the opening balance as a plain amount."

    # An unknown currency fails attribute validation (the blank opening
    # also exercises the empty-string default of parse_opening/2).
    html =
      view
      |> form("#generate-close-form", %{
        "close" => %{
          "period_date" => Date.to_iso8601(Date.utc_today()),
          "currency" => "NOPE",
          "bootstrap_opening" => ""
        }
      })
      |> render_submit()

    assert html =~ "The close inputs are incomplete"

    # A month before the policy's effective date cannot freeze.
    last_month = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1)

    html =
      view
      |> form("#generate-close-form", %{
        "close" => %{
          "period_date" => Date.to_iso8601(last_month),
          "currency" => "DKK",
          "bootstrap_opening" => "0.00"
        }
      })
      |> render_submit()

    assert html =~ "No posting policy is effective on that period&#39;s start date."

    # Not exercised on purpose: `generate_error(:invalid_date)` is dead code
    # (parse_date/1 returns bare :error, never {:error, :invalid_date});
    # `:bootstrap_opening_required` cannot escape this surface because the
    # form always submits an integer opening (nil/"" parse to 0); and the
    # changeset clause is defensive — CloseWorkflow.generate validates
    # attributes before any insert.
  end

  test "duplicate and out-of-order generation are refused", %{conn: conn, ctx: ctx, path: path} do
    close = generated_close(ctx)
    conn = log_in_user(conn, ctx.scope.user)
    {:ok, view, _html} = live(conn, path)

    # The first close exists, so the bootstrap-opening input is gone and the
    # submitted params carry no opening at all (nil default).
    refute has_element?(view, "#generate-close-form input[name='close[bootstrap_opening]']")

    html =
      view
      |> form("#generate-close-form", %{
        "close" => %{
          "period_date" => Date.to_iso8601(close.period_start),
          "currency" => "DKK"
        }
      })
      |> render_submit()

    assert html =~ "That period and currency already have a close."

    # The next month cannot freeze while this month's close is only ready.
    next_month = Date.add(close.period_end_exclusive, 1)

    html =
      view
      |> form("#generate-close-form", %{
        "close" => %{
          "period_date" => Date.to_iso8601(next_month),
          "currency" => "DKK"
        }
      })
      |> render_submit()

    assert html =~ "must be reconciled or closed before this month can freeze"
  end

  test "an auditor's mutation events are refused by the domain, not the template",
       %{conn: conn, ctx: ctx, path: path} do
    close = generated_close(ctx)
    auditor = team_scope_fixture(ctx.organization, ctx.team, [:auditor])
    conn = log_in_user(conn, auditor.user)

    {:ok, index, _html} = live(conn, path)

    # The forms are not rendered for auditors; pushing the events directly
    # exercises the domain denial paths behind the thin adapter.
    html = render_submit(index, "create_policy", %{"policy" => %{"journal_number" => "9"}})
    assert html =~ "The posting policy could not be created."

    html =
      render_submit(index, "generate_close", %{
        "close" => %{
          "period_date" => Date.to_iso8601(Date.utc_today()),
          "currency" => "DKK",
          "bootstrap_opening" => "0.00"
        }
      })

    assert html =~ "You are not permitted to do that."

    {:ok, show, _html} = live(conn, "#{path}/#{close.id}")
    html = render_submit(show, "approve", %{"approval" => %{"reason" => "sneaky"}})
    assert html =~ "You are not permitted to do that."
  end

  test "actions pushed in the wrong close state are refused with the state named",
       %{conn: conn, ctx: ctx, path: path} do
    close = generated_close(ctx)
    conn = log_in_user(conn, ctx.scope.user)
    {:ok, view, _html} = live(conn, "#{path}/#{close.id}")

    # Posting and period acceptance are not legal from :ready.
    html = render_click(view, "request_posting", %{})
    assert html =~ "That action is not allowed in state ready"

    # close_period drives the state machine directly, so the rejection is
    # phrased from the illegal transition rather than an expected-state list.
    html = render_click(view, "close_period", %{})
    assert html =~ "That action is not allowed in the close&#39;s current state."

    # Approve once, then a duplicate approval submission is refused.
    view
    |> form("#approve-close-form", %{"approval" => %{"reason" => "review"}})
    |> render_submit()

    assert has_element?(view, "#close-state", "approved")

    html = render_submit(view, "approve", %{"approval" => %{"reason" => "again"}})
    assert html =~ "That action is not allowed in state approved"

    # The timer-driven refresh path re-derives the same durable state.
    send(view.pid, :refresh_close)
    assert has_element?(view, "#close-state", "approved")

    # `reload_close/1`'s error branch is unreachable here: close rows are
    # never deleted and the scope cannot change mid-session.
  end

  test "posting refuses a close marked approved without a binding approval",
       %{conn: conn, ctx: ctx, path: path} do
    # Defense in depth: even if the durable state were ever moved to
    # :approved without its approval record (the exact drift
    # ensure_current_approval! exists for), posting must refuse.
    close = generated_close(ctx)
    close |> Ecto.Changeset.change(state: :approved) |> Repo.update!()

    conn = log_in_user(conn, ctx.scope.user)
    {:ok, view, _html} = live(conn, "#{path}/#{close.id}")

    html = view |> element("#post-close") |> render_click()
    assert html =~ "The approval is missing or no longer matches the report hash."
  end

  test "posting an approved close is refused while the connection is unvalidated",
       %{conn: conn} do
    other = credit_context_fixture(roles: [:finance_operator, :billing_admin])

    {:ok, _connection} =
      ERP.create_connection(other.scope, %{provider: "fake", secret_reference: "x"})

    close = generated_close(other)
    {:ok, _approved} = CloseWorkflow.approve(other.scope, close, reason: "review")

    conn = log_in_user(conn, other.scope.user)
    {:ok, view, _html} = live(conn, "/teams/#{other.team.id}/credit-closes/#{close.id}")

    html = view |> element("#post-close") |> render_click()
    assert html =~ "The ERP connection is unvalidated"
  end

  test "an unknown close id flashes and returns to the listing", %{
    conn: conn,
    ctx: ctx,
    path: path
  } do
    conn = log_in_user(conn, ctx.scope.user)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "#{path}/#{Ecto.UUID.generate()}")

    assert to == path
  end

  test "every durable posting state renders its operator guidance", %{
    conn: conn,
    ctx: ctx,
    path: path
  } do
    close = generated_close(ctx)
    conn = log_in_user(conn, ctx.scope.user)

    # These states are reached asynchronously by the durable posting
    # pipeline; the page must explain each one from the authoritative row
    # (INV-046/047), so the row is placed in each state directly.
    panels = [
      {:posted, "Posted — awaiting reconciliation"},
      {:mismatch, "Reconciliation mismatch"},
      {:outcome_unknown, "Outcome recovery in progress"},
      {:reversal_pending, "Reversal in progress"},
      {:superseded, "Close state"}
    ]

    for {state, title} <- panels do
      close |> Ecto.Changeset.change(state: state) |> Repo.update!()

      {:ok, view, _html} = live(conn, "#{path}/#{close.id}")
      assert has_element?(view, "#close-action-panel", title)
    end

    # :superseded reaches the catch-all guidance.
    {:ok, view, _html} = live(conn, "#{path}/#{close.id}")

    assert has_element?(
             view,
             "#close-action-panel",
             "not currently awaiting an operator decision"
           )

    # Not exercised on purpose: `evidence_label/1`'s to_string fallback is
    # defensive over a closed Ecto.Enum, and `:ledger_snapshot_mismatch`
    # requires the frozen transaction membership to recompute differently —
    # not reproducible without corrupting immutable ledger rows.
  end

  test "an auditor sees the close but no mutating actions", %{conn: conn, ctx: ctx} do
    close = generated_close(ctx)
    auditor = team_scope_fixture(ctx.organization, ctx.team, [:auditor])

    {:ok, view, _html} =
      conn
      |> log_in_user(auditor.user)
      |> live("/teams/#{ctx.team.id}/credit-closes/#{close.id}")

    assert has_element?(view, "#close-state", "ready")
    refute has_element?(view, "#approve-close-form")
    refute has_element?(view, "#post-close")

    {:ok, index, _html} =
      conn
      |> log_in_user(auditor.user)
      |> live("/teams/#{ctx.team.id}/credit-closes")

    assert has_element?(index, "#credit-closes")
    refute has_element?(index, "#generate-close-form")
    refute has_element?(index, "#close-policy-form")
  end

  test "an accepted close is corrected through reversal and replacement in the browser",
       %{conn: conn, ctx: ctx} do
    close = generated_close(ctx)
    {:ok, _} = CloseWorkflow.approve(ctx.scope, close, reason: "review")
    {:ok, _} = CloseWorkflow.request_posting(ctx.scope, close)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _} = CloseWorkflow.close_period(ctx.scope, close)

    conn = log_in_user(conn, ctx.scope.user)
    {:ok, view, _html} = live(conn, "/teams/#{ctx.team.id}/credit-closes/#{close.id}")

    # A reversal without an explicit reason is refused for the audit trail.
    html = render_submit(view, "request_reversal", %{"reversal" => %{"reason" => "   "}})
    assert html =~ "A correction needs an explicit reason for the audit trail."

    # The closed close offers the reversal remediation.
    result =
      view
      |> form("#request-reversal-form", %{"reversal" => %{"reason" => "wrong accounts"}})
      |> render_submit()

    {:ok, reversal_view, html} = follow_redirect(result, conn)
    assert html =~ "reversal"
    assert has_element?(reversal_view, "#close-kind", "reversal")
    assert has_element?(reversal_view, "#close-state", "ready")
    assert has_element?(reversal_view, "#close-correction-origin")

    # Drive the reversal voucher through approve/post; the original reverses.
    reversal = Repo.get_by!(CreditClose, close_kind: :reversal)
    {:ok, _} = CloseWorkflow.approve(ctx.scope, reversal, reason: "reversal review")
    {:ok, _} = CloseWorkflow.request_posting(ctx.scope, reversal)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    {:ok, original_view, _html} =
      live(conn, "/teams/#{ctx.team.id}/credit-closes/#{close.id}")

    assert has_element?(original_view, "#close-state", "reversed")
    assert has_element?(original_view, "#close-corrections", "reversal")
    assert has_element?(original_view, "#generate-replacement-form")

    # Generate the replacement under a corrected policy from the browser.
    {:ok, corrected} =
      BillingCore.Credits.Close.create_policy(ctx.scope, %{
        version: 2,
        effective_from: Date.beginning_of_month(Date.utc_today()),
        journal_number: 2,
        liability_account_number: 2991,
        posting_mode: :single_offset,
        default_offset_account_number: 5891,
        post_zero_delta: false,
        vat_neutral: true,
        created_by: ctx.scope.user.id
      })

    {:ok, original_view, _html} =
      live(conn, "/teams/#{ctx.team.id}/credit-closes/#{close.id}")

    result =
      original_view
      |> form("#generate-replacement-form", %{
        "replacement" => %{"policy_version_id" => corrected.id, "reason" => "repost corrected"}
      })
      |> render_submit()

    {:ok, replacement_view, _html} = follow_redirect(result, conn)
    assert has_element?(replacement_view, "#close-kind", "replacement")
    assert has_element?(replacement_view, "#close-state", "ready")

    replacement = Repo.get_by!(CreditClose, close_kind: :replacement)
    assert replacement.closing_minor == close.closing_minor
    assert replacement.policy_version_id == corrected.id

    # A second replacement for the same period is refused. (The prior view
    # navigated away on success, so the original close is remounted.)
    {:ok, original_view, _html} =
      live(conn, "/teams/#{ctx.team.id}/credit-closes/#{close.id}")

    html =
      render_submit(original_view, "generate_replacement", %{
        "replacement" => %{"policy_version_id" => corrected.id, "reason" => "again"}
      })

    assert html =~ "This period already has an active close."

    # A reversal, once accepted, cannot itself be reversed — only replaced.
    {:ok, _closed_reversal} = CloseWorkflow.close_period(ctx.scope, reversal)

    {:ok, reversal_view, _html} =
      live(conn, "/teams/#{ctx.team.id}/credit-closes/#{reversal.id}")

    html =
      render_submit(reversal_view, "request_reversal", %{"reversal" => %{"reason" => "undo"}})

    assert html =~ "A reversal close cannot itself be reversed"
  end

  test "another team's finance operator cannot see or download the close", %{conn: conn, ctx: ctx} do
    close = generated_close(ctx)
    other = credit_context_fixture()

    # The LiveView route rejects the foreign team outright.
    assert {:error, {:redirect, %{to: "/"}}} =
             conn
             |> log_in_user(other.scope.user)
             |> live("/teams/#{ctx.team.id}/credit-closes/#{close.id}")

    # The download endpoint leaks nothing either.
    conn =
      conn
      |> log_in_user(other.scope.user)
      |> get("/teams/#{ctx.team.id}/credit-closes/#{close.id}/report/pdf_summary")

    assert redirected_to(conn) == "/"
  end

  defp generated_close(ctx) do
    grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 5_000})

    {:ok, policy} =
      BillingCore.Credits.Close.create_policy(ctx.scope, %{
        version: 1,
        effective_from: Date.beginning_of_month(Date.utc_today()),
        journal_number: 1,
        liability_account_number: 2990,
        posting_mode: :single_offset,
        default_offset_account_number: 5890,
        post_zero_delta: false,
        vat_neutral: true,
        created_by: ctx.scope.user.id
      })

    {:ok, close} =
      CloseWorkflow.generate(ctx.scope, %{
        currency: "DKK",
        period_start: Date.beginning_of_month(Date.utc_today()),
        period_end_exclusive: Date.add(Date.end_of_month(Date.utc_today()), 1),
        transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
        policy_version_id: policy.id,
        bootstrap_opening_minor: 0
      })

    close
  end
end
