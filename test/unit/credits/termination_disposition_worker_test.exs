defmodule BillingCore.Credits.TerminationDispositionWorkerTest do
  @moduledoc """
  BC-US-109 durable trigger: every replayable outcome of the disposition
  evaluation converges to job completion — a vanished or not-yet-cancelled
  subscription never leaves the job retrying forever, and a cancelled last
  subscription actually runs the evaluation. The disposition policies
  themselves are certified in the termination-disposition workflow suite.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Audit, Contracts}
  alias BillingCore.Credits.TerminationDispositionWorker

  defp perform!(subscription_id) do
    TerminationDispositionWorker.perform(%Oban.Job{args: %{"subscription_id" => subscription_id}})
  end

  defp subscription_fixture! do
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

    %{scope: scope, subscription: subscription}
  end

  test "a subscription that no longer exists completes instead of retrying forever" do
    assert :ok = perform!(Ecto.UUID.generate())
  end

  test "a subscription that is not cancelled is a converging no-op" do
    %{subscription: subscription} = subscription_fixture!()

    assert :ok = perform!(subscription.id)

    refute Repo.exists?(
             from e in Audit.Entry,
               where:
                 e.event_type in [
                   "credits.termination_disposition.evaluated",
                   "credits.disposition.policy_missing"
                 ]
           )
  end

  test "a cancelled last subscription runs and records the disposition evaluation" do
    %{scope: scope, subscription: subscription} = subscription_fixture!()

    {:ok, _cancelled} =
      Contracts.cancel_subscription(scope, subscription, %{
        mode: :immediate,
        reason: "relationship ended"
      })

    assert :ok = perform!(subscription.id)

    assert entry =
             Repo.one(
               from e in Audit.Entry,
                 where: e.event_type == "credits.termination_disposition.evaluated",
                 limit: 1
             )

    assert entry.payload["customer_id"]
    # No credit accounts exist for this customer, so the evaluation records
    # an empty account map rather than inventing dispositions.
    assert entry.payload["accounts"] == %{}
  end

  # The worker's `{:error, reason} -> {:error, reason}` branch is not
  # reachable through real data today: `TerminationDisposition.evaluate/1`
  # only errors with `:not_found` (which the worker converts to `:ok`), and
  # per-account disposition failures are folded into the `{:ok, summary}`
  # outcome map instead of failing the job. Exercising the branch would
  # require stubbing the evaluation itself, which would assert nothing about
  # real behavior.
end
