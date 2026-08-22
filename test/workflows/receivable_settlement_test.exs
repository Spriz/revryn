defmodule BillingCore.Workflows.ReceivableSettlementTest do
  @moduledoc """
  SPEC §9.4.1 / BC-US-108 receivable settlement: automatic credit
  application is blocked until a settlement mode is certified; each
  application opens exactly one settlement record, distinct from the
  subledger, the invoice, and the monthly close; the settlement reconciles
  exactly once — through an idempotent clearing voucher when e-conomic owns
  receivables, or through a recorded external reference otherwise — and
  never turns the application into a discount.
  """

  use BillingCore.DataCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.CreditsFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Contracts, Credits, ERP, Operations, Orgs}
  alias BillingCore.Billing.Preview
  alias BillingCore.Credits.{CreditSettlement, Settlements}
  alias BillingCore.ERP.{FakeERP, Sync}

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
        interval_count: 1,
        billing_timing: :in_advance,
        amount: "1000.00"
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
        external_product_number: "SEAT"
      })

    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-08-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    account = account_fixture(scope.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, scope.team, customer.id)
    {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")

    {:ok, _grant} =
      Credits.grant_credit(scope, %{
        credit_account_id: credit_account.id,
        origin_type: "goodwill",
        amount_minor: 20_000,
        currency: "DKK",
        idempotency_key: "settlement-grant-1"
      })

    %{scope: scope, subscription: subscription, credit_account: credit_account, fake: fake}
  end

  test "application is blocked until a settlement mode is certified", %{
    scope: scope,
    subscription: subscription
  } do
    # Balance exists, but no policy declares who owns open receivables:
    # the preview plans no credit — the invoice is never netted silently.
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    assert preview.credit_planned_minor == 0
    assert preview.net_amount_minor == 100_000

    # Certifying a mode unblocks exactly the eligible amount.
    settlement_policy_fixture(scope, settlement_mode: :external_reference)

    {:ok, unblocked} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    assert unblocked.credit_planned_minor == 20_000
  end

  test "external mode records the settlement and reconciles it exactly once", %{
    scope: scope,
    subscription: subscription
  } do
    settlement_policy_fixture(scope, settlement_mode: :external_reference)

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    {:ok, intent} = Preview.freeze(scope, preview)

    settlement = Repo.get_by!(CreditSettlement, invoice_intent_id: intent.id)
    assert settlement.mode == :external_reference
    assert settlement.state == :pending
    assert settlement.amount_minor == 20_000
    assert settlement.currency == "DKK"

    # The application is a settlement event, not a discount: the frozen
    # snapshot keeps the gross lines and reports the credit separately.
    assert intent.net_amount_minor == 100_000
    assert intent.canonical_snapshot["creditAppliedMinor"] == 20_000
    assert intent.canonical_snapshot["amountDueMinor"] == 80_000

    assert {:ok, reconciled} =
             Settlements.record_external_settlement(scope, settlement.id, "bank-batch-77")

    assert reconciled.state == :reconciled
    assert reconciled.external_reference == "bank-batch-77"

    # Exactly once: the same reference replays idempotently, a different
    # reference conflicts, and the terminal state is database-enforced.
    assert {:ok, _same} =
             Settlements.record_external_settlement(scope, settlement.id, "bank-batch-77")

    assert {:error, :already_reconciled} =
             Settlements.record_external_settlement(scope, settlement.id, "bank-batch-78")

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update_all(
        from(s in CreditSettlement, where: s.id == ^settlement.id),
        set: [amount_minor: 1]
      )
    end
  end

  test "erp mode posts and reconciles the clearing voucher after booking", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    settlement_policy_fixture(scope,
      settlement_mode: :erp_customer_settlement,
      settlement_clearing_account_number: 5820,
      settlement_contra_account_number: 5821
    )

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    {:ok, intent} = Preview.freeze(scope, preview)

    settlement = Repo.get_by!(CreditSettlement, invoice_intent_id: intent.id)
    assert settlement.mode == :erp_customer_settlement
    assert settlement.state == :pending
    assert is_nil(settlement.operation_id)

    # Draft, approve, book — the booking reconciliation enqueues the
    # settlement posting, which drains in the same erp queue.
    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "review")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    # Booking enqueued the settlement posting as its own durable job.
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled
    assert is_binary(settlement.external_voucher_number)
    assert settlement.reconciled_at

    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "succeeded"
    assert operation.type == "erp.post_customer_credit_settlement"

    # The authoritative provider holds exactly one balanced clearing
    # voucher for this settlement: debit 5820, credit 5821.
    [voucher] =
      fake
      |> FakeERP.list_finance_vouchers()
      |> Enum.filter(&(&1.external_reference == Settlements.external_reference(settlement)))

    amounts =
      voucher.lines
      |> Enum.map(&{&1.account_external_id, &1.amount.minor_units})
      |> Enum.sort()

    assert amounts == [{"5820", 20_000}, {"5821", -20_000}]

    # Replay cannot double-post: the reconciled operation is not runnable
    # and the provider still holds exactly one voucher.
    sync_operation =
      Repo.get_by!(BillingCore.ERP.SyncOperation,
        operation_id: settlement.operation_id
      )

    assert :ok = BillingCore.Credits.SettlementPosting.execute(sync_operation.id)

    assert [_only_one] =
             fake
             |> FakeERP.list_finance_vouchers()
             |> Enum.filter(
               &(&1.external_reference == Settlements.external_reference(settlement))
             )
  end

  test "settlements are team-scoped reads and auditors can list them", %{
    scope: scope,
    subscription: subscription
  } do
    settlement_policy_fixture(scope, settlement_mode: :external_reference)
    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    {:ok, intent} = Preview.freeze(scope, preview)

    assert {:ok, [settlement]} = Settlements.list_settlements(scope)
    assert settlement.invoice_intent_id == intent.id

    assert {:ok, [_pending]} = Settlements.list_settlements(scope, state: :pending)
    assert {:ok, []} = Settlements.list_settlements(scope, state: :reconciled)

    other = billing_scope_fixture([:finance_operator])
    assert {:ok, []} = Settlements.list_settlements(other)
  end
end
