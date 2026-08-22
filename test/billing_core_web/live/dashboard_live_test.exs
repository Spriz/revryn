defmodule BillingCoreWeb.DashboardLiveTest do
  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.Demo
  alias BillingCore.ERP.FakeERP.InstanceSupervisor

  describe "dashboard" do
    test "an organization admin creates an additional team inline (BC-US-141)", %{conn: conn} do
      user = user_fixture()
      %{organization: organization, team: _team} = organization_fixture(%{owner: user})

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/")
      assert has_element?(view, "#new-team-form-#{organization.id}")

      result =
        view
        |> form("#new-team-form-#{organization.id}", %{
          "organization_id" => organization.id,
          "name" => "Drift"
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/teams/" <> team_id}}} = result

      team = BillingCore.Repo.get!(BillingCore.Orgs.Team, team_id)
      assert team.name == "Drift"
      assert team.organization_id == organization.id

      # The creator became the new team's admin and can resolve scope.
      assert {:ok, scope} = BillingCore.Orgs.resolve_scope(user, organization.id, team.id)
      assert scope.team_roles == [:team_admin]
    end

    test "a plain member sees no team-creation affordance", %{conn: conn} do
      user = user_fixture()
      %{organization: organization, team: team} = organization_fixture()
      organization_membership_fixture(organization, user, [:organization_member])
      team_membership_fixture(team, user, [:auditor])

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/")
      refute has_element?(view, "#new-team-form-#{organization.id}")

      # A crafted event is refused as well.
      render_submit(view, "create_team", %{
        "organization_id" => organization.id,
        "name" => "Sneaky"
      })

      refute BillingCore.Repo.get_by(BillingCore.Orgs.Team,
               organization_id: organization.id,
               name: "Sneaky"
             )
    end

    test "lists the user's teams grouped by organization", %{conn: conn} do
      user = user_fixture()
      %{organization: org_a, team: team_a} = organization_fixture(%{owner: user})
      %{organization: org_b} = organization_fixture()
      team_b = team_fixture(org_b)
      organization_membership_fixture(org_b, user)
      team_membership_fixture(team_b, user, [:finance_operator])

      {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/")

      assert html =~ org_a.name
      assert html =~ org_b.name
      assert has_element?(view, "#team-link-#{team_a.id}")
      assert has_element?(view, "#team-link-#{team_b.id}")
    end

    test "shows an empty state for a user without teams", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/")

      assert has_element?(view, "#no-teams")
      assert has_element?(view, "#explore-demo[href='/start']")
      assert has_element?(view, "#real-workspace-path")
    end

    test "does not list teams whose membership was removed", %{conn: conn} do
      user = user_fixture()
      %{organization: org} = organization_fixture()
      team = team_fixture(org)
      organization_membership_fixture(org, user)
      membership = team_membership_fixture(team, user, [:auditor])
      {:ok, _} = BillingCore.Orgs.remove_team_member(membership)

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/")

      refute has_element?(view, "#team-link-#{team.id}")
    end

    test "offers the exact active demo generation to returning users", %{conn: conn} do
      user = user_fixture()
      assert {:ok, demo} = Demo.start_workspace(user)
      on_exit(fn -> stop_if_running(demo.connection.id) end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/")

      assert has_element?(view, "#active-demo-workspace")
      assert has_element?(view, "#resume-demo[href='/teams/#{demo.team.id}/demo']")
    end
  end

  defp stop_if_running(connection_id) do
    case InstanceSupervisor.stop(connection_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
