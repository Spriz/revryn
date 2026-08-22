defmodule BillingCore.AuditExport do
  @moduledoc """
  Audit package export for one invoice chain (BC-US-114, BC-TASK-072).

  Produces a deterministic set of canonical-JSON evidence files plus a
  manifest with per-file SHA-256 checksums:

    * `invoice_chain.json` — the chain, every immutable intent version with
      its canonical snapshot (including per-line calculation traces), and
      the append-only lifecycle transition history;
    * `erp_documents.json` — mirrored ERP documents, durable sync
      operations (operation/idempotency keys, safe request/response
      metadata), and approval records;
    * `audit_log.json` — audit entries for the chain's intents and their
      durable operations.

  Redaction: connection rows, secret references, and credentials are never
  included; sync metadata and audit payloads are safe by construction
  (INV-006). Personal data is limited to the invoice's own commercial
  content.
  """

  import Ecto.Query

  alias BillingCore.{Repo, Scope}
  alias BillingCore.Audit
  alias BillingCore.Billing.{IntentLifecycle, InvoiceChain, InvoiceIntent}
  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP.{ApprovalRecord, ErpDocument, SyncOperation}
  alias BillingCore.Operations

  @read_roles [:finance_operator, :billing_admin, :team_admin, :auditor]
  @format_version 1

  @type file :: %{
          name: String.t(),
          content_type: String.t(),
          bytes: binary(),
          sha256: String.t()
        }

  @spec for_invoice_chain(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %{files: [file()], manifest: map(), manifest_json: binary()}}
          | {:error, :unauthorized | :not_found}
  def for_invoice_chain(%Scope{} = scope, invoice_intent_id) do
    with :ok <- authorize(scope),
         {:ok, uuid} <- cast_uuid(invoice_intent_id),
         %InvoiceIntent{} = intent <- get_team_intent(scope, uuid) do
      chain = Repo.get!(InvoiceChain, intent.invoice_chain_id)

      intents =
        Repo.all(
          from i in InvoiceIntent,
            where: i.invoice_chain_id == ^chain.id and i.team_id == ^Scope.team_id!(scope),
            order_by: [asc: i.intent_version],
            preload: [:lines]
        )

      intent_ids = Enum.map(intents, & &1.id)

      files = [
        build_file("invoice_chain.json", chain_document(chain, intents, intent_ids)),
        build_file("erp_documents.json", erp_document_evidence(scope, intent_ids)),
        build_file("audit_log.json", audit_evidence(scope, intent_ids))
      ]

      manifest = %{
        format_version: @format_version,
        invoice_chain_id: chain.id,
        team_id: chain.team_id,
        intent_count: length(intents),
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        files:
          Map.new(files, fn file ->
            {file.name, %{sha256: file.sha256, content_type: file.content_type}}
          end)
      }

      {:ok, %{files: files, manifest: manifest, manifest_json: Canonical.encode!(manifest)}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp chain_document(chain, intents, intent_ids) do
    current_states =
      Repo.all(
        from lifecycle in IntentLifecycle,
          where: lifecycle.invoice_intent_id in ^intent_ids,
          select: %{
            invoice_intent_id: lifecycle.invoice_intent_id,
            current_state: lifecycle.current_state
          }
      )

    transitions =
      Repo.all(
        from t in "invoice_intent_state_transitions",
          prefix: "billing",
          where: t.invoice_intent_id in type(^intent_ids, {:array, Ecto.UUID}),
          order_by: [asc: t.occurred_at],
          select: %{
            invoice_intent_id: type(t.invoice_intent_id, Ecto.UUID),
            from_state: t.from_state,
            to_state: t.to_state,
            event: t.event,
            occurred_at: t.occurred_at
          }
      )

    %{
      chain: %{
        id: chain.id,
        status: chain.status,
        current_intent_id: chain.current_intent_id
      },
      intents:
        Enum.map(intents, fn intent ->
          %{
            id: intent.id,
            intent_version: intent.intent_version,
            supersedes_invoice_intent_id: intent.supersedes_invoice_intent_id,
            document_kind: intent.document_kind,
            currency: intent.currency,
            invoice_date: intent.invoice_date,
            net_amount_minor: intent.net_amount_minor,
            content_hash: intent.content_hash,
            frozen_at: intent.frozen_at,
            canonical_snapshot: intent.canonical_snapshot,
            lines:
              Enum.map(intent.lines, fn line ->
                %{
                  id: line.id,
                  line_key: line.line_key,
                  description: line.description,
                  quantity: line.quantity,
                  amount_minor: line.amount_minor,
                  currency: line.currency,
                  recognition_mode: line.recognition_mode,
                  service_start: line.service_start,
                  service_end_exclusive: line.service_end_exclusive,
                  calculation_trace: line.calculation_trace,
                  ordinal: line.ordinal
                }
              end)
          }
        end),
      lifecycle_states: current_states,
      state_transitions: transitions
    }
  end

  defp erp_document_evidence(scope, intent_ids) do
    team_id = Scope.team_id!(scope)

    documents =
      Repo.all(
        from doc in ErpDocument,
          where: doc.invoice_intent_id in ^intent_ids and doc.team_id == ^team_id,
          order_by: [asc: doc.created_at]
      )

    document_ids = Enum.map(documents, & &1.id)

    sync_operations =
      Repo.all(
        from sync_op in SyncOperation,
          where: sync_op.erp_document_id in ^document_ids and sync_op.team_id == ^team_id,
          order_by: [asc: sync_op.created_at]
      )

    approvals =
      Repo.all(
        from approval in ApprovalRecord,
          where: approval.invoice_intent_id in ^intent_ids and approval.team_id == ^team_id,
          order_by: [asc: approval.occurred_at]
      )

    %{
      documents:
        Enum.map(documents, fn doc ->
          %{
            id: doc.id,
            invoice_intent_id: doc.invoice_intent_id,
            document_type: doc.document_type,
            state: doc.state,
            external_reference: doc.external_reference,
            external_draft_number: doc.external_draft_number,
            external_booked_number: doc.external_booked_number,
            last_external_snapshot: doc.last_external_snapshot,
            last_external_hash: doc.last_external_hash,
            last_reconciled_at: doc.last_reconciled_at
          }
        end),
      sync_operations:
        Enum.map(sync_operations, fn sync_op ->
          %{
            id: sync_op.id,
            erp_document_id: sync_op.erp_document_id,
            operation_id: sync_op.operation_id,
            operation_type: sync_op.operation_type,
            operation_key: sync_op.operation_key,
            idempotency_key: sync_op.idempotency_key,
            request_hash: sync_op.request_hash,
            request_metadata: sync_op.request_metadata,
            response_metadata: sync_op.response_metadata,
            state: sync_op.state,
            attempt_count: sync_op.attempt_count,
            last_error: sync_op.last_error,
            created_at: sync_op.created_at,
            completed_at: sync_op.completed_at
          }
        end),
      approvals:
        Enum.map(approvals, fn approval ->
          %{
            id: approval.id,
            invoice_intent_id: approval.invoice_intent_id,
            action: approval.action,
            actor_type: approval.actor_type,
            actor_id: approval.actor_id,
            reason: approval.reason,
            intent_hash: approval.intent_hash,
            erp_draft_hash: approval.erp_draft_hash,
            occurred_at: approval.occurred_at
          }
        end)
    }
  end

  defp audit_evidence(scope, intent_ids) do
    team_id = Scope.team_id!(scope)

    operation_ids =
      Repo.all(
        from operation in Operations.Operation,
          where:
            operation.team_id == ^team_id and operation.target_type == "invoice_intent" and
              operation.target_id in ^intent_ids,
          select: operation.id
      )

    entries =
      Repo.all(
        from entry in Audit.Entry,
          where:
            entry.team_id == ^team_id and
              ((entry.aggregate_type == "invoice_intent" and entry.aggregate_id in ^intent_ids) or
                 (entry.aggregate_type == "operation" and entry.aggregate_id in ^operation_ids)),
          order_by: [asc: entry.occurred_at, asc: entry.id]
      )

    %{
      entries:
        Enum.map(entries, fn entry ->
          %{
            id: entry.id,
            event_type: entry.event_type,
            actor_type: entry.actor_type,
            actor_id: entry.actor_id,
            aggregate_type: entry.aggregate_type,
            aggregate_id: entry.aggregate_id,
            correlation_id: entry.correlation_id,
            payload: entry.payload,
            occurred_at: entry.occurred_at
          }
        end)
    }
  end

  defp build_file(name, document) do
    bytes = Canonical.encode!(document)

    %{
      name: name,
      content_type: "application/json",
      bytes: bytes,
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end

  defp get_team_intent(scope, intent_id) do
    Repo.one(
      from intent in InvoiceIntent,
        where: intent.id == ^intent_id and intent.team_id == ^Scope.team_id!(scope)
    )
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp authorize(scope) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, @read_roles),
      do: :ok,
      else: {:error, :unauthorized}
  end
end
