defmodule BillingCore.Workflows.OrganizationLifecycleTest do
  @moduledoc """
  Organization/team lifecycle as documentation (BC-US-140/141, INV-033,
  SPEC §9.1.1): an organization is born with one team and one owner in a
  single transaction, teams may be renamed and archived freely — except the
  final active team — and owners can only leave once ownership and team
  memberships are resolved.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.Audit
  alias BillingCore.Orgs
  alias BillingCore.Orgs.{Organization, OrganizationMembership, Team, TeamMembership}

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  describe "creating an organization (BC-US-140)" do
    test "atomically creates the organization, its first team, and the creator's memberships" do
      creator = user_fixture()

      assert {:ok,
              %{
                organization: org,
                team: team,
                organization_membership: om,
                team_membership: tm
              }} = Orgs.create_organization(%{name: "Acme A/S"}, creator)

      # the organization is never observable with zero active teams
      assert org.status == :active
      assert org.slug == "acme-a-s"
      assert [%Team{id: team_id}] = Orgs.list_active_teams(org)
      assert team_id == team.id

      # the initial team is a fully usable billing scope with defaults
      assert team.organization_id == org.id
      assert team.name == "Default"
      assert team.slug == "default"
      assert team.legal_name == "Acme A/S"
      assert team.base_currency == "DKK"
      assert team.time_zone == "Europe/Copenhagen"
      assert team.locale == "da-DK"
      assert team.status == :active
      assert team.settings_version == 1
      assert %{version: 1} = Orgs.current_team_settings(team)

      # the creator owns the organization and administers the initial team
      assert om.user_id == creator.id
      assert om.roles == [:organization_owner]
      assert om.status == :active
      assert tm.user_id == creator.id
      assert tm.roles == [:team_admin]
      assert tm.status == :active

      # everything is audited in the same transaction
      events = audit_events(org.id)
      assert "orgs.organization.created" in events
      assert "orgs.team.created" in events
      assert "orgs.organization_membership.created" in events
      assert "orgs.team_membership.created" in events
    end

    test "a custom initial team name is honored" do
      creator = user_fixture()

      assert {:ok, %{team: team}} =
               Orgs.create_organization(
                 %{name: "Custom Corp", team_name: "Nordics"},
                 creator
               )

      assert team.name == "Nordics"
      assert team.slug == "nordics"
    end

    test "a failing step rolls back the whole creation — no partial organization" do
      creator = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Orgs.create_organization(
                 %{name: "Rollback Corp", team_slug: "NOT A SLUG"},
                 creator
               )

      assert Repo.aggregate(Organization, :count) == 0
      assert Repo.aggregate(Team, :count) == 0
      assert Repo.aggregate(OrganizationMembership, :count) == 0
    end
  end

  describe "renaming the bootstrap team (BC-US-140)" do
    test "renaming Default keeps its stable identity, and no rule branches on the name" do
      %{team: team} = organization_fixture()

      assert {:ok, renamed} = Orgs.rename_team(team, "Nordics Billing")
      assert renamed.id == team.id
      assert renamed.slug == team.slug
      assert renamed.name == "Nordics Billing"

      # the last-active-team invariant holds regardless of what it is called
      assert {:error, :last_active_team} = Orgs.archive_team(renamed)
    end
  end

  describe "archiving teams (BC-US-141, INV-033)" do
    test "the final active team of an active organization cannot be archived" do
      %{team: team} = organization_fixture()

      assert {:error, :last_active_team} = Orgs.archive_team(team)
      assert Orgs.get_team!(team.id).status == :active
    end

    test "a non-final team archives cleanly, then the survivor becomes protected" do
      %{organization: org, team: default_team} = organization_fixture()
      second = team_fixture(org, %{name: "Second"})

      assert {:ok, archived} = Orgs.archive_team(second)
      assert archived.status == :disabled
      assert "orgs.team.archived" in audit_events(org.id)

      # already-archived team cannot be archived again
      assert {:error, :not_active} = Orgs.archive_team(archived)

      # the remaining team is now the final active one
      assert {:error, :last_active_team} = Orgs.archive_team(default_team)
    end

    test "second team lifecycle: create, staff, rename, archive" do
      %{organization: org} = organization_fixture()
      member = user_fixture()
      {:ok, _om} = Orgs.add_organization_member(org, member, [:organization_member])

      {:ok, team} = Orgs.create_team(org, %{name: "Billing DK"})
      assert team.status == :active
      assert %{version: 1} = Orgs.current_team_settings(team)

      {:ok, _tm} = Orgs.add_team_member(team, member, [:billing_admin])
      assert {:ok, scope} = Orgs.resolve_scope(member, org.id, team.id)
      assert scope.team_roles == [:billing_admin]

      {:ok, team} = Orgs.rename_team(team, "Billing Denmark")

      assert {:ok, team} = Orgs.archive_team(team)
      assert team.status == :disabled

      # archived teams no longer resolve as a scope
      assert {:error, :unauthorized} = Orgs.resolve_scope(member, org.id, team.id)
    end
  end

  describe "organization membership lifecycle (BC-US-141/143)" do
    test "the last active owner can be neither removed nor demoted" do
      %{organization: org, owner: owner} = organization_fixture()

      om =
        Repo.get_by!(OrganizationMembership, organization_id: org.id, user_id: owner.id)

      assert {:error, :last_owner} = Orgs.remove_organization_member(om)
      assert {:error, :last_owner} = Orgs.change_organization_roles(om, [:organization_admin])

      assert Orgs.get_organization!(org.id)
      assert Repo.get!(OrganizationMembership, om.id).status == :active
    end

    test "removing a member requires resolving their team memberships first" do
      %{organization: org, owner: owner, team: team} = organization_fixture()
      second_owner = user_fixture()
      {:ok, _} = Orgs.add_organization_member(org, second_owner, [:organization_owner])

      om =
        Repo.get_by!(OrganizationMembership, organization_id: org.id, user_id: owner.id)

      # the original owner still administers the initial team
      assert {:error, :active_team_memberships} = Orgs.remove_organization_member(om)

      tm = Repo.get_by!(TeamMembership, team_id: team.id, user_id: owner.id)
      assert {:ok, removed_tm} = Orgs.remove_team_member(tm)
      assert removed_tm.status == :removed

      assert {:ok, removed_om} = Orgs.remove_organization_member(om)
      assert removed_om.status == :removed

      # membership history is retained but access is gone
      assert Repo.get!(OrganizationMembership, om.id).status == :removed
      assert {:error, :unauthorized} = Orgs.resolve_scope(owner, org.id)

      assert "orgs.team_membership.removed" in audit_events(org.id)
      assert "orgs.organization_membership.removed" in audit_events(org.id)
    end
  end

  defp audit_events(organization_id) do
    Repo.all(
      from e in Audit.Entry,
        where: e.organization_id == ^organization_id,
        select: e.event_type
    )
  end
end
