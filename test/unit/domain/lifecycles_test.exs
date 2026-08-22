defmodule BillingCore.Domain.LifecyclesTest do
  @moduledoc """
  BC-US-160: every named lifecycle is one executable transition table, and
  the checked-in diagram artifact always matches the code — a transition
  change is a reviewed documentation change by construction.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Domain.Lifecycles

  test "docs/architecture/state-machines.md matches the compiled lifecycles" do
    generated = Lifecycles.to_markdown()
    checked_in = File.read!(Path.expand("../../../docs/architecture/state-machines.md", __DIR__))

    assert checked_in == generated, """
    docs/architecture/state-machines.md is stale. A lifecycle transition
    table changed — review the diagram diff as product behavior, then run:

        mix run --no-start -e 'File.write!("docs/architecture/state-machines.md", \
    BillingCore.Domain.Lifecycles.to_markdown())'
    """
  end

  test "every registered lifecycle declares an initial state and reachable terminals" do
    for {slug, _title, machine, _enforcement} <- Lifecycles.all() do
      states = BillingCore.Domain.StateMachine.states(machine)
      assert machine.initial in states, "#{slug}: initial state not in state set"

      for terminal <- machine.terminal do
        assert terminal in states, "#{slug}: terminal #{terminal} not in state set"
      end
    end
  end
end
