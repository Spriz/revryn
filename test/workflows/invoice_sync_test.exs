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
  alias BillingCore.ERP
  alias BillingCore.ERP.{ErpDocument, FakeERP}
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

  defp freeze_annual_intent!(scope, customer, product_id) do
    {:ok, intent} =
      Billing.freeze_invoice_intent(scope, %{
        customer_id: customer.id,
        customer_version: customer.current_version,
        customer_external_id: customer.external_id,
        customer_legal_name: "Acme ApS",
        currency: "DKK",
        invoice_date: ~D[2026-09-01],
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
end
