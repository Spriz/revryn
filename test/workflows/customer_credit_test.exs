defmodule BillingCore.Workflows.CustomerCreditTest do
  @moduledoc """
  Customer-credit subledger lifecycle as documentation (BC-US-107/108/109,
  SPEC §11.4, §13.3, INV-050…053).

  Credit is money-like value in an append-only ledger: granting converts an
  unused prepaid service period into spendable balance; billing runs reserve
  it transactionally, finalize the debit when the invoice intent freezes,
  and release it idempotently when the invoice is abandoned; termination
  executes an explicit disposition policy (retain / refund / expire_after)
  as durable operations; and the projected balances always reconcile to the
  immutable transaction ledger.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Credits, Outbox}
  alias BillingCore.Credits.{CreditAccount, CreditGrant, CreditTransaction}
  alias BillingCore.Domain.StateMachine
  alias BillingCore.Operations

  import BillingCore.CreditsFixtures

  setup do
    ctx = credit_context_fixture()
    # SPEC §9.4.1: automatic application needs a certified settlement mode.
    settlement_policy_fixture(ctx.scope)
    Map.put(ctx, :now, DateTime.utc_now())
  end

  test "grant_machine/0 encodes the §11.4 grant projection lifecycle" do
    machine = Credits.grant_machine()

    assert machine.initial == :available

    assert StateMachine.states(machine) ==
             [
               :available,
               :expired,
               :expiry_scheduled,
               :partially_spent,
               :refund_pending,
               :refunded,
               :reserved,
               :spent
             ]

    assert StateMachine.legal?(machine, :available, :reserve)
    assert StateMachine.legal?(machine, :reserved, :release)
    assert StateMachine.legal?(machine, :reserved, :apply_partial)
    assert StateMachine.legal?(machine, :reserved, :apply_full)
    assert StateMachine.legal?(machine, :partially_spent, :reserve)
    assert StateMachine.legal?(machine, :partially_spent, :request_refund)
    assert StateMachine.legal?(machine, :available, :schedule_expiry)
    assert StateMachine.legal?(machine, :expiry_scheduled, :reverse_expiry)
    assert StateMachine.legal?(machine, :expiry_scheduled, :expire)
    refute StateMachine.legal?(machine, :available, :release)
    refute StateMachine.legal?(machine, :reserved, :request_refund)
    refute StateMachine.legal?(machine, :reserved, :schedule_expiry)
    assert StateMachine.terminal?(machine, :spent)
    assert StateMachine.terminal?(machine, :refunded)
    assert StateMachine.terminal?(machine, :expired)
  end

  describe "granting unused prepaid service value (BC-US-107)" do
    test "the downgrade example funds the ledger exactly once", ctx do
      # 10 users prepaid 12 months at 450.00 DKK/user/month, reduced to 8
      # after 2 months: credit for exactly 2 users x the unused 10-month
      # period at the original price = 2 * 10 * 45_000 minor units.
      unused_value = 2 * 10 * 45_000
      origin_line_id = Ecto.UUID.generate()

      assert {:ok, grant} =
               Credits.grant_credit(ctx.scope, %{
                 credit_account_id: ctx.credit_account.id,
                 origin_type: "unused_prepaid_service",
                 origin_invoice_line_id: origin_line_id,
                 amount_minor: unused_value,
                 currency: "DKK",
                 idempotency_key: "downgrade-credit-note-77",
                 reason_code: "prepaid_downgrade"
               })

      # the grant records origin, currency, amounts, and grant time
      assert grant.origin_type == "unused_prepaid_service"
      assert grant.origin_invoice_line_id == origin_line_id
      assert grant.granted_minor == unused_value
      assert grant.remaining_minor == unused_value
      assert grant.reserved_minor == 0
      assert grant.currency == "DKK"
      assert grant.status == :available
      assert %DateTime{} = grant.granted_at
      assert grant.expires_at == nil

      # balance change = ledger row + atomic projection update
      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == unused_value
      assert account.reserved_minor == 0

      assert [tx] = transactions(ctx.credit_account)
      assert tx.transaction_type == :grant
      assert tx.amount_minor == unused_value
      assert tx.grant_id == grant.id
      assert tx.idempotency_key == "downgrade-credit-note-77"

      assert "credits.grant.created" in audit_events(grant.id)
      assert "customer_credit.granted.v1" in outbox_events(grant.id)

      # replaying the funding command returns the original grant (exactly once)
      assert {:ok, replayed} =
               Credits.grant_credit(ctx.scope, %{
                 credit_account_id: ctx.credit_account.id,
                 origin_type: "unused_prepaid_service",
                 origin_invoice_line_id: origin_line_id,
                 amount_minor: unused_value,
                 currency: "DKK",
                 idempotency_key: "downgrade-credit-note-77"
               })

      assert replayed.id == grant.id
      assert [_only_one] = transactions(ctx.credit_account)
      assert Repo.get!(CreditAccount, ctx.credit_account.id).available_minor == unused_value

      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "grants validate origin, amount, currency, and idempotency key", ctx do
      base = %{
        credit_account_id: ctx.credit_account.id,
        origin_type: "goodwill",
        amount_minor: 5_000,
        currency: "DKK",
        idempotency_key: "k-1"
      }

      assert {:error, :invalid_origin_type} =
               Credits.grant_credit(ctx.scope, %{base | origin_type: "windfall"})

      assert {:error, :invalid_amount} =
               Credits.grant_credit(ctx.scope, %{base | amount_minor: 0})

      assert {:error, :invalid_amount} =
               Credits.grant_credit(ctx.scope, %{base | amount_minor: -5})

      assert {:error, :currency_mismatch} =
               Credits.grant_credit(ctx.scope, %{base | currency: "EUR"})

      assert {:error, :missing_idempotency_key} =
               Credits.grant_credit(ctx.scope, %{base | idempotency_key: ""})
    end

    test "reads admit all team roles; mutations require finance roles", ctx do
      auditor = credit_context_fixture(roles: [:auditor])

      assert {:error, :unauthorized} =
               Credits.grant_credit(auditor.scope, %{
                 credit_account_id: auditor.credit_account.id,
                 origin_type: "manual",
                 amount_minor: 1_000,
                 currency: "DKK",
                 idempotency_key: "k-x"
               })

      assert {:ok, _grants} = Credits.list_grants(auditor.scope, auditor.credit_account)
      assert {:ok, _txs} = Credits.list_transactions(auditor.scope, auditor.credit_account)

      # possession of an ID never grants access across teams
      assert {:error, :not_found} = Credits.list_grants(auditor.scope, ctx.credit_account)
      _ = ctx
    end
  end

  describe "spending credit on future charges (BC-US-108)" do
    test "reserve before side effects, finalize on freeze", ctx do
      grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 900_000})
      invoice_intent_id = Ecto.UUID.generate()

      # the billing run reserves transactionally before external side effects
      assert {:ok, [{grant_id, 540_000}]} =
               Credits.reserve(:system, ctx.credit_account, 540_000, "resv-2026-09",
                 invoice_intent_id: invoice_intent_id
               )

      assert grant_id == grant.id

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 360_000
      assert account.reserved_minor == 540_000

      reserved = Repo.get!(CreditGrant, grant.id)
      assert reserved.status == :reserved
      assert reserved.reserved_minor == 540_000
      assert reserved.remaining_minor == 900_000

      # replaying the reservation is a no-op returning the original allocation
      assert {:ok, [{^grant_id, 540_000}]} =
               Credits.reserve(:system, ctx.credit_account, 540_000, "resv-2026-09")

      assert Repo.get!(CreditAccount, ctx.credit_account.id).reserved_minor == 540_000

      # the debit finalizes only when the invoice intent freezes
      assert {:ok, [{^grant_id, 540_000}]} =
               Credits.apply_reservation(
                 :system,
                 ctx.credit_account,
                 [{grant.id, 540_000}],
                 "apply-2026-09",
                 invoice_intent_id: invoice_intent_id
               )

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 360_000
      assert account.reserved_minor == 0

      applied = Repo.get!(CreditGrant, grant.id)
      assert applied.status == :partially_spent
      assert applied.remaining_minor == 360_000
      assert applied.reserved_minor == 0

      # idempotent replay of the application
      assert {:ok, [{^grant_id, 540_000}]} =
               Credits.apply_reservation(
                 :system,
                 ctx.credit_account,
                 [{grant.id, 540_000}],
                 "apply-2026-09"
               )

      assert Repo.get!(CreditAccount, ctx.credit_account.id).available_minor == 360_000

      # ledger evidence: one reserve + one apply row, both tied to the intent
      types = transactions(ctx.credit_account) |> Enum.map(& &1.transaction_type)
      assert types == [:grant, :reserve, :apply]

      assert transactions(ctx.credit_account)
             |> Enum.filter(&(&1.transaction_type in [:reserve, :apply]))
             |> Enum.all?(&(&1.invoice_intent_id == invoice_intent_id))

      assert "customer_credit.reserved.v1" in outbox_events(ctx.credit_account.id)
      assert "customer_credit.applied.v1" in outbox_events(ctx.credit_account.id)

      # spending the remainder exhausts the grant
      assert {:ok, _} = Credits.reserve(:system, ctx.credit_account, 360_000, "resv-2026-10")

      assert {:ok, _} =
               Credits.apply_reservation(
                 :system,
                 ctx.credit_account,
                 [{grant.id, 360_000}],
                 "apply-2026-10"
               )

      assert Repo.get!(CreditGrant, grant.id).status == :spent
      assert Repo.get!(CreditAccount, ctx.credit_account.id).available_minor == 0
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "an abandoned invoice releases its reservation idempotently", ctx do
      grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 100_000})

      assert {:ok, allocations} =
               Credits.reserve(:system, ctx.credit_account, 60_000, "resv-abandoned")

      # release by reservation key (the workflow was superseded)
      assert {:ok, released} =
               Credits.release(:system, ctx.credit_account, "resv-abandoned", "rel-abandoned")

      assert released == allocations

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 100_000
      assert account.reserved_minor == 0
      assert Repo.get!(CreditGrant, grant.id).status == :available

      # replaying the release changes nothing
      assert {:ok, ^released} =
               Credits.release(:system, ctx.credit_account, "resv-abandoned", "rel-abandoned")

      assert Repo.get!(CreditAccount, ctx.credit_account.id).available_minor == 100_000

      # replaying the reservation still returns the original allocation
      # (at-least-once delivery), without re-reserving
      assert {:ok, ^allocations} =
               Credits.reserve(:system, ctx.credit_account, 60_000, "resv-abandoned")

      assert Repo.get!(CreditAccount, ctx.credit_account.id).reserved_minor == 0

      assert "customer_credit.released.v1" in outbox_events(ctx.credit_account.id)
      assert "credits.released" in audit_events(ctx.credit_account.id)
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "allocation is earliest-expiry-first, then oldest grant (INV-052)", ctx do
      now = ctx.now
      in_days = fn days -> DateTime.add(now, days * 86_400, :second) end

      # granted in this order; g2 expires soonest, g3 never expires
      g1 =
        grant_fixture(ctx.scope, ctx.credit_account, %{
          amount_minor: 10_000,
          expires_at: in_days.(30)
        })

      g2 =
        grant_fixture(ctx.scope, ctx.credit_account, %{
          amount_minor: 10_000,
          expires_at: in_days.(10)
        })

      g3 = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 10_000})

      # 15_000 consumes all of g2 (earliest expiry), then part of g1
      assert {:ok, [{first, 10_000}, {second, 5_000}]} =
               Credits.reserve(:system, ctx.credit_account, 15_000, "fifo-1")

      assert first == g2.id
      assert second == g1.id

      # the next 12_000 finishes g1 before touching the never-expiring g3
      assert {:ok, [{third, 5_000}, {fourth, 7_000}]} =
               Credits.reserve(:system, ctx.credit_account, 12_000, "fifo-2")

      assert third == g1.id
      assert fourth == g3.id

      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "reserving more than the eligible balance fails atomically", ctx do
      grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 10_000})

      assert {:error, :insufficient_credit} =
               Credits.reserve(:system, ctx.credit_account, 10_001, "too-much")

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 10_000
      assert account.reserved_minor == 0
      assert length(transactions(ctx.credit_account)) == 1
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "concurrent billing runs cannot double-spend the same credit", ctx do
      grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 10_000})
      parent = self()

      results =
        for key <- ["concurrent-a", "concurrent-b"] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Credits.reserve(:system, ctx.credit_account, 8_000, key)
          end)
        end
        |> Task.await_many()

      # exactly one reservation wins; the balance never goes below zero
      assert [{:ok, [{_, 8_000}]}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, :insufficient_credit}] =
               Enum.filter(results, &match?({:error, _}, &1))

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 2_000
      assert account.reserved_minor == 8_000
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end
  end

  describe "refund disposition (BC-US-109)" do
    test "refund is a durable operation with accounting evidence", ctx do
      grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 50_000})

      # spend part first so the refund covers a remaining balance
      {:ok, _} = Credits.reserve(:system, ctx.credit_account, 20_000, "r-1")

      {:ok, _} =
        Credits.apply_reservation(:system, ctx.credit_account, [{grant.id, 20_000}], "a-1")

      assert {:ok, operation} = Credits.request_refund(ctx.scope, ctx.credit_account, [grant.id])

      assert operation.type == "credit.refund"
      assert operation.state == "queued"
      assert operation.metadata["grant_ids"] == [grant.id]
      assert operation.metadata["total_minor"] == 30_000

      pending = Repo.get!(CreditGrant, grant.id)
      assert pending.status == :refund_pending
      assert "customer_credit.refund_requested.v1" in outbox_events(ctx.credit_account.id)

      # pending-refund value is no longer spendable
      assert {:error, :insufficient_credit} =
               Credits.reserve(:system, ctx.credit_account, 1, "r-blocked")

      # completing the refund posts the ledger evidence and settles the op
      assert {:ok, %{operation: done, refunds: [{refunded_id, 30_000}]}} =
               Credits.complete_refund(:system, operation, "refund-run-1")

      assert refunded_id == grant.id
      assert done.state == "succeeded"

      refunded = Repo.get!(CreditGrant, grant.id)
      assert refunded.status == :refunded
      assert refunded.remaining_minor == 0

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 0
      assert account.reserved_minor == 0

      assert [refund_tx] =
               transactions(ctx.credit_account)
               |> Enum.filter(&(&1.transaction_type == :refund))

      assert refund_tx.amount_minor == 30_000
      assert refund_tx.operation_id == operation.id
      assert "customer_credit.refunded.v1" in outbox_events(ctx.credit_account.id)

      # replay returns the recorded result without double-refunding
      assert {:ok, %{refunds: [{^refunded_id, 30_000}]}} =
               Credits.complete_refund(:system, done, "refund-run-1-retry")

      assert Repo.get!(CreditAccount, ctx.credit_account.id).available_minor == 0
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end
  end

  describe "expiry disposition (BC-US-109)" do
    test "schedule, run after the deadline, and evidence the write-off", ctx do
      grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 40_000})
      deadline = DateTime.add(ctx.now, 5 * 86_400, :second)

      assert {:ok, %{grant: scheduled, operation: operation}} =
               Credits.schedule_expiry(ctx.scope, grant, deadline)

      assert scheduled.status == :expiry_scheduled
      assert scheduled.expires_at == deadline
      assert operation.type == "credit.expiry"
      assert operation.state == "queued"
      assert "customer_credit.expiry_scheduled.v1" in outbox_events(grant.id)

      # nothing is written off before the deadline (BC-US-109)
      assert {:ok, []} = Credits.run_expiries(:system, ctx.now)
      assert Repo.get!(CreditGrant, grant.id).status == :expiry_scheduled

      after_deadline = DateTime.add(deadline, 3_600, :second)

      assert {:ok, [%{grant_id: expired_id, amount_minor: 40_000}]} =
               Credits.run_expiries(:system, after_deadline)

      assert expired_id == grant.id

      expired = Repo.get!(CreditGrant, grant.id)
      assert expired.status == :expired
      assert expired.remaining_minor == 0

      account = Repo.get!(CreditAccount, ctx.credit_account.id)
      assert account.available_minor == 0

      # accounting evidence: the auditable expiry transaction + event + op
      assert [expire_tx] =
               transactions(ctx.credit_account)
               |> Enum.filter(&(&1.transaction_type == :expire))

      assert expire_tx.amount_minor == 40_000
      assert expire_tx.operation_id == operation.id
      assert "customer_credit.expired.v1" in outbox_events(grant.id)
      assert Operations.get!(operation.id).state == "succeeded"

      # the sweep is idempotent
      assert {:ok, []} = Credits.run_expiries(:system, after_deadline)
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "an authorized reversal before the deadline restores the grant", ctx do
      original_expiry = DateTime.add(ctx.now, 90 * 86_400, :second)

      grant =
        grant_fixture(ctx.scope, ctx.credit_account, %{
          amount_minor: 25_000,
          expires_at: original_expiry
        })

      deadline = DateTime.add(ctx.now, 3 * 86_400, :second)
      {:ok, %{operation: operation}} = Credits.schedule_expiry(ctx.scope, grant, deadline)

      assert {:ok, restored} = Credits.reverse_expiry_schedule(ctx.scope, grant)
      assert restored.status == :available
      assert restored.expires_at == original_expiry

      # the pending operation is closed with the reversal as evidence
      closed = Operations.get!(operation.id)
      assert closed.state == "failed"
      assert closed.safe_error_code == "expiry_reversed"

      # the deadline passing no longer forfeits anything
      assert {:ok, []} = Credits.run_expiries(:system, DateTime.add(deadline, 60, :second))
      assert Repo.get!(CreditGrant, grant.id).status == :available

      # and the balance is spendable again
      assert {:ok, [{_, 25_000}]} =
               Credits.reserve(:system, ctx.credit_account, 25_000, "after-reversal")

      assert "credits.expiry.reversed" in audit_events(grant.id)
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end
  end

  describe "disposition policy configuration (BC-US-109, INV-053)" do
    test "policies are immutable, versioned, and expire_after needs a duration", ctx do
      assert {:ok, v1} =
               Credits.set_disposition_policy(ctx.scope, ctx.credit_account, %{policy: :retain})

      assert v1.version == 1
      assert v1.policy == :retain

      assert {:error, changeset} =
               Credits.set_disposition_policy(ctx.scope, ctx.credit_account, %{
                 policy: :expire_after
               })

      assert %{expire_after_days: _} = errors_on(changeset)

      assert {:ok, v2} =
               Credits.set_disposition_policy(ctx.scope, ctx.credit_account, %{
                 policy: :expire_after,
                 expire_after_days: 90
               })

      assert v2.version == 2
      assert {:ok, current} = Credits.current_disposition_policy(ctx.scope, ctx.credit_account)
      assert current.id == v2.id
    end

    test "retain leaves the balance eligible for later invoices", ctx do
      grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 12_000})
      {:ok, _} = Credits.set_disposition_policy(ctx.scope, ctx.credit_account, %{policy: :retain})

      assert {:ok, %{policy: :retain}} =
               Credits.execute_disposition(ctx.scope, ctx.credit_account)

      assert {:ok, [{_, 12_000}]} =
               Credits.reserve(:system, ctx.credit_account, 12_000, "post-retain")
    end

    test "refund policy creates one durable refund operation for the remainder", ctx do
      g1 = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 10_000})
      g2 = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 5_000})
      {:ok, _} = Credits.set_disposition_policy(ctx.scope, ctx.credit_account, %{policy: :refund})

      assert {:ok, %{policy: :refund, operation: operation}} =
               Credits.execute_disposition(:system, ctx.credit_account)

      assert operation.metadata["grant_ids"] == [g1.id, g2.id]
      assert operation.metadata["total_minor"] == 15_000
      assert Repo.get!(CreditGrant, g1.id).status == :refund_pending
      assert Repo.get!(CreditGrant, g2.id).status == :refund_pending
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "expire_after schedules grant-aware expiry at now + duration", ctx do
      grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 8_000})

      {:ok, _} =
        Credits.set_disposition_policy(ctx.scope, ctx.credit_account, %{
          policy: :expire_after,
          expire_after_days: 90
        })

      assert {:ok, %{policy: :expire_after, expire_at: expire_at, scheduled: [entry]}} =
               Credits.execute_disposition(:system, ctx.credit_account)

      assert entry.grant_id == grant.id
      assert_in_delta DateTime.diff(expire_at, ctx.now, :second), 90 * 86_400, 5

      scheduled = Repo.get!(CreditGrant, grant.id)
      assert scheduled.status == :expiry_scheduled
      assert scheduled.expires_at == expire_at

      # the write-off posts only after the deadline
      assert {:ok, []} = Credits.run_expiries(:system, DateTime.add(ctx.now, 86_400, :second))

      assert {:ok, [%{amount_minor: 8_000}]} =
               Credits.run_expiries(:system, DateTime.add(expire_at, 60, :second))

      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
    end

    test "termination never implicitly forfeits credit without a policy", ctx do
      grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 1_000})

      assert {:error, :no_disposition_policy} =
               Credits.execute_disposition(:system, ctx.credit_account)

      assert Repo.get!(CreditAccount, ctx.credit_account.id).available_minor == 1_000
    end
  end

  describe "ledger reconciliation (SPEC §13.3, INV-051)" do
    test "the projection reconciles after a full mixed lifecycle", ctx do
      g1 = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 30_000})
      _g2 = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 20_000})

      {:ok, _abandoned} = Credits.reserve(:system, ctx.credit_account, 35_000, "mix-r1")
      {:ok, _} = Credits.release(:system, ctx.credit_account, "mix-r1", "mix-rel1")
      {:ok, allocations} = Credits.reserve(:system, ctx.credit_account, 35_000, "mix-r2")
      {:ok, _} = Credits.apply_reservation(:system, ctx.credit_account, allocations, "mix-a1")
      assert Repo.get!(CreditGrant, g1.id).status == :spent

      assert Credits.reconcile_account(ctx.credit_account.id) == :ok
      assert Credits.reconcile_account!(ctx.credit_account.id) == :ok
    end

    test "a corrupted projection is detected loudly", ctx do
      grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 10_000})
      assert Credits.reconcile_account(ctx.credit_account.id) == :ok

      # corrupt the account projection behind the ledger's back
      Repo.update_all(
        from(a in CreditAccount, where: a.id == ^ctx.credit_account.id),
        inc: [available_minor: 1_234]
      )

      assert {:mismatch, details} = Credits.reconcile_account(ctx.credit_account.id)

      assert details.account.available_minor == %{expected: 10_000, actual: 11_234}

      assert_raise RuntimeError, ~r/reconciliation failed/, fn ->
        Credits.reconcile_account!(ctx.credit_account.id)
      end

      # grant-level corruption is caught too
      Repo.update_all(
        from(a in CreditAccount, where: a.id == ^ctx.credit_account.id),
        inc: [available_minor: -1_234]
      )

      Repo.update_all(
        from(g in CreditGrant, where: g.id == ^grant.id),
        inc: [remaining_minor: -1]
      )

      assert {:mismatch, details} = Credits.reconcile_account(ctx.credit_account.id)
      assert details.grants[grant.id].remaining_minor == %{expected: 10_000, actual: 9_999}
    end

    test "the ledger itself is append-only at the database level", ctx do
      grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 1_000})
      [tx] = transactions(ctx.credit_account)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(
          from(t in CreditTransaction, where: t.id == ^tx.id),
          set: [amount_minor: 999_999]
        )
      end
    end
  end

  defp transactions(credit_account) do
    Repo.all(
      from t in CreditTransaction,
        where: t.credit_account_id == ^credit_account.id,
        order_by: [asc: t.occurred_at, asc: t.id]
    )
  end

  defp audit_events(aggregate_id) do
    Repo.all(from e in Audit.Entry, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end

  defp outbox_events(aggregate_id) do
    Repo.all(from e in Outbox.Event, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end
end
