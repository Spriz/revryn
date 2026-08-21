defmodule BillingCore.Pricing.Discounts.Result do
  @moduledoc """
  Result of `BillingCore.Pricing.Discounts.apply_discounts/2`:

    * `discount_lines` — materialized negative lines (SPEC §10.8) in
      application order, grouped per discount;
    * `line_totals` — `{line_id, net Money}` per eligible line in input
      order, after all discounts;
    * `gross_total` / `net_total` — eligible base before and after
      discounts; the net total is never negative (SPEC §10.7 step 5);
    * `trace` — canonical-JSON-safe application trace with per-discount
      bases, amounts, clamping, and allocations.
  """

  alias BillingCore.Domain.Money
  alias BillingCore.Pricing.DiscountLine

  @enforce_keys [:discount_lines, :line_totals, :gross_total, :net_total, :trace]
  defstruct [:discount_lines, :line_totals, :gross_total, :net_total, :trace]

  @type t :: %__MODULE__{
          discount_lines: [DiscountLine.t()],
          line_totals: [{String.t(), Money.t()}],
          gross_total: Money.t(),
          net_total: Money.t(),
          trace: map()
        }
end
