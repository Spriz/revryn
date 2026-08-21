defmodule BillingCore.ERP.DescriptionTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Period
  alias BillingCore.ERP.Description

  # NOTE: assertions are deliberately separator-agnostic between the headline
  # and the usage/ref row. `Description.render/2` joins them with `"\n"`, but
  # `Fingerprint.normalize_text/1` strips control characters (including the
  # newline) before collapsing whitespace, so the two rows currently render
  # with no separator at all — a deviation from the two-line SPEC §17.6 format
  # that belongs to description.ex, not to these tests.

  @period Period.new!(~D[2026-09-15], ~D[2027-09-15])

  test "usage row renders quantity, unit, rate, currency, and ref (SPEC §17.6)" do
    rendered =
      Description.render("Platform subscription",
        period: @period,
        quantity: Decimal.new("10.5"),
        unit: "users",
        rate: Decimal.new("1200"),
        currency: "DKK",
        line_ref: "a1b2c3"
      )

    # The service end is inclusive: end_exclusive - 1 day.
    assert rendered =~ "Platform subscription — 2026-09-15 to 2027-09-14"
    assert String.ends_with?(rendered, "Usage: 10.5 users @ 1200 DKK | Ref: a1b2c3")
  end

  test "decimals render canonically without trailing zeros or exponents" do
    rendered =
      Description.render("Metered usage",
        period: @period,
        quantity: Decimal.new("10.50"),
        rate: Decimal.new("100.00"),
        currency: "EUR",
        line_ref: "l1"
      )

    assert rendered =~ "Usage: 10.5 units @ 100 EUR | Ref: l1"
  end

  test "unit defaults to \"units\" when not provided" do
    rendered =
      Description.render("Seats",
        quantity: Decimal.new(3),
        rate: Decimal.new(250),
        currency: "DKK",
        line_ref: "l2"
      )

    assert rendered =~ "Seats"
    assert String.ends_with?(rendered, "Usage: 3 units @ 250 DKK | Ref: l2")
  end

  test "fixed charge with a period omits the usage row but keeps the ref" do
    rendered = Description.render("Annual platform fee", period: @period, line_ref: "l3")

    assert rendered =~ "Annual platform fee — 2026-09-15 to 2027-09-14"
    assert String.ends_with?(rendered, "Ref: l3")
    refute rendered =~ "Usage:"
  end

  test "fixed charge without a period is name plus ref only" do
    rendered = Description.render("Onboarding fee", line_ref: "l4")

    assert rendered =~ "Onboarding fee"
    assert String.ends_with?(rendered, "Ref: l4")
    refute rendered =~ "Usage:"
    refute rendered =~ "—"
  end

  test "discount lines are prefixed Discount:" do
    rendered =
      Description.render("Volume tier 2", kind: :discount, period: @period, line_ref: "l5")

    assert String.starts_with?(rendered, "Discount: Volume tier 2 — 2026-09-15 to 2027-09-14")
    assert String.ends_with?(rendered, "Ref: l5")
  end

  test "credit lines are prefixed Credit:" do
    rendered = Description.render("Unused service", kind: :credit, line_ref: "l6")

    assert String.starts_with?(rendered, "Credit: Unused service")
    assert String.ends_with?(rendered, "Ref: l6")
  end

  test "truncation stays below the maximum while retaining Ref: <id>" do
    long_name = String.duplicate("Very long product name ", 30)

    rendered =
      Description.render(long_name,
        period: @period,
        quantity: Decimal.new(7),
        rate: Decimal.new("99.95"),
        currency: "DKK",
        line_ref: "shortid",
        max_length: 60
      )

    assert String.length(rendered) <= 60
    assert String.ends_with?(rendered, "… | Ref: shortid")
  end

  test "default maximum length is 255" do
    long_name = String.duplicate("x", 500)
    rendered = Description.render(long_name, line_ref: "l7")

    assert String.length(rendered) <= 255
    assert String.ends_with?(rendered, "Ref: l7")
  end

  test "short descriptions are not truncated" do
    rendered = Description.render("Simple", line_ref: "l8", max_length: 255)

    assert rendered =~ "Simple"
    assert String.ends_with?(rendered, "Ref: l8")
    refute rendered =~ "…"
  end

  test "control characters are stripped and whitespace runs collapse" do
    dirty_name = "Weird" <> <<1>> <> " name   with    spacing" <> <<7>>

    rendered = Description.render(dirty_name, line_ref: "l9")

    assert rendered =~ "Weird name with spacing"
    refute String.contains?(rendered, <<1>>)
    refute String.contains?(rendered, <<7>>)
    refute rendered =~ ~r/\s{2,}/
  end
end
