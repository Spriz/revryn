defmodule BillingCore.Workflows.InvoiceSyncTest do
  @moduledoc """
  Workflow documentation: synchronizing frozen invoice intent to an ERP draft,
  reconciling the read-back, approving, and booking (SPEC §1.2 vertical slice,
  Epic F, §17.8–17.10).

  The stateful fake ERP stands in for e-conomic at the network boundary;
  PostgreSQL, contexts, durable operations, Oban jobs, and reconciliation are
  real (SPEC §23.7).
  """

  use BillingCore.DataCase, async: false

  import BillingCore.ContractsFixtures

  alias BillingCore.{Billing, Contracts, Operations, Repo}
  alias BillingCore.Domain.Money
  alias BillingCore.ERP
  alias BillingCore.ERP.{CanonicalInvoice, ErpDocument, FakeERP, SyncOperation}
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Sync

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    customer = customer_fixture(scope)

    {:ok, connection} =
      ERP.create_connection(scope, %{provider: "fake", secret_reference: "unused"})

    {:ok, connection} = ERP.validate_connection(scope, connection)
    assert connection.status == "active"

    {:ok, _mapping} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    product_id = insert_product_with_mapping!(scope, connection, "SAAS-ANNUAL")

    %{
      fake: fake,
      scope: scope,
      customer: customer,
      connection: connection,
      product_id: product_id
    }
  end

  defp insert_product_with_mapping!(scope, connection, external_number) do
    team_id = scope.team.id
    product_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.insert_all(
      "products",
      [
        %{
          id: Ecto.UUID.dump!(product_id),
          team_id: Ecto.UUID.dump!(team_id),
          code: "platform-#{System.unique_integer([:positive])}",
          name: "Platform",
          status: "active",
          current_version: 1,
          created_at: now,
          updated_at: now
        }
      ],
      prefix: "billing"
    )

    Repo.insert_all(
      "product_erp_mappings",
      [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          team_id: Ecto.UUID.dump!(team_id),
          product_id: Ecto.UUID.dump!(product_id),
          erp_connection_id: Ecto.UUID.dump!(connection.id),
          external_product_number: external_number,
          validation_status: "valid",
          created_at: now,
          updated_at: now
        }
      ],
      prefix: "billing"
    )

    product_id
  end

  defp freeze_annual_intent!(scope, customer, product_id, invoice_date \\ ~D[2026-09-01]) do
    {:ok, intent} =
      Billing.freeze_invoice_intent(scope, %{
        customer_id: customer.id,
        customer_version: customer.current_version,
        customer_external_id: customer.external_id,
        customer_legal_name: "Acme ApS",
        currency: "DKK",
        invoice_date: invoice_date,
        usage_cutoff: ~U[2026-09-01 00:00:00Z],
        lines: [
          %{
            line_key: "subscription:sub-1:component:annual:2026-09-15",
            product_id: product_id,
            product_version: 1,
            description: "Annual platform subscription — 2026-09-15 to 2027-09-14",
            quantity: Decimal.new(1),
            amount_minor: 12_000_000,
            recognition_mode: :over_time,
            service_start: ~D[2026-09-15],
            service_end_exclusive: ~D[2027-09-15],
            calculation_trace: %{"model" => "fixed_recurring"},
            ordinal: 0
          }
        ]
      })

    intent
  end

  defp drain_erp_queue do
    Oban.drain_queue(queue: :erp, with_safety: false)
  end

  test "annual prepaid intent syncs to a reconciled draft, then books with accrual dates preserved",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    # Given a frozen intent for the SPEC §10.10 annual prepaid example
    intent = freeze_annual_intent!(scope, customer, product_id)
    assert intent.net_amount_minor == 12_000_000
    assert Billing.intent_state(intent) == "frozen"

    # When synchronization is requested and the worker runs
    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert Billing.intent_state(intent) == "sync_pending"

    assert %{success: 1} = drain_erp_queue()

    # Then the draft exists externally, was read back, and reconciled exactly
    assert Billing.intent_state(intent) == "erp_draft"
    operation = Operations.get!(operation.id)
    assert operation.state == "succeeded"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "draft"
    assert doc.external_draft_number
    assert doc.last_reconciled_at

    ctx = FakeERP.connection_context(fake)
    {:ok, external} = FakeERP.get_document(ctx, {:draft, doc.external_draft_number})
    assert [line] = external.lines
    assert line.amount.minor_units == 12_000_000
    assert line.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}

    # And approval + booking complete the accounting workflow
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "reviewed")
    assert Billing.intent_state(intent) == "approved"

    {:ok, _book_op} = Sync.request_booking(scope, intent)
    assert Billing.intent_state(intent) == "booking_pending"
    assert %{success: 1} = drain_erp_queue()

    assert Billing.intent_state(intent) == "erp_booked"
    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "booked"
    assert doc.external_booked_number

    {:ok, booked} = FakeERP.get_document(ctx, {:booked, doc.external_booked_number})
    assert [booked_line] = booked.lines
    assert booked_line.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}
  end

  test "missing product mapping blocks synchronization with an explicit blocker",
       %{scope: scope, customer: customer} do
    orphan_product = Ecto.UUID.generate()

    intent =
      freeze_annual_intent!(scope, customer, orphan_product)

    assert {:error, {:blocked, blockers}} = Sync.request_synchronization(scope, intent)
    assert {:product_mapping_missing, orphan_product} in blockers
    assert Billing.intent_state(intent) == "frozen"
  end

  test "unknown outcome reconciles by external reference instead of duplicating the draft",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_unknown_outcome(fake, :create_draft)

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    # The side effect happened, the response was lost, and recovery found the
    # existing draft by stable reference — no duplicate was created.
    assert Billing.intent_state(intent) == "erp_draft"
    assert Operations.get!(operation.id).state == "succeeded"

    ctx = FakeERP.connection_context(fake)
    docs = FakeERP.list_documents(fake)
    assert length(docs) == 1

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    {:ok, external} = FakeERP.get_document(ctx, {:draft, doc.external_draft_number})
    assert external.external_reference == doc.external_reference
  end

  test "human-edited draft is detected before booking and blocks with remediation",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)
    {:ok, _op} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()
    {:ok, _} = Sync.approve_invoice(scope, intent)

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)

    FakeERP.human_edit_draft(fake, doc.external_draft_number, fn draft ->
      update_in(draft.lines, fn [line] -> [%{line | description: "edited by a human"}] end)
    end)

    {:ok, book_op} = Sync.request_booking(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    operation = Operations.get!(book_op.id)
    assert operation.state == "blocked"
    assert operation.blocked_reason == "external_draft_changed_after_approval"
    assert Billing.intent_state(intent) == "sync_error"

    # The fake still holds a draft — nothing was booked.
    assert [%{state: :draft}] = FakeERP.list_documents(fake)
  end

  test "rate limiting schedules a retry and eventually succeeds",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_failure(fake, :create_draft, {:error, {:rate_limited, %{retry_after: 1}}})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "retry_scheduled"
    assert operation.error_class == "throttled"

    # The snoozed job re-runs after the retry timer; draining scheduled jobs
    # simulates the timer elapsing.
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)

    assert Operations.get!(operation.id).state == "succeeded"
    assert Billing.intent_state(intent) == "erp_draft"
  end

  test "cross-team scope cannot synchronize another team's intent",
       %{customer: customer, product_id: product_id, scope: scope} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    other_scope = billing_scope_fixture([:finance_operator])
    assert {:error, :unauthorized} = Sync.request_synchronization(other_scope, intent)
  end

  test "approval and booking refuse every out-of-order entry with an explicit error",
       %{scope: scope, customer: customer, product_id: product_id} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    # Nothing has synced: there is no draft to approve or book.
    assert {:error, :no_reconciled_draft} = Sync.approve_invoice(scope, intent)
    assert {:error, :no_reconciled_draft} = Sync.request_booking(scope, intent)

    {:ok, _op} = Sync.request_synchronization(scope, intent)

    # A duplicate synchronization request rolls back instead of enqueueing a
    # second draft-creation operation.
    assert {:error, {:illegal_state, _}} = Sync.request_synchronization(scope, intent)

    assert %{success: 1} = drain_erp_queue()

    # Booking without an approval record is refused.
    assert {:error, :not_approved} = Sync.request_booking(scope, intent)

    {:ok, _approval} = Sync.approve_invoice(scope, intent)

    # A second approval finds the reconciled draft but the lifecycle refuses.
    assert {:error, {:illegal_state, _}} = Sync.approve_invoice(scope, intent)

    {:ok, _book_op} = Sync.request_booking(scope, intent)

    # A duplicate booking request while the first is still queued rolls back
    # instead of enqueueing a second external booking.
    assert {:error, {:illegal_state, _}} = Sync.request_booking(scope, intent)

    assert %{success: 1} = drain_erp_queue()
    assert Billing.intent_state(intent) == "erp_booked"

    # Once booked, neither approval nor booking can restart on the document.
    assert {:error, :no_reconciled_draft} = Sync.approve_invoice(scope, intent)
    assert {:error, :no_reconciled_draft} = Sync.request_booking(scope, intent)
  end

  test "manual retry refuses operations that are not ERP operations", %{scope: scope} do
    operation =
      Operations.create!(%{
        team_id: scope.team.id,
        type: "billing.run",
        actor_type: "system",
        target_type: "billing_run",
        target_id: Ecto.UUID.generate()
      })

    assert {:error, :not_an_erp_operation} = Sync.retry_operation(scope, operation)
  end

  test "disabled ERP writes defer the queued operation without touching the provider",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)
    {:ok, operation} = Sync.request_synchronization(scope, intent)
    sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)

    Application.put_env(:billing_core, :erp_writes_disabled, true)
    on_exit(fn -> Application.delete_env(:billing_core, :erp_writes_disabled) end)

    # The job completes without side effects; the durable operation stays
    # queued for after reconciliation re-enables writes (SPEC §21.5).
    assert %{success: 1} = drain_erp_queue()
    assert Operations.get!(operation.id).state == "queued"
    assert Repo.get!(SyncOperation, sync_op.id).state == "queued"
    assert FakeERP.list_documents(fake) == []

    Application.delete_env(:billing_core, :erp_writes_disabled)

    # Re-executing the same durable sync operation resumes exactly once.
    assert :ok = Sync.execute(sync_op.id)
    assert Billing.intent_state(intent) == "erp_draft"
    assert Operations.get!(operation.id).state == "succeeded"
    assert [%{state: :draft}] = FakeERP.list_documents(fake)

    # A redelivered job for the completed operation is not runnable.
    assert :ok = Sync.execute(sync_op.id)
    assert [%{state: :draft}] = FakeERP.list_documents(fake)
  end

  test "a mapping that vanishes after enqueue fails validation at execution time",
       %{scope: scope, customer: customer, product_id: product_id} do
    intent = freeze_annual_intent!(scope, customer, product_id)
    {:ok, operation} = Sync.request_synchronization(scope, intent)

    # The customer mapping is deleted under the queued operation.
    Repo.delete_all(
      from m in "customer_erp_mappings",
        prefix: "billing",
        where: m.team_id == type(^scope.team.id, Ecto.UUID)
    )

    # Simulate a crash-replay in which the intent lifecycle already recorded
    # the failure before the worker re-ran (INV-015 tolerance).
    {:ok, _} = Billing.transition_intent(:system, intent, :sync_failed, reason: "crash-replay")
    assert Billing.intent_state(intent) == "sync_error"

    assert %{success: 1} = drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "failed"
    assert operation.error_class == "validation"
    assert operation.safe_error_code == "mapping_validation"
    assert operation.safe_error_summary == "customer_mapping_missing"

    sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)
    assert sync_op.state == "failed"
    assert sync_op.response_metadata["blockers"] == ["customer_mapping_missing"]

    assert Billing.intent_state(intent) == "sync_error"
  end

  test "a lost booking response reconciles the booked invoice without booking twice",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)
    {:ok, _} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()
    {:ok, _} = Sync.approve_invoice(scope, intent)

    FakeERP.inject_unknown_outcome(fake, :book_document)
    {:ok, book_op} = Sync.request_booking(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    # The booking committed, the response was lost, and reconciliation found
    # the booked invoice by its stable reference — exactly one document.
    assert Billing.intent_state(intent) == "erp_booked"
    assert Operations.get!(book_op.id).state == "succeeded"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "booked"
    assert [%{state: :booked}] = FakeERP.list_documents(fake)
  end

  test "an unknown outcome with proven absence retries the same idempotency key",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_unknown_outcome(fake, :create_draft)
    # The reconciliation read is also lost to a caching edge: the provider
    # claims the reference does not exist, so absence is (wrongly but
    # consistently) proven and the retry replays the SAME idempotency key.
    FakeERP.inject_failure(fake, :find_document, {:ok, nil})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{snoozed: 1} = drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "retry_scheduled"

    sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)
    assert sync_op.state == "queued"
    assert sync_op.response_metadata["recovery"] == "absence_proven"

    # The retried create hits the provider's idempotency cache: the draft
    # that was created before the response was lost is returned, not
    # duplicated.
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)
    assert Billing.intent_state(intent) == "erp_draft"
    assert Operations.get!(operation.id).state == "succeeded"
    assert [%{state: :draft}] = FakeERP.list_documents(fake)
  end

  test "a provider error during unknown-outcome reconciliation parks and auto-resumes",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    # The create response is lost AND the reconciliation read then errors:
    # the outcome stays unknown, so the operation parks in `reconciling`
    # and the job snoozes. (The machine has no failure edge out of
    # reconciling — this path used to crash record_failure!/3, leaving the
    # operation permanently stuck.)
    FakeERP.inject_unknown_outcome(fake, :create_draft)
    FakeERP.inject_failure(fake, :find_document, {:error, {:provider_failure, %{status: 502}}})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{snoozed: 1} = drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "reconciling"

    sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)
    assert sync_op.state == "reconciling"

    # The provider recovers: the snoozed job resumes the reconciliation and
    # finds the draft the lost write actually created — exactly once.
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)
    assert Billing.intent_state(intent) == "erp_draft"
    assert Operations.get!(operation.id).state == "succeeded"
    assert [%{state: :draft}] = FakeERP.list_documents(fake)
  end

  test "a draft the provider cannot find at booking time blocks until remediation",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)
    {:ok, _} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()
    {:ok, _} = Sync.approve_invoice(scope, intent)

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)

    FakeERP.inject_failure(
      fake,
      :get_document,
      {:error, {:not_found, {:draft, doc.external_draft_number}}}
    )

    {:ok, book_op} = Sync.request_booking(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    operation = Operations.get!(book_op.id)
    assert operation.state == "blocked"
    assert operation.error_class == "conflict"
    assert operation.blocked_reason == "external_document_missing"
    assert Repo.get_by!(SyncOperation, operation_id: book_op.id).state == "blocked"
    assert Billing.intent_state(intent) == "sync_error"

    # Remediation requeues the same durable operation, which now books.
    {:ok, _} = Sync.remediate_operation(scope, operation)
    assert %{success: 1} = drain_erp_queue()

    assert Operations.get!(book_op.id).state == "succeeded"
    assert Repo.get_by!(ErpDocument, invoice_intent_id: intent.id).state == "booked"
    # The book operation does not resume the intent lifecycle; the tolerated
    # sync_error state stays visible for the operator (INV-015).
    assert Billing.intent_state(intent) == "sync_error"
  end

  test "a transient provider failure while booking retries to success",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)
    {:ok, _} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()
    {:ok, _} = Sync.approve_invoice(scope, intent)

    FakeERP.inject_failure(fake, :book_document, {:error, {:provider_failure, :flaky_socket}})

    {:ok, book_op} = Sync.request_booking(scope, intent)
    drain_erp_queue()

    operation = Operations.get!(book_op.id)
    assert operation.state == "retry_scheduled"
    assert operation.error_class == "transient"

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)
    assert Operations.get!(book_op.id).state == "succeeded"
    assert Billing.intent_state(intent) == "erp_booked"
    assert [%{state: :booked}] = FakeERP.list_documents(fake)
  end

  test "an unclassifiable provider error is treated as transient and retried",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_failure(fake, :create_draft, {:error, :socket_closed_mid_handshake})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "retry_scheduled"
    assert operation.error_class == "transient"
    assert operation.safe_error_code == "unclassified"

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)
    assert Operations.get!(operation.id).state == "succeeded"
    assert Billing.intent_state(intent) == "erp_draft"
  end

  test "a provider draft that does not match the frozen intent fails reconciliation closed",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    # The provider answers the create with a different document than the
    # canonical invoice (simulating a corrupted or crossed response). The
    # decoy is a real provider document with a different amount.
    decoy_invoice = %CanonicalInvoice{
      external_reference: "decoy:#{Ecto.UUID.generate()}",
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Acme ApS", country: "DK"},
      invoice_date: ~D[2026-09-01],
      currency: "DKK",
      lines: [
        %Line{
          order: 0,
          line_key: "decoy-line",
          product_external_id: "SAAS-ANNUAL",
          description: "Annual platform subscription — wrong amount",
          amount: Money.new!("DKK", 11_999_999),
          recognition:
            {:over_time,
             %BillingCore.Domain.Period{
               start_date: ~D[2026-09-15],
               end_date_exclusive: ~D[2027-09-15]
             }}
        }
      ]
    }

    ctx = FakeERP.connection_context(fake)
    {:ok, decoy_doc} = FakeERP.create_draft(ctx, decoy_invoice, "decoy-key")
    FakeERP.inject_failure(fake, :create_draft, {:ok, decoy_doc})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "failed"
    assert operation.error_class == "validation"
    assert operation.safe_error_code == "reconciliation_mismatch"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "reconciliation_failed"

    sync_op = Repo.get_by!(SyncOperation, operation_id: operation.id)
    assert sync_op.state == "failed"
    assert sync_op.response_metadata["mismatch_count"] >= 1

    assert Billing.intent_state(intent) == "sync_error"

    assert Repo.exists?(
             from e in BillingCore.Outbox.Event,
               where:
                 e.event_type == "erp_document.reconciliation_failed.v1" and
                   e.aggregate_id == ^doc.id
           )
  end

  test "an authentication failure blocks the operation and quarantines the connection",
       %{
         scope: scope,
         customer: customer,
         product_id: product_id,
         fake: fake,
         connection: connection
       } do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_failure(fake, :create_draft, {:error, {:authentication, :expired_token}})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "blocked"
    assert operation.error_class == "authorization"
    assert operation.blocked_reason == "credentials_invalid"
    assert Billing.intent_state(intent) == "sync_error"

    # The connection is quarantined, so further synchronization requests are
    # refused up front rather than queued against dead credentials.
    assert Repo.get!(BillingCore.ERP.Connection, connection.id).status == "action_required"

    second = freeze_annual_intent!(scope, customer, product_id, ~D[2026-10-01])

    assert {:error, {:connection_not_usable, "action_required"}} =
             Sync.request_synchronization(scope, second)
  end

  test "a provider conflict on draft creation blocks until remediation",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_failure(
      fake,
      :create_draft,
      {:error, {:conflict, %{reason: :duplicate_external_reference}}}
    )

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    operation = Operations.get!(operation.id)
    assert operation.state == "blocked"
    assert operation.error_class == "conflict"
    assert operation.blocked_reason == "external_state_conflict"
    assert Billing.intent_state(intent) == "sync_error"

    {:ok, _} = Sync.remediate_operation(scope, operation)
    assert %{success: 1} = drain_erp_queue()

    assert Operations.get!(operation.id).state == "succeeded"
    assert Billing.intent_state(intent) == "erp_draft"
    assert [%{state: :draft}] = FakeERP.list_documents(fake)
  end

  test "manual retry converges when the intent lifecycle already resumed",
       %{scope: scope, customer: customer, product_id: product_id, fake: fake} do
    intent = freeze_annual_intent!(scope, customer, product_id)

    FakeERP.inject_failure(fake, :create_draft, {:error, {:validation, [%{field: :layout}]}})

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = drain_erp_queue()

    assert Operations.get!(operation.id).state == "failed"
    assert Billing.intent_state(intent) == "sync_error"

    # A crash-replay already moved the intent back to sync_pending before the
    # operator retried; the retry tolerates the pre-resumed lifecycle.
    {:ok, _} = Billing.transition_intent(:system, intent, :retry_sync)
    assert Billing.intent_state(intent) == "sync_pending"

    {:ok, _retried} = Sync.retry_operation(scope, Operations.get!(operation.id))
    assert %{success: 1} = drain_erp_queue()

    assert Operations.get!(operation.id).state == "succeeded"
    assert Billing.intent_state(intent) == "erp_draft"
    assert [%{state: :draft}] = FakeERP.list_documents(fake)
  end

  # Sync branches left uncovered deliberately:
  #
  #   * `recover_unknown/7`'s find_document error arm — the operation is in
  #     `reconciling` there, and `Operations.record_failure!/3` only accepts
  #     an executing operation, so exercising the arm raises a
  #     FunctionClauseError today (latent bug); asserting the crash would
  #     enshrine it as expected behavior.
  #   * `handle_provider_error/5`'s `_ -> :ok` arm — record_failure! can only
  #     leave the operation retry_scheduled, blocked, or failed for the error
  #     classes classify/1 produces, so the arm is defensive.
  #   * `snooze_seconds/1` with a nil next_attempt_at — every caller sets
  #     next_attempt_at (absence_proven and retryable_error both stamp it),
  #     so the nil head is a fallback only.
  #   * `actor_id/1`'s nil fallback — request/approve/book are only reachable
  #     through user-resolved scopes in these workflows; non-user principals
  #     (API tokens) have no ERP-sync surface yet.
end
