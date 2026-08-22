defmodule BillingCore.Contracts.SubscriptionChangeTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Contracts.SubscriptionChange

  test "change_types/0 lists every accepted subscription command" do
    assert SubscriptionChange.change_types() ==
             [:start, :quantity_change, :plan_change, :pause, :resume, :cancel, :correction]
  end

  test "payload and result default to empty maps" do
    change = %SubscriptionChange{}
    assert change.payload == %{}
    assert change.result == %{}
  end

  test "rejects change types outside the enum" do
    changeset = cast(%SubscriptionChange{}, %{change_type: "explode"}, [:change_type])

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:change_type]
  end

  test "casts every declared change type to its atom" do
    for type <- SubscriptionChange.change_types() do
      changeset =
        cast(%SubscriptionChange{}, %{change_type: Atom.to_string(type)}, [:change_type])

      assert changeset.valid?
      assert get_change(changeset, :change_type) == type
    end
  end
end
