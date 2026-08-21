defmodule BillingCore.Orgs.ListUserTeamsTest do
  use BillingCore.DataCase, async: true

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.Orgs

  describe "list_user_teams/1" do
    test "returns active teams across organizations with the organization preloaded" do
      user = user_fixture()
      %{organization: org_a, team: team_a} = organization_fixture(%{owner: user})
      %{organization: org_b} = organization_fixture()
      team_b = team_fixture(org_b)
      organization_membership_fixture(org_b, user)
      team_membership_fixture(team_b, user, [:auditor])

      teams = Orgs.list_user_teams(user)

      assert Enum.map(teams, & &1.id) |> Enum.sort() == Enum.sort([team_a.id, team_b.id])
      assert Enum.all?(teams, &match?(%Orgs.Organization{}, &1.organization))
      assert org_a.id in Enum.map(teams, & &1.organization_id)
    end

    test "excludes teams after the team membership is removed" do
      user = user_fixture()
      %{organization: org} = organization_fixture()
      team = team_fixture(org)
      organization_membership_fixture(org, user)
      membership = team_membership_fixture(team, user, [:auditor])

      assert [_team] = Orgs.list_user_teams(user)

      {:ok, _} = Orgs.remove_team_member(membership)
      assert Orgs.list_user_teams(user) == []
    end

    test "excludes archived teams" do
      user = user_fixture()
      %{organization: org, team: default_team} = organization_fixture(%{owner: user})
      extra_team = team_fixture(org)
      team_membership_fixture(extra_team, user, [:auditor])

      {:ok, _} = Orgs.archive_team(extra_team)

      assert [team] = Orgs.list_user_teams(user)
      assert team.id == default_team.id
    end

    test "excludes teams whose organization membership is missing" do
      user = user_fixture()
      %{organization: org} = organization_fixture()
      team = team_fixture(org)

      # No organization membership at all → no team access (SPEC §13.4);
      # a direct team membership cannot even be granted without one.
      assert {:error, :not_organization_member} = Orgs.add_team_member(team, user, [:auditor])
      assert Orgs.list_user_teams(user) == []
    end
  end
end
