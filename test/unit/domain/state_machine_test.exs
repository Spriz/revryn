defmodule BillingCore.Domain.StateMachineTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.StateMachine
  alias BillingCore.Domain.StateMachine.TransitionError

  defp machine do
    StateMachine.new(:subscription,
      initial: :scheduled,
      transitions: [
        {:scheduled, :start, :active},
        {:scheduled, :cancel, :cancelled},
        {:active, :pause, :paused, guard: :not_mid_run},
        {:paused, :resume, :active},
        {:active, :cancel, :cancelled}
      ],
      terminal: [:cancelled],
      guards: [
        not_mid_run: fn ctx ->
          if ctx[:billing_run_open], do: {:error, :billing_run_open}, else: :ok
        end
      ]
    )
  end

  test "legal transitions resolve to the next state" do
    assert {:ok, :active} = StateMachine.transition(machine(), :scheduled, :start)
    assert {:ok, :cancelled} = StateMachine.transition(machine(), :active, :cancel)
  end

  test "illegal transitions return a structured error" do
    assert {:error, %TransitionError{reason: :illegal_transition, from: :paused, event: :cancel}} =
             StateMachine.transition(machine(), :paused, :cancel)
  end

  test "terminal states accept no events" do
    assert {:error, %TransitionError{reason: :terminal_state}} =
             StateMachine.transition(machine(), :cancelled, :start)

    assert StateMachine.legal_events(machine(), :cancelled) == []
  end

  test "guards can reject with a reason" do
    assert {:ok, :paused} =
             StateMachine.transition(machine(), :active, :pause, %{billing_run_open: false})

    assert {:error, %TransitionError{reason: :guard_rejected, guard: :billing_run_open}} =
             StateMachine.transition(machine(), :active, :pause, %{billing_run_open: true})
  end

  test "introspection lists states and events" do
    m = machine()
    assert :cancelled in StateMachine.states(m)
    assert StateMachine.events(m) == [:cancel, :pause, :resume, :start]
    assert StateMachine.legal_events(m, :scheduled) == [:cancel, :start]
    assert StateMachine.terminal?(m, :cancelled)
  end

  test "mermaid rendering includes all transitions and terminals" do
    mermaid = StateMachine.to_mermaid(machine())
    assert mermaid =~ "stateDiagram-v2"
    assert mermaid =~ "[*] --> scheduled"
    assert mermaid =~ "active --> paused: pause [not_mid_run]"
    assert mermaid =~ "cancelled --> [*]"
  end
end
