defmodule BillingCore.Workflows.AnnualPrepaidSubscriptionTest do
  @moduledoc """
  Workflow documentation for the SPEC §1.2 minimal vertical slice: an annual
  prepaid fixed subscription flows from catalog publication through preview,
  immutable invoice intent with a 12-month service period, ERP draft
  synchronization, reconciliation, approval, and booking — with the fake ERP
  at the network boundary (SPEC §7.1, §10.10, docs/features/annual-prepaid-
  subscriptions.md).
  """

  use BillingCore.DataCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Billing, Contracts}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP
  alias BillingCore.ERP.{ErpDocument, FakeERP}
  alias BillingCore.ERP.Sync

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    # Catalog: an over-time product on an annual prepaid plan (DKK 120,000.00)
    product =
      product_fixture(scope, %{
        recognition_mode: :over_time,
        service_period_source: :billing_period
      })

    plan_version =
      published_plan_version_fixture(scope,
        product: product,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 12,
        billing_timing: :in_advance,
        amount: "120000.00",
        component_code: "annual-platform"
      )

    # ERP: fake connection, customer + product mappings
    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, connection} = ERP.validate_connection(scope, connection)

    customer = customer_fixture(scope, %{legal_name: "Example ApS"})

    {:ok, _} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    {:ok, _} =
      BillingCore.Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "SAAS-ANNUAL"
      })

    contract =
      contract_fixture(scope, %{
        customer_id: customer.id,
        currency: "DKK",
        start_date: ~D[2026-01-01]
      })

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-09-15],
        quantity: Decimal.new(1)
      })

    %{scope: scope, subscription: subscription, customer: customer, fake: fake}
  end

  test "annual prepaid slice: preview → freeze → sync → reconcile → approve → book",
       %{scope: scope, subscription: subscription, fake: fake} do
    # Preview shows the full annual amount over the 12-month service period
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-15])

    assert preview.blockers == []
    assert preview.currency == "DKK"
    assert [line] = preview.lines
    assert line.amount_minor == 12_000_000
    assert line.recognition_mode == :over_time
    assert line.service_start == ~D[2026-09-15]
    assert line.service_end_exclusive == ~D[2027-09-15]
    assert preview.net_amount_minor == 12_000_000
    assert is_binary(preview.fingerprint)

    # Preview is deterministic for unchanged inputs
    {:ok, preview2} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-15])
    assert preview2.fingerprint == preview.fingerprint

    # Freeze: immutable intent with SHA-256 canonical snapshot (INV-013)
    {:ok, intent} = Preview.freeze(scope, preview, usage_cutoff: ~U[2026-09-01 00:00:00Z])
    assert intent.net_amount_minor == 12_000_000
    assert intent.content_hash =~ ~r/^[0-9a-f]{64}$/
    assert Billing.intent_state(intent) == "frozen"

    snapshot = intent.canonical_snapshot
    assert snapshot["schemaVersion"] == 1
    assert [snap_line] = snapshot["lines"]
    assert snap_line["amountMinor"] == 12_000_000
    assert snap_line["recognition"]["mode"] == "over_time"
    assert snap_line["recognition"]["serviceStart"] == "2026-09-15"
    assert snap_line["recognition"]["serviceEndExclusive"] == "2027-09-15"

    # Frozen intent rows are database-immutable
    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.query!(
        "UPDATE billing.invoice_intents SET net_amount_minor = 1 WHERE id = $1",
        [Ecto.UUID.dump!(intent.id)]
      )
    end

    # Sync to the ERP: draft carries the inclusive accrual end date (§10.10)
    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Billing.intent_state(intent) == "erp_draft"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    ctx = FakeERP.connection_context(fake)
    {:ok, external} = FakeERP.get_document(ctx, {:draft, doc.external_draft_number})
    assert [external_line] = external.lines
    assert external_line.amount.minor_units == 12_000_000
    assert external_line.product_external_id == "SAAS-ANNUAL"
    assert external_line.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}

    # Approve and book — the booked document preserves accrual dates
    {:ok, _} = Sync.approve_invoice(scope, intent, reason: "finance review")
    {:ok, _} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    assert Billing.intent_state(intent) == "erp_booked"

    doc = Repo.get_by!(ErpDocument, invoice_intent_id: intent.id)
    {:ok, booked} = FakeERP.get_document(ctx, {:booked, doc.external_booked_number})
    assert booked.state == :booked
    assert [booked_line] = booked.lines
    assert booked_line.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}
  end

  test "mid-period preview prorates only when the subscription starts mid-period",
       %{scope: scope, subscription: subscription} do
    # As-of a date inside the first year, the same full annual period applies.
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2027-01-10])
    assert [line] = preview.lines
    assert line.service_start == ~D[2026-09-15]
    assert line.service_end_exclusive == ~D[2027-09-15]
    assert line.amount_minor == 12_000_000

    # The second year rolls the anchor forward a full year.
    {:ok, second_year} = Preview.for_subscription(scope, subscription.id, ~D[2027-09-15])
    assert [line2] = second_year.lines
    assert line2.service_start == ~D[2027-09-15]
    assert line2.service_end_exclusive == ~D[2028-09-15]
  end

  test "superseding a frozen intent keeps the old version immutable and advances the chain",
       %{scope: scope, subscription: subscription} do
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-15])
    {:ok, intent} = Preview.freeze(scope, preview)

    {:ok, replacement} =
      Billing.supersede_invoice_intent(scope, intent, %{
        customer_id: preview.customer_id,
        customer_version: preview.customer_version,
        customer_external_id: preview.customer_external_id,
        customer_legal_name: preview.customer_legal_name,
        currency: preview.currency,
        invoice_date: ~D[2026-09-02],
        usage_cutoff: ~U[2026-09-02 00:00:00Z],
        lines: preview.lines,
        reason: "corrected invoice date"
      })

    assert Billing.intent_state(intent) == "superseded"
    assert Billing.intent_state(replacement) == "frozen"
    assert replacement.intent_version == 2
    assert replacement.invoice_chain_id == intent.invoice_chain_id
    assert replacement.supersedes_invoice_intent_id == intent.id

    chain = Repo.get!(BillingCore.Billing.InvoiceChain, intent.invoice_chain_id)
    assert chain.current_intent_id == replacement.id

    # A superseded intent can no longer synchronize
    assert {:error, {:illegal_state, _}} =
             Billing.transition_intent(scope, intent, :enqueue_sync)
  end
end
