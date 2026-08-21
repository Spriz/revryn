defmodule BillingCore.Workflows.SubscriptionLifecycleTest do
  @moduledoc """
  Subscription lifecycle as documentation (BC-US-034…039, SPEC §11.1,
  §13.3): a subscription starts inside its contract dates — immediately
  active or scheduled for the future — evolves through non-overlapping
  version snapshots on quantity/plan changes, and ends through period-end or
  immediate cancellation, all evidenced by append-only change rows, audit
  entries, and outbox events.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.Audit
  alias BillingCore.Contracts
  alias BillingCore.Contracts.SubscriptionVersion
  alias BillingCore.Domain.StateMachine
  alias BillingCore.Outbox

  import BillingCore.ContractsFixtures

  setup do
    scope = billing_scope_fixture()
    today = Date.utc_today()
    contract = contract_fixture(scope, %{start_date: Date.add(today, -100)})
    %{scope: scope, contract: contract, today: today}
  end

  test "subscription_machine/0 encodes the §11.1 lifecycle" do
    machine = Contracts.subscription_machine()

    assert machine.initial == :scheduled

    assert StateMachine.states(machine) ==
             [:active, :cancelled, :paused, :pending_cancellation, :scheduled]

    assert StateMachine.legal?(machine, :scheduled, :activate)
    assert StateMachine.legal?(machine, :scheduled, :cancel)
    assert StateMachine.legal?(machine, :active, :change)
    assert StateMachine.legal?(machine, :active, :cancel)
    assert StateMachine.legal?(machine, :active, :cancel_at_period_end)
    assert StateMachine.legal?(machine, :paused, :resume)
    assert StateMachine.legal?(machine, :pending_cancellation, :reach_period_boundary)
    refute StateMachine.legal?(machine, :paused, :cancel)
    assert StateMachine.terminal?(machine, :cancelled)
  end

  describe "starting a subscription (BC-US-034)" do
    test "a start date that has arrived yields an active subscription", ctx do
      start_date = Date.add(ctx.today, -10)
      plan_version_id = Ecto.UUID.generate()

      assert {:ok, subscription} =
               Contracts.start_subscription(ctx.scope, %{
                 external_id: "sub-hosting-1",
                 contract_id: ctx.contract.id,
                 plan_version_id: plan_version_id,
                 quantity: 5,
                 start_date: start_date
               })

      assert subscription.status == :active
      assert subscription.start_date == start_date
      assert subscription.end_date_exclusive == nil
      assert subscription.billing_anchor_day == start_date.day
      assert subscription.time_zone == ctx.scope.team.time_zone
      assert subscription.current_version == 1

      # version 1 pins plan + quantity from the start date, open-ended
      assert {:ok, [v1]} = Contracts.list_subscription_versions(ctx.scope, subscription)
      assert v1.plan_version_id == plan_version_id
      assert Decimal.eq?(v1.quantity, 5)
      assert v1.effective_start == start_date
      assert v1.effective_end_exclusive == nil

      # the command is evidenced: change row, audit, outbox event
      assert {:ok, [change]} = Contracts.list_subscription_changes(ctx.scope, subscription)
      assert change.change_type == :start
      assert change.effective_date == start_date
      assert change.actor_reference == "user:#{ctx.scope.user.id}"
      assert "contracts.subscription.started" in audit_events(subscription.id)
      assert "subscription.started.v1" in outbox_events(subscription.id)
    end

    test "a future start date yields a scheduled subscription", ctx do
      start_date = Date.add(ctx.today, 10)

      assert {:ok, subscription} =
               Contracts.start_subscription(ctx.scope, %{
                 external_id: unique_subscription_external_id(),
                 contract_id: ctx.contract.id,
                 plan_version_id: Ecto.UUID.generate(),
                 quantity: 1,
                 start_date: start_date
               })

      assert subscription.status == :scheduled
      assert "subscription.started.v1" in outbox_events(subscription.id)
    end

    test "the subscription cannot start outside its contract dates", ctx do
      bounded =
        contract_fixture(ctx.scope, %{
          start_date: Date.add(ctx.today, -50),
          end_date_exclusive: Date.add(ctx.today, 50)
        })

      base = %{
        external_id: unique_subscription_external_id(),
        contract_id: bounded.id,
        plan_version_id: Ecto.UUID.generate(),
        quantity: 1
      }

      # before the contract begins
      assert {:error, :outside_contract_period} =
               Contracts.start_subscription(
                 ctx.scope,
                 Map.put(base, :start_date, Date.add(ctx.today, -51))
               )

      # at/after the contract's exclusive end
      assert {:error, :outside_contract_period} =
               Contracts.start_subscription(
                 ctx.scope,
                 Map.put(base, :start_date, Date.add(ctx.today, 50))
               )

      # extending beyond the contract's exclusive end
      assert {:error, :outside_contract_period} =
               Contracts.start_subscription(
                 ctx.scope,
                 base
                 |> Map.put(:start_date, ctx.today)
                 |> Map.put(:end_date_exclusive, Date.add(ctx.today, 51))
               )
    end

    test "an identical replay by external ID returns the existing subscription", ctx do
      attrs = %{
        external_id: "sub-replay-1",
        contract_id: ctx.contract.id,
        plan_version_id: Ecto.UUID.generate(),
        quantity: 3,
        start_date: ctx.today
      }

      assert {:ok, original} = Contracts.start_subscription(ctx.scope, attrs)
      assert {:ok, replayed} = Contracts.start_subscription(ctx.scope, attrs)

      assert replayed.id == original.id
      assert {:ok, [_v1]} = Contracts.list_subscription_versions(ctx.scope, original)
      assert {:ok, [_start]} = Contracts.list_subscription_changes(ctx.scope, original)
    end

    test "a replay with a different payload is a conflict", ctx do
      attrs = %{
        external_id: "sub-replay-2",
        contract_id: ctx.contract.id,
        plan_version_id: Ecto.UUID.generate(),
        quantity: 3,
        start_date: ctx.today
      }

      assert {:ok, _subscription} = Contracts.start_subscription(ctx.scope, attrs)
      assert {:error, :conflict} = Contracts.start_subscription(ctx.scope, %{attrs | quantity: 4})
    end
  end

  describe "scheduled activation (BC-US-035)" do
    test "activate_due_subscriptions promotes exactly the due subscriptions", ctx do
      start_date = Date.add(ctx.today, 10)

      subscription =
        subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id, start_date: start_date})

      assert subscription.status == :scheduled

      # not yet due — nothing happens
      assert Contracts.activate_due_subscriptions(Date.add(start_date, -1)) == 0
      assert {:ok, %{status: :scheduled}} = Contracts.get_subscription(ctx.scope, subscription.id)

      # the boundary day activates it, audited as :system, idempotently
      assert Contracts.activate_due_subscriptions(start_date) == 1
      assert {:ok, %{status: :active}} = Contracts.get_subscription(ctx.scope, subscription.id)
      assert Contracts.activate_due_subscriptions(start_date) == 0

      assert "contracts.subscription.activated" in audit_events(subscription.id)
      assert "subscription.changed.v1" in outbox_events(subscription.id)
    end
  end

  describe "quantity change (BC-US-036)" do
    test "closes the current version at the effective date and appends the next", ctx do
      start_date = Date.add(ctx.today, -30)

      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: start_date,
          quantity: 5
        })

      assert {:ok, updated} =
               Contracts.change_quantity(ctx.scope, subscription, %{
                 quantity: 8,
                 effective_date: ctx.today,
                 idempotency_key: "qty-1"
               })

      assert updated.current_version == 2
      assert updated.version == subscription.version + 1

      # a seamless half-open timeline: [start, today) then [today, ∞)
      assert {:ok, [v1, v2]} = Contracts.list_subscription_versions(ctx.scope, updated)
      assert v1.effective_start == start_date
      assert v1.effective_end_exclusive == ctx.today
      assert v2.effective_start == ctx.today
      assert v2.effective_end_exclusive == nil
      assert Decimal.eq?(v1.quantity, 5)
      assert Decimal.eq?(v2.quantity, 8)
      assert v2.plan_version_id == v1.plan_version_id

      assert {:ok, [_start, change]} = Contracts.list_subscription_changes(ctx.scope, updated)
      assert change.change_type == :quantity_change
      assert "subscription.changed.v1" in outbox_events(subscription.id)
    end

    test "the database exclusion constraint rejects overlapping versions", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, -30)
        })

      # bypass the context and insert a version overlapping [start, ∞) directly
      assert_raise Ecto.ConstraintError, ~r/subscription_versions_no_overlap/, fn ->
        Repo.insert!(%SubscriptionVersion{
          team_id: subscription.team_id,
          subscription_id: subscription.id,
          version: 99,
          plan_version_id: Ecto.UUID.generate(),
          quantity: Decimal.new(1),
          effective_start: Date.add(ctx.today, -10)
        })
      end
    end

    test "an effective date before the current version is rejected", ctx do
      start_date = Date.add(ctx.today, -30)

      subscription =
        subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id, start_date: start_date})

      assert {:error, :effective_date_in_past} =
               Contracts.change_quantity(ctx.scope, subscription, %{
                 quantity: 2,
                 effective_date: Date.add(start_date, -1),
                 idempotency_key: "qty-past"
               })
    end

    test "quantity changes require an active subscription", ctx do
      subscription = subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id})
      {:ok, paused} = Contracts.pause_subscription(ctx.scope, subscription)

      assert {:error, :invalid_state} =
               Contracts.change_quantity(ctx.scope, paused, %{
                 quantity: 2,
                 idempotency_key: "qty-paused"
               })
    end
  end

  describe "plan version change (BC-US-037)" do
    test "moves to the new plan version with the same splitting mechanics", ctx do
      start_date = Date.add(ctx.today, -30)

      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: start_date,
          quantity: 5
        })

      new_plan_version_id = Ecto.UUID.generate()

      assert {:ok, updated} =
               Contracts.change_plan_version(ctx.scope, subscription, %{
                 plan_version_id: new_plan_version_id,
                 effective_date: ctx.today,
                 idempotency_key: "plan-1"
               })

      assert updated.current_version == 2
      assert {:ok, [v1, v2]} = Contracts.list_subscription_versions(ctx.scope, updated)
      assert v1.effective_end_exclusive == ctx.today
      assert v2.plan_version_id == new_plan_version_id
      # quantity carries over unless changed
      assert Decimal.eq?(v2.quantity, v1.quantity)

      assert {:ok, [_start, change]} = Contracts.list_subscription_changes(ctx.scope, updated)
      assert change.change_type == :plan_change
    end
  end

  describe "cancellation (BC-US-038)" do
    test "end-of-period cancellation stops renewal, the boundary finalizes it", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, -30)
        })

      period_end = Date.add(ctx.today, 9)

      assert {:ok, pending} =
               Contracts.cancel_subscription(ctx.scope, subscription, %{
                 mode: :end_of_period,
                 reason: "churn",
                 period_end_date: period_end
               })

      # renewal stops; the current service period is untouched until its end
      assert pending.status == :pending_cancellation
      assert pending.end_date_exclusive == period_end
      assert {:ok, [v1]} = Contracts.list_subscription_versions(ctx.scope, pending)
      assert v1.effective_end_exclusive == period_end
      assert v1.status_reason == "churn"
      assert "subscription.cancelled.v1" in outbox_events(subscription.id)

      # nothing happens before the boundary; the boundary completes §11.1
      assert Contracts.finalize_due_cancellations(Date.add(period_end, -1)) == 0
      assert Contracts.finalize_due_cancellations(period_end) == 1
      assert {:ok, %{status: :cancelled}} = Contracts.get_subscription(ctx.scope, pending.id)
      assert "contracts.subscription.cancellation_finalized" in audit_events(subscription.id)
    end

    test "immediate cancellation ends service at the effective date", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, -30)
        })

      assert {:ok, cancelled} =
               Contracts.cancel_subscription(ctx.scope, subscription, %{
                 mode: :immediate,
                 reason: "fraud"
               })

      assert cancelled.status == :cancelled
      assert cancelled.end_date_exclusive == ctx.today
      assert {:ok, [v1]} = Contracts.list_subscription_versions(ctx.scope, cancelled)
      assert v1.effective_end_exclusive == ctx.today
      assert v1.status_reason == "fraud"

      # reason and actor are retained (BC-US-038)
      assert {:ok, [_start, change]} = Contracts.list_subscription_changes(ctx.scope, cancelled)
      assert change.change_type == :cancel
      assert change.payload["reason"] == "fraud"
      assert change.actor_reference == "user:#{ctx.scope.user.id}"
      assert "subscription.cancelled.v1" in outbox_events(subscription.id)
    end

    test "a scheduled subscription can be cancelled before it starts", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, 20)
        })

      assert subscription.status == :scheduled

      assert {:ok, cancelled} =
               Contracts.cancel_subscription(ctx.scope, subscription, %{mode: :immediate})

      # never active: no end date, the version never becomes effective
      assert cancelled.status == :cancelled
      assert cancelled.end_date_exclusive == nil
      assert {:ok, [v1]} = Contracts.list_subscription_versions(ctx.scope, cancelled)
      assert v1.effective_end_exclusive == v1.effective_start
    end

    test "cancelled is terminal — no further commands are accepted", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, -30)
        })

      {:ok, cancelled} =
        Contracts.cancel_subscription(ctx.scope, subscription, %{mode: :immediate})

      assert {:error, :invalid_state} =
               Contracts.change_quantity(ctx.scope, cancelled, %{
                 quantity: 2,
                 idempotency_key: "qty-after-cancel"
               })

      assert {:error, :invalid_state} = Contracts.pause_subscription(ctx.scope, cancelled)

      assert {:error, :invalid_state} =
               Contracts.cancel_subscription(ctx.scope, cancelled, %{mode: :immediate})
    end

    test "end-of-period cancellation requires the explicit boundary date", ctx do
      subscription = subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id})

      assert {:error, :missing_period_end_date} =
               Contracts.cancel_subscription(ctx.scope, subscription, %{mode: :end_of_period})
    end
  end

  describe "pause and resume (BC-US-039)" do
    test "an active subscription pauses and resumes with full evidence", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, -30)
        })

      assert {:ok, paused} =
               Contracts.pause_subscription(ctx.scope, subscription, %{reason: "vacation"})

      assert paused.status == :paused

      assert {:ok, resumed} = Contracts.resume_subscription(ctx.scope, paused)
      assert resumed.status == :active

      assert {:ok, changes} = Contracts.list_subscription_changes(ctx.scope, resumed)
      assert Enum.map(changes, & &1.change_type) == [:start, :pause, :resume]
      assert "contracts.subscription.paused" in audit_events(subscription.id)
      assert "contracts.subscription.resumed" in audit_events(subscription.id)
    end

    test "a scheduled subscription cannot pause (§11.1)", ctx do
      subscription =
        subscription_fixture(ctx.scope, %{
          contract_id: ctx.contract.id,
          start_date: Date.add(ctx.today, 20)
        })

      assert {:error, :invalid_state} = Contracts.pause_subscription(ctx.scope, subscription)
    end
  end

  describe "team isolation and authorization" do
    test "a scope from another team can neither read nor mutate", ctx do
      subscription = subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id})
      other_scope = billing_scope_fixture()

      assert {:error, :not_found} = Contracts.get_subscription(other_scope, subscription.id)
      assert {:ok, []} = Contracts.list_subscription_versions(other_scope, subscription)

      assert {:error, :subscription_not_found} =
               Contracts.change_quantity(other_scope, subscription, %{
                 quantity: 99,
                 idempotency_key: "cross-team"
               })

      assert {:error, :subscription_not_found} =
               Contracts.cancel_subscription(other_scope, subscription, %{mode: :immediate})

      # nothing changed in the owning team
      assert {:ok, %{status: :active, current_version: 1}} =
               Contracts.get_subscription(ctx.scope, subscription.id)
    end

    test "mutations require billing_admin or team_admin", ctx do
      subscription = subscription_fixture(ctx.scope, %{contract_id: ctx.contract.id})
      auditor = team_scope_fixture(ctx.scope.organization, ctx.scope.team, [:auditor])

      assert {:error, :unauthorized} =
               Contracts.start_subscription(auditor, %{
                 external_id: unique_subscription_external_id(),
                 contract_id: ctx.contract.id,
                 plan_version_id: Ecto.UUID.generate(),
                 quantity: 1,
                 start_date: ctx.today
               })

      assert {:error, :unauthorized} =
               Contracts.cancel_subscription(auditor, subscription, %{mode: :immediate})

      # read roles can still observe
      assert {:ok, %{id: id}} = Contracts.get_subscription(auditor, subscription.id)
      assert id == subscription.id
    end
  end

  defp audit_events(aggregate_id) do
    Repo.all(from e in Audit.Entry, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end

  defp outbox_events(aggregate_id) do
    Repo.all(from e in Outbox.Event, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end
end
