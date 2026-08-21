defmodule BillingCore.Orgs.AccountsTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Orgs}
  alias BillingCore.Orgs.AccountTeamCustomer

  import BillingCore.OrgsFixtures

  describe "accounts (BC-US-142)" do
    test "create_account/3 stores an organization-scoped identity" do
      %{organization: org} = organization_fixture()

      assert {:ok, account} =
               Orgs.create_account(org, %{
                 external_id: "crm-4711",
                 display_name: "Vestergaard Byg ApS",
                 metadata: %{"cvr" => "12345678"}
               })

      assert account.organization_id == org.id
      assert account.status == :active
      assert account.metadata == %{"cvr" => "12345678"}

      assert [_entry] =
               Repo.all(from e in Audit.Entry, where: e.event_type == "orgs.account.created")
    end

    test "external_id is unique per organization but free across organizations" do
      %{organization: org_a} = organization_fixture()
      %{organization: org_b} = organization_fixture()

      assert {:ok, _} = Orgs.create_account(org_a, %{external_id: "x-1", display_name: "A"})

      assert {:error, %Ecto.Changeset{}} =
               Orgs.create_account(org_a, %{external_id: "x-1", display_name: "A again"})

      assert {:ok, _} = Orgs.create_account(org_b, %{external_id: "x-1", display_name: "B"})
    end

    test "update_account/3 and archive_account/2" do
      %{organization: org} = organization_fixture()
      account = account_fixture(org)

      assert {:ok, updated} = Orgs.update_account(account, %{display_name: "Renamed"})
      assert updated.display_name == "Renamed"

      assert {:ok, archived} = Orgs.archive_account(updated)
      assert archived.status == :archived

      # idempotent
      assert {:ok, ^archived} = Orgs.archive_account(archived)
    end
  end

  describe "project_account_to_team/4" do
    test "creates a team-local customer projection and upserts on repeat" do
      %{organization: org, team: team} = organization_fixture()
      account = account_fixture(org)
      customer_id = Ecto.UUID.generate()

      assert {:ok, projection} = Orgs.project_account_to_team(account, team, customer_id)
      assert projection.account_id == account.id
      assert projection.team_id == team.id
      assert projection.customer_id == customer_id

      # re-projecting replaces the customer mapping, still one row per (account, team)
      replacement_id = Ecto.UUID.generate()
      assert {:ok, replaced} = Orgs.project_account_to_team(account, team, replacement_id)
      assert replaced.customer_id == replacement_id

      assert Repo.aggregate(
               from(p in AccountTeamCustomer,
                 where: p.account_id == ^account.id and p.team_id == ^team.id
               ),
               :count
             ) == 1
    end

    test "one account can project into several teams independently" do
      %{organization: org, team: team_1} = organization_fixture()
      team_2 = team_fixture(org)
      account = account_fixture(org)

      {:ok, p1} = Orgs.project_account_to_team(account, team_1, Ecto.UUID.generate())
      {:ok, p2} = Orgs.project_account_to_team(account, team_2, Ecto.UUID.generate())

      assert p1.customer_id != p2.customer_id
    end

    test "refuses a team from another organization (SPEC §13.4)" do
      %{organization: org_a} = organization_fixture()
      %{team: team_b} = organization_fixture()
      account = account_fixture(org_a)

      assert {:error, :cross_organization} =
               Orgs.project_account_to_team(account, team_b, Ecto.UUID.generate())

      assert Repo.aggregate(AccountTeamCustomer, :count) == 0
    end
  end
end
