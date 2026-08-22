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
  alias BillingCore.ERP.{FakeERP, Sync, SyncOperation}

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

  # Books the invoice under an :erp_customer_settlement policy, leaving the
  # settlement's durable posting job queued (not yet drained).
  defp enqueue_erp_settlement!(scope, subscription) do
    policy =
      settlement_policy_fixture(scope,
        settlement_mode: :erp_customer_settlement,
        settlement_clearing_account_number: 5820,
        settlement_contra_account_number: 5821
      )

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
    {:ok, intent} = Preview.freeze(scope, preview)
    settlement = Repo.get_by!(CreditSettlement, invoice_intent_id: intent.id)

    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "review")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    settlement = Repo.get!(CreditSettlement, settlement.id)
    sync_op = Repo.get_by!(SyncOperation, operation_id: settlement.operation_id)
    %{settlement: settlement, sync_op: sync_op, policy: policy}
  end

  defp drain_settlement, do: Oban.drain_queue(queue: :erp, with_safety: false)

  defp drain_scheduled_settlement,
    do: Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)

  defp settlement_vouchers(fake, settlement) do
    fake
    |> FakeERP.list_finance_vouchers()
    |> Enum.filter(&(&1.external_reference == Settlements.external_reference(settlement)))
  end

  defp voucher_amounts(voucher) do
    voucher.lines
    |> Enum.map(&{&1.account_external_id, &1.amount.minor_units})
    |> Enum.sort()
  end

  test "a lost voucher response reconciles by reference without double-posting", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement} = enqueue_erp_settlement!(scope, subscription)

    :ok = FakeERP.inject_unknown_outcome(fake, :create_finance_voucher)
    assert %{success: 1} = drain_settlement()

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled

    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "succeeded"

    # Exactly one voucher exists for the settlement, with exact minor units.
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
    assert settlement.external_voucher_number == voucher.external_voucher_number
  end

  test "an unproven lost response schedules a durable retry and replays idempotently", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement, sync_op: sync_op} = enqueue_erp_settlement!(scope, subscription)

    # The voucher creation commits but the response is lost, and both the
    # pre-create search and the recovery search claim absence.
    :ok = FakeERP.inject_unknown_outcome(fake, :create_finance_voucher)
    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:ok, nil})
    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:ok, nil})

    assert %{snoozed: 1} = drain_settlement()

    assert Operations.get!(settlement.operation_id).state == "retry_scheduled"
    sync_op = Repo.get!(SyncOperation, sync_op.id)
    assert sync_op.state == "queued"
    assert sync_op.response_metadata["recovery"] == "absence_proven"
    # The settlement never claims reconciliation before read-back proves it.
    assert Repo.get!(CreditSettlement, settlement.id).state == :pending

    # The retry finds the voucher created before the response was lost.
    assert %{success: 1} = drain_scheduled_settlement()

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled
    assert Operations.get!(settlement.operation_id).state == "succeeded"
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
  end

  test "a conflicting voucher under the settlement reference fails closed", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement, sync_op: sync_op, policy: policy} =
      enqueue_erp_settlement!(scope, subscription)

    # Someone (or some earlier system) parked a voucher with the settlement's
    # stable reference but the wrong amount: 199.99 instead of 200.00.
    accounting_date = DateTime.to_date(settlement.created_at)

    {:ok, conflicting} =
      Settlements.build_settlement_voucher(
        %{settlement | amount_minor: 19_999},
        policy,
        accounting_date
      )

    ctx = FakeERP.connection_context(fake)
    {:ok, _} = FakeERP.create_finance_voucher(ctx, conflicting, "conflicting-voucher-key")

    assert %{success: 1} = drain_settlement()

    # The settlement is never reconciled against mismatching amounts.
    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :pending
    assert is_nil(settlement.external_voucher_number)

    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "failed"
    assert operation.error_class == "validation"
    assert operation.safe_error_code == "credit_settlement_mismatch"
    assert operation.safe_error_summary == "settlement_voucher_content"

    sync_op = Repo.get!(SyncOperation, sync_op.id)
    assert sync_op.state == "failed"
    assert sync_op.response_metadata["mismatch"] == "settlement_voucher_content"

    assert Repo.exists?(
             from e in BillingCore.Outbox.Event,
               where:
                 e.event_type == "customer_credit_settlement.mismatch_detected.v1" and
                   e.aggregate_id == ^settlement.id
           )

    # The conflicting voucher was not overwritten and no second voucher was
    # created for the reference.
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 19_999}, {"5821", -19_999}]
  end

  test "a transient search failure retries through policy and reconciles", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement} = enqueue_erp_settlement!(scope, subscription)

    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:error, {:provider_failure, :io}})

    assert %{snoozed: 1} = drain_settlement()

    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "retry_scheduled"
    assert operation.error_class == "transient"
    assert Repo.get!(CreditSettlement, settlement.id).state == :pending

    assert %{success: 1} = drain_scheduled_settlement()

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
  end

  test "a voucher that vanishes at read-back blocks until remediation", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement, sync_op: sync_op} = enqueue_erp_settlement!(scope, subscription)

    # The create succeeds, but the authoritative read-back claims the voucher
    # does not exist: a provider-side conflict, never a silent success.
    :ok = FakeERP.inject_failure(fake, :get_finance_voucher, {:ok, nil})

    assert %{success: 1} = drain_settlement()

    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "blocked"
    assert operation.error_class == "conflict"
    assert operation.safe_error_code == "provider_not_found"
    assert Repo.get!(SyncOperation, sync_op.id).state == "failed"
    assert Repo.get!(CreditSettlement, settlement.id).state == :pending

    # The voucher does exist (only the read was wrong); remediation re-runs
    # the same durable operation, finds it, and reconciles exactly once.
    assert [_created] = settlement_vouchers(fake, settlement)

    {:ok, _} = Sync.remediate_operation(scope, operation)
    assert %{success: 1} = drain_settlement()

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
  end

  test "a provider validation failure dead-letters and manual retry converges", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement, sync_op: sync_op} = enqueue_erp_settlement!(scope, subscription)

    :ok =
      FakeERP.inject_failure(
        fake,
        :create_finance_voucher,
        {:error, {:validation, [%{field: :journal}]}}
      )

    assert %{success: 1} = drain_settlement()

    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "failed"
    assert operation.error_class == "validation"
    assert operation.safe_error_code == "provider_validation"
    assert Repo.get!(SyncOperation, sync_op.id).state == "failed"
    assert settlement_vouchers(fake, settlement) == []

    # BC-US-106: manual retry routes back into the settlement worker.
    {:ok, _} = Sync.retry_operation(scope, operation)
    assert %{success: 1} = drain_settlement()

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled
    assert Operations.get!(settlement.operation_id).state == "succeeded"
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
  end

  test "an already-reconciled settlement completes the retried operation with no provider write",
       %{scope: scope, subscription: subscription, fake: fake} do
    %{settlement: settlement, sync_op: sync_op} = enqueue_erp_settlement!(scope, subscription)

    :ok =
      FakeERP.inject_failure(
        fake,
        :create_finance_voucher,
        {:error, {:validation, [%{field: :journal}]}}
      )

    assert %{success: 1} = drain_settlement()
    assert Operations.get!(settlement.operation_id).state == "failed"

    # During recovery an operator records that the receivable was cleared out
    # of band (the database permits pending -> reconciled, never back).
    Repo.get!(CreditSettlement, settlement.id)
    |> Ecto.Changeset.change(
      state: :reconciled,
      external_reference: "operator-clearing-9",
      reconciled_at: DateTime.utc_now()
    )
    |> Repo.update!()

    {:ok, _} = Sync.retry_operation(scope, Operations.get!(settlement.operation_id))
    assert %{success: 1} = drain_settlement()

    # The retried operation observes the terminal settlement and completes
    # without ever touching the provider again.
    assert Operations.get!(settlement.operation_id).state == "succeeded"
    sync_op = Repo.get!(SyncOperation, sync_op.id)
    assert sync_op.state == "succeeded"
    assert sync_op.response_metadata["already_reconciled"] == true
    assert FakeERP.list_finance_vouchers(fake) == []
  end

  test "provider errors are classified per policy across successive attempts", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement} = enqueue_erp_settlement!(scope, subscription)

    # Throttled: honors retry_after and schedules a retry.
    :ok =
      FakeERP.inject_failure(
        fake,
        :find_finance_voucher,
        {:error, {:rate_limited, %{retry_after: 1}}}
      )

    assert %{snoozed: 1} = drain_settlement()
    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "retry_scheduled"
    assert operation.error_class == "throttled"
    assert operation.safe_error_code == "rate_limited"

    # Authentication: blocked as an operator-remediable credentials problem.
    :ok =
      FakeERP.inject_failure(fake, :find_finance_voucher, {:error, {:authentication, :expired}})

    assert %{success: 1} = drain_scheduled_settlement()
    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "blocked"
    assert operation.error_class == "authorization"
    assert operation.blocked_reason == "credentials_invalid"

    # Authorization-class remediation is operator-only; this scope carries
    # team_admin, so remediation requeues the same durable operation.
    {:ok, _} = Sync.remediate_operation(scope, operation)

    # Provider conflicts block for remediation instead of retrying blindly.
    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:error, {:conflict, %{}}})
    assert %{success: 1} = drain_settlement()
    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "blocked"
    assert operation.error_class == "conflict"
    assert operation.safe_error_code == "provider_conflict"

    {:ok, _} = Sync.remediate_operation(scope, operation)

    # Unknown error shapes fail terminally rather than retry blindly.
    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:error, :weird_wire_noise})
    assert %{success: 1} = drain_settlement()
    operation = Operations.get!(settlement.operation_id)
    assert operation.state == "failed"
    assert operation.error_class == "terminal"
    assert operation.safe_error_code == "unexpected_provider_error"

    # After manual retry with a healthy provider the settlement reconciles.
    {:ok, _} = Sync.retry_operation(scope, operation)
    assert %{success: 1} = drain_settlement()

    settlement = Repo.get!(CreditSettlement, settlement.id)
    assert settlement.state == :reconciled
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
  end

  test "a provider error during unknown-outcome recovery parks, then auto-resumes", %{
    scope: scope,
    subscription: subscription,
    fake: fake
  } do
    %{settlement: settlement, sync_op: sync_op} = enqueue_erp_settlement!(scope, subscription)

    # Response lost after the create; the recovery search then fails too.
    # The outcome is STILL unknown, so the operation parks in `reconciling`
    # and the job snoozes — no state is claimed and no blind retry runs.
    # (This path once marked the sync row failed with no way back: the
    # machine has no failure edge from reconciling and manual_retry only
    # accepts failed operations, so the money was permanently stuck.)
    # First find: the pre-create lookup proves absence; then the create's
    # response is lost; the recovery find then fails.
    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:ok, nil})
    :ok = FakeERP.inject_unknown_outcome(fake, :create_finance_voucher)
    :ok = FakeERP.inject_failure(fake, :find_finance_voucher, {:error, {:authorization, :denied}})

    assert %{snoozed: 1} = drain_settlement()

    assert Operations.get!(settlement.operation_id).state == "reconciling"
    assert Repo.get!(SyncOperation, sync_op.id).state == "reconciling"
    assert Repo.get!(CreditSettlement, settlement.id).state == :pending

    # The voucher the lost response created is still there, exactly once.
    assert [_voucher] = settlement_vouchers(fake, settlement)

    # The provider recovers: the snoozed job resumes the reconciliation,
    # finds that voucher, and completes — still exactly once.
    assert %{success: 1} =
             Oban.drain_queue(queue: :erp, with_scheduled: true, with_safety: false)

    assert Operations.get!(settlement.operation_id).state == "succeeded"
    assert Repo.get!(CreditSettlement, settlement.id).state == :reconciled
    assert [voucher] = settlement_vouchers(fake, settlement)
    assert voucher_amounts(voucher) == [{"5820", 20_000}, {"5821", -20_000}]
  end

  # Two SettlementPosting branches stay uncovered deliberately:
  #
  #   * the `{:mismatch, reason, operation}` with-else clause — no code path
  #     produces a three-element mismatch tuple (obtain_voucher returns ok /
  #     retry / error shapes; reconcile/2 returns two-element mismatches), so
  #     the clause is defensive dead code;
  #   * `schedule_retry!/2`'s `_other` operation-state arm — a retry is only
  #     ever scheduled from the reconciling state (the unknown-outcome path
  #     transitions to reconciling before searching), so the arm guards a
  #     future caller, not a reachable state.

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
