defmodule BillingCore.CreditsFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Credits` context.
  """

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.Credits
  alias BillingCore.Orgs

  @doc """
  A complete credit test context: a team-resolved scope (default role
  `:finance_operator`), an organization-scoped commercial account, and its
  credit account (default currency `"DKK"`).

  Returns `%{scope:, organization:, team:, account:, credit_account:}`.
  """
  def credit_context_fixture(opts \\ []) do
    roles = Keyword.get(opts, :roles, [:finance_operator])
    currency = Keyword.get(opts, :currency, "DKK")

    %{organization: organization, team: team} = organization_fixture()
    scope = team_scope_fixture(organization, team, roles)

    # account setup needs a mutation role, independent of the requested roles
    setup_scope =
      if :finance_operator in roles or :billing_admin in roles do
        scope
      else
        team_scope_fixture(organization, team, [:finance_operator])
      end

    account = account_fixture(organization)
    {:ok, credit_account} = Credits.get_or_create_account(setup_scope, account.id, currency)

    %{
      scope: scope,
      organization: organization,
      team: team,
      account: account,
      credit_account: credit_account
    }
  end

  @doc "A team-resolved scope for a new user with `roles` in an existing team."
  def team_scope_fixture(organization, team, roles) do
    user = user_fixture()
    organization_membership_fixture(organization, user, [:organization_member])
    team_membership_fixture(team, user, roles)
    {:ok, scope} = Orgs.resolve_scope(user, organization.id, team.id)
    scope
  end

  @doc "Creates (or fetches) a credit account for an existing commercial account."
  def credit_account_fixture(scope, account, currency \\ "DKK") do
    {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, currency)
    credit_account
  end

  @doc "Grants credit onto `credit_account`; override any attr."
  def grant_fixture(scope, credit_account, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:credit_account_id, credit_account.id)
      |> Map.put_new(:origin_type, "manual")
      |> Map.put_new(:amount_minor, 10_000)
      |> Map.put_new(:currency, credit_account.currency)
      |> Map.put_new(:idempotency_key, "grant-#{System.unique_integer([:positive])}")

    {:ok, grant} = Credits.grant_credit(scope, attrs)
    grant
  end
end
