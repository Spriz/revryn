defmodule BillingCore.Pricing.EngineTest do
  @moduledoc """
  Rating engine: fixed recurring / one-time / standard metered calculation
  rows of the SPEC §23.2 matrix, the worked examples of SPEC §10.10–§10.11,
  and the proration/split/credit property invariants of SPEC §23.3.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.{Canonical, Money, Period}
  alias BillingCore.Pricing.{ChargeResult, Engine, RatingRequest}
  alias BillingCore.Pricing.Model.{FixedRecurring, OneTime, StandardMetered}
  alias Decimal, as: D

  defp rate!(request) do
    {:ok, %ChargeResult{} = result} = Engine.rate(request)
    result
  end

  defp fixed_request(price, quantity, full, active \\ nil) do
    %RatingRequest{
      pricing: %FixedRecurring{unit_price: D.new(price)},
      currency: "DKK",
      quantity: D.new(quantity),
      full_period: full,
      active_period: active
    }
  end

  describe "fixed recurring (SPEC §10.1)" do
    test "full monthly fixed charge: exact full amount and period" do
      full = Period.new!(~D[2026-01-01], ~D[2026-02-01])
      result = rate!(fixed_request("100.00", 3, full))

      assert result.amount == Money.new!("DKK", 30_000)
      assert D.eq?(result.unrounded, D.new("300"))
      assert result.trace["model"] == "fixed_recurring"
      assert result.trace["proration"] == "1"
      assert result.trace["period_days"] == 31
      assert result.trace["active_days"] == 31

      assert result.trace["full_period"] == %{
               "start" => "2026-01-01",
               "end_exclusive" => "2026-02-01"
             }

      assert result.trace["rounding_delta_minor"] == "0"
      assert result.trace["amount_minor"] == 30_000
      # trace is canonical-JSON-safe (INV-012)
      assert is_binary(Canonical.encode!(result.trace))
    end

    test "mid-month start: correct active/period day fraction" do
      full = Period.new!(~D[2026-04-01], ~D[2026-05-01])
      active = Period.new!(~D[2026-04-16], ~D[2026-05-01])
      result = rate!(fixed_request("100.00", 1, full, active))

      assert result.trace["period_days"] == 30
      assert result.trace["active_days"] == 15
      assert result.trace["proration"] == "0.5"
      assert result.amount == Money.new!("DKK", 5_000)
    end

    test "no billing period rates the full charge without proration keys" do
      result = rate!(fixed_request("100.00", 2, nil))

      assert result.amount == Money.new!("DKK", 20_000)
      assert result.trace["proration"] == "1"
      refute Map.has_key?(result.trace, "period_days")
      refute Map.has_key?(result.trace, "full_period")
    end

    test "rounding delta is retained in the trace" do
      result = rate!(fixed_request("0.335", 1, nil))

      # 0.335 → 33.5 minor → half-away-from-zero → 34
      assert result.amount == Money.new!("DKK", 34)
      assert result.trace["unrounded_amount"] == "0.335"
      assert result.trace["rounding_delta_minor"] == "0.5"
    end
  end

  describe "mid-period changes and credits (SPEC §10.11, §23.2)" do
    setup do
      full = Period.new!(~D[2026-08-01], ~D[2026-09-01])
      remaining = Period.new!(~D[2026-08-11], ~D[2026-09-01])
      %{full: full, remaining: remaining}
    end

    test "immediate upgrade: DKK 3100 → 6200 after 10 of 31 days", %{
      full: full,
      remaining: remaining
    } do
      credit = Engine.negate(rate!(fixed_request("3100", 1, full, remaining)))
      charge = rate!(fixed_request("6200", 1, full, remaining))

      assert credit.amount == Money.new!("DKK", -210_000)
      assert charge.amount == Money.new!("DKK", 420_000)
      assert Money.add!(credit.amount, charge.amount) == Money.new!("DKK", 210_000)
      assert credit.trace["negated"] == true
      assert credit.trace["active_days"] == 21
      assert charge.trace["period_days"] == 31
    end

    test "immediate downgrade: old credit plus lower new charge", %{
      full: full,
      remaining: remaining
    } do
      credit = Engine.negate(rate!(fixed_request("6200", 1, full, remaining)))
      charge = rate!(fixed_request("3100", 1, full, remaining))

      assert credit.amount == Money.new!("DKK", -420_000)
      assert charge.amount == Money.new!("DKK", 210_000)
      assert Money.add!(credit.amount, charge.amount) == Money.new!("DKK", -210_000)
    end

    test "immediate cancellation with credit: negative remaining-period line", %{
      full: full,
      remaining: remaining
    } do
      credit = Engine.negate(rate!(fixed_request("3100", 1, full, remaining)))

      assert Money.negative?(credit.amount)
      assert credit.amount == Money.new!("DKK", -210_000)
      # discount/credit lines keep the service period of the line they adjust
      assert credit.trace["active_period"] == %{
               "start" => "2026-08-11",
               "end_exclusive" => "2026-09-01"
             }
    end

    test "cancel at period end: no current-period credit", %{full: full} do
      # The unused remainder [period_end, period_end) is not a valid period —
      # there is nothing to credit, so no credit line arises.
      assert {:error, :invalid_period} =
               Period.new(full.end_date_exclusive, full.end_date_exclusive)

      # Equivalently: the service consumed equals the full charge exactly.
      charged = rate!(fixed_request("3100", 1, full))
      consumed = rate!(fixed_request("3100", 1, full, full))
      assert Money.add!(Engine.negate(consumed).amount, charged.amount) == Money.zero("DKK")
    end

    test "full credit: exact inverse line and periods", %{full: full, remaining: remaining} do
      original = rate!(fixed_request("99.99", 3, full, remaining))
      credit = Engine.negate(original)

      assert Money.add!(original.amount, credit.amount) == Money.zero("DKK")
      assert D.eq?(D.add(original.unrounded, credit.unrounded), D.new(0))
      assert credit.trace["full_period"] == original.trace["full_period"]
      assert credit.trace["active_period"] == original.trace["active_period"]
    end

    test "partial credit is bounded by the original charge", %{full: full} do
      original = rate!(fixed_request("3100", 1, full))
      partial = Period.new!(~D[2026-08-20], ~D[2026-09-01])
      credit = Engine.negate(rate!(fixed_request("3100", 1, full, partial)))

      assert credit.amount.minor_units < 0
      assert abs(credit.amount.minor_units) < original.amount.minor_units
    end
  end

  describe "anchor policies (SPEC §23.2, BC-US-065)" do
    test "leap-day annual start keeps a stable anniversary" do
      start = ~D[2024-02-29]
      first = Period.billing_period_at(start, start, 12)

      assert first == Period.new!(~D[2024-02-29], ~D[2025-02-28])
      assert Period.days(first) == 365

      # the anniversary returns to Feb 29 in the next leap year
      assert Period.add_months(start, 48, 29) == ~D[2028-02-29]

      result = rate!(fixed_request("1200.00", 1, first))
      assert result.amount == Money.new!("DKK", 120_000)
      assert result.trace["proration"] == "1"
    end

    test "January 31 monthly anchor clamps to the last valid day in February" do
      start = ~D[2026-01-31]
      february = Period.billing_period_at(start, ~D[2026-02-15], 1)

      assert february == Period.new!(~D[2026-01-31], ~D[2026-02-28])

      march = Period.billing_period_at(start, ~D[2026-03-01], 1)
      assert march == Period.new!(~D[2026-02-28], ~D[2026-03-31])

      # a clamped 28-day period is still a full period: no proration
      result = rate!(fixed_request("100.00", 1, february))
      assert result.trace["proration"] == "1"
      assert result.amount == Money.new!("DKK", 10_000)
    end
  end

  describe "annual prepaid and one-time (SPEC §10.10, §23.2)" do
    test "annual prepaid line: 12000000 minor units and inclusive ERP end date" do
      service = Period.new!(~D[2026-09-15], ~D[2027-09-15])
      result = rate!(fixed_request("120000.00", 1, service))

      assert result.amount == Money.new!("DKK", 12_000_000)
      assert result.trace["proration"] == "1"
      # the e-conomic adapter emits inclusive endDate = end_exclusive - 1 day
      assert Period.inclusive_end(service) == ~D[2027-09-14]
    end

    test "point-in-time setup fee: no accrual fields in the trace" do
      request = %RatingRequest{
        pricing: %OneTime{unit_price: D.new("500.00")},
        currency: "DKK",
        quantity: D.new(1)
      }

      result = rate!(request)

      assert result.amount == Money.new!("DKK", 50_000)
      assert result.trace["model"] == "one_time"

      for key <- ["full_period", "active_period", "period_days", "active_days", "proration"] do
        refute Map.has_key?(result.trace, key), "unexpected accrual key #{key}"
      end
    end

    test "one-time charge multiplies by quantity" do
      request = %RatingRequest{
        pricing: %OneTime{unit_price: D.new("19.99")},
        currency: "DKK",
        quantity: D.new(3)
      }

      assert rate!(request).amount == Money.new!("DKK", 5_997)
    end
  end

  defp metered_request(rate, quantity, currency \\ "DKK") do
    %RatingRequest{
      pricing: %StandardMetered{unit_rate: D.new(rate)},
      currency: currency,
      quantity: D.new(quantity)
    }
  end

  describe "standard metered (SPEC §10.2, §23.2)" do
    test "standard usage: quantity × rate" do
      result = rate!(metered_request("0.10", "123.456"))

      assert result.trace["unrounded_amount"] == "12.3456"
      assert result.amount == Money.new!("DKK", 1_235)
      assert result.trace["unit_rate"] == "0.1"
      assert result.trace["quantity"] == "123.456"
    end

    test "foreign currency: currency preserved and minor-unit rules applied" do
      # JPY has 0 minor-unit decimals: 100.5 × 3 = 301.5 → 302 JPY
      jpy = rate!(metered_request("3", "100.5", "JPY"))
      assert jpy.amount == Money.new!("JPY", 302)

      eur = rate!(metered_request("1.005", "1", "EUR"))
      assert eur.amount == Money.new!("EUR", 101)
      assert eur.amount.currency == "EUR"
    end

    test "negative amount rounding is symmetric (usage correction)" do
      positive = rate!(metered_request("1", "1.005"))
      negative = rate!(metered_request("1", "-1.005"))

      assert positive.amount == Money.new!("DKK", 101)
      assert negative.amount == Money.new!("DKK", -101)
      assert negative.trace["rounding_delta_minor"] == "-0.5"
    end
  end

  describe "request validation" do
    test "invalid currency, quantity, and period combinations" do
      base = fixed_request("1", 1, nil)

      assert {:error, {:invalid_currency, "dk"}} = Engine.rate(%{base | currency: "dk"})
      assert {:error, {:invalid_quantity, 1}} = Engine.rate(%{base | quantity: 1})

      full = Period.new!(~D[2026-01-01], ~D[2026-02-01])
      outside = Period.new!(~D[2026-01-15], ~D[2026-02-02])

      assert {:error, :active_period_without_full_period} =
               Engine.rate(%{base | active_period: full})

      assert {:error, :active_period_not_covered} =
               Engine.rate(%{base | full_period: full, active_period: outside})
    end

    test "unsupported pricing terms are rejected" do
      assert {:error, {:unsupported_pricing, :nope}} =
               Engine.rate(%RatingRequest{pricing: :nope, currency: "DKK", quantity: D.new(1)})
    end
  end

  ## Property invariants (SPEC §23.3)

  defp money_decimal_gen(max_coef, max_scale) do
    gen all(
          coef <- integer(0..max_coef),
          scale <- integer(0..max_scale)
        ) do
      D.new(1, coef, -scale)
    end
  end

  property "proration fraction is in (0, 1] for normal active subperiods" do
    check all(
            days <- integer(1..400),
            active_offset <- integer(0..(days - 1)),
            active_days <- integer(1..(days - active_offset)),
            start_offset <- integer(0..2000)
          ) do
      start = Date.add(~D[2024-01-01], start_offset)
      full = Period.new!(start, Date.add(start, days))

      active =
        Period.new!(Date.add(start, active_offset), Date.add(start, active_offset + active_days))

      # kernel fraction (exact division at context precision)
      fraction = Period.proration_fraction(full, active)
      assert D.compare(fraction, D.new(0)) == :gt
      assert D.compare(fraction, D.new(1)) != :gt

      # engine fraction (fixed rating scale) obeys the same bounds
      result = rate!(fixed_request("100.00", 1, full, active))
      engine_fraction = D.new(result.trace["proration"])
      assert D.compare(engine_fraction, D.new(0)) == :gt
      assert D.compare(engine_fraction, D.new(1)) != :gt
    end
  end

  property "splitting a full period rates to the same unrounded total as the whole" do
    check all(
            price <- money_decimal_gen(100_000, 2),
            quantity <- money_decimal_gen(10_000, 2),
            days <- integer(2..366),
            split <- integer(1..(days - 1)),
            start_offset <- integer(0..2000)
          ) do
      start = Date.add(~D[2024-01-01], start_offset)
      middle = Date.add(start, split)
      finish = Date.add(start, days)
      full = Period.new!(start, finish)

      price_string = Canonical.decimal_string(price)
      quantity_string = Canonical.decimal_string(quantity)

      whole = rate!(fixed_request(price_string, quantity_string, full))

      first =
        rate!(fixed_request(price_string, quantity_string, full, Period.new!(start, middle)))

      second =
        rate!(fixed_request(price_string, quantity_string, full, Period.new!(middle, finish)))

      # exact decimals before rounding (SPEC §23.3)
      assert D.eq?(D.add(first.unrounded, second.unrounded), whole.unrounded)
      # rounded parts differ from the whole by at most one minor unit
      assert abs(first.amount.minor_units + second.amount.minor_units - whole.amount.minor_units) <=
               1
    end
  end

  property "credit of a line plus the original is exactly zero minor units" do
    check all(
            coef <- integer(0..10_000_000),
            scale <- integer(0..4),
            rate_coef <- integer(0..100_000),
            rate_scale <- integer(0..4),
            sign <- member_of([1, -1])
          ) do
      quantity = D.new(sign, coef, -scale)

      request = %RatingRequest{
        pricing: %StandardMetered{unit_rate: D.new(1, rate_coef, -rate_scale)},
        currency: "DKK",
        quantity: quantity
      }

      result = rate!(request)
      credit = Engine.negate(result)

      assert Money.zero?(Money.add!(result.amount, credit.amount))
      assert D.eq?(D.add(result.unrounded, credit.unrounded), D.new(0))

      # symmetric rounding: rating the negated quantity gives the same credit
      mirrored = rate!(%{request | quantity: D.negate(quantity)})
      assert mirrored.amount == credit.amount

      assert is_binary(Canonical.encode!(credit.trace))
    end
  end
end
