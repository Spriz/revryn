defmodule BillingCore.Credits.SettlementPosting do
  @moduledoc """
  Worker-side execution of one receivable-settlement clearing voucher
  (SPEC §9.4.1, BC-US-108).

  Same discipline as every external effect: authoritative lookup before any
  write, stable idempotency key, unknown-outcome recovery before retry, and
  read-back reconciliation before the settlement becomes terminal
  (INV-008/009). The settlement stays `pending` — visible in the operations
  inbox — until the voucher reconciles exactly.
  """

  alias BillingCore.{Audit, ERP, Operations, Outbox, Repo}
  alias BillingCore.Credits.Close.PolicyVersion
  alias BillingCore.Credits.{CreditSettlement, Settlements}
  alias BillingCore.ERP.{Connection, ErpDocument, SyncOperation}
  alias BillingCore.ERP.Vouchers.Voucher

  @doc false
  def execute(sync_operation_id) do
    sync_operation = Repo.get!(SyncOperation, sync_operation_id)
    operation = Operations.get!(sync_operation.operation_id)

    case claim(operation) do
      {:ok, operation} -> run(sync_operation, operation)
      :not_runnable -> :ok
    end
  end

  defp run(sync_operation, operation) do
    document = Repo.get!(ErpDocument, sync_operation.erp_document_id)
    settlement = Repo.get!(CreditSettlement, operation.target_id)

    if settlement.state == :reconciled do
      complete_operation_only!(sync_operation, operation)
    else
      policy = Repo.get!(PolicyVersion, settlement.policy_version_id)
      connection = Repo.get!(Connection, document.erp_connection_id)
      adapter = ERP.adapter_for(connection)
      accounting_date = DateTime.to_date(settlement.created_at)
      context = Settlements.adapter_context(connection, settlement, policy, accounting_date)

      {:ok, expected} = Settlements.build_settlement_voucher(settlement, policy, accounting_date)

      with {:ok, voucher, operation} <-
             obtain_voucher(adapter, context, expected, sync_operation, operation),
           {:ok, authoritative} <-
             adapter.get_finance_voucher(context, {:voucher, voucher.external_voucher_number}),
           :ok <- reconcile(expected, authoritative) do
        complete!(sync_operation, operation, settlement, document, authoritative)
      else
        {:retry, operation} ->
          schedule_retry!(sync_operation, operation)

        {:mismatch, reason, operation} ->
          fail!(sync_operation, operation, settlement, :validation, reason)

        {:error, error, operation} ->
          provider_error!(sync_operation, operation, settlement, error)

        {:error, error} ->
          provider_error!(sync_operation, operation, settlement, error)

        {:mismatch, reason} ->
          fail!(sync_operation, operation, settlement, :validation, reason)
      end
    end
  end

  defp obtain_voucher(adapter, context, expected, sync_operation, operation) do
    case adapter.find_finance_voucher(context, expected.external_reference) do
      {:ok, %Voucher{} = voucher} ->
        {:ok, voucher, operation}

      {:ok, nil} ->
        create_voucher(adapter, context, expected, sync_operation, operation)

      {:error, error} ->
        {:error, error, operation}
    end
  end

  defp create_voucher(adapter, context, expected, sync_operation, operation) do
    case adapter.create_finance_voucher(context, expected, sync_operation.idempotency_key) do
      {:ok, %Voucher{} = voucher} ->
        {:ok, voucher, operation}

      {:unknown, _hint} ->
        operation =
          Operations.record_failure!(operation, :outcome_unknown,
            code: "provider_response_lost",
            summary: "settlement voucher response lost"
          )

        operation = Operations.transition!(operation, :reconcile)

        case adapter.find_finance_voucher(context, expected.external_reference) do
          {:ok, %Voucher{} = voucher} -> {:ok, voucher, operation}
          {:ok, nil} -> {:retry, operation}
          {:error, error} -> {:error, error, operation}
        end

      {:error, error} ->
        {:error, error, operation}
    end
  end

  defp reconcile(expected, %Voucher{} = actual) do
    expected_amounts =
      expected.lines
      |> Enum.map(&{&1.account_external_id, &1.amount.minor_units})
      |> Enum.sort()

    actual_amounts =
      actual.lines
      |> Enum.map(&{&1.account_external_id, &1.amount.minor_units})
      |> Enum.sort()

    if expected_amounts == actual_amounts and actual.currency == expected.currency do
      :ok
    else
      {:mismatch, :settlement_voucher_content}
    end
  end

  defp reconcile(_expected, nil), do: {:error, {:not_found, :voucher}}

  defp complete!(sync_operation, operation, settlement, document, voucher) do
    {:ok, _} =
      Repo.transaction(fn ->
        settlement =
          settlement
          |> Ecto.Changeset.change(
            state: :reconciled,
            external_voucher_number: voucher.external_voucher_number,
            reconciled_at: DateTime.utc_now()
          )
          |> Repo.update!()

        document
        |> Ecto.Changeset.change(
          state: "reconciled",
          external_voucher_number: voucher.external_voucher_number,
          last_external_hash: voucher.external_hash,
          last_reconciled_at: DateTime.utc_now()
        )
        |> Ecto.Changeset.optimistic_lock(:version)
        |> Repo.update!()

        update_sync!(sync_operation, "succeeded", %{
          "external_voucher_number" => voucher.external_voucher_number
        })

        operation = complete_operation!(operation)

        Audit.record!(:system, "credits.settlement.reconciled",
          aggregate: {:customer_credit_settlement, settlement.id},
          team_id: settlement.team_id,
          payload: %{
            operation_id: operation.id,
            external_voucher_number: voucher.external_voucher_number,
            mode: :erp_customer_settlement
          }
        )

        Outbox.emit!("customer_credit_settlement.reconciled.v1",
          aggregate: {:customer_credit_settlement, settlement.id},
          team_id: settlement.team_id,
          causation_id: operation.id,
          payload: %{
            invoice_intent_id: settlement.invoice_intent_id,
            amount_minor: settlement.amount_minor,
            currency: settlement.currency,
            external_voucher_number: voucher.external_voucher_number
          }
        )

        :telemetry.execute(
          [:billing_core, :customer_credit_settlement, :reconciled],
          %{count: 1},
          %{currency: settlement.currency, mode: :erp_customer_settlement}
        )

        settlement
      end)

    :ok
  end

  defp complete_operation_only!(sync_operation, operation) do
    Repo.transaction(fn ->
      update_sync!(sync_operation, "succeeded", %{"already_reconciled" => true})
      complete_operation!(operation)
    end)

    :ok
  end

  defp schedule_retry!(sync_operation, operation) do
    Repo.transaction(fn ->
      operation =
        case operation.state do
          "reconciling" ->
            Operations.transition!(operation, :absence_proven, %{
              next_attempt_at: DateTime.utc_now()
            })

          _other ->
            operation
        end

      update_sync!(sync_operation, "queued", %{"recovery" => "absence_proven"})
      operation
    end)

    {:snooze, 0}
  end

  defp fail!(sync_operation, operation, settlement, class, reason) do
    Repo.transaction(fn ->
      if operation.state == "executing" do
        Operations.record_failure!(operation, class,
          code: "credit_settlement_mismatch",
          summary: to_string(reason)
        )
      end

      update_sync!(sync_operation, "failed", %{"mismatch" => to_string(reason)})

      Outbox.emit!("customer_credit_settlement.mismatch_detected.v1",
        aggregate: {:customer_credit_settlement, settlement.id},
        team_id: settlement.team_id,
        causation_id: operation.id,
        payload: %{reason: reason}
      )
    end)

    :ok
  end

  defp provider_error!(sync_operation, operation, _settlement, error) do
    {class, opts} = classify(error)

    if operation.state == "executing" do
      operation = Operations.record_failure!(operation, class, opts)
      state = if operation.state == "retry_scheduled", do: "retry_scheduled", else: "failed"
      update_sync!(sync_operation, state, %{"error" => safe_error(error)})
      if operation.state == "retry_scheduled", do: {:snooze, 1}, else: :ok
    else
      update_sync!(sync_operation, "failed", %{"error" => safe_error(error)})
      :ok
    end
  end

  defp update_sync!(sync_operation, state, response_metadata) do
    attrs = [
      state: state,
      response_metadata: response_metadata,
      attempt_count: sync_operation.attempt_count + 1
    ]

    attrs =
      if state in ["succeeded", "failed"],
        do: [{:completed_at, DateTime.utc_now()} | attrs],
        else: attrs

    sync_operation
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp complete_operation!(%{state: "executing"} = operation),
    do: Operations.transition!(operation, :succeed)

  defp complete_operation!(%{state: "reconciling"} = operation),
    do: Operations.transition!(operation, :effect_found)

  defp claim(%{state: "queued"} = operation), do: {:ok, Operations.transition!(operation, :claim)}

  defp claim(%{state: "retry_scheduled"} = operation),
    do: {:ok, Operations.transition!(operation, :retry)}

  defp claim(_operation), do: :not_runnable

  defp classify({:authentication, _}),
    do: {:authorization, [code: "authentication", blocked_reason: "credentials_invalid"]}

  defp classify({:authorization, _}),
    do: {:authorization, [code: "authorization", blocked_reason: "insufficient_permissions"]}

  defp classify({:validation, _}), do: {:validation, [code: "provider_validation"]}
  defp classify({:not_found, _}), do: {:conflict, [code: "provider_not_found"]}
  defp classify({:conflict, _}), do: {:conflict, [code: "provider_conflict"]}

  defp classify({:rate_limited, %{retry_after: retry_after}}),
    do: {:throttled, [code: "rate_limited", retry_after: retry_after]}

  defp classify({:provider_failure, _}), do: {:transient, [code: "provider_failure"]}
  defp classify(_), do: {:terminal, [code: "unexpected_provider_error"]}

  defp safe_error(error), do: error |> inspect() |> String.slice(0, 300)
end
