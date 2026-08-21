defmodule BillingCore.Pricing.DiscountsTest do
  @moduledoc """
  Discount ordering, materialization, allocation, and the non-negative
  invoice floor (SPEC §10.7–§10.9) — including the §10.9 worked example and
  the allocation-sum property of SPEC §23.3.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.{Canonical, Money, Period}

  alias BillingCore.Pricing.{
    ChargeResult,
    DiscountLine,
    Discounts,
    Discounts.Result,
    EligibleLine,
    Engine,
    FixedDiscount,
    PercentageDiscount,
    RatingRequest
  }

  alias BillingCore.Pricing.Model.FixedRecurring
  alias Decimal, as: D

  defp line(id, minor, extra \\ []) do
    struct!(EligibleLine, [id: id, amount: Money.new!("DKK", minor)] ++ extra)
  end

  defp apply!(lines, discounts) do
    {:ok, %Result{} = result} = Discounts.apply_discounts(lines, discounts)
    result
  end

  describe "fixed discounts (SPEC §10.9)" do
    test "spec example: DKK 100.00 across 500/300/200 → 50/30/20" do
      lines = [line("a", 50_000), line("b", 30_000), line("c", 20_000)]
      result = apply!(lines, [%FixedDiscount{id: "d1", amount_minor: 10_000, currency: "DKK"}])

      assert Enum.map(result.discount_lines, &{&1.source_line_id, &1.allocation.minor_units}) ==
               [{"a", -5_000}, {"b", -3_000}, {"c", -2_000}]

      assert result.gross_total == Money.new!("DKK", 100_000)
      assert result.net_total == Money.new!("DKK", 90_000)

      assert result.line_totals == [
               {"a", Money.new!("DKK", 45_000)},
               {"b", Money.new!("DKK", 27_000)},
               {"c", Money.new!("DKK", 18_000)}
             ]

      assert is_binary(Canonical.encode!(result.trace))
    end

    test "largest-remainder residuals go to the stable smallest line id" do
      lines = [line("a", 10_000), line("b", 10_000), line("c", 10_000)]
      result = apply!(lines, [%FixedDiscount{id: "d1", amount_minor: 10_000, currency: "DKK"}])

      assert Enum.map(result.discount_lines, &{&1.source_line_id, &1.allocation.minor_units}) ==
               [{"a", -3_334}, {"b", -3_333}, {"c", -3_333}]
    end

    test "allocations for one discount sum exactly to the discount amount" do
      lines = [line("a", 33_333), line("b", 44_445), line("c", 11)]
      result = apply!(lines, [%FixedDiscount{id: "d1", amount_minor: 9_999, currency: "DKK"}])

      total =
        result.discount_lines
        |> Enum.map(& &1.allocation.minor_units)
        |> Enum.sum()

      assert total == -9_999
    end

    test "fixed discount larger than the base is clamped to the base" do
      result =
        apply!([line("a", 5_000)], [
          %FixedDiscount{id: "d1", amount_minor: 8_000, currency: "DKK"}
        ])

      assert result.net_total == Money.zero("DKK")
      assert [%DiscountLine{allocation: %Money{minor_units: -5_000}}] = result.discount_lines

      assert [%{"clamped" => true, "requested_minor" => 8_000, "amount_minor" => 5_000}] =
               result.trace["discounts"]
    end

    test "a later fixed discount that would cross zero is clamped (invoice floor)" do
      lines = [line("a", 10_000)]

      discounts = [
        %FixedDiscount{id: "f1", amount_minor: 7_000, currency: "DKK", priority: 1},
        %FixedDiscount{id: "f2", amount_minor: 5_000, currency: "DKK", priority: 2}
      ]

      result = apply!(lines, discounts)

      assert result.net_total == Money.zero("DKK")

      assert [
               %{"discount_id" => "f1", "amount_minor" => 7_000, "clamped" => false},
               %{"discount_id" => "f2", "amount_minor" => 3_000, "clamped" => true}
             ] =
               result.trace["discounts"]
    end
  end

  describe "percentage discounts (SPEC §10.7)" do
    test "exact negative allocation on a single line" do
      result = apply!([line("a", 12_345)], [%PercentageDiscount{id: "p1", basis_points: 1_000}])

      # 10% of 123.45 = 12.345 → 12.35
      assert [%DiscountLine{allocation: %Money{minor_units: -1_235}}] = result.discount_lines
      assert result.net_total == Money.new!("DKK", 11_110)

      assert [%{"exact_amount" => "12.345", "rounding_delta_minor" => "0.5"}] =
               result.trace["discounts"]
    end

    test "percentage discounts allocate across lines by current amounts" do
      lines = [line("a", 50_000), line("b", 30_000), line("c", 20_000)]
      result = apply!(lines, [%PercentageDiscount{id: "p1", basis_points: 1_000}])

      assert Enum.map(result.discount_lines, &{&1.source_line_id, &1.allocation.minor_units}) ==
               [{"a", -5_000}, {"b", -3_000}, {"c", -2_000}]
    end

    test "later percentage discounts compound on the running base" do
      discounts = [
        %PercentageDiscount{id: "p1", basis_points: 5_000, priority: 1},
        %PercentageDiscount{id: "p2", basis_points: 1_000, priority: 2}
      ]

      result = apply!([line("a", 100_000)], discounts)

      # 1000.00 → 50% → 500.00 → 10% of the running base → 50.00 → 450.00
      assert result.net_total == Money.new!("DKK", 45_000)

      assert [
               %{"discount_id" => "p1", "base_minor" => 100_000, "amount_minor" => 50_000},
               %{"discount_id" => "p2", "base_minor" => 50_000, "amount_minor" => 5_000}
             ] =
               result.trace["discounts"]
    end

    test "100% discount produces exact zero, never negative" do
      lines = [line("a", 33_333), line("b", 66_667)]

      discounts = [
        %PercentageDiscount{id: "p1", basis_points: 10_000},
        %FixedDiscount{id: "f1", amount_minor: 1_000, currency: "DKK"}
      ]

      result = apply!(lines, discounts)

      assert result.net_total == Money.zero("DKK")
      refute Money.negative?(result.net_total)
      # the subsequent fixed discount finds no base and materializes nothing
      assert Enum.map(result.discount_lines, & &1.discount_id) == ["p1", "p1"]

      assert [_, %{"discount_id" => "f1", "amount_minor" => 0, "allocations" => []}] =
               result.trace["discounts"]

      assert Enum.all?(result.line_totals, fn {_id, money} -> Money.zero?(money) end)
    end

    test "zero-percent discount materializes no lines" do
      result = apply!([line("a", 10_000)], [%PercentageDiscount{id: "p1", basis_points: 0}])

      assert result.discount_lines == []
      assert result.net_total == Money.new!("DKK", 10_000)
    end
  end

  describe "ordering (SPEC §10.7)" do
    test "all percentage discounts apply before any fixed discount, regardless of list order" do
      discounts = [
        %FixedDiscount{id: "f1", amount_minor: 5_000, currency: "DKK", priority: 0},
        %PercentageDiscount{id: "p1", basis_points: 5_000, priority: 9}
      ]

      result = apply!([line("a", 20_000)], discounts)

      # percentage first: 200.00 → 100.00; then fixed 50.00 → 50.00
      assert result.net_total == Money.new!("DKK", 5_000)
      assert Enum.map(result.trace["discounts"], & &1["discount_id"]) == ["p1", "f1"]
    end

    test "priority orders within a kind, ties broken by discount id" do
      discounts = [
        %PercentageDiscount{id: "b", basis_points: 1_000, priority: 1},
        %PercentageDiscount{id: "a", basis_points: 2_000, priority: 1},
        %PercentageDiscount{id: "z", basis_points: 3_000, priority: 0}
      ]

      result = apply!([line("l", 100_000)], discounts)

      assert Enum.map(result.trace["discounts"], & &1["discount_id"]) == ["z", "a", "b"]
    end
  end

  describe "materialization metadata (SPEC §10.8)" do
    test "discount lines inherit service period and recognition mode of the source line" do
      annual = Period.new!(~D[2026-09-15], ~D[2027-09-15])

      lines = [
        line("annual", 12_000_000, service_period: annual, recognition_mode: :over_time),
        line("setup", 50_000, recognition_mode: :point_in_time)
      ]

      result = apply!(lines, [%PercentageDiscount{id: "p1", basis_points: 1_000}])

      annual_discount = Enum.find(result.discount_lines, &(&1.source_line_id == "annual"))
      setup_discount = Enum.find(result.discount_lines, &(&1.source_line_id == "setup"))

      assert annual_discount.service_period == annual
      assert annual_discount.recognition_mode == :over_time
      assert Money.negative?(annual_discount.allocation)

      assert setup_discount.service_period == nil
      assert setup_discount.recognition_mode == :point_in_time
    end

    test "zero-weight lines receive no discount line" do
      lines = [line("a", 10_000), line("zero", 0)]
      result = apply!(lines, [%PercentageDiscount{id: "p1", basis_points: 1_000}])

      assert Enum.map(result.discount_lines, & &1.source_line_id) == ["a"]
      assert {"zero", Money.zero("DKK")} in result.line_totals
    end
  end

  describe "discount plus proration (SPEC §23.2)" do
    test "documented order: base charge and proration first, then discounts" do
      full = Period.new!(~D[2026-08-01], ~D[2026-09-01])
      remaining = Period.new!(~D[2026-08-11], ~D[2026-09-01])

      {:ok, %ChargeResult{} = prorated} =
        Engine.rate(%RatingRequest{
          pricing: %FixedRecurring{unit_price: D.new("3100")},
          currency: "DKK",
          quantity: D.new(1),
          full_period: full,
          active_period: remaining
        })

      assert prorated.amount == Money.new!("DKK", 210_000)

      eligible = [
        %EligibleLine{
          id: "sub",
          amount: prorated.amount,
          service_period: remaining,
          recognition_mode: :over_time
        }
      ]

      discounts = [
        %PercentageDiscount{id: "p1", basis_points: 1_000},
        %FixedDiscount{id: "f1", amount_minor: 9_000, currency: "DKK"}
      ]

      result = apply!(eligible, discounts)

      # 2100.00 → 10% (210.00) → 1890.00 → fixed 90.00 → 1800.00
      assert result.net_total == Money.new!("DKK", 180_000)
      assert Enum.map(result.trace["discounts"], & &1["discount_id"]) == ["p1", "f1"]
      assert Enum.all?(result.discount_lines, &(&1.service_period == remaining))
    end
  end

  describe "validation" do
    test "input errors" do
      assert {:error, :no_eligible_lines} = Discounts.apply_discounts([], [])

      assert {:error, :duplicate_line_ids} =
               Discounts.apply_discounts([line("a", 1), line("a", 2)], [])

      assert {:error, :mixed_currencies} =
               Discounts.apply_discounts(
                 [line("a", 1), %EligibleLine{id: "b", amount: Money.new!("EUR", 1)}],
                 []
               )

      assert {:error, {:negative_line_amount, "a"}} =
               Discounts.apply_discounts([line("a", -1)], [])

      assert {:error, {:invalid_line, :nope}} = Discounts.apply_discounts([:nope], [])
    end

    test "discount definition errors" do
      lines = [line("a", 1_000)]

      assert {:error, {:invalid_basis_points, "p"}} =
               Discounts.apply_discounts(lines, [
                 %PercentageDiscount{id: "p", basis_points: 10_001}
               ])

      assert {:error, {:invalid_fixed_amount, "f"}} =
               Discounts.apply_discounts(lines, [
                 %FixedDiscount{id: "f", amount_minor: 0, currency: "DKK"}
               ])

      assert {:error, {:discount_currency_mismatch, "f"}} =
               Discounts.apply_discounts(lines, [
                 %FixedDiscount{id: "f", amount_minor: 1, currency: "EUR"}
               ])

      assert {:error, {:invalid_discount, :nope}} = Discounts.apply_discounts(lines, [:nope])
    end
  end

  ## Property invariants (SPEC §23.3)

  defp lines_gen do
    gen all(amounts <- list_of(integer(0..1_000_000), min_length: 1, max_length: 5)) do
      amounts
      |> Enum.with_index()
      |> Enum.map(fn {amount, index} -> line("line-#{index}", amount) end)
    end
  end

  defp discounts_gen do
    percentage =
      gen all(
            bp <- integer(0..10_000),
            priority <- integer(-5..5),
            suffix <- integer(0..999)
          ) do
        %PercentageDiscount{id: "pct-#{suffix}", basis_points: bp, priority: priority}
      end

    fixed =
      gen all(
            amount <- integer(1..2_000_000),
            priority <- integer(-5..5),
            suffix <- integer(0..999)
          ) do
        %FixedDiscount{
          id: "fix-#{suffix}",
          amount_minor: amount,
          currency: "DKK",
          priority: priority
        }
      end

    list_of(one_of([percentage, fixed]), max_length: 4)
  end

  property "discount allocations sum exactly to the (possibly clamped) amount and never breach the floor" do
    check all(lines <- lines_gen(), discounts <- discounts_gen()) do
      result = apply!(lines, discounts)

      # every applied discount's allocations sum exactly to its amount
      for applied <- result.trace["discounts"] do
        allocated = applied["allocations"] |> Enum.map(& &1["amount_minor"]) |> Enum.sum()
        assert allocated == -applied["amount_minor"]
        assert applied["amount_minor"] >= 0
        assert applied["amount_minor"] <= applied["base_minor"]
      end

      # net equals gross minus all applied discounts, and never goes negative
      total_discount =
        result.trace["discounts"] |> Enum.map(& &1["amount_minor"]) |> Enum.sum()

      assert result.net_total.minor_units == result.gross_total.minor_units - total_discount
      assert result.net_total.minor_units >= 0
      assert Enum.all?(result.line_totals, fn {_id, money} -> money.minor_units >= 0 end)

      # materialized lines are negative and consistent with the traces
      assert Enum.all?(result.discount_lines, &(&1.allocation.minor_units < 0))

      materialized =
        result.discount_lines |> Enum.map(& &1.allocation.minor_units) |> Enum.sum()

      assert materialized == -total_discount

      # traces stay canonical-JSON-safe (INV-012)
      assert is_binary(Canonical.encode!(result.trace))
    end
  end
end
