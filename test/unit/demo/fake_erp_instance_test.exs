defmodule BillingCore.Demo.FakeERPInstanceTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Demo.FakeERPInstance

  test "states/0 lists the snapshot lifecycle" do
    assert FakeERPInstance.states() == [:active, :archived]
  end

  test "new instances default to an active first-format snapshot at lock version 1" do
    instance = %FakeERPInstance{}
    assert instance.state == :active
    assert instance.snapshot_format_version == 1
    assert instance.lock_version == 1
  end

  test "rejects states outside the enum" do
    changeset = cast(%FakeERPInstance{}, %{state: "hibernating"}, [:state])

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:state]
  end

  test "casts every declared state to its atom" do
    for state <- FakeERPInstance.states() do
      changeset = cast(%FakeERPInstance{}, %{state: Atom.to_string(state)}, [:state])
      assert changeset.valid?
      assert get_field(changeset, :state) == state
    end
  end
end
