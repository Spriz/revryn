defmodule BillingCore.Credits.CreditTransactionTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Credits.CreditTransaction

  test "transaction_types/0 lists every ledger row type" do
    assert CreditTransaction.transaction_types() ==
             [:grant, :reserve, :release, :apply, :refund, :expire, :adjust]
  end

  test "metadata defaults to an empty map" do
    assert %CreditTransaction{}.metadata == %{}
  end

  test "rejects transaction types outside the enum" do
    changeset = cast(%CreditTransaction{}, %{transaction_type: "chargeback"}, [:transaction_type])

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:transaction_type]
  end

  test "casts every declared transaction type to its atom" do
    for type <- CreditTransaction.transaction_types() do
      changeset =
        cast(%CreditTransaction{}, %{transaction_type: Atom.to_string(type)}, [:transaction_type])

      assert changeset.valid?
      assert get_change(changeset, :transaction_type) == type
    end
  end
end
