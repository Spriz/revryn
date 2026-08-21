defmodule BillingCore.Domain.PeriodTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.Period
  alias Decimal, as: D

  describe "half-open semantics" do
    test "rejects empty and inverted periods" do
      assert_raise ArgumentError, fn -> Period.new!(~D[2026-01-01], ~D[2026-01-01]) end
      assert {:error, :invalid_period} = Period.new(~D[2026-02-01], ~D[2026-01-01])
    end

    test "day count is exclusive-end minus start" do
      assert Period.days(Period.new!(~D[2026-09-15], ~D[2027-09-15])) == 365
      assert Period.days(Period.new!(~D[2024-02-01], ~D[2024-03-01])) == 29
    end

    test "spec example: annual period converts to inclusive ERP end date" do
      period = Period.new!(~D[2026-09-15], ~D[2027-09-15])
      assert Period.inclusive_end(period) == ~D[2027-09-14]
    end

    test "adjacent periods do not overlap" do
      a = Period.new!(~D[2026-01-01], ~D[2026-02-01])
      b = Period.new!(~D[2026-02-01], ~D[2026-03-01])
      refute Period.overlaps?(a, b)
      assert Period.adjacent?(a, b)
      assert Period.intersect(a, b) == nil
    end

    test "contains_date? includes start, excludes end" do
      p = Period.new!(~D[2026-01-01], ~D[2026-02-01])
      assert Period.contains_date?(p, ~D[2026-01-01])
      assert Period.contains_date?(p, ~D[2026-01-31])
      refute Period.contains_date?(p, ~D[2026-02-01])
    end
  end

  describe "proration_fraction/2" do
    test "spec §10.11: 21 of 31 days" do
      full = Period.new!(~D[2026-01-01], ~D[2026-02-01])
      active = Period.new!(~D[2026-01-11], ~D[2026-02-01])
      assert D.eq?(Period.proration_fraction(full, active), D.div(D.new(21), D.new(31)))
    end

    test "rejects an active period outside the full period" do
      full = Period.new!(~D[2026-01-01], ~D[2026-02-01])
      active = Period.new!(~D[2026-01-15], ~D[2026-02-02])
      assert_raise ArgumentError, fn -> Period.proration_fraction(full, active) end
    end

    property "fraction is in (0, 1] for contained subperiods" do
      check all(
              start_offset <- integer(0..27),
              len <- integer(1..(28 - 27)),
              max_runs: 50
            ) do
        full = Period.new!(~D[2026-02-01], ~D[2026-03-01])
        active_start = Date.add(~D[2026-02-01], start_offset)
        active = Period.new!(active_start, Date.add(active_start, len))
        fraction = Period.proration_fraction(full, active)

        assert D.compare(fraction, D.new(0)) == :gt
        assert D.compare(fraction, D.new(1)) in [:lt, :eq]
      end
    end
  end

  describe "month arithmetic with anchor clamping" do
    test "Jan 31 anchor clamps in February and recovers in March" do
      assert Period.add_months(~D[2026-01-31], 1, 31) == ~D[2026-02-28]
      assert Period.add_months(~D[2026-02-28], 1, 31) == ~D[2026-03-31]
      assert Period.add_months(~D[2024-01-31], 1, 31) == ~D[2024-02-29]
    end

    test "leap-day annual anchor is stable" do
      assert Period.add_months(~D[2024-02-29], 12, 29) == ~D[2025-02-28]
      assert Period.add_months(~D[2025-02-28], 12, 29) == ~D[2026-02-28]
      assert Period.add_months(~D[2027-02-28], 12, 29) == ~D[2028-02-29]
    end

    test "billing_period_at for a Jan 31 monthly subscription" do
      assert Period.billing_period_at(~D[2026-01-31], ~D[2026-02-10], 1) ==
               Period.new!(~D[2026-01-31], ~D[2026-02-28])

      assert Period.billing_period_at(~D[2026-01-31], ~D[2026-02-28], 1) ==
               Period.new!(~D[2026-02-28], ~D[2026-03-31])
    end

    test "billing_period_at at exact start" do
      assert Period.billing_period_at(~D[2026-09-15], ~D[2026-09-15], 12) ==
               Period.new!(~D[2026-09-15], ~D[2027-09-15])
    end

    property "consecutive billing periods are adjacent and non-overlapping" do
      check all(
              start_day <- integer(1..31),
              months_ahead <- integer(0..36),
              interval <- member_of([1, 3, 12]),
              max_runs: 60
            ) do
        start = Date.new!(2026, 1, min(start_day, 31))
        from = Date.add(start, months_ahead * 30)
        p1 = Period.billing_period_at(start, from, interval)
        p2 = Period.billing_period_at(start, p1.end_date_exclusive, interval)

        assert Period.adjacent?(p1, p2)
        refute Period.overlaps?(p1, p2)
        assert Period.contains_date?(p1, from)
      end
    end
  end
end
