defmodule BillingCore.Orgs.MembershipTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Orgs}
  alias BillingCore.Orgs.OrganizationMembership

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  describe "organization memberships" do
    test "a user can hold at most one active membership per organization" do
      %{organization: org} = organization_fixture()
      user = user_fixture()

      assert {:ok, _} = Orgs.add_organization_member(org, user, [:organization_member])

      assert {:error, :already_member} =
               Orgs.add_organization_member(org, user, [:organization_admin])
    end

    test "a removed membership can be re-granted with a fresh row" do
      %{organization: org} = organization_fixture()
      user = user_fixture()

      {:ok, membership} = Orgs.add_organization_member(org, user, [:organization_member])
      {:ok, removed} = Orgs.remove_organization_member(membership)
      assert removed.status == :removed

      assert {:ok, fresh} = Orgs.add_organization_member(org, user, [:organization_admin])
      assert fresh.id != membership.id
      assert fresh.roles == [:organization_admin]
    end

    test "roles must be canonical and non-empty" do
      %{organization: org} = organization_fixture()
      user = user_fixture()

      assert {:error, %Ecto.Changeset{}} = Orgs.add_organization_member(org, user, [:superuser])
      assert {:error, %Ecto.Changeset{}} = Orgs.add_organization_member(org, user, [])
    end

    test "role changes work while another active owner remains, and are audited" do
      %{organization: org, owner: owner} = organization_fixture()
      second = user_fixture()
      {:ok, _} = Orgs.add_organization_member(org, second, [:organization_owner])

      membership =
        Repo.get_by!(OrganizationMembership, organization_id: org.id, user_id: owner.id)

      assert {:ok, updated} = Orgs.change_organization_roles(membership, [:organization_admin])
      assert updated.roles == [:organization_admin]

      assert [entry] =
               Repo.all(
                 from e in Audit.Entry,
                   where: e.event_type == "orgs.organization_membership.roles_changed"
               )

      assert entry.payload["from"] == ["organization_owner"]
      assert entry.payload["to"] == ["organization_admin"]
    end
  end

  describe "team memberships" do
    test "require an active organization membership" do
      %{team: team} = organization_fixture()
      outsider = user_fixture()

      assert {:error, :not_organization_member} =
               Orgs.add_team_member(team, outsider, [:auditor])
    end

    test "a suspended organization membership does not qualify" do
      %{organization: org, team: team} = organization_fixture()
      user = user_fixture()
      {:ok, membership} = Orgs.add_organization_member(org, user, [:organization_member])
      Repo.update!(Ecto.Changeset.change(membership, status: :suspended))

      assert {:error, :not_organization_member} = Orgs.add_team_member(team, user, [:auditor])
    end

    test "at most one active membership per team, re-grantable after removal" do
      %{organization: org, team: team} = organization_fixture()
      user = user_fixture()
      {:ok, _} = Orgs.add_organization_member(org, user, [:organization_member])

      {:ok, membership} = Orgs.add_team_member(team, user, [:auditor])
      assert {:error, :already_member} = Orgs.add_team_member(team, user, [:billing_admin])

      {:ok, _} = Orgs.remove_team_member(membership)
      assert {:ok, fresh} = Orgs.add_team_member(team, user, [:billing_admin])
      assert fresh.roles == [:billing_admin]
    end

    test "role changes are applied and audited" do
      %{organization: org, team: team} = organization_fixture()
      user = user_fixture()
      {:ok, _} = Orgs.add_organization_member(org, user, [:organization_member])
      {:ok, membership} = Orgs.add_team_member(team, user, [:auditor])

      assert {:ok, updated} =
               Orgs.change_team_roles(membership, [:finance_operator, :auditor])

      assert updated.roles == [:finance_operator, :auditor]

      assert [entry] =
               Repo.all(
                 from e in Audit.Entry,
                   where: e.event_type == "orgs.team_membership.roles_changed"
               )

      assert entry.team_id == team.id
      assert entry.payload["to"] == ["finance_operator", "auditor"]
    end

    test "operations on non-active memberships are refused" do
      %{organization: org, team: team} = organization_fixture()
      user = user_fixture()
      {:ok, _} = Orgs.add_organization_member(org, user, [:organization_member])
      {:ok, membership} = Orgs.add_team_member(team, user, [:auditor])
      {:ok, removed} = Orgs.remove_team_member(membership)

      assert {:error, :not_active} = Orgs.remove_team_member(removed)
      assert {:error, :not_active} = Orgs.change_team_roles(removed, [:auditor])
    end
  end
end
