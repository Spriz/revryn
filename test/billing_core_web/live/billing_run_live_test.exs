defmodule BillingCoreWeb.BillingRunLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{Billing, Contracts}

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    plan_version =
      published_plan_version_fixture(scope,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        billing_timing: :in_advance,
        amount: "250.00"
      )

    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id, currency: "DKK"})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.utc_today(),
        quantity: Decimal.new(1)
      })

    %{
      conn: log_in_user(conn, scope.user),
      scope: scope,
      subscription: subscription,
      plan_version: plan_version
    }
  end

  test "processing a run freezes one intent per customer (BC-US-115)", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/billing-runs")

    html =
      view
      |> form("#process-run-form", run: %{invoice_date: Date.to_iso8601(Date.utc_today())})
      |> render_submit()

    assert html =~ "1 invoice(s) frozen"
    assert has_element?(view, "#billing-runs")
  end

  test "run detail groups intents by lifecycle bucket with next actions", %{
    conn: conn,
    scope: scope
  } do
    {:ok, %{run: run, invoiced: [intent]}} =
      Billing.Scheduler.process_regular_run(scope, Date.utc_today())

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/billing-runs/#{run.id}")

    assert has_element?(view, "#bucket-ready #run-intent-#{intent.id}")
    assert has_element?(view, "#bucket-ready", "Synchronize to the ERP")
    assert has_element?(view, "#bucket-booked", "None.")
  end

  test "an unknown run id flashes and returns to the run list", %{conn: conn, scope: scope} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/teams/#{scope.team.id}/billing-runs/#{Ecto.UUID.generate()}")

    assert to == "/teams/#{scope.team.id}/billing-runs"
  end

  test "the dashboard names the next action for every lifecycle state", %{
    conn: conn,
    scope: scope,
    plan_version: plan_version
  } do
    # A second customer gives the run a second intent so the superseded
    # section can be shown alongside the walked lifecycle.
    customer2 = customer_fixture(scope)
    contract2 = contract_fixture(scope, %{customer_id: customer2.id, currency: "DKK"})

    {:ok, _subscription2} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract2.id,
        plan_version_id: plan_version.id,
        start_date: Date.utc_today(),
        quantity: Decimal.new(1)
      })

    {:ok, %{run: run, invoiced: [intent_a, intent_b]}} =
      Billing.Scheduler.process_regular_run(scope, Date.utc_today())

    path = ~p"/teams/#{scope.team.id}/billing-runs/#{run.id}"

    # A superseded intent leaves the buckets for the dedicated section.
    {:ok, _} = Billing.transition_intent(:system, intent_b, :supersede)

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#bucket-other", "superseded")
    refute has_element?(view, "#run-intent-#{intent_b.id}")

    # Walk the other intent through its lifecycle; each durable state maps
    # to one bucket and one explicit next action (BC-US-115).
    steps = [
      {:enqueue_sync, "bucket-syncing", "Draft creation in progress — automatic"},
      {:sync_failed, "bucket-failed", "Investigate in the operations inbox"},
      {:retry_sync, "bucket-syncing", "Draft creation in progress — automatic"},
      {:draft_reconciled, "bucket-awaiting_approval", "Review the reconciled draft and approve"},
      {:approve, "bucket-awaiting_approval", "Book the approved draft"},
      {:book, "bucket-syncing", "Booking in progress — automatic"},
      {:booked_reconciled, "bucket-booked", "None — booked"},
      {:correction_approved, "bucket-blocked", "Complete the correction case"}
    ]

    for {event, bucket, action} <- steps do
      {:ok, _} = Billing.transition_intent(:system, intent_a, event)
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "##{bucket} #run-intent-#{intent_a.id}")
      assert has_element?(view, "##{bucket}", action)
    end

    # Not exercised on purpose: `customer_label/1`'s customer-id fallback
    # needs a frozen snapshot without legalName/externalId (freezes always
    # capture both), and `next_action/1`'s "—" fallback needs a bucket state
    # without a clause — every bucket state has one; superseded intents
    # render in their own section without a next action.
  end

  test "closing a run with unresolved intents is refused (BC-US-116)", %{
    conn: conn,
    scope: scope
  } do
    {:ok, %{run: run, invoiced: [_intent]}} =
      Billing.Scheduler.process_regular_run(scope, Date.utc_today())

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/billing-runs/#{run.id}")

    html = view |> element("#close-run-button") |> render_click()

    assert html =~ "unresolved invoice intents"
    assert render(view) =~ "open"
  end

  test "a run without intents can be closed", %{conn: conn, scope: scope} do
    # Tomorrow is not a billing boundary for a subscription that started today,
    # so the run opens with zero intents.
    tomorrow = Date.add(Date.utc_today(), 1)
    {:ok, %{run: run, invoiced: []}} = Billing.Scheduler.process_regular_run(scope, tomorrow)

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/billing-runs/#{run.id}")

    view |> element("#close-run-button") |> render_click()

    refute has_element?(view, "#close-run-button")
    assert render(view) =~ "closed"
  end
end
