defmodule BillingCore.Credits.Close.CloseSchemaTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Credits.Close.{Approval, Close, Movement}

  describe "Close.exact_arithmetic?/1" do
    test "accepts an exactly bridged close with debit-positive liability line" do
      assert Close.exact_arithmetic?(%{
               opening_minor: 100,
               closing_minor: 70,
               net_change_minor: -30,
               economic_liability_line_minor: 30
             })
    end

    test "accepts a zero-movement close" do
      assert Close.exact_arithmetic?(%{
               opening_minor: 0,
               closing_minor: 0,
               net_change_minor: 0,
               economic_liability_line_minor: 0
             })
    end

    test "rejects a net change that does not bridge opening to closing" do
      refute Close.exact_arithmetic?(%{
               opening_minor: 100,
               closing_minor: 70,
               net_change_minor: -31,
               economic_liability_line_minor: 30
             })
    end

    test "rejects a liability line that is not opening - closing (sign flip)" do
      refute Close.exact_arithmetic?(%{
               opening_minor: 100,
               closing_minor: 70,
               net_change_minor: -30,
               economic_liability_line_minor: -30
             })
    end

    test "rejects negative opening or closing balances" do
      refute Close.exact_arithmetic?(%{
               opening_minor: -10,
               closing_minor: 20,
               net_change_minor: 30,
               economic_liability_line_minor: -30
             })

      refute Close.exact_arithmetic?(%{
               opening_minor: 10,
               closing_minor: -20,
               net_change_minor: -30,
               economic_liability_line_minor: 30
             })
    end

    test "rejects closes with missing or non-integer amounts via the fallthrough clause" do
      refute Close.exact_arithmetic?(%Close{})
      refute Close.exact_arithmetic?(%{opening_minor: nil, closing_minor: 0})

      refute Close.exact_arithmetic?(%{
               opening_minor: Decimal.new(1),
               closing_minor: 0,
               net_change_minor: -1,
               economic_liability_line_minor: 1
             })
    end
  end

  describe "Close schema" do
    test "states/0 lists the full close lifecycle" do
      assert Close.states() == [
               :open,
               :calculating,
               :ready,
               :approved,
               :posting,
               :outcome_unknown,
               :posted,
               :reconciled,
               :closed,
               :failed,
               :mismatch,
               :superseded,
               :reversal_pending,
               :reversed
             ]
    end

    test "new closes default to the open state and a regular close kind" do
      close = %Close{}
      assert close.state == :open
      assert close.close_kind == :regular
    end

    test "rejects state and close_kind values outside the enum" do
      changeset = cast(%Close{}, %{state: "flying", close_kind: "casual"}, [:state, :close_kind])

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:state]
      assert {"is invalid", _} = changeset.errors[:close_kind]
    end

    test "casts every declared state" do
      for state <- Close.states() do
        changeset = cast(%Close{}, %{state: Atom.to_string(state)}, [:state])
        assert changeset.valid?
        assert get_field(changeset, :state) == state
      end
    end
  end

  describe "Approval schema" do
    test "actions/0 lists the append-only approval actions" do
      assert Approval.actions() == [:approved, :revoked, :reversal_approved]
    end

    test "rejects actions outside the enum and casts declared ones" do
      refute cast(%Approval{}, %{action: "self_approved"}, [:action]).valid?

      for action <- Approval.actions() do
        changeset = cast(%Approval{}, %{action: Atom.to_string(action)}, [:action])
        assert changeset.valid?
        assert get_change(changeset, :action) == action
      end
    end
  end

  describe "Movement schema" do
    test "movement_types/0 lists the aggregate movement evidence types" do
      assert Movement.movement_types() == [
               :grant,
               :reserve,
               :release,
               :apply,
               :refund,
               :expire,
               :positive_adjustment,
               :negative_adjustment,
               :prior_period_adjustment
             ]
    end

    test "rejects movement types outside the enum and casts declared ones" do
      changeset = cast(%Movement{}, %{movement_type: "teleport"}, [:movement_type])
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:movement_type]

      for type <- Movement.movement_types() do
        changeset = cast(%Movement{}, %{movement_type: Atom.to_string(type)}, [:movement_type])
        assert changeset.valid?
        assert get_change(changeset, :movement_type) == type
      end
    end
  end
end
