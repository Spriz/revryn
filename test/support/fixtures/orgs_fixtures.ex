defmodule BillingCore.OrgsFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Orgs` context.
  """

  import BillingCore.IdentityFixtures

  alias BillingCore.Orgs

  @doc "A unique organization name (slug derives uniquely from it)."
  def unique_organization_name, do: "Org #{System.unique_integer([:positive])}"

  @doc """
  Creates an organization via `Orgs.create_organization/2`.

  Returns `%{organization: _, team: _, organization_membership: _,
  team_membership: _, owner: _}` — the initial team plus the creator's
  owner/team-admin memberships. Pass `:owner` to use an existing user; all
  other keys are forwarded as creation attrs.
  """
  def organization_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {owner, attrs} = Map.pop_lazy(attrs, :owner, fn -> user_fixture() end)
    attrs = Map.put_new(attrs, :name, unique_organization_name())

    {:ok, result} = Orgs.create_organization(attrs, owner)
    Map.put(result, :owner, owner)
  end

  @doc "Creates an additional active team in `organization`."
  def team_fixture(organization, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:name, "Team #{System.unique_integer([:positive])}")

    {:ok, team} = Orgs.create_team(organization, attrs)
    team
  end

  @doc "Grants `user` an active organization membership."
  def organization_membership_fixture(organization, user, roles \\ [:organization_member]) do
    {:ok, membership} = Orgs.add_organization_member(organization, user, roles)
    membership
  end

  @doc "Grants `user` an active team membership (requires org membership)."
  def team_membership_fixture(team, user, roles \\ [:auditor]) do
    {:ok, membership} = Orgs.add_team_member(team, user, roles)
    membership
  end

  @doc "Creates an organization-scoped account."
  def account_fixture(organization, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:external_id, "acct-#{System.unique_integer([:positive])}")
      |> Map.put_new(:display_name, "Account #{System.unique_integer([:positive])}")

    {:ok, account} = Orgs.create_account(organization, attrs)
    account
  end
end
