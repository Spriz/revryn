defmodule BillingCore.Workflows.UnusedServiceCreditTest do
  @moduledoc """
  BC-US-107 acceptance: unused prepaid service on a downgrade becomes
  customer credit through the ordinary correction workflow — computed with
  the §10.1 day-based proration rule, funded into the subledger exactly
  once when the credit note is authoritative, never mutating the booked
  original.
  """

  use BillingCore.DataCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Billing, Contracts, Credits, ERP, Orgs}
  alias BillingCore.Billing.{Corrections, Preview}
  alias BillingCore.Credits.UnusedService
  alias BillingCore.ERP.{FakeERP, Sync}

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    # 10 seats prepaid 12 months at 5,400.00 DKK per seat-year.
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
        amount: "5400.00",
        component_code: "seat-annual"
      )

    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, _connection} = ERP.validate_connection(scope, connection)

    customer = customer_fixture(scope)

    {:ok, _mapping} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    {:ok, _mapping} =
      BillingCore.Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "SEAT-ANNUAL"
      })

    contract =
      contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-09-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-09-01],
        quantity: Decimal.new(10)
      })

    # Book the annual invoice: 10 × 5,400.00 = 54,000.00 DKK.
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-01])
    assert preview.net_amount_minor == 5_400_000
    {:ok, intent} = Preview.freeze(scope, preview)
    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "annual review")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    [invoice_line] = Repo.preload(intent, :lines).lines

    %{
      scope: scope,
      intent: intent,
      invoice_line: invoice_line,
      subscription: subscription,
      customer: customer
    }
  end

  defp link_credit_account!(scope, customer) do
    account = account_fixture(scope.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, scope.team, customer.id)
    {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")
    credit_account
  end

  defp book_credit_note!(scope, credit_intent) do
    {:ok, _operation} = Sync.request_synchronization(scope, credit_intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, credit_intent, reason: "credit review")
    {:ok, _operation} = Sync.request_booking(scope, credit_intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    :ok
  end

  test "the 10→8 seat downgrade credits exactly the day-prorated unused value once",
       %{scope: scope, intent: intent, invoice_line: invoice_line, customer: customer} do
    credit_account = link_credit_account!(scope, customer)
    effective = ~D[2026-11-01]

    # The deterministic figure: 5_400_000 × (304/365 unused days) × (2/10
    # seats), rounded half-away-from-zero once at the final amount.
    expected =
      Decimal.new(5_400_000)
      |> Decimal.mult(Decimal.div(Decimal.new(304), Decimal.new(365)))
      |> Decimal.mult(Decimal.div(Decimal.new(2), Decimal.new(10)))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    assert {:ok, %{case: correction_case, credit_intent: credit_intent, computation: comp}} =
             UnusedService.credit_reduction(scope, intent, %{
               line_key: invoice_line.line_key,
               effective_date: effective,
               original_quantity: 10,
               reduced_quantity: 8
             })

    assert comp.unused_days == 304
    assert comp.period_days == 365
    assert comp.credit_minor == expected
    assert credit_intent.net_amount_minor == -expected
    assert credit_intent.document_kind == "credit_note"

    # The original booked invoice was never mutated.
    assert Billing.intent_state(intent) in ["erp_booked", "credit_required"]

    # No funding before the credit note is authoritative.
    assert {:error, {:documents_not_booked, 1}} =
             Corrections.complete_case(scope, correction_case)

    {:ok, [] = _grants} = Credits.list_grants(scope, credit_account)

    # Book the credit note through the ordinary sync flow.
    :ok = book_credit_note!(scope, credit_intent)

    # Completion funds the ledger exactly once.
    assert {:ok, completed} = Corrections.complete_case(scope, correction_case)
    assert completed.status == "completed"

    {:ok, [grant]} = Credits.list_grants(scope, credit_account)
    assert grant.origin_type == "unused_prepaid_service"
    assert grant.granted_minor == expected
    assert grant.origin_id == correction_case.id

    # Replaying the funding (or a duplicate completion path) cannot
    # double-fund: the idempotency key derives from the case.
    assert {:ok, replayed} = UnusedService.fund_from_case(scope, completed)
    assert replayed.id == grant.id
    {:ok, [_only_one]} = Credits.list_grants(scope, credit_account)
    assert :ok = Credits.reconcile_account(credit_account.id)
  end

  test "guards: over-time only, a real reduction, and an in-period date",
       %{scope: scope, intent: intent, invoice_line: invoice_line} do
    assert {:error, :not_a_reduction} =
             UnusedService.credit_reduction(scope, intent, %{
               line_key: invoice_line.line_key,
               effective_date: ~D[2026-11-01],
               original_quantity: 10,
               reduced_quantity: 10
             })

    assert {:error, :effective_date_outside_service_period} =
             UnusedService.credit_reduction(scope, intent, %{
               line_key: invoice_line.line_key,
               effective_date: ~D[2027-09-01],
               original_quantity: 10,
               reduced_quantity: 8
             })

    assert {:error, :line_not_found} =
             UnusedService.credit_reduction(scope, intent, %{
               line_key: "missing",
               effective_date: ~D[2026-11-01],
               original_quantity: 10,
               reduced_quantity: 8
             })
  end

  test "completion is blocked, never silently skipped, without a credit account",
       %{scope: scope, intent: intent, invoice_line: invoice_line, customer: customer} do
    assert {:ok, %{case: correction_case, credit_intent: credit_intent}} =
             UnusedService.credit_reduction(scope, intent, %{
               line_key: invoice_line.line_key,
               effective_date: ~D[2026-11-01],
               original_quantity: 10,
               reduced_quantity: 8
             })

    :ok = book_credit_note!(scope, credit_intent)

    # The customer has no linked commercial account yet: completion refuses
    # rather than losing the funding obligation.
    assert {:error, {:credit_funding_failed, :no_credit_account}} =
             Corrections.complete_case(scope, correction_case)

    assert Repo.reload!(correction_case).status == "credit_pending"

    # Linking the account remediates; completion then funds exactly once.
    credit_account = link_credit_account!(scope, customer)
    assert {:ok, completed} = Corrections.complete_case(scope, correction_case)
    assert completed.status == "completed"
    {:ok, [grant]} = Credits.list_grants(scope, credit_account)
    assert grant.origin_id == correction_case.id
  end
end
