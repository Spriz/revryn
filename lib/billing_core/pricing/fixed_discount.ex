defmodule BillingCore.Pricing.FixedDiscount do
  @moduledoc """
  Fixed-amount discount definition (SPEC §10.7): a positive integer
  `amount_minor` in minor units of `currency`, allocated across eligible
  lines proportionally to their current post-discount amounts via
  `BillingCore.Domain.Money.allocate!/2` (largest remainder, stable line-id
  tie-break, SPEC §9.3, §10.9).

  Fixed discounts apply after all percentage discounts, in ascending
  `priority` order with ties broken by `id`. A fixed discount that would push
  the eligible base below zero is clamped to the remaining base
  (non-negative invoice floor, SPEC §10.7 step 5).
  """

  @enforce_keys [:id, :amount_minor, :currency]
  defstruct [:id, :amount_minor, :currency, priority: 0]

  @type t :: %__MODULE__{
          id: String.t(),
          amount_minor: pos_integer(),
          currency: String.t(),
          priority: integer()
        }
end
