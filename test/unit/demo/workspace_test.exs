defmodule BillingCore.Demo.WorkspaceTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Demo.Workspace

  test "states/0 lists the workspace lifecycle" do
    assert Workspace.states() == [:provisioning, :active, :completed, :failed, :archived]
  end

  test "new workspaces default to provisioning on the current scenario" do
    workspace = %Workspace{}
    assert workspace.state == :provisioning
    assert workspace.scenario_version == "northstar-v1"
    assert workspace.progress == %{}
  end

  test "rejects states outside the enum" do
    changeset = cast(%Workspace{}, %{state: "daydreaming"}, [:state])

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:state]
  end

  test "casts every declared state to its atom" do
    for state <- Workspace.states() do
      changeset = cast(%Workspace{}, %{state: Atom.to_string(state)}, [:state])
      assert changeset.valid?
      assert get_field(changeset, :state) == state
    end
  end
end
