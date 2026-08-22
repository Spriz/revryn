defmodule BillingCoreWeb.DemoLiveTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.ContractsFixtures
  import BillingCore.IdentityFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{Demo, Repo}
  alias BillingCore.Billing.Preview
  alias BillingCore.Demo.{Scenario, Workspace}
  alias BillingCore.ERP.FakeERP.InstanceSupervisor
  alias BillingCore.ERP.Sync

  test "shows only the provider proof as complete until real artifacts exist", %{conn: conn} do
    user = user_fixture()
    assert {:ok, demo} = Demo.start_workspace(user)
    on_exit(fn -> stop_if_running(demo.connection.id) end)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/teams/#{demo.team.id}/demo")

    assert has_element?(view, "#demo-workspace")
    assert has_element?(view, "#demo-connection-proof")
    assert has_element?(view, "#demo-phase-connection", "Ready")
    assert has_element?(view, "#demo-phase-commercial", "Next step")
    assert has_element?(view, "#demo-build-commercial")
    assert has_element?(view, "#demo-phase-invoice", "Upcoming")
    assert has_element?(view, "#demo-phase-credit", "Upcoming")
    assert has_element?(view, "#demo-phase-close", "Upcoming")
    assert has_element?(view, "#reset-demo")
  end

  test "building the commercial model advances the journey and links real artifacts",
       %{conn: conn} do
    user = user_fixture()
    assert {:ok, demo} = Demo.start_workspace(user)
    on_exit(fn -> stop_if_running(demo.connection.id) end)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/teams/#{demo.team.id}/demo")

    view |> element("#demo-build-commercial") |> render_click()

    assert has_element?(view, "#demo-phase-commercial", "Ready")
    refute has_element?(view, "#demo-build-commercial")

    # The links target the ordinary product surfaces holding the artifacts.
    {:ok, bundle} = Demo.active_workspace(user)
    %{commercial: %{state: :complete, refs: refs}} = Scenario.status(bundle)

    assert view
           |> element("#demo-link-plan-version")
           |> render() =~
             "/teams/#{demo.team.id}/catalog/plan-versions/#{refs["plan_version_id"]}"

    assert view
           |> element("#demo-link-customer")
           |> render() =~ "/teams/#{demo.team.id}/customers/#{refs["customer_id"]}"

    # The invoice phase unlocks and points at the subscription surface.
    assert has_element?(view, "#demo-phase-invoice", "Next step")

    assert view
           |> element("#demo-invoice-action")
           |> render() =~ "/teams/#{demo.team.id}/subscriptions/#{refs["subscription_id"]}"

    # Completion was recorded durably, not in socket state.
    assert bundle.workspace.progress["commercial_model"] == refs
  end

  test "the invoice phase renders durable sub-state and booked evidence", %{conn: conn} do
    user = user_fixture()
    assert {:ok, demo} = Demo.start_workspace(user)
    on_exit(fn -> stop_if_running(demo.connection.id) end)

    {:ok, refs} = Scenario.build_commercial_model(demo)
    scope = demo.scope
    anchor = Scenario.anchor_date(demo.workspace)

    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    {:ok, intent} = Preview.freeze(scope, preview)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/teams/#{demo.team.id}/demo")

    assert has_element?(view, "#demo-phase-invoice", "Next step")

    assert view
           |> element("#demo-invoice-action")
           |> render() =~ "/teams/#{demo.team.id}/invoices/#{intent.id}"

    # Drive the ordinary sync/approve/book commands to the booked document.
    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "demo review")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    {:ok, view, _html} = live(conn |> log_in_user(user), ~p"/teams/#{demo.team.id}/demo")

    assert has_element?(view, "#demo-phase-invoice", "Ready")
    assert has_element?(view, "#demo-invoice-evidence", "Draft")
    assert has_element?(view, "#demo-invoice-evidence", "Booked")

    assert view
           |> element("#demo-invoice-action")
           |> render() =~ "/teams/#{demo.team.id}/invoices/#{intent.id}"

    # Booking unlocks the credit phase; recording it completes phase 4.
    assert has_element?(view, "#demo-phase-credit", "Next step")

    view |> element("#demo-grant-credit") |> render_click()

    assert has_element?(view, "#demo-phase-credit", "Ready")
    assert has_element?(view, "#demo-credit-evidence", "Goodwill grant")

    assert view
           |> element("#demo-link-credit")
           |> render() =~ "/teams/#{demo.team.id}/customers/"

    # The credit unlocks the final aggregate-close phase, which guides into
    # the real credit-closes surface.
    assert has_element?(view, "#demo-phase-close", "Next step")

    assert view
           |> element("#demo-close-action")
           |> render() =~ "/teams/#{demo.team.id}/credit-closes"
  end

  test "the aggregate-close phase renders durable close sub-state and final evidence",
       %{conn: conn} do
    user = user_fixture()
    assert {:ok, demo} = Demo.start_workspace(user)
    on_exit(fn -> stop_if_running(demo.connection.id) end)

    {:ok, refs} = Scenario.build_commercial_model(demo)
    scope = demo.scope
    anchor = Scenario.anchor_date(demo.workspace)
    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    {:ok, intent} = Preview.freeze(scope, preview)
    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "demo review")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _credit_refs} = Scenario.record_customer_credit(demo)

    month_start = Date.beginning_of_month(Date.utc_today())

    {:ok, policy} =
      BillingCore.Credits.Close.create_policy(scope, %{
        version: 1,
        effective_from: month_start,
        journal_number: 1,
        liability_account_number: 2990,
        posting_mode: :single_offset,
        default_offset_account_number: 5890,
        post_zero_delta: false,
        vat_neutral: true,
        created_by: scope.user.id
      })

    {:ok, close} =
      BillingCore.Credits.CloseWorkflow.generate(scope, %{
        currency: "DKK",
        period_start: month_start,
        period_end_exclusive: Date.add(Date.end_of_month(month_start), 1),
        transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
        policy_version_id: policy.id,
        bootstrap_opening_minor: 0
      })

    {:ok, view, _html} = live(conn |> log_in_user(user), ~p"/teams/#{demo.team.id}/demo")
    assert has_element?(view, "#demo-phase-close", "Next step")

    assert view
           |> element("#demo-close-action")
           |> render() =~ "/teams/#{demo.team.id}/credit-closes/#{close.id}"

    {:ok, _approved} = BillingCore.Credits.CloseWorkflow.approve(scope, close, reason: "review")
    {:ok, _operation} = BillingCore.Credits.CloseWorkflow.request_posting(scope, close)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _closed} = BillingCore.Credits.CloseWorkflow.close_period(scope, close)

    {:ok, view, _html} = live(conn |> log_in_user(user), ~p"/teams/#{demo.team.id}/demo")
    assert has_element?(view, "#demo-phase-close", "Ready")
    assert has_element?(view, "#demo-close-evidence", "Voucher")
    assert has_element?(view, "#demo-close-evidence", "Closing liability")
  end

  test "a simulated provider rejection lands safely and recovers through ordinary retry",
       %{conn: conn} do
    user = user_fixture()
    assert {:ok, demo} = Demo.start_workspace(user)
    on_exit(fn -> stop_if_running(demo.connection.id) end)

    {:ok, refs} = Scenario.build_commercial_model(demo)
    scope = demo.scope
    anchor = Scenario.anchor_date(demo.workspace)
    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    {:ok, intent} = Preview.freeze(scope, preview)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/teams/#{demo.team.id}/demo")

    # The frozen state offers the chaos affordance; arming it audits a cause.
    assert has_element?(view, "#demo-inject-failure")
    view |> element("#demo-inject-failure") |> render_click()

    # The next draft creation fails exactly once, through the real path.
    {:ok, operation} = Sync.request_synchronization(scope, intent)
    Oban.drain_queue(queue: :erp, with_safety: false)
    assert BillingCore.Operations.get!(operation.id).state == "failed"

    {:ok, view, _html} = live(conn |> log_in_user(user), ~p"/teams/#{demo.team.id}/demo")
    assert has_element?(view, "#demo-phase-invoice", "Needs attention")
    assert has_element?(view, "#demo-failure-explainer")

    assert view
           |> element("#demo-invoice-action")
           |> render() =~ "/teams/#{demo.team.id}/operations"

    # Ordinary remediation recovers to a reconciled draft.
    {:ok, _retried} =
      Sync.retry_operation(scope, BillingCore.Operations.get!(operation.id))

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    {:ok, view, _html} = live(conn |> log_in_user(user), ~p"/teams/#{demo.team.id}/demo")
    assert has_element?(view, "#demo-phase-invoice", "Next step")
    assert has_element?(view, "#demo-invoice-evidence", "Draft")
  end

  test "reset archives evidence and navigates to a new generation", %{conn: conn} do
    user = user_fixture()
    assert {:ok, first} = Demo.start_workspace(user)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/teams/#{first.team.id}/demo")

    view |> element("#reset-demo") |> render_click()

    assert {:ok, second} = Demo.active_workspace(user)
    on_exit(fn -> stop_if_running(second.connection.id) end)
    assert second.workspace.generation == 2
    assert second.workspace.predecessor_workspace_id == first.workspace.id
    assert Repo.get!(Workspace, first.workspace.id).state == :archived
    assert_redirect(view, ~p"/teams/#{second.team.id}/demo")
  end

  test "a normal team cannot be presented as a guided workspace", %{conn: conn} do
    scope = billing_scope_fixture([:team_admin])

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn
             |> log_in_user(scope.user)
             |> live(~p"/teams/#{scope.team.id}/demo")
  end

  defp stop_if_running(connection_id) do
    case InstanceSupervisor.stop(connection_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
