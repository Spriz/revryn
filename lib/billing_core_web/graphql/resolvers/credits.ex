defmodule BillingCoreWeb.GraphQL.Resolvers.Credits do
  @moduledoc """
  Customer-credit subledger resolvers (BC-US-107/108) — thin adapters over
  `BillingCore.Credits`, the same commands behind the LiveView surfaces and
  the demo scenario.
  """

  alias BillingCore.Credits
  alias BillingCoreWeb.GraphQL.{Authz, Errors}

  @doc "Stringifies an atom-valued struct field for a `:string` GraphQL field."
  def stringify(field, parent, _args, _resolution) do
    case Map.get(parent, field) do
      nil -> {:ok, nil}
      value -> {:ok, to_string(value)}
    end
  end

  ## Queries

  def credit_accounts(_parent, %{customer_id: customer_id}, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(customer_id),
         {:ok, accounts} <- Credits.list_accounts_for_customer(scope, uuid) do
      {:ok, accounts}
    else
      false -> Errors.unauthorized()
      :error -> Errors.not_found()
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  def account_grants(account, _args, %{context: %{scope: scope}}) do
    Credits.list_grants(scope, account)
  end

  def account_transactions(account, _args, %{context: %{scope: scope}}) do
    Credits.list_transactions(scope, account)
  end

  def account_disposition_policy(account, _args, %{context: %{scope: scope}}) do
    case Credits.current_disposition_policy(scope, account) do
      {:ok, policy} -> {:ok, policy}
      {:error, _reason} -> {:ok, nil}
    end
  end

  ## Mutations

  def grant_credit(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs = %{
      credit_account_id: input.credit_account_id,
      origin_type: input.origin_type,
      amount_minor: input.amount_minor,
      currency: input.currency,
      idempotency_key: input.idempotency_key,
      reason_code: input[:reason_code],
      expires_at: input[:expires_at]
    }

    case Credits.grant_credit(scope, attrs) do
      {:ok, grant} -> {:ok, %{credit_grant: grant, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  @disposition_policies ~w(retain refund expire_after)a

  def set_disposition_policy(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, policy} <- cast_policy(input.policy),
         {:ok, account} <- Credits.get_credit_account(scope, input.credit_account_id),
         {:ok, version} <-
           Credits.set_disposition_policy(scope, account, %{
             policy: policy,
             expire_after_days: input[:expire_after_days]
           }) do
      {:ok, %{disposition_policy: version, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  # Fixed policy set; never String.to_atom/1 on API input.
  defp cast_policy(policy_param) when is_binary(policy_param) do
    case Enum.find(@disposition_policies, &(Atom.to_string(&1) == policy_param)) do
      nil -> {:error, :invalid_disposition_policy}
      policy -> {:ok, policy}
    end
  end
end
