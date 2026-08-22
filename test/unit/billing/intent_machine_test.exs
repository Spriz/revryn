defmodule BillingCore.Billing.IntentMachineTest do
  @moduledoc """
  SPEC §11.2 invoice-intent lifecycle: every documented transition is legal,
  everything else is a structured error, and `superseded` is terminal.
  Mirrors `test/unit/domain/lifecycles_test.exs` in treating the transition
  table as executable documentation.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Billing.IntentMachine
  alias BillingCore.Domain.StateMachine
  alias BillingCore.Domain.StateMachine.TransitionError

  @legal_transitions [
    {:frozen, :supersede, :superseded},
    {:frozen, :enqueue_sync, :sync_pending},
    {:sync_pending, :draft_reconciled, :erp_draft},
    {:sync_pending, :sync_failed, :sync_error},
    {:erp_draft, :draft_updated, :erp_draft},
    {:erp_draft, :approve, :approved},
    {:erp_draft, :externally_booked, :erp_booked},
    {:approved, :book, :booking_pending},
    {:approved, :approval_invalidated, :erp_draft},
    {:booking_pending, :booked_reconciled, :erp_booked},
    {:booking_pending, :sync_failed, :sync_error},
    {:erp_booked, :correction_approved, :credit_required},
    {:credit_required, :correction_case_created, :erp_booked},
    {:sync_error, :retry_sync, :sync_pending}
  ]

  test "every documented transition resolves to its next state" do
    for {from, event, to} <- @legal_transitions do
      assert IntentMachine.transition(from, event) == {:ok, to},
             "expected #{from} --#{event}--> #{to}"
    end
  end

  test "undocumented transitions are structured illegal-transition errors" do
    for {from, event} <- [
          {:frozen, :approve},
          {:frozen, :book},
          {:sync_pending, :approve},
          {:erp_draft, :book},
          {:erp_booked, :approve},
          {:sync_error, :book},
          {:credit_required, :approve}
        ] do
      assert {:error,
              %TransitionError{
                machine: :invoice_intent,
                reason: :illegal_transition,
                from: ^from,
                event: ^event
              }} = IntentMachine.transition(from, event)
    end
  end

  test "superseded is terminal and accepts no events" do
    assert {:error, %TransitionError{reason: :terminal_state, from: :superseded}} =
             IntentMachine.transition(:superseded, :enqueue_sync)

    assert {:error, %TransitionError{reason: :terminal_state}} =
             IntentMachine.transition(:superseded, :supersede)
  end

  test "accepts persisted string states" do
    assert {:ok, :approved} = IntentMachine.transition("erp_draft", :approve)

    assert {:error, %TransitionError{reason: :illegal_transition}} =
             IntentMachine.transition("erp_booked", :approve)
  end

  test "a string that is not a known state raises instead of minting atoms" do
    assert_raise ArgumentError, fn ->
      IntentMachine.transition("definitely_not_an_intent_state", :approve)
    end
  end

  test "machine/0 starts intents frozen (preview is never persisted)" do
    machine = IntentMachine.machine()
    assert %StateMachine{name: :invoice_intent, initial: :frozen} = machine
    assert StateMachine.terminal?(machine, :superseded)
  end

  test "states/0 covers exactly the lifecycle states" do
    assert Enum.sort(IntentMachine.states()) ==
             Enum.sort([
               :frozen,
               :superseded,
               :sync_pending,
               :sync_error,
               :erp_draft,
               :approved,
               :booking_pending,
               :erp_booked,
               :credit_required
             ])
  end

  test "to_mermaid/0 renders the lifecycle for feature documentation" do
    mermaid = IntentMachine.to_mermaid()
    assert mermaid =~ "stateDiagram-v2"
    assert mermaid =~ "[*] --> frozen"
    assert mermaid =~ "frozen --> sync_pending: enqueue_sync"
    assert mermaid =~ "superseded --> [*]"
  end
end
