defmodule BillingCoreWeb.GraphQL.Resolvers.Erp do
  @moduledoc """
  ERP connection, synchronization, approval, booking, and durable operation
  resolvers (SPEC §14.5 ERP operations, §14.11, §22.9).
  """

  alias BillingCore.{Billing, Idempotency, Operations, Scope}
  alias BillingCore.ERP
  alias BillingCore.ERP.Sync
  alias BillingCoreWeb.GraphQL.{Authz, Errors}
  alias BillingCoreWeb.GraphQL.Resolvers.Contracts, as: Shared

  ## Queries

  def erp_connection(_parent, _args, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, connection} <- ERP.get_connection(scope) do
      {:ok, connection}
    else
      false -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  def operation(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, operation} <- fetch_operation(scope, id) do
      {:ok, operation}
    else
      false -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  ## validateErpConnection

  def validate_erp_connection(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, connection} <- ERP.get_connection(scope),
         true <- connection.id == input.erp_connection_id,
         {:ok, validated} <- ERP.validate_connection(scope, connection) do
      {:ok, %{erp_connection: validated, client_mutation_id: cmid}}
    else
      false -> {:ok, Errors.business_error(:not_found, cmid)}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## synchronizeInvoice (SPEC §14.11)

  def synchronize_invoice(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "synchronize_invoice",
        input.idempotency_key,
        Authz.principal_id(scope),
        Shared.canonical_input(input),
        fn ->
          with {:ok, intent} <- Billing.get_intent(scope, input.invoice_intent_id),
               {:ok, operation} <- Sync.request_synchronization(scope, intent) do
            {:ok, %{"resource_reference" => operation.id}}
          end
        end
      )

    case Shared.resolve_outcome(outcome, scope, &fetch_operation/2) do
      {:ok, operation} -> {:ok, %{operation: operation, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## approveInvoice

  def approve_invoice(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, intent} <- Billing.get_intent(scope, input.invoice_intent_id),
         {:ok, _approval} <- Sync.approve_invoice(scope, intent, reason: input[:reason]),
         {:ok, refreshed} <- Billing.get_intent(scope, intent.id) do
      {:ok, %{invoice_intent: refreshed, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## bookInvoice

  def book_invoice(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "book_invoice",
        input.idempotency_key,
        Authz.principal_id(scope),
        Shared.canonical_input(input),
        fn ->
          with {:ok, intent} <- Billing.get_intent(scope, input.invoice_intent_id),
               {:ok, operation} <- Sync.request_booking(scope, intent) do
            {:ok, %{"resource_reference" => operation.id}}
          end
        end
      )

    case Shared.resolve_outcome(outcome, scope, &fetch_operation/2) do
      {:ok, operation} -> {:ok, %{operation: operation, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## retryOperation

  @doc """
  Manual retry of a failed durable operation (SPEC §22.9.3 failure inbox).
  Requires the finance role; only `failed → queued` is legal (§11.3).
  """
  def retry_operation(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    if Authz.finance?(scope) do
      with {:ok, operation} <- fetch_operation(scope, input.operation_id),
           {:ok, retried} <- do_retry(scope, operation) do
        {:ok, %{operation: retried, client_mutation_id: cmid}}
      else
        {:error, %BillingCore.Domain.StateMachine.TransitionError{}} ->
          {:ok, Errors.business_error({:illegal_state, :manual_retry}, cmid)}

        {:error, reason} ->
          {:ok, Errors.business_error(reason, cmid)}
      end
    else
      {:ok, Errors.authorization(cmid)}
    end
  end

  # ERP operations re-enqueue their worker so execution actually resumes;
  # other durable operations only transition (their schedulers pick them up).
  defp do_retry(scope, %{type: "erp." <> _} = operation) do
    BillingCore.ERP.Sync.retry_operation(scope, operation)
  end

  defp do_retry(_scope, operation) do
    Operations.transition(operation, :manual_retry)
  end

  ## Internals

  # Wraps `Operations.get!/1` safely and enforces the team boundary: an
  # unknown ID and another team's operation are indistinguishable.
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
