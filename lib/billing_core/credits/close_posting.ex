defmodule BillingCore.Credits.ClosePosting do
  @moduledoc """
  Worker-side execution of aggregate credit-close voucher effects.

  Every write is preceded by an authoritative lookup, uses a stable key, and
  is followed by voucher and attachment read-back. A lost response enters the
  durable unknown-outcome path before any retry (INV-008/009).
  """

  alias BillingCore.{Audit, ERP, Operations, Outbox, Repo}
  alias BillingCore.Credits.Close.{Close, Evidence}
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP.{Connection, ErpDocument, SyncOperation}
  alias BillingCore.ERP.Vouchers.{AttachmentEvidence, FinanceVoucher, Voucher}

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

    close =
      Close
      |> Repo.get!(document.customer_credit_close_id)
      |> Repo.preload([:policy_version, :movements])

    connection = Repo.get!(Connection, document.erp_connection_id)
    adapter = ERP.adapter_for(connection)
    context = CloseWorkflow.adapter_context(connection, close, close.policy_version)

    {:ok, expected} =
      CloseWorkflow.build_finance_voucher(close, close.policy_version, close.movements)

    with {:ok, voucher, operation, close} <-
           obtain_voucher(adapter, context, expected, sync_operation, operation, close),
         document <- persist_voucher!(document, voucher),
         {:ok, attachment, operation, close} <-
           ensure_attachment(
             adapter,
             context,
             voucher,
             sync_operation,
             operation,
             close
           ),
         {:ok, authoritative} <-
           adapter.get_finance_voucher(context, {:voucher, voucher.external_voucher_number}),
         {:ok, operation, close} <-
           reconcile_with_context(
             expected,
             authoritative,
             attachment,
             operation,
             close
           ) do
      complete!(sync_operation, operation, close, document, authoritative, attachment)
    else
      {:retry, operation, close} ->
        schedule_retry!(sync_operation, operation, close)

      {:mismatch, reason, operation, close} ->
        mismatch!(sync_operation, operation, close, reason)

      {:error, error, operation, close} ->
        provider_error!(sync_operation, operation, close, error)

      {:error, error} ->
        provider_error!(sync_operation, operation, close, error)
    end
  end

  defp obtain_voucher(adapter, context, expected, sync_operation, operation, close) do
    case adapter.find_finance_voucher(context, expected.external_reference) do
      {:ok, %Voucher{} = voucher} ->
        {:ok, voucher, operation, close}

      {:ok, nil} ->
        create_voucher(adapter, context, expected, sync_operation, operation, close)

      {:error, error} ->
        {:error, error, operation, close}
    end
  end

  defp create_voucher(adapter, context, expected, sync_operation, operation, close) do
    case adapter.create_finance_voucher(context, expected, sync_operation.idempotency_key) do
      {:ok, %Voucher{} = voucher} ->
        {:ok, voucher, operation, close}

      {:unknown, _hint} ->
        {operation, close} = enter_unknown!(operation, close, "voucher response lost")
        operation = Operations.transition!(operation, :reconcile)

        case adapter.find_finance_voucher(context, expected.external_reference) do
          {:ok, %Voucher{} = voucher} -> {:ok, voucher, operation, close}
          {:ok, nil} -> {:retry, operation, close}
          {:error, error} -> {:error, error, operation, close}
        end

      {:error, error} ->
        {:error, error, operation, close}
    end
  end

  defp ensure_attachment(
         adapter,
         context,
         voucher,
         sync_operation,
         operation,
         close
       ) do
    expected = CloseWorkflow.report_attachment!(close.id)
    voucher_ref = {:voucher, voucher.external_voucher_number}

    case adapter.get_voucher_attachment(context, voucher_ref) do
      {:ok, %AttachmentEvidence{} = actual} ->
        attachment_result(expected, actual, operation, close)

      {:ok, nil} ->
        attach_report(
          adapter,
          context,
          voucher_ref,
          expected,
          sync_operation,
          operation,
          close
        )

      {:error, error} ->
        {:error, error, operation, close}
    end
  end

  defp attach_report(adapter, context, voucher_ref, expected, sync_operation, operation, close) do
    attachment_key = sync_operation.idempotency_key <> ":attachment"

    case adapter.attach_voucher_report(context, voucher_ref, expected, attachment_key) do
      :ok ->
        read_attachment(adapter, context, voucher_ref, expected, operation, close)

      {:unknown, _hint} ->
        {operation, close} = maybe_enter_unknown!(operation, close, "attachment response lost")
        operation = ensure_reconciling!(operation)
        read_attachment(adapter, context, voucher_ref, expected, operation, close)

      {:error, error} ->
        {:error, error, operation, close}
    end
  end

  defp read_attachment(adapter, context, voucher_ref, expected, operation, close) do
    case adapter.get_voucher_attachment(context, voucher_ref) do
      {:ok, %AttachmentEvidence{} = actual} ->
        attachment_result(expected, actual, operation, close)

      {:ok, nil} ->
        {:retry, operation, close}

      {:error, error} ->
        {:error, error, operation, close}
    end
  end

  defp attachment_result(expected, actual, operation, close) do
    if expected.sha256 == actual.sha256 and expected.byte_size == actual.byte_size do
      {:ok, actual, operation, close}
    else
      {:mismatch, :attachment_hash_or_size, operation, close}
    end
  end

  defp reconcile(%FinanceVoucher{} = expected, %Voucher{} = actual, attachment, close) do
    cond do
      not CloseWorkflow.voucher_matches?(expected, actual) ->
        {:mismatch, :voucher_content}

      attachment.sha256 != CloseWorkflow.report_attachment!(close.id).sha256 ->
        {:mismatch, :attachment_hash}

      true ->
        :ok
    end
  end

  defp reconcile(_expected, nil, _attachment, _close), do: {:error, {:not_found, :voucher}}

  defp reconcile_with_context(expected, actual, attachment, operation, close) do
    case reconcile(expected, actual, attachment, close) do
      :ok -> {:ok, operation, close}
      {:mismatch, reason} -> {:mismatch, reason, operation, close}
      {:error, error} -> {:error, error, operation, close}
    end
  end

  defp complete!(sync_operation, operation, close, document, voucher, attachment) do
    Repo.transaction(fn ->
      close =
        case close.state do
          :posting ->
            close
            |> CloseWorkflow.transition_close!(:posting_succeeded)
            |> CloseWorkflow.transition_close!(:reconcile)

          :outcome_unknown ->
            close
            |> CloseWorkflow.transition_close!(:outcome_found)
            |> CloseWorkflow.transition_close!(:reconcile)

          # A retried operation after a permanent provider failure or a
          # detected mismatch re-runs to a matching read-back: §11.5 models
          # that recovery as mismatch → remediate → reconciled.
          :mismatch ->
            CloseWorkflow.transition_close!(close, :remediate)
        end

      finalize_reversal!(close)

      document
      |> Ecto.Changeset.change(
        state: "reconciled",
        last_external_snapshot: voucher_snapshot(voucher),
        last_external_hash: voucher.external_hash,
        last_reconciled_at: DateTime.utc_now()
      )
      |> Ecto.Changeset.optimistic_lock(:version)
      |> Repo.update!()

      update_sync!(sync_operation, "succeeded", %{
        "external_voucher_number" => voucher.external_voucher_number,
        "attachment_sha256" => attachment.sha256
      })

      operation = complete_operation!(operation)

      persist_evidence!(close, :erp_voucher, voucher_snapshot(voucher))

      persist_evidence!(close, :erp_attachment, %{
        external_attachment_id: attachment.external_attachment_id,
        sha256: attachment.sha256,
        byte_size: attachment.byte_size
      })

      persist_evidence!(close, :reconciliation, %{
        status: :match,
        voucher_hash: voucher.external_hash,
        attachment_sha256: attachment.sha256
      })

      Audit.record!(:system, "credits.close.reconciled",
        aggregate: {:customer_credit_close, close.id},
        team_id: close.team_id,
        payload: %{
          operation_id: operation.id,
          external_voucher_number: voucher.external_voucher_number,
          attachment_sha256: attachment.sha256
        }
      )

      emit_success_events!(close, operation.id, voucher.external_voucher_number)

      :telemetry.execute(
        [:billing_core, :customer_credit_close, :reconciled],
        %{count: 1},
        %{currency: close.currency, result: :match}
      )

      close
    end)

    :ok
  end

  defp persist_voucher!(document, voucher) do
    document
    |> Ecto.Changeset.change(
      state: "posted",
      external_voucher_number: voucher.external_voucher_number,
      external_accounting_year: voucher.accounting_year_external_id,
      last_external_snapshot: voucher_snapshot(voucher),
      last_external_hash: voucher.external_hash
    )
    |> Ecto.Changeset.optimistic_lock(:version)
    |> Repo.update!()
  end

  defp enter_unknown!(operation, close, summary) do
    operation =
      Operations.record_failure!(operation, :outcome_unknown,
        code: "provider_response_lost",
        summary: summary
      )

    close = CloseWorkflow.transition_close!(close, :posting_uncertain)
    {operation, close}
  end

  defp maybe_enter_unknown!(%{state: "executing"} = operation, close, summary),
    do: enter_unknown!(operation, close, summary)

  defp maybe_enter_unknown!(operation, close, _summary), do: {operation, close}

  defp ensure_reconciling!(%{state: "outcome_unknown"} = operation),
    do: Operations.transition!(operation, :reconcile)

  defp ensure_reconciling!(operation), do: operation

  defp schedule_retry!(sync_operation, operation, close) do
    Repo.transaction(fn ->
      operation = ensure_reconciling!(operation)

      operation =
        case operation.state do
          "reconciling" ->
            Operations.transition!(operation, :absence_proven, %{
              next_attempt_at: DateTime.utc_now()
            })

          "retry_scheduled" ->
            operation
        end

      close =
        case close.state do
          :posting ->
            close
            |> CloseWorkflow.transition_close!(:posting_uncertain)
            |> CloseWorkflow.transition_close!(:retry_posting)

          :outcome_unknown ->
            CloseWorkflow.transition_close!(close, :retry_posting)
        end

      update_sync!(sync_operation, "queued", %{"recovery" => "absence_proven"})
      {operation, close}
    end)

    {:snooze, 0}
  end

  defp mismatch!(sync_operation, operation, close, reason) do
    Repo.transaction(fn ->
      close = move_to_mismatch!(close)

      if operation.state == "executing" do
        Operations.record_failure!(operation, :validation,
          code: "credit_close_reconciliation_mismatch",
          summary: to_string(reason)
        )
      end

      update_sync!(sync_operation, "failed", %{"mismatch" => to_string(reason)})
      persist_evidence!(close, :reconciliation, %{status: :mismatch, reason: reason})

      Outbox.emit!("customer_credit_close.mismatch_detected.v1",
        aggregate: {:customer_credit_close, close.id},
        team_id: close.team_id,
        causation_id: operation.id,
        payload: %{reason: reason}
      )

      :telemetry.execute(
        [:billing_core, :customer_credit_close, :mismatch],
        %{count: 1},
        %{currency: close.currency, reason: reason}
      )
    end)

    :ok
  end

  defp provider_error!(sync_operation, operation, close, error) do
    {class, opts} = classify(error)

    if operation.state == "executing" do
      operation = Operations.record_failure!(operation, class, opts)
      state = if operation.state == "retry_scheduled", do: "retry_scheduled", else: "failed"
      update_sync!(sync_operation, state, %{"error" => safe_error(error)})

      if operation.state == "retry_scheduled" do
        {:snooze, 1}
      else
        mismatch!(sync_operation, operation, close, opts[:code] || class)
      end
    else
      update_sync!(sync_operation, "failed", %{"error" => safe_error(error)})
      :ok
    end
  end

  # ADR-031: a reconciled reversal close terminally reverses its original
  # (`reversal_pending → reversed`). Idempotent for recovered re-runs.
  defp finalize_reversal!(%Close{close_kind: :reversal, reversal_of_close_id: original_id})
       when is_binary(original_id) do
    original = Repo.get!(Close, original_id)

    if original.state == :reversal_pending do
      reversed = CloseWorkflow.transition_close!(original, :reversal_reconciled)

      Audit.record!(:system, "credits.close.reversed",
        aggregate: {:customer_credit_close, reversed.id},
        team_id: reversed.team_id,
        payload: %{report_sha256: reversed.report_sha256}
      )

      Outbox.emit!("customer_credit_close.reversed.v1",
        aggregate: {:customer_credit_close, reversed.id},
        team_id: reversed.team_id,
        payload: %{report_sha256: reversed.report_sha256}
      )
    end

    :ok
  end

  defp finalize_reversal!(_close), do: :ok

  defp move_to_mismatch!(%Close{state: :posting} = close) do
    close
    |> CloseWorkflow.transition_close!(:posting_succeeded)
    |> CloseWorkflow.transition_close!(:detect_mismatch)
  end

  defp move_to_mismatch!(%Close{state: :outcome_unknown} = close) do
    close
    |> CloseWorkflow.transition_close!(:outcome_found)
    |> CloseWorkflow.transition_close!(:detect_mismatch)
  end

  defp move_to_mismatch!(%Close{state: :posted} = close),
    do: CloseWorkflow.transition_close!(close, :detect_mismatch)

  defp move_to_mismatch!(%Close{} = close), do: close

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

  defp persist_evidence!(close, type, metadata) do
    canonical_metadata = metadata |> Canonical.encode!() |> Jason.decode!()

    Repo.insert!(%Evidence{
      team_id: close.team_id,
      close_id: close.id,
      evidence_type: type,
      sha256: Canonical.hash(canonical_metadata),
      content_type: "application/json",
      metadata: canonical_metadata
    })
  end

  defp emit_success_events!(close, operation_id, voucher_number) do
    opts = [
      aggregate: {:customer_credit_close, close.id},
      team_id: close.team_id,
      causation_id: operation_id,
      payload: %{
        operation_id: operation_id,
        external_voucher_number: voucher_number,
        report_sha256: close.report_sha256
      }
    ]

    Outbox.emit!("customer_credit_close.posted.v1", opts)
    Outbox.emit!("customer_credit_close.reconciled.v1", opts)
  end

  defp complete_operation!(%{state: "executing"} = operation),
    do: Operations.transition!(operation, :succeed)

  defp complete_operation!(%{state: "reconciling"} = operation),
    do: Operations.transition!(operation, :effect_found)

  defp claim(%{state: "queued"} = operation), do: {:ok, Operations.transition!(operation, :claim)}

  defp claim(%{state: "retry_scheduled"} = operation),
    do: {:ok, Operations.transition!(operation, :retry)}

  defp claim(_operation), do: :not_runnable

  defp voucher_snapshot(voucher) do
    voucher
    |> Map.from_struct()
    |> Map.update!(:lines, fn lines -> Enum.map(lines, &Map.from_struct/1) end)
    |> Canonical.encode!()
    |> Jason.decode!()
  end

  defp classify({:authentication, _}),
    do: {:authorization, [code: "authentication", blocked_reason: "credentials_invalid"]}

  defp classify({:authorization, _}),
    do: {:authorization, [code: "authorization", blocked_reason: "insufficient_permissions"]}

  defp classify({:validation, _}), do: {:validation, [code: "provider_validation"]}
  defp classify({:not_found, _}), do: {:conflict, [code: "provider_not_found"]}
  defp classify({:conflict, _}), do: {:conflict, [code: "provider_conflict"]}

  defp classify({:rate_limited, %{retry_after: retry_after}}),
    do: {:throttled, [code: "rate_limited", retry_after: retry_after]}

  defp classify({:unsupported_capability, capability}),
    do: {:validation, [code: "unsupported_#{capability}"]}

  defp classify({:provider_failure, _}), do: {:transient, [code: "provider_failure"]}
  defp classify(_), do: {:terminal, [code: "unexpected_provider_error"]}

  defp safe_error(error), do: error |> inspect() |> String.slice(0, 300)
end
