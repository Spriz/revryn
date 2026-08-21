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

  defp perform_job(worker, args) do
    job = %Oban.Job{args: args}
    worker.perform(job)
  end
end
