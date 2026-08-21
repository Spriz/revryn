defmodule BillingCoreWeb.SettingsLiveTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.ERP.FakeERP

  setup %{conn: conn} do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    %{conn: log_in_user(conn, scope.user), scope: scope, fake: fake}
  end

  test "shows team configuration", %{conn: conn, scope: scope} do
    {:ok, view, html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    assert html =~ scope.team.legal_name
    assert has_element?(view, "#team-settings-card", scope.team.base_currency)
    assert has_element?(view, "#new-connection-form")
  end

  test "creates and validates an ERP connection rendering preflight checks (BC-US-003/004)",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    view
    |> form("#new-connection-form",
      connection: %{provider: "fake", secret_reference: "unused"}
    )
    |> render_submit()

    assert has_element?(view, "#connection-status-badge", "unvalidated")
    assert has_element?(view, "#validate-connection")

    view |> element("#validate-connection") |> render_click()

    assert has_element?(view, "#connection-status-badge", "active")
    assert has_element?(view, "#preflight-checks")
    assert has_element?(view, "#preflight-checks", "pass")
  end

  test "a failing preflight check moves the connection to action_required",
       %{conn: conn, scope: scope, fake: fake} do
    FakeERP.set_preflight_checks(fake, [
      %{check: :credentials, status: :pass, detail: "ok"},
      %{check: :vat_zones, status: :fail, detail: "missing zone mapping"}
    ])

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    view
    |> form("#new-connection-form",
      connection: %{provider: "fake", secret_reference: "unused"}
    )
    |> render_submit()

    view |> element("#validate-connection") |> render_click()

    assert has_element?(view, "#connection-status-badge", "action required")
    assert has_element?(view, "#preflight-checks", "missing zone mapping")
  end
end
