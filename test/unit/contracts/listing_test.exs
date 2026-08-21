defmodule BillingCore.Contracts.ListingTest do
  @moduledoc "Read-only listing helpers added for the LiveView surfaces."

  use BillingCore.DataCase, async: true

  import BillingCore.ContractsFixtures

  alias BillingCore.Contracts
  alias BillingCore.ERP

  setup do
    %{scope: billing_scope_fixture([:billing_admin, :finance_operator])}
  end

  test "count_customers/1 counts only the scope's team", %{scope: scope} do
    customer_fixture(scope)
    customer_fixture(scope)
    other_scope = billing_scope_fixture()
    customer_fixture(other_scope)

    assert {:ok, 2} = Contracts.count_customers(scope)
    assert {:ok, 1} = Contracts.count_customers(other_scope)
  end

  test "list_contracts/2 filters by customer", %{scope: scope} do
    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id})
    _other_contract = contract_fixture(scope)

    assert {:ok, [only]} = Contracts.list_contracts(scope, customer_id: customer.id)
    assert only.id == contract.id

    assert {:ok, contracts} = Contracts.list_contracts(scope)
    assert length(contracts) == 2
  end

  test "list_subscriptions/2 filters by contract and status", %{scope: scope} do
    contract = contract_fixture(scope)
    subscription = subscription_fixture(scope, %{contract_id: contract.id})
    _elsewhere = subscription_fixture(scope)

    assert {:ok, [only]} = Contracts.list_subscriptions(scope, contract_id: contract.id)
    assert only.id == subscription.id

    assert {:ok, active} = Contracts.list_subscriptions(scope, status: :active)
    assert length(active) == 2
    assert {:ok, []} = Contracts.list_subscriptions(scope, status: :paused)
  end

  test "count_subscriptions/2 counts by status", %{scope: scope} do
    subscription = subscription_fixture(scope)
    assert {:ok, 1} = Contracts.count_subscriptions(scope, :active)

    {:ok, _} = Contracts.pause_subscription(scope, subscription)
    assert {:ok, 0} = Contracts.count_subscriptions(scope, :active)
    assert {:ok, 1} = Contracts.count_subscriptions(scope, :paused)
  end

  test "get_subscription_by_external_id/2 is team-scoped", %{scope: scope} do
    subscription = subscription_fixture(scope)

    assert {:ok, found} =
             Contracts.get_subscription_by_external_id(scope, subscription.external_id)

    assert found.id == subscription.id

    other_scope = billing_scope_fixture()

    assert {:error, :not_found} =
             Contracts.get_subscription_by_external_id(other_scope, subscription.external_id)
  end

  test "list_customer_erp_mappings/2 returns the customer's mappings", %{scope: scope} do
    customer = customer_fixture(scope)
    assert {:ok, []} = Contracts.list_customer_erp_mappings(scope, customer)

    {:ok, connection} =
      ERP.create_connection(scope, %{provider: "fake", secret_reference: "unused"})

    {:ok, _mapping} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    assert {:ok, [mapping]} = Contracts.list_customer_erp_mappings(scope, customer)
    assert mapping.external_customer_number == "1001"
  end
end
