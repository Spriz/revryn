defmodule BillingCore.Domain.MoneyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.Money
  alias Decimal, as: D

  describe "construction and arithmetic" do
    test "new!/2 validates currency shape" do
      assert %Money{currency: "DKK", minor_units: 100} = Money.new!("DKK", 100)
      assert_raise ArgumentError, fn -> Money.new!("dkk", 100) end
      assert_raise ArgumentError, fn -> Money.new!("DKKK", 100) end
    end

    test "add!/2 requires matching currency" do
      assert Money.add!(Money.new!("DKK", 5), Money.new!("DKK", -7)) == Money.new!("DKK", -2)
      assert_raise ArgumentError, fn -> Money.add!(Money.new!("DKK", 1), Money.new!("EUR", 1)) end
    end

    test "currency exponents" do
      assert Money.exponent("DKK") == 2
      assert Money.exponent("JPY") == 0
      assert Money.exponent("BHD") == 3
    end
  end

  describe "round_major/2 — half away from zero" do
    test "rounds ties away from zero in both signs" do
      assert Money.round_major(D.new("1.005"), "DKK") == Money.new!("DKK", 101)
      assert Money.round_major(D.new("-1.005"), "DKK") == Money.new!("DKK", -101)
      assert Money.round_major(D.new("1.004"), "DKK") == Money.new!("DKK", 100)
      assert Money.round_major(D.new("-1.004"), "DKK") == Money.new!("DKK", -100)
    end

    test "respects currency scale" do
      assert Money.round_major(D.new("123.4"), "JPY") == Money.new!("JPY", 123)
      assert Money.round_major(D.new("1.2345"), "BHD") == Money.new!("BHD", 1235)
    end

    test "rounding delta is recorded exactly" do
      delta = Money.rounding_delta_minor(D.new("1.005"), "DKK")
      assert D.eq?(delta, D.new("0.5"))
    end
  end

  describe "allocate!/2 — largest remainder" do
    test "spec example: 100.00 across 500/300/200" do
      total = Money.new!("DKK", 10_000)

      weights = [{"line-1", D.new(50_000)}, {"line-2", D.new(30_000)}, {"line-3", D.new(20_000)}]

      assert Money.allocate!(total, weights) == [
               {"line-1", Money.new!("DKK", 5_000)},
               {"line-2", Money.new!("DKK", 3_000)},
               {"line-3", Money.new!("DKK", 2_000)}
             ]
    end

    test "residual minor units go to largest remainders, tie-broken by stable id" do
      total = Money.new!("DKK", 100)
      weights = [{"a", D.new(1)}, {"b", D.new(1)}, {"c", D.new(1)}]

      assert [
               {"a", %Money{minor_units: 34}},
               {"b", %Money{minor_units: 33}},
               {"c", %Money{minor_units: 33}}
             ] =
               Money.allocate!(total, weights)
    end

    test "allocating a negative amount sums exactly" do
      total = Money.new!("DKK", -100)
      weights = [{"a", D.new(1)}, {"b", D.new(1)}, {"c", D.new(1)}]
      allocations = Money.allocate!(total, weights)

      assert allocations |> Enum.map(fn {_id, m} -> m.minor_units end) |> Enum.sum() == -100
    end

    property "allocations always sum exactly to the allocated amount" do
      check all(
              amount <- integer(-1_000_000..1_000_000),
              weights <-
                uniq_list_of(
                  tuple({string(:alphanumeric, min_length: 1), positive_integer()}),
                  uniq_fun: &elem(&1, 0),
                  min_length: 1,
                  max_length: 12
                )
            ) do
        money = Money.new!("DKK", amount)
        decimal_weights = Enum.map(weights, fn {id, w} -> {id, D.new(w)} end)
        allocations = Money.allocate!(money, decimal_weights)

        assert allocations |> Enum.map(fn {_id, m} -> m.minor_units end) |> Enum.sum() == amount
        assert length(allocations) == length(weights)
      end
    end
  end
end
