defmodule BillingCoreWeb.SettingsLiveTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.ERP
  alias BillingCore.ERP.FakeERP

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  defp start_fake_erp(opts \\ []) do
    fake = start_supervised!({FakeERP, opts})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)
    fake
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

  test "a validated connection shows its evidence and revalidates on demand",
       %{conn: conn, scope: scope} do
    _fake = start_fake_erp()
    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, _} = ERP.validate_connection(scope, connection)

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    # The persisted preflight evidence renders on mount (BC-US-004).
    assert has_element?(view, "#connection-status-badge", "active")
    assert render(view) =~ "Last validated"
    assert has_element?(view, "#preflight-checks", "agreement")
    assert has_element?(view, "#preflight-checks", "api_health")

    html = view |> element("#validate-connection") |> render_click()
    assert html =~ "Connection validated — all checks passed."
    assert has_element?(view, "#connection-status-badge", "active")
  end

  test "failing preflight checks mark the connection action_required", %{conn: conn, scope: scope} do
    _fake =
      start_fake_erp(
        preflight_checks: [
          %{check: :agreement, status: :fail, detail: "agreement not accessible"}
        ]
      )

    {:ok, _connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    html = view |> element("#validate-connection") |> render_click()
    assert html =~ "Validation found failing checks — the connection needs attention."
    assert has_element?(view, "#connection-status-badge", "action required")
    assert has_element?(view, "#preflight-checks", "agreement not accessible")
  end

  test "a provider error during validation lands as a flash", %{conn: conn, scope: scope} do
    fake = start_fake_erp()
    {:ok, _connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    FakeERP.inject_failure(fake, :capabilities, {:error, {:provider_failure, %{status: 502}}})

    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    html = view |> element("#validate-connection") |> render_click()
    assert html =~ "The command failed:"
    assert has_element?(view, "#connection-status-badge", "unvalidated")
  end

  test "an unresolvable secret reference fails validation without crashing the page",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/settings")

    view
    |> form("#new-connection-form",
      connection: %{
        provider: "economic",
        secret_reference: "MISSING_SECRET_REF",
        external_agreement_id: "123456"
      }
    )
    |> render_submit()

    assert has_element?(view, "#validate-connection")

    html = view |> element("#validate-connection") |> render_click()
    assert html =~ "Validation failed:"
    assert html =~ "MISSING_SECRET_REF"
    assert has_element?(view, "#connection-status-badge", "unvalidated")

    # A second e-conomic connection for the same team is refused by the
    # domain even though the form is no longer rendered (and an absent
    # agreement id normalizes to nil).
    html =
      render_submit(view, "create_connection", %{
        "connection" => %{"secret_reference" => "ANOTHER_REF"}
      })

    assert html =~ "It already exists."
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
