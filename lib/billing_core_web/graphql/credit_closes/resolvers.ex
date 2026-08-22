defmodule BillingCoreWeb.GraphQL.CreditCloses.Resolvers do
  @moduledoc """
  Monthly customer-credit close resolvers (BC-TASK-104). Thin adapters over
  `BillingCore.Credits.CloseWorkflow` / `BillingCore.Credits.Close` — the
  identical commands behind the LiveView, CLI, and MCP surfaces.
  """

  alias BillingCore.{Idempotency, Operations, Scope}
  alias BillingCore.Credits.Close, as: CloseKernel
  alias BillingCore.Credits.Close.Evidence
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCoreWeb.GraphQL.{Authz, Errors}
  alias BillingCoreWeb.GraphQL.Resolvers.Contracts, as: Shared

  ## Field helpers

  @doc "Stringifies an atom-valued struct field for a `:string` GraphQL field."
  def stringify(field, parent, _args, _resolution) do
    case Map.get(parent, field) do
      nil -> {:ok, nil}
      value -> {:ok, to_string(value)}
    end
  end

  def close_movements(close, _args, %{context: %{scope: scope}}) do
    CloseWorkflow.list_movements(scope, close.id)
  end

  def close_evidence(close, _args, %{context: %{scope: scope}}) do
    CloseWorkflow.list_evidence_meta(scope, close.id)
  end

  def close_corrections(close, _args, %{context: %{scope: scope}}) do
    CloseWorkflow.list_corrections(scope, close.id)
  end

  def close_voucher_number(close, _args, %{context: %{scope: scope}}) do
    case CloseWorkflow.posting_status(scope, close) do
      {:ok, %{document: %{external_voucher_number: number}}} -> {:ok, number}
      _other -> {:ok, nil}
    end
  end

  def close_report(close, %{evidence_type: type_param}, %{context: %{scope: scope}}) do
    with {:ok, evidence_type} <- cast_evidence_type(type_param),
         {:ok, evidence} <- CloseWorkflow.report(scope, close.id, evidence_type) do
      {:ok,
       %{
         evidence_type: to_string(evidence.evidence_type),
         sha256: evidence.sha256,
         content_type: evidence.content_type,
         content_base64: Base.encode64(evidence.bytes)
       }}
    else
      {:error, :unknown_evidence_type} -> Errors.not_found()
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Queries

  def credit_close(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, close} <- CloseKernel.fetch(scope, uuid) do
      {:ok, close}
    else
      false -> Errors.unauthorized()
      _other -> Errors.not_found()
    end
  end

  def credit_closes(_parent, args, %{context: %{scope: scope}}) do
    opts =
      []
      |> maybe_opt(:currency, args[:currency])
      |> maybe_opt(:state, args[:state] && safe_state(args[:state]))

    case CloseWorkflow.list_closes(scope, opts) do
      {:ok, closes} -> {:ok, closes}
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  def credit_close_policies(_parent, _args, %{context: %{scope: scope}}) do
    case CloseWorkflow.list_policies(scope) do
      {:ok, policies} -> {:ok, policies}
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  ## Mutations

  def create_credit_close_policy(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, policies} <- CloseWorkflow.list_policies(scope),
         {:ok, settlement_mode} <- cast_settlement_mode(input[:settlement_mode]),
         {:ok, policy} <-
           CloseKernel.create_policy(scope, %{
             version: next_policy_version(policies),
             effective_from: input.effective_from,
             journal_number: input.journal_number,
             liability_account_number: input.liability_account_number,
             posting_mode: :single_offset,
             default_offset_account_number: input.default_offset_account_number,
             post_zero_delta: input[:post_zero_delta] || false,
             vat_neutral: Map.get(input, :vat_neutral, true),
             settlement_mode: settlement_mode,
             settlement_clearing_account_number: input[:settlement_clearing_account_number],
             settlement_contra_account_number: input[:settlement_contra_account_number],
             created_by: actor_user_id(scope)
           }) do
      {:ok, %{policy: policy, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def credit_settlements(_parent, args, %{context: %{scope: scope}}) do
    filters =
      [invoice_intent_id: args[:invoice_intent_id], state: cast_settlement_state(args[:state])]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case BillingCore.Credits.Settlements.list_settlements(scope, filters) do
      {:ok, settlements} -> {:ok, settlements}
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  def record_external_settlement(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, settlement_id} <- cast_uuid(input.settlement_id),
         {:ok, settlement} <-
           BillingCore.Credits.Settlements.record_external_settlement(
             scope,
             settlement_id,
             input.external_reference
           ) do
      {:ok, %{settlement: settlement, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  # Whitelist-find, never String.to_atom/1 on user input.
  defp cast_settlement_mode(nil), do: {:ok, :none}

  defp cast_settlement_mode(mode) do
    case Enum.find(
           BillingCore.Credits.Close.PolicyVersion.settlement_modes(),
           &(Atom.to_string(&1) == mode)
         ) do
      nil -> {:error, :invalid_settlement_mode}
      cast -> {:ok, cast}
    end
  end

  defp cast_settlement_state(state) when state in ["pending", "reconciled"],
    do: String.to_existing_atom(state)

  defp cast_settlement_state(_state), do: nil

  def generate_credit_close(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "generate_credit_close",
        input.idempotency_key,
        Authz.principal_id(scope),
        Shared.canonical_input(input),
        fn ->
          period_start = Date.beginning_of_month(input.period_date)

          with {:ok, policy_version_id} <- resolve_policy(scope, input[:policy_version_id]),
               {:ok, close} <-
                 CloseWorkflow.generate(scope, %{
                   currency: input.currency,
                   period_start: period_start,
                   period_end_exclusive: Date.add(Date.end_of_month(period_start), 1),
                   transaction_cutoff: DateTime.utc_now(),
                   policy_version_id: policy_version_id,
                   bootstrap_opening_minor: input[:bootstrap_opening_minor]
                 }) do
            {:ok, %{"resource_reference" => close.id}}
          end
        end
      )

    case Shared.resolve_outcome(outcome, scope, &CloseKernel.fetch/2) do
      {:ok, close} -> {:ok, %{credit_close: close, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def approve_credit_close(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, uuid} <- cast_uuid(input.credit_close_id),
         {:ok, close} <- CloseWorkflow.approve(scope, uuid, reason: input[:reason]) do
      {:ok, %{credit_close: close, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def request_credit_close_posting(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "request_credit_close_posting",
        input.idempotency_key,
        Authz.principal_id(scope),
        Shared.canonical_input(input),
        fn ->
          with {:ok, uuid} <- cast_uuid(input.credit_close_id),
               {:ok, operation} <- CloseWorkflow.request_posting(scope, uuid) do
            {:ok, %{"resource_reference" => operation.id}}
          end
        end
      )

    with {:ok, operation} <- Shared.resolve_outcome(outcome, scope, &fetch_operation/2),
         {:ok, uuid} <- cast_uuid(input.credit_close_id),
         {:ok, close} <- CloseKernel.fetch(scope, uuid) do
      {:ok, %{operation: operation, credit_close: close, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def request_credit_close_reversal(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, uuid} <- cast_uuid(input.credit_close_id),
         {:ok, reversal} <- CloseWorkflow.request_reversal(scope, uuid, reason: input.reason) do
      {:ok, %{reversal_close: reversal, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def generate_credit_close_replacement(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, uuid} <- cast_uuid(input.credit_close_id),
         {:ok, policy_uuid} <- cast_uuid(input.policy_version_id),
         {:ok, replacement} <-
           CloseWorkflow.generate_replacement(scope, uuid,
             policy_version_id: policy_uuid,
             reason: input.reason
           ) do
      {:ok, %{replacement_close: replacement, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def close_credit_period(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, uuid} <- cast_uuid(input.credit_close_id),
         {:ok, close} <- CloseWorkflow.close_period(scope, uuid) do
      {:ok, %{credit_close: close, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## Helpers

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: [{key, value} | opts]

  # Close states are a fixed set; never String.to_atom/1 on API input.
  defp safe_state(state_param) when is_binary(state_param) do
    Enum.find(
      ~w(open calculating ready failed approved posting outcome_unknown posted mismatch
         reconciled closed superseded reversal_pending reversed)a,
      &(Atom.to_string(&1) == state_param)
    )
  end

  defp cast_evidence_type(param) when is_binary(param) do
    case Enum.find(Evidence.evidence_types(), &(Atom.to_string(&1) == param)) do
      nil -> {:error, :unknown_evidence_type}
      evidence_type -> {:ok, evidence_type}
    end
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp resolve_policy(scope, nil) do
    case CloseWorkflow.list_policies(scope) do
      {:ok, [latest | _rest]} -> {:ok, latest.id}
      {:ok, []} -> {:error, :close_policy_not_effective}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_policy(_scope, policy_version_id), do: cast_uuid(policy_version_id)

  defp next_policy_version([]), do: 1
  defp next_policy_version(policies), do: Enum.max_by(policies, & &1.version).version + 1

  defp actor_user_id(%Scope{user: %{id: id}}), do: id
  defp actor_user_id(_scope), do: nil

  defp fetch_operation(scope, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{} = operation <- safe_get_operation(uuid),
         true <- operation.team_id == Scope.team_id!(scope) do
      {:ok, operation}
    else
      _ -> {:error, :not_found}
    end
  end

  defp safe_get_operation(id) do
    Operations.get!(id)
  rescue
    Ecto.NoResultsError -> nil
  end
end
