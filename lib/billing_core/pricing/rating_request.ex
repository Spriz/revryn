defmodule BillingCore.Pricing.RatingRequest do
  @moduledoc """
  Input to `BillingCore.Pricing.Engine.rate/1` (SPEC §10).

    * `pricing` — one of the pricing model structs (SPEC §9.6);
    * `currency` — ISO 4217 code; the minor-unit scale comes from
      `BillingCore.Domain.Money.exponent/1` (SPEC §9.3);
    * `quantity` — subscription quantity or aggregated usage quantity as a
      `Decimal` (never a float, INV-006);
    * `full_period` — the full billing period (half-open, SPEC §9.2), or
      `nil` for charges without a service period;
    * `active_period` — the active service sub-period; defaults to
      `full_period` and must be covered by it. Only fixed recurring charges
      prorate (SPEC §10.1) — other models carry the periods as line metadata
      only.
  """

  alias BillingCore.Domain.Period
  alias BillingCore.Pricing.Model

  @enforce_keys [:pricing, :currency, :quantity]
  defstruct [:pricing, :currency, :quantity, :full_period, :active_period]

  @type t :: %__MODULE__{
          pricing: Model.t(),
          currency: String.t(),
          quantity: Decimal.t(),
          full_period: Period.t() | nil,
          active_period: Period.t() | nil
        }
end
