defmodule BillingCoreWeb.SettingsLiveTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  test "shows team configuration", %{conn: conn, scope: scope} do
    {:ok, view, html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    assert html =~ scope.team.legal_name
    assert has_element?(view, "#team-settings-card", scope.team.base_currency)
    assert has_element?(view, "#new-connection-form")
  end

  test "creates only an e-conomic connection from the real workspace settings path",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    refute has_element?(view, "#new-connection-form option[value='fake']")

    view
    |> form("#new-connection-form",
      connection: %{provider: "economic", secret_reference: "unused"}
    )
    |> render_submit()

    assert has_element?(view, "#connection-status-badge", "unvalidated")
    assert has_element?(view, "#validate-connection")
    assert {:ok, connection} = BillingCore.ERP.get_connection(scope)
    assert connection.provider == "economic"
  end

  test "configures raw-usage retention with the 90-day floor", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    assert has_element?(view, "#retention-settings-form")

    # A value below the floor is clamped, not accepted (SPEC §20: dispute
    # and audit needs outrank storage preferences).
    view
    |> form("#retention-settings-form", retention: %{raw_usage_retention_days: "30"})
    |> render_submit()

    snapshot = BillingCore.Orgs.current_team_settings(scope.team)
    assert snapshot.settings["raw_usage_retention_days"] == 90

    # Clearing the field removes the configuration entirely.
    view
    |> form("#retention-settings-form", retention: %{raw_usage_retention_days: ""})
    |> render_submit()

    snapshot = BillingCore.Orgs.current_team_settings(scope.team)
    refute Map.has_key?(snapshot.settings, "raw_usage_retention_days")
  end
end
