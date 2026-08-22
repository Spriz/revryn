defmodule BillingCore.Workflows.ExternalBookingTest do
  @moduledoc """
  Workflow documentation: observing a draft booked directly inside the ERP
  (SPEC BC-US-086, §17.11/§17.12, INV-010). A webhook is only a hint — the
  poller performs the authoritative read and reconciles before any state
  claim, recording reconciliation evidence (BC-US-113).
  """

  use BillingCore.DataCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Billing, Contracts}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP
  alias BillingCore.ERP.{ErpDocument, FakeERP, PollWorker}
  alias BillingCore.ERP.Sync

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    product = product_fixture(scope)

    plan_version =
      published_plan_version_fixture(scope,
        product: product,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        amount: "500.00"
      )

    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, connection} = ERP.validate_connection(scope, connection)

    customer = customer_fixture(scope)

    {:ok, _} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    {:ok, _} =
      BillingCore.Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "P-1"
      })

    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    {:ok, intent} = Preview.freeze(scope, preview)
    {:ok, _} = Sync.request_synchronization(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Billing.intent_state(intent) == "erp_draft"

    %{scope: scope, intent: intent, fake: fake, connection: connection}
  end

  test "a draft booked inside the ERP is detected, reconciled, and recorded",
       %{intent: intent, fake: fake, connection: connection} do
    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)

    # A human books the draft directly in the ERP UI.
    FakeERP.book_externally(fake, doc.external_draft_number)

    # The polling fallback performs the authoritative read.
    :ok = perform_job(PollWorker, %{"erp_connection_id" => connection.id})

    assert Billing.intent_state(intent) == "erp_booked"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "booked"
    assert doc.external_booked_number

    results =
      Repo.all(
        from r in "reconciliation_results",
          prefix: "billing",
          where: r.erp_document_id == type(^doc.id, Ecto.UUID),
          select: {r.status, r.run_kind}
      )

    assert {"match", "poll"} in results
  end

  test "an externally deleted draft is marked missing with evidence",
       %{intent: intent, connection: connection} do
    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)

    # The fake has no delete API; pointing the document at a reference the
    # provider never saw simulates external deletion.
    doc
    |> Ecto.Changeset.change(external_reference: "abc:gone:#{Ecto.UUID.generate()}:v1")
    |> Ecto.Changeset.optimistic_lock(:version)
    |> Repo.update!()

    :ok = perform_job(PollWorker, %{"erp_connection_id" => connection.id})

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "missing"

    results =
      Repo.all(
        from r in "reconciliation_results",
          prefix: "billing",
          where: r.erp_document_id == type(^doc.id, Ecto.UUID),
          select: r.status
      )

    assert "missing" in results
  end

  test "polling refreshes a drifting draft snapshot and tolerates provider read failures",
       %{intent: intent, fake: fake, connection: connection} do
    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    hash_before = doc.last_external_hash

    {:ok, edited} =
      FakeERP.human_edit_draft(fake, doc.external_draft_number, fn draft ->
        update_in(draft.lines, fn [line] -> [%{line | description: "edited in the ERP UI"}] end)
      end)

    :ok = perform_job(PollWorker, %{"erp_connection_id" => connection.id})

    # The draft stays a draft, but the stored external hash now shows the
    # drift an approval check would catch.
    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "draft"
    assert doc.last_external_hash == edited.external_hash
    refute doc.last_external_hash == hash_before

    # A transient provider failure leaves the document untouched for the
    # next scheduled poll instead of guessing at external state.
    :ok = FakeERP.inject_failure(fake, :find_document, {:error, {:provider_failure, :io}})
    :ok = perform_job(PollWorker, %{"erp_connection_id" => connection.id})

    unchanged = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert unchanged.state == "draft"
    assert unchanged.last_external_hash == edited.external_hash
    assert unchanged.version == doc.version
  end

  test "an externally booked draft that no longer matches the frozen intent fails reconciliation",
       %{intent: intent, fake: fake, connection: connection} do
    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)

    # A human edits the amount and books directly in the ERP: the booked
    # document no longer matches the frozen intent (500.00 DKK vs 499.99).
    {:ok, _edited} =
      FakeERP.human_edit_draft(fake, doc.external_draft_number, fn draft ->
        update_in(draft.lines, fn [line] ->
          [%{line | amount: BillingCore.Domain.Money.new!("DKK", 49_999)}]
        end)
      end)

    {:ok, booked} = FakeERP.book_externally(fake, doc.external_draft_number, webhook: :drop)

    :ok = perform_job(PollWorker, %{"erp_connection_id" => connection.id})

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "reconciliation_failed"
    assert doc.external_booked_number == booked.external_booked_number
    assert doc.last_external_hash == booked.external_hash

    # The intent never claims erp_booked from a mismatching external state.
    assert Billing.intent_state(intent) == "erp_draft"

    assert [differences] =
             Repo.all(
               from r in "reconciliation_results",
                 prefix: "billing",
                 where: r.erp_document_id == type(^doc.id, Ecto.UUID) and r.status == "mismatch",
                 select: r.differences
             )

    assert [%{"severity" => _, "field" => _} | _] = differences["items"]

    assert Repo.exists?(
             from e in BillingCore.Outbox.Event,
               where:
                 e.event_type == "erp_document.reconciliation_failed.v1" and
                   e.aggregate_id == ^doc.id
           )
  end

  test "a matching external booking converges even when the intent lifecycle has moved on",
       %{scope: scope, intent: intent, fake: fake, connection: connection} do
    {:ok, _} = Sync.approve_invoice(scope, intent, reason: "reviewed")
    assert Billing.intent_state(intent) == "approved"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    {:ok, booked} = FakeERP.book_externally(fake, doc.external_draft_number, webhook: :drop)

    # The reconciled booking is recorded on the document, while the
    # illegal :externally_booked transition from :approved is tolerated
    # (INV-015 idempotent workers) instead of crashing the poll.
    :ok = perform_job(PollWorker, %{"erp_connection_id" => connection.id})

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    assert doc.state == "booked"
    assert doc.external_booked_number == booked.external_booked_number
    assert Billing.intent_state(intent) == "approved"

    results =
      Repo.all(
        from r in "reconciliation_results",
          prefix: "billing",
          where: r.erp_document_id == type(^doc.id, Ecto.UUID),
          select: r.status
      )

    assert results == ["match"]
  end

  defp perform_job(worker, args) do
    job = %Oban.Job{args: args}
    worker.perform(job)
  end
end
