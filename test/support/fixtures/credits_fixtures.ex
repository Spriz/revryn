defmodule BillingCore.CreditsFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Credits` context.
  """

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.Credits
  alias BillingCore.Orgs

  @doc """
  Certifies a receivable-settlement mode for the scope's team by creating a
  currently effective close posting-policy version (SPEC §9.4.1). Automatic
  credit application stays blocked until a test calls this.
  """
  def settlement_policy_fixture(scope, opts \\ []) do
    mode = Keyword.get(opts, :settlement_mode, :external_reference)

    attrs = %{
      version: System.unique_integer([:positive]),
      effective_from: Date.utc_today() |> Date.beginning_of_month(),
      journal_number: Keyword.get(opts, :journal_number, 1),
      liability_account_number: Keyword.get(opts, :liability_account_number, 2990),
      posting_mode: :single_offset,
      default_offset_account_number: 5890,
      vat_neutral: true,
      settlement_mode: mode,
      settlement_clearing_account_number:
        Keyword.get(opts, :settlement_clearing_account_number, settlement_default(mode, 5820)),
      settlement_contra_account_number:
        Keyword.get(opts, :settlement_contra_account_number, settlement_default(mode, 5821)),
      created_by: scope.user && scope.user.id
    }

    {:ok, policy} = BillingCore.Credits.Close.create_policy(scope, attrs)
    policy
  end

  defp settlement_default(:erp_customer_settlement, account), do: account
  defp settlement_default(_mode, _account), do: nil

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
