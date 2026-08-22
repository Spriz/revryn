defmodule BillingCore.ERP.Sync do
  @moduledoc """
  Draft synchronization, approval, and booking workflows
  (SPEC Epic F, §17.8–17.10, §11.2/§11.3).

  Every external write is a durable operation with a stable operation key and
  idempotency key; outcomes are verified by read-after-write reconciliation
  before any lifecycle claim (INV-008/009). Unknown outcomes reconcile before
  retry (BC-US-105).
  """

  import Ecto.Query

  alias BillingCore.{Audit, Billing, Operations, Outbox, Repo, Scope}
  alias BillingCore.Billing.InvoiceIntent
  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP
  alias BillingCore.ERP.{ApprovalRecord, Connection, ErpDocument, SyncOperation}
  alias BillingCore.ERP.Sync.Builder
  alias BillingCore.Reconciliation.Comparator

  @doc """
  Validates and enqueues draft creation for a frozen intent (BC-US-081).
  Returns the durable operation to follow. Mapping/validation blockers return
  `{:error, {:blocked, blockers}}` without side effects (BC-US-080).
  """
  @spec request_synchronization(Scope.t(), InvoiceIntent.t()) ::
          {:ok, Operations.Operation.t()} | {:error, term()}
  def request_synchronization(%Scope{} = scope, %InvoiceIntent{} = intent) do
    with :ok <- authorize(scope, [:finance_operator]),
         :ok <- ensure_team(scope, intent.team_id),
         {:ok, connection} <- ERP.get_connection(scope),
         :ok <- ensure_connection_usable(connection),
         {:ok, _canonical} <- Builder.build(intent, connection) do
      external_reference = Builder.external_reference(intent)
      operation_key = "create_draft:#{intent.id}:v#{intent.intent_version}"

      Repo.transaction(fn ->
        case Billing.transition_intent(scope, intent, :enqueue_sync) do
          {:ok, _lifecycle} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        erp_document =
          Repo.insert!(%ErpDocument{
            team_id: intent.team_id,
            erp_connection_id: connection.id,
            invoice_intent_id: intent.id,
            document_type: intent.document_kind,
            state: "pending",
            external_reference: external_reference
          })

        operation =
          Operations.create!(%{
            team_id: intent.team_id,
            organization_id: scope.organization && scope.organization.id,
            type: "erp.create_draft",
            actor_type: "user",
            actor_id: actor_id(scope),
            target_type: "invoice_intent",
            target_id: intent.id,
            correlation_id: scope.correlation_id,
            metadata: %{"erp_document_id" => erp_document.id}
          })

        sync_op =
          Repo.insert!(%SyncOperation{
            team_id: intent.team_id,
            erp_document_id: erp_document.id,
            operation_id: operation.id,
            operation_type: "create_draft",
            operation_key: operation_key,
            idempotency_key: Canonical.hash(%{"key" => operation_key}),
            request_hash: intent.content_hash,
            request_metadata: %{"external_reference" => external_reference},
            state: "queued",
            created_at: DateTime.utc_now()
          })

        Audit.record!(scope, "erp.sync.requested",
          aggregate: {:invoice_intent, intent.id},
          payload: %{operation_id: operation.id}
        )

        %{operation_id: operation.id, sync_operation_id: sync_op.id}
        |> BillingCore.ERP.SyncWorker.new()
        |> Oban.insert!()

        operation
      end)
    end
  end

  @doc """
  Approves a reconciled draft for booking (BC-US-084). Requires a current
  successful reconciliation; records intent and external draft hashes.
  """
  @spec approve_invoice(Scope.t(), InvoiceIntent.t(), keyword()) ::
          {:ok, ApprovalRecord.t()} | {:error, term()}
  def approve_invoice(%Scope{} = scope, %InvoiceIntent{} = intent, opts \\ []) do
    with :ok <- authorize(scope, [:finance_operator]),
         :ok <- ensure_team(scope, intent.team_id),
         %ErpDocument{state: "draft", last_reconciled_at: %DateTime{}} = doc <-
           current_document(intent) || {:error, :no_reconciled_draft} do
      Repo.transaction(fn ->
        case Billing.transition_intent(scope, intent, :approve) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        approval =
          Repo.insert!(%ApprovalRecord{
            team_id: intent.team_id,
            invoice_intent_id: intent.id,
            action: "approved",
            actor_type: "user",
            actor_id: actor_id(scope),
            reason: opts[:reason],
            intent_hash: intent.content_hash,
            erp_draft_hash: doc.last_external_hash,
            occurred_at: DateTime.utc_now()
          })

        Audit.record!(scope, "erp.invoice.approved",
          aggregate: {:invoice_intent, intent.id},
          payload: %{erp_draft_hash: doc.last_external_hash}
        )

        approval
      end)
    else
      %ErpDocument{} -> {:error, :no_reconciled_draft}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Enqueues booking of an approved draft (BC-US-085)."
  @spec request_booking(Scope.t(), InvoiceIntent.t()) ::
          {:ok, Operations.Operation.t()} | {:error, term()}
  def request_booking(%Scope{} = scope, %InvoiceIntent{} = intent) do
    with :ok <- authorize(scope, [:finance_operator]),
         :ok <- ensure_team(scope, intent.team_id),
         %ErpDocument{state: "draft"} = doc <-
           current_document(intent) || {:error, :no_reconciled_draft},
         %ApprovalRecord{} = approval <- latest_approval(intent) || {:error, :not_approved} do
      operation_key = "book:#{intent.id}:v#{intent.intent_version}"

      Repo.transaction(fn ->
        case Billing.transition_intent(scope, intent, :book) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        operation =
          Operations.create!(%{
            team_id: intent.team_id,
            organization_id: scope.organization && scope.organization.id,
            type: "erp.book_document",
            actor_type: "user",
            actor_id: actor_id(scope),
            target_type: "invoice_intent",
            target_id: intent.id,
            correlation_id: scope.correlation_id,
            metadata: %{
              "erp_document_id" => doc.id,
              "approved_draft_hash" => approval.erp_draft_hash
            }
          })

        sync_op =
          Repo.insert!(%SyncOperation{
            team_id: intent.team_id,
            erp_document_id: doc.id,
            operation_id: operation.id,
            operation_type: "book",
            operation_key: operation_key,
            idempotency_key: Canonical.hash(%{"key" => operation_key}),
            request_hash: intent.content_hash,
            request_metadata: %{},
            state: "queued",
            created_at: DateTime.utc_now()
          })

        Audit.record!(scope, "erp.booking.requested",
          aggregate: {:invoice_intent, intent.id},
          payload: %{operation_id: operation.id}
        )

        %{operation_id: operation.id, sync_operation_id: sync_op.id}
        |> BillingCore.ERP.SyncWorker.new()
        |> Oban.insert!()

        operation
      end)
    else
      %ErpDocument{} -> {:error, :no_reconciled_draft}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Authorized manual retry of a failed ERP operation (BC-US-106, §11.3):
  transitions `failed → queued`, requeues the linked sync operation, and
  re-enqueues the worker so execution actually resumes. Retry re-runs full
  validation against current mappings.
  """
  @spec retry_operation(Scope.t(), Operations.Operation.t()) ::
          {:ok, Operations.Operation.t()} | {:error, term()}
  def retry_operation(%Scope{} = scope, %Operations.Operation{} = operation) do
    with :ok <- authorize(scope, [:finance_operator]),
         :ok <- ensure_team(scope, operation.team_id),
         :ok <- ensure_erp_operation(operation),
         {:ok, retried} <- Operations.transition(operation, :manual_retry) do
      {:ok, retried} =
        Repo.transaction(fn ->
          sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)

          sync_op
          |> Ecto.Changeset.change(state: "queued", next_attempt_at: nil)
          |> Repo.update!()

          resume_intent_sync(scope, operation, "manual_retry")

          Audit.record!(scope, "erp.operation.manual_retry",
            aggregate: {:operation, operation.id}
          )

          %{operation_id: retried.id, sync_operation_id: sync_op.id}
          |> retry_worker(operation).new()
          |> Oban.insert!()

          retried
        end)

      {:ok, retried}
    end
  end

  @doc """
  Remediate-and-requeue for a blocked ERP operation (§11.3, BC-US-156).

  The operator fixes the underlying precondition first; this command then
  moves `blocked → queued` and re-enqueues the SAME durable sync operation
  (same operation key — idempotent replay, no duplicate external effect).
  Authorization-class blocks (provider credentials/permissions) are
  operator-only and require `team_admin`; other blocked preconditions are
  finance remediations.
  """
  @spec remediate_operation(Scope.t(), Operations.Operation.t()) ::
          {:ok, Operations.Operation.t()} | {:error, term()}
  def remediate_operation(%Scope{} = scope, %Operations.Operation{} = operation) do
    with :ok <- authorize_remediation(scope, operation),
         :ok <- ensure_team(scope, operation.team_id),
         :ok <- ensure_erp_operation(operation),
         {:ok, requeued} <- Operations.transition(operation, :remediate) do
      {:ok, requeued} =
        Repo.transaction(fn ->
          sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)

          sync_op
          |> Ecto.Changeset.change(state: "queued", next_attempt_at: nil)
          |> Repo.update!()

          resume_intent_sync(scope, operation, "remediated")

          Audit.record!(scope, "erp.operation.remediated",
            aggregate: {:operation, operation.id},
            payload: %{error_class: operation.error_class}
          )

          %{operation_id: requeued.id, sync_operation_id: sync_op.id}
          |> retry_worker(operation).new()
          |> Oban.insert!()

          requeued
        end)

      {:ok, requeued}
    end
  end

  # §11.2 models the operator recovery edge explicitly
  # (sync_error → retry_sync → sync_pending) so a retried draft
  # creation can reconcile legally; other intent states tolerate
  # the no-op (INV-015).
  defp resume_intent_sync(
         scope,
         %{type: "erp.create_draft", target_type: "invoice_intent"} = operation,
         reason
       ) do
    intent = Repo.get!(InvoiceIntent, operation.target_id)

    case Billing.transition_intent(scope, intent, :retry_sync, reason: reason) do
      {:ok, _lifecycle} -> :ok
      {:error, {:illegal_state, _}} -> :ok
    end
  end

  defp resume_intent_sync(_scope, _operation, _reason), do: :ok

  defp authorize_remediation(scope, %{error_class: "authorization"}),
    do: authorize(scope, [:team_admin])

  defp authorize_remediation(scope, _operation),
    do: authorize(scope, [:finance_operator, :team_admin])

  defp ensure_erp_operation(%{type: "erp." <> _}), do: :ok
  defp ensure_erp_operation(_), do: {:error, :not_an_erp_operation}

  # Close-posting operations execute through the close worker; re-enqueueing
  # the invoice sync worker would load a voucher document with no invoice
  # intent and crash the retry.
  defp retry_worker(%{type: "erp.post_customer_credit_settlement"}),
    do: BillingCore.Credits.SettlementWorker

  defp retry_worker(%{type: "erp.post_customer_credit_close"}),
    do: BillingCore.Credits.CloseWorker

  defp retry_worker(_operation), do: BillingCore.ERP.SyncWorker

  ## Worker execution paths (called by SyncWorker)

  @doc false
  def execute(sync_operation_id) do
    if Application.get_env(:billing_core, :erp_writes_disabled, false) do
      # Restore-validation mode (SPEC §21.5/§23.9): never touch a real ERP.
      # The operation stays queued for after reconciliation re-enables writes.
      require Logger
      Logger.warning("erp writes disabled; deferring sync operation #{sync_operation_id}")
      :ok
    else
      do_execute(sync_operation_id)
    end
  end

  defp do_execute(sync_operation_id) do
    sync_op = Repo.get!(SyncOperation, sync_operation_id)
    operation = Operations.get!(sync_op.operation_id)
    doc = Repo.get!(ErpDocument, sync_op.erp_document_id)

    intent =
      Repo.one!(from i in InvoiceIntent, where: i.id == ^doc.invoice_intent_id, preload: [:lines])

    connection = Repo.get!(Connection, doc.erp_connection_id)

    case claim(operation) do
      {:ok, operation} ->
        run_operation(sync_op.operation_type, sync_op, operation, doc, intent, connection)

      :not_runnable ->
        :ok
    end
  end

  defp claim(%{state: "queued"} = op), do: {:ok, Operations.transition!(op, :claim)}
  defp claim(%{state: "retry_scheduled"} = op), do: {:ok, Operations.transition!(op, :retry)}
  # A provider error during unknown-outcome reconciliation parks the
  # operation in `reconciling` (the machine has no failure edge from
  # there); the snoozed job must be able to resume the reconciliation.
  defp claim(%{state: "reconciling"} = op), do: {:ok, op}
  defp claim(_), do: :not_runnable

  # Resumption of a parked reconciliation: the operation is already in
  # `reconciling` (a provider error interrupted the last attempt), so skip
  # straight back to proving the outcome instead of re-issuing the write.
  defp run_operation(type, sync_op, %{state: "reconciling"} = operation, doc, intent, connection) do
    kind = if type == "book", do: :booked, else: :draft
    {:ok, canonical} = Builder.build(intent, connection)
    reconcile_unknown(sync_op, operation, doc, intent, canonical, connection, kind)
  end

  defp run_operation("create_draft", sync_op, operation, doc, intent, connection) do
    adapter = ERP.adapter_for(connection)
    ctx = ERP.connection_context(connection)

    case Builder.build(intent, connection) do
      {:ok, canonical} ->
        doc = mark_syncing!(doc)

        case adapter.create_draft(ctx, canonical, sync_op.idempotency_key) do
          {:ok, external_doc} ->
            reconcile_and_complete(
              sync_op,
              operation,
              doc,
              intent,
              canonical,
              external_doc,
              :draft
            )

          {:unknown, _hint} ->
            operation =
              Operations.record_failure!(operation, :outcome_unknown,
                summary: "response lost after create"
              )

            recover_unknown(sync_op, operation, doc, intent, canonical, connection, :draft)

          {:error, error} ->
            handle_provider_error(sync_op, operation, doc, connection, error)
        end

      {:error, {:blocked, blockers}} ->
        fail_validation(sync_op, operation, doc, blockers)
    end
  end

  defp run_operation("book", sync_op, operation, doc, intent, connection) do
    adapter = ERP.adapter_for(connection)
    ctx = ERP.connection_context(connection)
    {:ok, canonical} = Builder.build(intent, connection)

    approved_hash = operation.metadata["approved_draft_hash"]

    with {:fetch, {:ok, current}} <-
           {:fetch, adapter.get_document(ctx, {:draft, doc.external_draft_number})},
         {:drift, false} <- {:drift, current.external_hash != approved_hash} do
      delivery_mode = Builder.delivery_mode(connection)

      case adapter.book_document(
             ctx,
             {:draft, doc.external_draft_number},
             %{delivery_mode: delivery_mode},
             sync_op.idempotency_key
           ) do
        {:ok, booked_doc} ->
          reconcile_and_complete(sync_op, operation, doc, intent, canonical, booked_doc, :booked)

        {:unknown, _hint} ->
          operation =
            Operations.record_failure!(operation, :outcome_unknown,
              summary: "response lost after book"
            )

          recover_unknown(sync_op, operation, doc, intent, canonical, connection, :booked)

        {:error, error} ->
          handle_provider_error(sync_op, operation, doc, connection, error)
      end
    else
      {:fetch, {:error, error}} ->
        handle_provider_error(sync_op, operation, doc, connection, error)

      {:drift, true} ->
        # BC-US-084/§17.10: external draft changed after approval.
        Repo.transaction(fn ->
          Operations.record_failure!(operation, :conflict,
            blocked_reason: "external_draft_changed_after_approval",
            summary: "draft hash differs from approved snapshot"
          )

          update_sync_op!(sync_op, "blocked", %{"reason" => "draft_hash_drift"})
          intent_transition!(:system, sync_op, doc, :sync_failed, reason: "draft_hash_drift")
        end)

        :ok
    end
  end

  defp reconcile_and_complete(sync_op, operation, doc, intent, canonical, external_doc, kind) do
    case Comparator.compare(canonical, external_doc) do
      %Comparator.Result{status: :match} ->
        {:ok, _} =
          Repo.transaction(fn ->
            now = DateTime.utc_now()

            doc
            |> Ecto.Changeset.change(
              state: to_string(kind),
              external_draft_number: external_doc.external_draft_id || doc.external_draft_number,
              external_booked_number: external_doc.external_booked_number,
              last_external_snapshot: external_snapshot(external_doc),
              last_external_hash: external_doc.external_hash,
              last_reconciled_at: now
            )
            |> Ecto.Changeset.optimistic_lock(:version)
            |> Repo.update!()

            update_sync_op!(sync_op, "succeeded", %{
              "external_draft_id" => external_doc.external_draft_id,
              "external_booked_number" => external_doc.external_booked_number
            })

            case operation.state do
              "reconciling" -> Operations.transition!(operation, :effect_found)
              _ -> Operations.transition!(operation, :succeed)
            end

            event = if kind == :draft, do: :draft_reconciled, else: :booked_reconciled
            intent_transition!(:system, sync_op, doc, event, operation_id: operation.id)

            outbox_event =
              if kind == :draft,
                do: "erp_document.draft_created.v1",
                else: "erp_document.booked.v1"

            Outbox.emit!(outbox_event,
              aggregate: {:erp_document, doc.id},
              team_id: doc.team_id,
              causation_id: operation.id,
              payload: %{
                invoice_intent_id: intent.id,
                external_reference: doc.external_reference,
                external_booked_number: external_doc.external_booked_number
              }
            )

            # SPEC §9.4.1: once the invoice is booked the receivable
            # exists, so its pending credit settlement (if any) gets its
            # durable clearing-voucher operation in the same transaction.
            if kind == :booked do
              BillingCore.Credits.Settlements.enqueue_for_booked_intent!(doc)
            end
          end)

        :ok

      %Comparator.Result{status: :mismatch, differences: differences} ->
        {:ok, _} =
          Repo.transaction(fn ->
            doc
            |> Ecto.Changeset.change(
              state: "reconciliation_failed",
              last_external_snapshot: external_snapshot(external_doc),
              last_external_hash: external_doc.external_hash,
              last_reconciled_at: DateTime.utc_now()
            )
            |> Ecto.Changeset.optimistic_lock(:version)
            |> Repo.update!()

            update_sync_op!(sync_op, "failed", %{"mismatch_count" => length(differences)})

            Operations.record_failure!(operation, :validation,
              code: "reconciliation_mismatch",
              summary: summarize_differences(differences)
            )

            intent_transition!(:system, sync_op, doc, :sync_failed,
              reason: "reconciliation_mismatch"
            )

            Outbox.emit!("erp_document.reconciliation_failed.v1",
              aggregate: {:erp_document, doc.id},
              team_id: doc.team_id,
              causation_id: operation.id,
              payload: %{differences: Enum.map(differences, &difference_payload/1)}
            )
          end)

        :ok
    end
  end

  defp recover_unknown(sync_op, operation, doc, intent, canonical, connection, kind) do
    operation = Operations.transition!(operation, :reconcile)
    reconcile_unknown(sync_op, operation, doc, intent, canonical, connection, kind)
  end

  defp reconcile_unknown(sync_op, operation, doc, intent, canonical, connection, kind) do
    adapter = ERP.adapter_for(connection)
    ctx = ERP.connection_context(connection)

    case adapter.find_document(ctx, doc.external_reference) do
      {:ok, nil} ->
        # Absence proven under the operation lock: safe to retry.
        operation =
          Operations.transition!(operation, :absence_proven, %{
            next_attempt_at: DateTime.utc_now()
          })

        update_sync_op!(sync_op, "queued", %{"recovery" => "absence_proven"})
        {:snooze, snooze_seconds(operation)}

      {:ok, external_doc} ->
        reconcile_and_complete(sync_op, operation, doc, intent, canonical, external_doc, kind)

      {:error, error} ->
        # The outcome is STILL unknown — the machine has no failure edge
        # out of `reconciling`, and recording a failure here would crash
        # (record_failure!/3 accepts executing operations only). Park the
        # operation as `reconciling`, flag auth problems, and snooze so
        # this same job resumes the reconciliation (see claim/1).
        {class, _opts} = classify(error)

        if class == :authorization do
          ERP.mark_action_required!(connection, "provider_auth_failure")
        end

        update_sync_op!(sync_op, "reconciling", %{"error" => inspect_error(error)})
        {:snooze, 30}
    end
  end

  defp handle_provider_error(sync_op, operation, doc, connection, error) do
    {class, opts} = classify(error)

    if class == :authorization do
      ERP.mark_action_required!(connection, "provider_auth_failure")
    end

    operation = Operations.record_failure!(operation, class, opts)

    case operation.state do
      "retry_scheduled" ->
        update_sync_op!(sync_op, "retry_scheduled", %{"error" => inspect_error(error)})
        {:snooze, snooze_seconds(operation)}

      "blocked" ->
        Repo.transaction(fn ->
          update_sync_op!(sync_op, "blocked", %{"error" => inspect_error(error)})

          intent_transition!(:system, sync_op, doc, :sync_failed,
            reason: opts[:code] || "blocked"
          )
        end)

        :ok

      "failed" ->
        Repo.transaction(fn ->
          update_sync_op!(sync_op, "failed", %{"error" => inspect_error(error)})

          intent_transition!(:system, sync_op, doc, :sync_failed,
            reason: opts[:code] || "terminal"
          )
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp fail_validation(sync_op, operation, doc, blockers) do
    Repo.transaction(fn ->
      update_sync_op!(sync_op, "failed", %{"blockers" => Enum.map(blockers, &to_string/1)})

      Operations.record_failure!(operation, :validation,
        code: "mapping_validation",
        summary: blockers |> Enum.map_join(", ", &to_string/1)
      )

      intent_transition!(:system, sync_op, doc, :sync_failed, reason: "mapping_validation")
    end)

    :ok
  end

  ## Helpers

  defp classify({:authentication, _}),
    do: {:authorization, [code: "authentication", blocked_reason: "credentials_invalid"]}

  defp classify({:authorization, _}),
    do: {:authorization, [code: "authorization", blocked_reason: "insufficient_permissions"]}

  defp classify({:validation, fields}),
    do: {:validation, [code: "provider_validation", summary: inspect_error(fields)]}

  defp classify({:not_found, _}),
    do: {:conflict, [code: "external_missing", blocked_reason: "external_document_missing"]}

  defp classify({:conflict, _}),
    do: {:conflict, [code: "external_conflict", blocked_reason: "external_state_conflict"]}

  defp classify({:rate_limited, %{retry_after: retry_after}}),
    do: {:throttled, [code: "rate_limited", retry_after: retry_after]}

  defp classify({:provider_failure, _}), do: {:transient, [code: "provider_failure"]}

  defp classify({:unsupported_capability, cap}),
    do: {:terminal, [code: "unsupported_capability", summary: to_string(cap)]}

  defp classify(other), do: {:transient, [code: "unclassified", summary: inspect_error(other)]}

  defp snooze_seconds(%{next_attempt_at: nil}), do: 5

  defp snooze_seconds(%{next_attempt_at: at}) do
    max(DateTime.diff(at, DateTime.utc_now()), 1)
  end

  defp mark_syncing!(doc) do
    doc
    |> Ecto.Changeset.change(state: "syncing")
    |> Ecto.Changeset.optimistic_lock(:version)
    |> Repo.update!()
  end

  defp update_sync_op!(sync_op, state, response_metadata) do
    sync_op
    |> Ecto.Changeset.change(
      state: state,
      attempt_count: sync_op.attempt_count + 1,
      response_metadata: response_metadata,
      completed_at: if(state in ["succeeded", "failed"], do: DateTime.utc_now())
    )
    |> Repo.update!()
  end

  defp intent_transition!(actor, _sync_op, doc, event, opts) do
    intent = Repo.get!(InvoiceIntent, doc.invoice_intent_id)

    case Billing.transition_intent(actor, intent, event, opts) do
      {:ok, _} -> :ok
      # Lifecycle may already reflect the target state after a crash-retry;
      # idempotent workers tolerate that (INV-015).
      {:error, {:illegal_state, _}} -> :ok
    end
  end

  defp current_document(%InvoiceIntent{} = intent) do
    Repo.one(
      from d in ErpDocument,
        where: d.invoice_intent_id == ^intent.id,
        order_by: [desc: d.created_at],
        limit: 1
    )
  end

  defp latest_approval(%InvoiceIntent{} = intent) do
    Repo.one(
      from a in ApprovalRecord,
        where: a.invoice_intent_id == ^intent.id and a.action == "approved",
        order_by: [desc: a.occurred_at],
        limit: 1
    )
  end

  defp ensure_connection_usable(%Connection{status: "active"}), do: :ok

  defp ensure_connection_usable(%Connection{status: status}),
    do: {:error, {:connection_not_usable, status}}

  defp external_snapshot(external_doc) do
    external_doc
    |> Map.from_struct()
    |> Map.take([
      :state,
      :external_draft_id,
      :external_booked_number,
      :external_reference,
      :currency,
      :provider_extras
    ])
    |> Canonical.encode!()
    |> Jason.decode!()
  end

  defp summarize_differences(differences) do
    differences
    |> Enum.filter(&(&1.severity == :fatal))
    |> Enum.map_join(", ", &"#{&1.field}#{if &1.line_key, do: "@#{&1.line_key}"}")
    |> String.slice(0, 250)
  end

  defp difference_payload(diff) do
    %{severity: diff.severity, field: diff.field, line_key: diff.line_key}
  end

  defp inspect_error(error), do: error |> inspect() |> String.slice(0, 300)

  defp authorize(%Scope{} = scope, roles) do
    if Scope.has_team_role?(scope, roles), do: :ok, else: {:error, :unauthorized}
  end

  defp ensure_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :unauthorized}
  end

  defp actor_id(%Scope{user: %{id: id}}), do: to_string(id)
  defp actor_id(_), do: nil
end

defmodule BillingCore.ERP.SyncWorker do
  @moduledoc "Oban worker executing durable ERP sync operations (SPEC §11.3)."

  use Oban.Worker, queue: :erp, max_attempts: 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sync_operation_id" => sync_operation_id}}) do
    BillingCore.ERP.Sync.execute(sync_operation_id)
  end
end
