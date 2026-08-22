defmodule BillingCore.Credits.CreditSettlementTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Credits.CreditSettlement

  test "modes/0 lists the two settlement evidence modes" do
    assert CreditSettlement.modes() == [:erp_customer_settlement, :external_reference]
  end

  test "states/0 lists only pending and the terminal reconciled state" do
    assert CreditSettlement.states() == [:pending, :reconciled]
  end

  test "new settlements start pending" do
    assert %CreditSettlement{}.state == :pending
  end

  test "rejects modes and states outside the enums" do
    changeset =
      cast(%CreditSettlement{}, %{mode: "cash_drawer", state: "half_reconciled"}, [:mode, :state])

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:mode]
    assert {"is invalid", _} = changeset.errors[:state]
  end

  test "casts declared modes and states to their atoms" do
    changeset =
      cast(%CreditSettlement{}, %{mode: "external_reference", state: "reconciled"}, [
        :mode,
        :state
      ])

    assert changeset.valid?
    assert get_change(changeset, :mode) == :external_reference
    assert get_change(changeset, :state) == :reconciled
  end
end
