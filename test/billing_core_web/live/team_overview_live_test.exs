defmodule BillingCoreWeb.TeamOverviewLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.ERP

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "shows counts and the missing-connection hint", %{conn: conn, scope: scope} do
    customer = customer_fixture(scope)
    customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id})
    subscription_fixture(scope, %{contract_id: contract.id})

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}")

    assert has_element?(view, "#stat-customers", "2")
    assert has_element?(view, "#stat-subscriptions", "1")
    assert has_element?(view, "#stat-open-runs", "0")
    assert has_element?(view, "#stat-failure-inbox", "0")
    assert has_element?(view, "#erp-connection-card", "No ERP connection")
  end

  test "shows the ERP connection status when configured", %{conn: conn, scope: scope} do
    {:ok, _connection} =
      ERP.create_connection(scope, %{provider: "fake", secret_reference: "unused"})

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}")

    assert has_element?(view, "#erp-connection-card", "fake")
    assert has_element?(view, "#erp-connection-card", "unvalidated")
  end
end
