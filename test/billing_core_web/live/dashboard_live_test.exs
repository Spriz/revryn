defmodule BillingCoreWeb.DashboardLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  describe "dashboard" do
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
  end
end
