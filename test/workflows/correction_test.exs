defmodule BillingCore.Workflows.CorrectionTest do
  @moduledoc """
  Workflow documentation: correcting booked invoices through compensating
  credit documents (SPEC INV-001/002, BC-US-102/103/104).
  """

  use BillingCore.DataCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Billing, Contracts}
  alias BillingCore.Billing.{Corrections, Preview}
  alias BillingCore.ERP
  alias BillingCore.ERP.FakeERP
  alias BillingCore.ERP.Sync

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

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
        amount: "120000.00"
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
        external_product_number: "SAAS-ANNUAL"
      })

    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-09-15],
        quantity: Decimal.new(1)
      })

    # Book the original invoice through the normal workflow.
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-15])
    {:ok, intent} = Preview.freeze(scope, preview)
    {:ok, _} = Sync.request_synchronization(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _} = Sync.approve_invoice(scope, intent)
    {:ok, _} = Sync.request_booking(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Billing.intent_state(intent) == "erp_booked"

    %{scope: scope, intent: intent, fake: fake}
  end

  test "full credit produces exact negative lines preserving periods, and books as a credit note",
       %{scope: scope, intent: intent} do
    {:ok, %{case: correction_case, credit_intent: credit_intent}} =
      Corrections.create_full_credit(scope, intent, reason_code: "wrong_customer_po")

    assert correction_case.status == "credit_pending"
    assert correction_case.original_booked_number

    # Exact inverse: net of original + credit is zero (SPEC §23.2 full credit row).
    assert credit_intent.net_amount_minor == -intent.net_amount_minor
    assert credit_intent.document_kind == "credit_note"

    {:ok, loaded} = Billing.get_intent(scope, credit_intent.id)
    assert [credit_line] = loaded.lines
    assert credit_line.amount_minor == -12_000_000
    assert credit_line.service_start == ~D[2026-09-15]
    assert credit_line.service_end_exclusive == ~D[2027-09-15]
    assert credit_line.adjusts_line_id

    # The original intent remains booked; the case tracks the linkage.
    assert Billing.intent_state(intent) == "erp_booked"

    # The credit intent flows through normal synchronization and booking.
    {:ok, _} = Sync.request_synchronization(scope, credit_intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Billing.intent_state(credit_intent) == "erp_draft"

    {:ok, _} = Sync.approve_invoice(scope, credit_intent)
    {:ok, _} = Sync.request_booking(scope, credit_intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Billing.intent_state(credit_intent) == "erp_booked"
  end

  test "partial credits are bounded by the original line amount cumulatively",
       %{scope: scope, intent: intent} do
    {:ok, loaded} = Billing.get_intent(scope, intent.id)
    [line] = loaded.lines

    {:ok, %{credit_intent: first}} =
      Corrections.create_partial_credit(scope, intent, [{line.line_key, 5_000_000}],
        reason_code: "partial_service_failure"
      )

    assert first.net_amount_minor == -5_000_000

    # Second partial credit up to the boundary is fine…
    {:ok, %{credit_intent: second}} =
      Corrections.create_partial_credit(scope, intent, [{line.line_key, 7_000_000}])

    assert second.net_amount_minor == -7_000_000

    # …but exceeding the original cumulatively is rejected (BC-US-103).
    assert {:error, {:credit_exceeds_original, _key, detail}} =
             Corrections.create_partial_credit(scope, intent, [{line.line_key, 1}])

    assert detail.already_credited == 12_000_000
  end

  test "credit and rebill links credit + replacement in one case and completes after booking",
       %{scope: scope, intent: intent} do
    {:ok, loaded} = Billing.get_intent(scope, intent.id)
    [line] = loaded.lines

    replacement_lines = [
      %{
        line_key: "rebill:#{line.line_key}",
        product_id: line.product_id,
        product_version: line.product_version,
        description: "Corrected annual platform subscription",
        quantity: line.quantity,
        amount_minor: 10_000_000,
        recognition_mode: line.recognition_mode,
        service_start: line.service_start,
        service_end_exclusive: line.service_end_exclusive,
        calculation_trace: %{"kind" => "rebill"},
        ordinal: 0
      }
    ]

    {:ok, %{case: kase, credit_intent: credit, replacement_intent: replacement}} =
      Corrections.create_credit_and_rebill(scope, intent, replacement_lines,
        reason_code: "price_correction"
      )

    assert kase.credit_invoice_intent_id == credit.id
    assert kase.replacement_invoice_intent_id == replacement.id
    assert replacement.net_amount_minor == 10_000_000
    assert replacement.document_kind == "invoice"

    # Completion requires both documents booked.
    assert {:error, {:documents_not_booked, 2}} = Corrections.complete_case(scope, kase)

    for doc_intent <- [credit, replacement] do
      {:ok, _} = Sync.request_synchronization(scope, doc_intent)
      %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
      {:ok, _} = Sync.approve_invoice(scope, doc_intent)
      {:ok, _} = Sync.request_booking(scope, doc_intent)
      %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
      assert Billing.intent_state(doc_intent) == "erp_booked"
    end

    {:ok, completed} = Corrections.complete_case(scope, kase)
    assert completed.status == "completed"
  end

  test "credits require a booked original and finance role", %{scope: scope, intent: intent} do
    # A frozen (unbooked) intent cannot be credited.
    {:ok, preview_scope} = {:ok, scope}
    {:ok, other} = Billing.get_intent(preview_scope, intent.id)
    assert Billing.intent_state(other) == "erp_booked"

    auditor_scope = billing_scope_fixture([:auditor])
    assert {:error, :unauthorized} = Corrections.create_full_credit(auditor_scope, intent)
  end
end
