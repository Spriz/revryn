defmodule BillingCore.Pricing.ChargeResult do
  @moduledoc """
  Result of rating one charge line (SPEC §10):

    * `amount` — the final rounded `Money`, produced by the single
      documented currency-rounding boundary (SPEC §9.3);
    * `unrounded` — the exact pre-rounding `Decimal` amount in major
      currency units;
    * `trace` — canonical-JSON-safe calculation trace (SPEC INV-012):
      model type, inputs, day counts, proration fraction, per-tier
      breakdown, unrounded amount, rounding delta, and final minor units.
  """

  alias BillingCore.Domain.Money

  @enforce_keys [:amount, :unrounded, :trace]
  defstruct [:amount, :unrounded, :trace]

  @type t :: %__MODULE__{amount: Money.t(), unrounded: Decimal.t(), trace: map()}
end
