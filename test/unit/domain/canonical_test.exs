defmodule BillingCore.Domain.CanonicalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.{Canonical, Money, Period}
  alias Decimal, as: D

  test "object keys are sorted and stable" do
    assert Canonical.encode!(%{"b" => 1, "a" => 2}) == ~s({"a":2,"b":1})
    assert Canonical.encode!(%{b: 1, a: 2}) == ~s({"a":2,"b":1})
  end

  test "decimal normalization strips trailing zeros and exponents" do
    assert Canonical.encode!(%{"q" => D.new("1.500")}) == ~s({"q":"1.5"})
    assert Canonical.encode!(%{"q" => D.new("1E+2")}) == ~s({"q":"100"})
    assert Canonical.encode!(%{"q" => D.new("-0.0")}) == ~s({"q":"0"})
  end

  test "dates, money, and periods have stable shapes" do
    assert Canonical.encode!(~D[2026-09-15]) == ~s("2026-09-15")

    assert Canonical.encode!(Money.new!("DKK", 12_000_000)) ==
             ~s({"currency":"DKK","minorUnits":12000000})

    assert Canonical.encode!(Period.new!(~D[2026-09-15], ~D[2027-09-15])) ==
             ~s({"endExclusive":"2027-09-15","start":"2026-09-15"})
  end

  test "floats are rejected" do
    assert_raise ArgumentError, fn -> Canonical.encode!(%{"amount" => 1.5}) end
  end

  test "datetime is normalized to UTC ISO 8601" do
    dt = DateTime.new!(~D[2026-08-21], ~T[15:00:00], "Etc/UTC")
    assert Canonical.encode!(dt) == ~s("2026-08-21T15:00:00Z")
  end

  property "hash is independent of map insertion order" do
    check all(
            pairs <-
              uniq_list_of(
                tuple({string(:alphanumeric, min_length: 1), integer()}),
                uniq_fun: &elem(&1, 0),
                min_length: 2,
                max_length: 10
              )
          ) do
      map = Map.new(pairs)
      shuffled = pairs |> Enum.shuffle() |> Map.new()
      assert Canonical.hash(map) == Canonical.hash(shuffled)
    end
  end

  property "hashing is deterministic across calls" do
    check all(value <- term_generator()) do
      assert Canonical.hash(value) == Canonical.hash(value)
    end
  end

  defp term_generator do
    one_of([
      integer(),
      string(:printable, max_length: 20),
      map_of(string(:alphanumeric, min_length: 1), integer(), max_length: 5)
    ])
  end
end
