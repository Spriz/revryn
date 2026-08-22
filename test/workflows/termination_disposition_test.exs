defmodule BillingCore.Workflows.TerminationDispositionTest do
  @moduledoc """
  BC-US-109: cancelling the customer's last live subscription durably
  triggers the configured remaining-credit disposition — retain records,
  refund opens the durable obligation, expire_after schedules the auditable
  deadline, and a spendable balance with no policy is surfaced to finance
  rather than silently kept.
  """

  use BillingCore.DataCase, async: false

  import Ecto.Query
  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.CreditsFixtures, only: [grant_fixture: 3]
  import BillingCore.OrgsFixtures

  alias BillingCore.{Audit, Contracts, Credits, Orgs, Repo}
  alias BillingCore.Credits.CreditGrant

  setup do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    plan_version = published_plan_version_fixture(scope, currency: "DKK", amount: "100.00")
    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.add(Date.utc_today(), -30),
        quantity: Decimal.new(1)
      })

    account = account_fixture(scope.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, scope.team, customer.id)
    {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")
    grant_fixture(scope, credit_account, %{amount_minor: 40_000})

    %{
      scope: scope,
      customer: customer,
      contract: contract,
      subscription: subscription,
      credit_account: credit_account,
      plan_version: plan_version
    }
  end

  defp cancel_now!(scope, subscription) do
    {:ok, cancelled} =
      Contracts.cancel_subscription(scope, subscription, %{
        mode: :immediate,
        reason: "relationship ended"
      })

    assert %{success: 1} = Oban.drain_queue(queue: :billing, with_safety: false)
    cancelled
  end

  test "expire_after schedules the auditable deadline on last-subscription cancellation",
       %{scope: scope, subscription: subscription, credit_account: credit_account} do
    {:ok, _policy} =
      Credits.set_disposition_policy(scope, credit_account, %{
        policy: :expire_after,
        expire_after_days: 90
      })

    cancel_now!(scope, subscription)

    [grant] = Repo.all(from g in CreditGrant, where: g.credit_account_id == ^credit_account.id)
    assert grant.expires_at
    assert DateTime.diff(grant.expires_at, DateTime.utc_now(), :day) in 89..90

    assert Repo.exists?(
             from e in Audit.Entry,
               where: e.event_type == "credits.termination_disposition.evaluated"
           )
  end

  test "a missing policy with spendable balance is surfaced, never silently retained",
       %{scope: scope, subscription: subscription, credit_account: credit_account} do
    cancel_now!(scope, subscription)

    assert entry =
             Repo.one(
               from e in Audit.Entry,
                 where: e.event_type == "credits.disposition.policy_missing",
                 limit: 1
             )

    assert entry.payload["spendable_minor"] == 40_000
    assert entry.aggregate_id == credit_account.id
  end

  test "no disposition runs while the customer still has another live subscription",
       %{scope: scope, contract: contract, subscription: subscription, plan_version: plan_version} do
    {:ok, _second} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.add(Date.utc_today(), -30),
        quantity: Decimal.new(1)
      })

    cancel_now!(scope, subscription)

    refute Repo.exists?(
             from e in Audit.Entry,
               where:
                 e.event_type in [
                   "credits.termination_disposition.evaluated",
                   "credits.disposition.policy_missing"
                 ]
           )
  end

  test "retain records the outcome and leaves the balance eligible",
       %{scope: scope, subscription: subscription, credit_account: credit_account} do
    {:ok, _policy} =
      Credits.set_disposition_policy(scope, credit_account, %{policy: :retain})

    cancel_now!(scope, subscription)

    account = Repo.reload!(credit_account)
    assert account.available_minor == 40_000

    entry =
      Repo.one!(
        from e in Audit.Entry,
          where: e.event_type == "credits.termination_disposition.evaluated",
          limit: 1
      )

    assert [%{"policy" => "retain"} | _] =
             entry.payload["accounts"] |> Map.values()
  end
end
