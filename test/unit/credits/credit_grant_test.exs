defmodule BillingCore.Credits.CreditGrantTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Credits.CreditGrant

  test "origin_types/0 lists the BC-US-107 origins as strings" do
    assert CreditGrant.origin_types() ==
             ~w(unused_prepaid_service goodwill external_correction manual)
  end

  test "statuses/0 lists the §11.4 projection states" do
    assert CreditGrant.statuses() == [
             :available,
             :reserved,
             :partially_spent,
             :spent,
             :refund_pending,
             :refunded,
             :expiry_scheduled,
             :expired
           ]
  end

  test "new grants default to available with nothing reserved and version 1" do
    grant = %CreditGrant{}
    assert grant.status == :available
    assert grant.reserved_minor == 0
    assert grant.version == 1
    assert grant.metadata == %{}
  end

  describe "headroom/1" do
    test "is the unreserved remainder in minor units" do
      grant = %CreditGrant{remaining_minor: 100, reserved_minor: 30}
      assert CreditGrant.headroom(grant) == 70
    end

    test "a fully reserved grant has zero headroom" do
      grant = %CreditGrant{remaining_minor: 100, reserved_minor: 100}
      assert CreditGrant.headroom(grant) == 0
    end

    test "uses the schema's zero reservation default" do
      assert CreditGrant.headroom(%CreditGrant{remaining_minor: 50}) == 50
    end
  end

  test "rejects statuses outside the enum" do
    changeset = cast(%CreditGrant{}, %{status: "vaporized"}, [:status])

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:status]
  end
end
