defmodule BillingCore.Workflows.CreditApplicationTest do
  @moduledoc """
  Workflow documentation: available customer credit is applied automatically
  before new money is due (SPEC BC-US-108, INV-050/051/052).
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Contracts, Credits, Orgs}
  alias BillingCore.Billing.Preview

  setup do
    %{organization: organization, team: team} = organization_fixture()

    scope =
      team_scope_fixture(organization, team, [:team_admin, :billing_admin, :finance_operator])

    plan_version =
      published_plan_version_fixture(scope,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        amount: "1000.00"
      )

    customer = customer_fixture(scope)
    account = account_fixture(organization)
    {:ok, _} = Orgs.project_account_to_team(account, team, customer.id)

    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")

    %{scope: scope, subscription: subscription, credit_account: credit_account}
  end

  defp grant!(scope, credit_account, amount) do
    {:ok, grant} =
      Credits.grant_credit(scope, %{
        credit_account_id: credit_account.id,
        origin_type: "unused_prepaid_service",
        amount_minor: amount,
        currency: "DKK",
        idempotency_key: "grant-#{System.unique_integer([:positive])}"
      })

    grant
  end

  test "preview shows gross, credit applied, and remaining due; freeze spends the credit exactly once",
       %{scope: scope, subscription: subscription, credit_account: credit_account} do
    grant!(scope, credit_account, 30_000)

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-01])

    # Gross DKK 1,000.00; credit DKK 300.00; due DKK 700.00 — shown separately.
    assert preview.net_amount_minor == 100_000
    assert preview.credit_available_minor == 30_000
    assert preview.credit_planned_minor == 30_000
    assert preview.amount_due_minor == 70_000

    {:ok, intent} = Preview.freeze(scope, preview)
    assert intent.canonical_snapshot["creditAppliedMinor"] == 30_000
    assert intent.canonical_snapshot["amountDueMinor"] == 70_000

    # The ledger finalized exactly the applied amount against this intent.
    {:ok, account} = Credits.get_or_create_account(scope, credit_account.account_id, "DKK")
    assert account.available_minor == 0
    assert account.reserved_minor == 0
    assert :ok = Credits.reconcile_account(account.id)

    # A later preview has no credit left to apply.
    {:ok, next} = Preview.for_subscription(scope, subscription.id, ~D[2026-10-01])
    assert next.credit_available_minor == 0
    assert next.amount_due_minor == 100_000
  end

  test "credit never exceeds the eligible payable amount",
       %{scope: scope, subscription: subscription, credit_account: credit_account} do
    grant!(scope, credit_account, 500_000)

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-01])
    assert preview.credit_planned_minor == 100_000
    assert preview.amount_due_minor == 0

    {:ok, _intent} = Preview.freeze(scope, preview)

    {:ok, account} = Credits.get_or_create_account(scope, credit_account.account_id, "DKK")
    assert account.available_minor == 400_000
    assert :ok = Credits.reconcile_account(account.id)
  end

  test "a customer without a projected account gets no credit application",
       %{scope: scope} do
    plan_version =
      published_plan_version_fixture(scope,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        amount: "100.00"
      )

    lone_customer = customer_fixture(scope)

    contract =
      contract_fixture(scope, %{customer_id: lone_customer.id, start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-01])
    assert preview.credit_available_minor == 0
    assert preview.amount_due_minor == preview.net_amount_minor
  end
end
