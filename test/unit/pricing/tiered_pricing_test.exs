defmodule BillingCore.Pricing.TieredPricingTest do
  @moduledoc """
  Volume tiers, graduated tiers, package pricing, and minimum commit
  (SPEC §10.3–§10.6) — including the boundary rows and the graduated-sum
  property of SPEC §23.2–§23.3.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.{Canonical, Money}
  alias BillingCore.Pricing.{ChargeResult, Engine, RatingRequest, Tier}

  alias BillingCore.Pricing.Model.{
    GraduatedTier,
    MinimumCommit,
    Package,
    StandardMetered,
    VolumeTier
  }

  alias Decimal, as: D

  defp rate!(pricing, quantity, currency \\ "DKK") do
    {:ok, %ChargeResult{} = result} =
      Engine.rate(%RatingRequest{pricing: pricing, currency: currency, quantity: D.new(quantity)})

    result
  end

  defp tier(from, to, rate, fee \\ 0) do
    %Tier{
      from: D.new(from),
      to: to && D.new(to),
      unit_rate: D.new(rate),
      flat_fee_minor: fee
    }
  end

  defp three_tiers do
    [tier("0", "100", "1.00"), tier("100", "200", "0.90"), tier("200", nil, "0.80")]
  end

  describe "volume tiers (SPEC §10.3)" do
    test "boundary minus epsilon selects the lower tier" do
      result = rate!(%VolumeTier{tiers: three_tiers()}, "99.999")

      assert result.trace["selected_tier_index"] == 0
      # 99.999 × 1.00 = 99.999 → 100.00
      assert result.amount == Money.new!("DKK", 10_000)
    end

    test "exact boundary selects the tier whose from equals it (documented rule)" do
      result = rate!(%VolumeTier{tiers: three_tiers()}, "100")

      assert result.trace["selected_tier_index"] == 1
      # 100 × 0.90 = 90.00
      assert result.amount == Money.new!("DKK", 9_000)
    end

    test "boundary plus epsilon selects the next tier" do
      result = rate!(%VolumeTier{tiers: three_tiers()}, "100.001")

      assert result.trace["selected_tier_index"] == 1
      # 100.001 × 0.90 = 90.0009 → 90.00
      assert result.amount == Money.new!("DKK", 9_000)
    end

    test "selected tier flat fee is added before the single rounding" do
      tiers = [tier("0", "100", "1.00"), tier("100", nil, "0.90", 500)]
      result = rate!(%VolumeTier{tiers: tiers}, "150")

      # 150 × 0.90 + 5.00 = 140.00
      assert result.amount == Money.new!("DKK", 14_000)
      assert result.trace["unrounded_amount"] == "140"
    end

    test "zero quantity selects the first tier" do
      result = rate!(%VolumeTier{tiers: three_tiers()}, "0")

      assert result.trace["selected_tier_index"] == 0
      assert result.amount == Money.zero("DKK")
    end

    test "per-tier breakdown is retained in the trace" do
      result = rate!(%VolumeTier{tiers: three_tiers()}, "250")

      assert [
               %{"index" => 0, "selected" => false, "quantity" => "0"},
               %{"index" => 1, "selected" => false},
               %{
                 "index" => 2,
                 "selected" => true,
                 "quantity" => "250",
                 "amount" => "200",
                 "to" => nil
               }
             ] = result.trace["tiers"]

      assert is_binary(Canonical.encode!(result.trace))
    end

    test "negative quantity is rejected" do
      assert {:error, {:negative_quantity, "volume_tier"}} =
               Engine.rate(%RatingRequest{
                 pricing: %VolumeTier{tiers: three_tiers()},
                 currency: "DKK",
                 quantity: D.new("-1")
               })
    end
  end

  describe "graduated tiers (SPEC §10.4)" do
    test "per-tier quantities sum to the total and price their own slice" do
      result = rate!(%GraduatedTier{tiers: three_tiers()}, "250")

      # 100 × 1.00 + 100 × 0.90 + 50 × 0.80 = 100 + 90 + 40 = 230.00
      assert result.amount == Money.new!("DKK", 23_000)

      assert [
               %{"index" => 0, "quantity" => "100", "amount" => "100"},
               %{"index" => 1, "quantity" => "100", "amount" => "90"},
               %{"index" => 2, "quantity" => "50", "amount" => "40"}
             ] = result.trace["tiers"]
    end

    test "flat fees apply only to tiers with quantity_i > 0" do
      tiers = [tier("0", "100", "1.00", 100), tier("100", nil, "0.90", 999)]
      result = rate!(%GraduatedTier{tiers: tiers}, "100")

      # quantity_2 = max(0, 100 - 100) = 0 → its flat fee does not apply
      # 100 × 1.00 + 1.00 = 101.00
      assert result.amount == Money.new!("DKK", 10_100)

      assert [%{"quantity" => "100"}, %{"quantity" => "0", "amount" => "0"}] =
               result.trace["tiers"]
    end

    test "zero quantity produces zero without any flat fees" do
      tiers = [tier("0", "100", "1.00", 100), tier("100", nil, "0.90", 999)]
      result = rate!(%GraduatedTier{tiers: tiers}, "0")

      assert result.amount == Money.zero("DKK")
      assert result.trace["unrounded_amount"] == "0"
    end

    test "negative quantity is rejected" do
      assert {:error, {:negative_quantity, "graduated_tier"}} =
               Engine.rate(%RatingRequest{
                 pricing: %GraduatedTier{tiers: three_tiers()},
                 currency: "DKK",
                 quantity: D.new("-0.01")
               })
    end
  end

  describe "package pricing (SPEC §10.5)" do
    test "ceiling package count" do
      package = %Package{package_size: D.new("10"), package_price: D.new("25.00")}

      exact = rate!(package, "100")
      assert exact.trace["packages"] == 10
      assert exact.amount == Money.new!("DKK", 25_000)

      partial = rate!(package, "101")
      assert partial.trace["packages"] == 11
      assert partial.amount == Money.new!("DKK", 27_500)

      fraction = rate!(package, "0.5")
      assert fraction.trace["packages"] == 1

      zero = rate!(package, "0")
      assert zero.trace["packages"] == 0
      assert zero.amount == Money.zero("DKK")
    end

    test "fractional package size uses exact arithmetic" do
      package = %Package{package_size: D.new("2.5"), package_price: D.new("10.00")}

      assert rate!(package, "6").trace["packages"] == 3
      assert rate!(package, "5").trace["packages"] == 2
      assert rate!(package, "5.01").trace["packages"] == 3
    end
  end

  describe "minimum commit (SPEC §10.6)" do
    setup do
      %{
        pricing: %MinimumCommit{
          minimum_amount_minor: 10_000,
          inner: %StandardMetered{unit_rate: D.new("5.00")}
        }
      }
    end

    test "below threshold: uplift to minimum", %{pricing: pricing} do
      result = rate!(pricing, "10")

      # rated 50.00 < minimum 100.00
      assert result.amount == Money.new!("DKK", 10_000)
      assert result.trace["minimum_applied"] == true
      assert result.trace["minimum_uplift"] == "50"
      assert result.trace["rated_unrounded"] == "50"
      assert result.trace["inner"]["model"] == "standard_metered"
      assert result.trace["inner"]["amount_minor"] == 5_000
      assert is_binary(Canonical.encode!(result.trace))
    end

    test "above threshold: no uplift", %{pricing: pricing} do
      result = rate!(pricing, "30")

      assert result.amount == Money.new!("DKK", 15_000)
      assert result.trace["minimum_applied"] == false
      assert result.trace["minimum_uplift"] == "0"
    end

    test "exactly at threshold: no uplift", %{pricing: pricing} do
      result = rate!(pricing, "20")

      assert result.amount == Money.new!("DKK", 10_000)
      assert result.trace["minimum_applied"] == false
      assert result.trace["minimum_uplift"] == "0"
    end

    test "inner model errors propagate" do
      pricing = %MinimumCommit{
        minimum_amount_minor: 1,
        inner: %VolumeTier{tiers: three_tiers()}
      }

      assert {:error, {:negative_quantity, "volume_tier"}} =
               Engine.rate(%RatingRequest{pricing: pricing, currency: "DKK", quantity: D.new(-1)})
    end
  end

  ## Property invariants (SPEC §23.3)

  defp tiers_gen do
    gen all(
          increments <- list_of({integer(1..10_000), integer(0..2)}, max_length: 3),
          rate_specs <-
            list_of({integer(0..100_000), integer(0..3)}, length: length(increments) + 1),
          fees <- list_of(integer(0..10_000), length: length(increments) + 1)
        ) do
      boundaries =
        increments
        |> Enum.map(fn {coef, scale} -> D.new(1, coef, -scale) end)
        |> Enum.scan(D.new(0), fn increment, acc -> D.add(acc, increment) end)

      froms = [D.new(0) | boundaries]
      tos = boundaries ++ [nil]
      rates = Enum.map(rate_specs, fn {coef, scale} -> D.new(1, coef, -scale) end)

      [froms, tos, rates, fees]
      |> Enum.zip()
      |> Enum.map(fn {from, to, rate, fee} ->
        %Tier{from: from, to: to, unit_rate: rate, flat_fee_minor: fee}
      end)
    end
  end

  defp quantity_gen do
    gen all(coef <- integer(0..10_000_000), scale <- integer(0..3)) do
      D.new(1, coef, -scale)
    end
  end

  property "graduated tier quantities sum to the total quantity" do
    check all(tiers <- tiers_gen(), quantity <- quantity_gen()) do
      assert Tier.validate_tiers(tiers) == :ok

      result = rate!(%GraduatedTier{tiers: tiers}, quantity)

      total =
        result.trace["tiers"]
        |> Enum.map(&D.new(&1["quantity"]))
        |> Enum.reduce(D.new(0), &D.add/2)

      assert D.eq?(total, quantity)
    end
  end

  property "volume tier selection picks exactly the one tier containing Q" do
    check all(tiers <- tiers_gen(), quantity <- quantity_gen()) do
      containing = Enum.filter(tiers, &Tier.contains?(&1, quantity))
      assert length(containing) == 1

      result = rate!(%VolumeTier{tiers: tiers}, quantity)
      selected = Enum.at(tiers, result.trace["selected_tier_index"])
      assert Tier.contains?(selected, quantity)
      assert selected == hd(containing)
    end
  end
end
