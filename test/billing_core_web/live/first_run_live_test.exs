defmodule BillingCoreWeb.FirstRunLiveTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.IdentityFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.Demo
  alias BillingCore.ERP.FakeERP.InstanceSupervisor

  test "presents a specific choice between isolated sample books and real ERP setup", %{
    conn: conn
  } do
    user = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/start")

    assert has_element?(view, "#first-run")
    assert has_element?(view, "#demo-erp-path")
    assert has_element?(view, "#real-erp-path")
    assert has_element?(view, "#start-demo-workspace")
    refute has_element?(view, "#resume-demo-workspace")
  end

  test "starts through the Demo context and resumes the same durable generation", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/start")
    view |> element("#start-demo-workspace") |> render_click()

    assert {:ok, first} = Demo.active_workspace(user)
    on_exit(fn -> stop_if_running(first.connection.id) end)
    assert_redirect(view, ~p"/teams/#{first.team.id}/demo")

    {:ok, resumed_view, _html} = live(conn, ~p"/start")
    assert has_element?(resumed_view, "#resume-demo-workspace")
    refute has_element?(resumed_view, "#start-demo-workspace")

    assert {:ok, resumed} = Demo.resume_workspace(user)
    assert resumed.workspace.id == first.workspace.id
    assert resumed.connection.id == first.connection.id
  end

  test "the real path creates a workspace and lands on the new team (BC-US-140)",
       %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn |> log_in_user(user) |> live(~p"/start")

    assert has_element?(view, "#create-workspace-form")

    result =
      view
      |> form("#create-workspace-form", %{
        "workspace" => %{
          "name" => "Fjeldsted Consulting",
          "team_name" => "Økonomi",
          "base_currency" => "EUR",
          "legal_name" => "Fjeldsted Consulting ApS"
        }
      })
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/teams/" <> team_id}}} = result

    {:ok, scope} =
      BillingCore.Orgs.resolve_scope(
        user,
        BillingCore.Repo.get!(BillingCore.Orgs.Team, team_id).organization_id,
        team_id
      )

    assert scope.team.name == "Økonomi"
    assert scope.team.base_currency == "EUR"
    assert scope.team.legal_name == "Fjeldsted Consulting ApS"
    assert scope.organization_roles == [:organization_owner]
    assert scope.team_roles == [:team_admin]
  end

  defp stop_if_running(connection_id) do
    case InstanceSupervisor.stop(connection_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
