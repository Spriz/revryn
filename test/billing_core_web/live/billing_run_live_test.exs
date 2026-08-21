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

    %{conn: log_in_user(conn, scope.user), scope: scope, subscription: subscription}
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
