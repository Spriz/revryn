defmodule BillingCore.Credits.TerminationDisposition do
  @moduledoc """
  Applies the configured remaining-credit disposition when a customer's
  commercial relationship ends (BC-US-109, BC-TASK-102).

  Triggered durably (Oban) after a subscription reaches `cancelled`. When
  the customer has no other live subscription in the team, each of their
  credit accounts runs `Credits.execute_disposition/2` under its versioned
  policy: `retain` is a recorded no-op, `refund` opens the durable refund
  obligation, `expire_after` schedules the auditable write-off deadline. A
  spendable balance with **no** configured policy never fails silently — it
  records a `credits.disposition.policy_missing` audit fact for finance.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Credits, Repo}
  alias BillingCore.Contracts.{Contract, Subscription}
  alias BillingCore.Credits.CreditAccount

  @live_statuses [:scheduled, :active, :paused, :pending_cancellation]

  @spec evaluate(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def evaluate(subscription_id) do
    with %Subscription{status: :cancelled} = subscription <-
           Repo.get(Subscription, subscription_id) || {:error, :not_found},
         %Contract{} = contract <- Repo.get(Contract, subscription.contract_id) do
      if customer_still_live?(subscription, contract.customer_id) do
        {:ok, %{result: :customer_still_active}}
      else
        {:ok, dispose_accounts(subscription, contract.customer_id)}
      end
    else
      %Subscription{} -> {:ok, %{result: :not_cancelled}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  defp customer_still_live?(subscription, customer_id) do
    Repo.exists?(
      from s in Subscription,
        join: c in Contract,
        on: c.id == s.contract_id,
        where:
          c.customer_id == ^customer_id and s.team_id == ^subscription.team_id and
            s.id != ^subscription.id and s.status in ^@live_statuses
    )
  end

  defp dispose_accounts(subscription, customer_id) do
    account_ids =
      Repo.all(
        from projection in "account_team_customers",
          prefix: "billing",
          where:
            projection.customer_id == type(^customer_id, Ecto.UUID) and
              projection.team_id == type(^subscription.team_id, Ecto.UUID),
          select: type(projection.account_id, Ecto.UUID)
      )

    accounts =
      Repo.all(
        from account in CreditAccount,
          where: account.account_id in ^account_ids and account.team_id == ^subscription.team_id
      )

    outcomes =
      Enum.map(accounts, fn account ->
        spendable = account.available_minor - account.reserved_minor

        case Credits.execute_disposition(:system, account) do
          {:ok, outcome} ->
            {account.id, summarize(outcome)}

          {:error, :no_disposition_policy} when spendable > 0 ->
            Audit.record!(:system, "credits.disposition.policy_missing",
              aggregate: {:credit_account, account.id},
              team_id: account.team_id,
              payload: %{
                customer_id: customer_id,
                subscription_id: subscription.id,
                spendable_minor: spendable,
                currency: account.currency
              }
            )

            {account.id, %{result: :policy_missing, spendable_minor: spendable}}

          {:error, :no_disposition_policy} ->
            {account.id, %{result: :no_balance_no_policy}}

          {:error, reason} ->
            {account.id, %{result: :error, reason: inspect(reason)}}
        end
      end)

    summary = %{result: :evaluated, accounts: Map.new(outcomes)}

    Audit.record!(:system, "credits.termination_disposition.evaluated",
      aggregate: {"subscription", subscription.id},
      team_id: subscription.team_id,
      payload: %{customer_id: customer_id, accounts: Map.new(outcomes)}
    )

    summary
  end

  defp summarize(%{policy: policy} = outcome) do
    outcome
    |> Map.take([:policy_version, :action])
    |> Map.put(:policy, policy)
    |> Map.put_new(:action, :applied)
  end
end
