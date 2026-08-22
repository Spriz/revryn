defmodule BillingCoreWeb.OperationsLiveTest do
  @moduledoc """
  Failure inbox (SPEC §22.9.3) over the real sync pipeline with the fake ERP
  injecting provider failures. Async: false — Oban drains run inline.
  """

  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{Billing, Catalog, Contracts, Operations}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP
  alias BillingCore.ERP.{FakeERP, Sync}

  setup %{conn: conn} do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    product =
      product_fixture(scope, %{
        recognition_mode: :over_time,
        service_period_source: :billing_period
      })

    plan_version =
      published_plan_version_fixture(scope,
        product: product,
        currency: "DKK",
        interval_count: 12,
        billing_timing: :in_advance,
        amount: "1000.00"
      )

    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, connection} = ERP.validate_connection(scope, connection)

    customer = customer_fixture(scope)

    {:ok, _} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    {:ok, _} =
      Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "SAAS-1"
      })

    contract =
      contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-09-15],
        quantity: Decimal.new(1)
      })

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-15])
    {:ok, intent} = Preview.freeze(scope, preview)

    %{
      conn: log_in_user(conn, scope.user),
      scope: scope,
      fake: fake,
      intent: intent,
      path: "/teams/#{scope.team.id}/operations"
    }
  end

  test "the inbox starts empty", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#empty-inbox")

    # The periodic timer re-derives the same durable state.
    send(view.pid, :refresh)
    assert has_element?(view, "#empty-inbox")
  end

  test "a transient provider failure shows as an automatic retry, not an action",
       %{conn: conn, path: path, scope: scope, fake: fake, intent: intent} do
    FakeERP.inject_failure(
      fake,
      :create_draft,
      {:error, {:provider_failure, %{status: 502, detail: "blip"}}}
    )

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    Oban.drain_queue(queue: :erp, with_safety: false)

    operation = Operations.get!(operation.id)
    assert operation.state == "retry_scheduled"
    assert operation.next_attempt_at

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{operation.id}", "automatic retry pending")
    assert has_element?(view, "#operation-#{operation.id}", "Next attempt")
    # No operator affordances while the retry policy owns the recovery.
    refute has_element?(view, "#retry-#{operation.id}")
    refute has_element?(view, "#remediate-#{operation.id}")
    refute has_element?(view, "#safety-#{operation.id}")
  end

  test "mid-recovery reconciliation states read as automatic", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    # `outcome_unknown` and `reconciling` are transited through by the
    # recovery pipeline; the rows are placed there via the real state
    # machine so the inbox labels can be asserted deterministically.
    base = %{
      team_id: scope.team.id,
      organization_id: scope.organization.id,
      actor_type: "system"
    }

    unknown =
      base
      |> Map.put(:type, "erp.create_draft")
      |> Operations.create!()
      |> Operations.transition!(:claim)
      |> Operations.transition!(:lose_outcome)

    reconciling =
      base
      |> Map.put(:type, "erp.book_document")
      |> Operations.create!()
      |> Operations.transition!(:claim)
      |> Operations.transition!(:lose_outcome)
      |> Operations.transition!(:reconcile)

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{unknown.id}", "automatic reconciliation pending")
    assert has_element?(view, "#operation-#{reconciling.id}", "reconciling — automatic")
    refute has_element?(view, "#retry-#{unknown.id}")
    refute has_element?(view, "#remediate-#{reconciling.id}")

    # Not exercised on purpose: the `:automatic` arms inside
    # `attention_label/1`, `retry_safety/1`, and `guidance/1` only run when
    # attention is :action_required (state blocked/failed), and
    # `remediation_kind/1` never returns :automatic for those states — the
    # clauses are defensive dead arms of exhaustive case expressions.
  end

  test "a failed non-ERP operation offers the bundle but no ERP retry",
       %{conn: conn, path: path, scope: scope} do
    correlation = Ecto.UUID.generate()

    operation =
      Operations.create!(%{
        team_id: scope.team.id,
        organization_id: scope.organization.id,
        type: "credit_close.post_voucher",
        actor_type: "system",
        target_type: "customer_credit_close",
        target_id: Ecto.UUID.generate(),
        correlation_id: correlation
      })
      |> Operations.transition!(:claim)

    operation =
      Operations.record_failure!(operation, :validation,
        code: "close_validation",
        summary: "policy account missing"
      )

    assert operation.state == "failed"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{operation.id}", "action required")
    assert has_element?(view, "#operation-#{operation.id}", "customer_credit_close")
    assert has_element?(view, "#operation-#{operation.id}", correlation)
    assert has_element?(view, "#bundle-#{operation.id}")
    # The ERP retry command does not apply to non-ERP operation types.
    refute has_element?(view, "#retry-#{operation.id}")
  end

  test "retry and remediate reject unknown or foreign operation ids", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path)

    html = render_click(view, "retry", %{"id" => Ecto.UUID.generate()})
    assert html =~ "Not found."

    html = render_click(view, "remediate", %{"id" => "not-a-uuid"})
    assert html =~ "Not found."
  end

  test "a dead-lettered ERP operation shows action required and can be retried (BC-US-106)",
       %{conn: conn, path: path, scope: scope, fake: fake, intent: intent} do
    FakeERP.inject_failure(fake, :create_draft, {:error, {:validation, %{field: "customer"}}})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(operation.id).state == "failed"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{operation.id}", "action required")
    assert has_element?(view, "#operation-#{operation.id}", "validation")
    assert has_element?(view, "#operation-#{operation.id}", "invoice intent")

    # Manual retry re-runs full validation and, with the injection consumed,
    # succeeds this time.
    view |> element("#retry-#{operation.id}") |> render_click()
    assert Operations.get!(operation.id).state == "queued"

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(operation.id).state == "succeeded"
    assert Billing.intent_state(intent) == "erp_draft"

    refute view |> render() =~ "action required"
  end

  test "a blocked operation exposes remediate-and-requeue (§11.3)",
       %{conn: conn, path: path, scope: scope, fake: fake, intent: intent} do
    # Draft, approve, then let a human edit the external draft: booking blocks
    # with external_draft_changed_after_approval (BC-US-084).
    {:ok, _op} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _} = Sync.approve_invoice(scope, intent, reason: "review")

    doc = BillingCore.ERP.get_document_for_intent(scope, intent.id)

    FakeERP.human_edit_draft(fake, doc.external_draft_number, fn draft ->
      update_in(draft.lines, fn [line] -> [%{line | description: "edited by a human"}] end)
    end)

    {:ok, book_op} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(book_op.id).state == "blocked"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{book_op.id}", "action required")
    assert has_element?(view, "#operation-#{book_op.id}", "external_draft_changed_after_approval")

    view |> element("#remediate-#{book_op.id}") |> render_click()

    assert Operations.get!(book_op.id).state == "queued"
    refute has_element?(view, "#operation-#{book_op.id}")
    assert has_element?(view, "#recent-operation-#{book_op.id}", "queued")
  end

  test "an authorization failure is operator-only: distinguished, gated, and remediable by admins",
       %{conn: conn, path: path, scope: scope, fake: fake, intent: intent} do
    FakeERP.inject_failure(fake, :create_draft, {:error, {:authorization, %{detail: "revoked"}}})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(operation.id).state == "blocked"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{operation.id}", "operator-only")
    assert has_element?(view, "#safety-#{operation.id}", "team admin must revalidate")
    assert has_element?(view, "#bundle-#{operation.id}")
    refute has_element?(view, "#retry-#{operation.id}")

    # A finance operator without team_admin cannot requeue an
    # authorization-class failure (BC-US-156 operator-only gating).
    finance = team_scope_fixture(scope.organization, scope.team, [:finance_operator])
    finance_conn = log_in_user(Phoenix.ConnTest.build_conn(), finance.user)
    {:ok, finance_view, _html} = live(finance_conn, path)

    finance_view |> element("#remediate-#{operation.id}") |> render_click()
    assert Operations.get!(operation.id).state == "blocked"

    # The team admin requeues; with the one-shot injection consumed the
    # replay succeeds under the same operation key.
    view |> element("#remediate-#{operation.id}") |> render_click()
    assert Operations.get!(operation.id).state == "queued"
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(operation.id).state == "succeeded"
  end

  test "a terminal failure is non-retryable: no retry action, escalation bundle instead",
       %{conn: conn, path: path, scope: scope, fake: fake, intent: intent} do
    FakeERP.inject_failure(
      fake,
      :create_draft,
      {:error, {:unsupported_capability, :simulated_defect}}
    )

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    Oban.drain_queue(queue: :erp, with_safety: false)

    operation = Operations.get!(operation.id)
    assert operation.state == "failed"
    assert operation.error_class == "terminal"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#operation-#{operation.id}", "non-retryable")
    refute has_element?(view, "#retry-#{operation.id}")
    refute has_element?(view, "#remediate-#{operation.id}")
    assert has_element?(view, "#safety-#{operation.id}", "Not retryable")

    # The support bundle identifies the operation and audit trail without
    # exposing payloads (BC-US-156).
    html = render(view)
    assert html =~ "revryn-support operation=#{operation.id}"
    assert html =~ "correlation="
  end
end
