defmodule BillingCore.Credits.CustomerAccountsTest do
  @moduledoc "Customer → credit-account listing for the LiveView surface (BC-US-108)."

  use BillingCore.DataCase, async: true

  import BillingCore.ContractsFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Credits, Orgs}

  test "list_accounts_for_customer/2 resolves through account_team_customers" do
    scope = billing_scope_fixture([:billing_admin, :finance_operator])
    customer = customer_fixture(scope)

    assert {:ok, []} = Credits.list_accounts_for_customer(scope, customer.id)

    account = account_fixture(scope.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, scope.team, customer.id)
    {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")

    assert {:ok, [listed]} = Credits.list_accounts_for_customer(scope, customer.id)
    assert listed.id == credit_account.id
    assert listed.currency == "DKK"
  end

  test "another team's scope cannot see the accounts" do
    scope = billing_scope_fixture([:billing_admin, :finance_operator])
    customer = customer_fixture(scope)
    account = account_fixture(scope.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, scope.team, customer.id)
    {:ok, _credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")

    other_scope = billing_scope_fixture([:finance_operator])
    assert {:ok, []} = Credits.list_accounts_for_customer(other_scope, customer.id)
  end
end
