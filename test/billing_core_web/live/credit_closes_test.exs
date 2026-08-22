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
