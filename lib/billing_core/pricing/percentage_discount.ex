defmodule BillingCore.Pricing.PercentageDiscount do
  @moduledoc """
  Percentage discount definition (SPEC §10.7): `basis_points / 10000` of the
  current running eligible base (the post-prior-discount line amounts).

  All percentage discounts apply before any fixed discount, in ascending
  `priority` order with ties broken by `id` (stable ordering, SPEC §10.7).
  `basis_points` is an integer in `0..10000`; 10000 is a 100% discount and
  produces an exactly-zero net, never a negative one.
  """

  @enforce_keys [:id, :basis_points]
  defstruct [:id, :basis_points, priority: 0]

  @type t :: %__MODULE__{id: String.t(), basis_points: 0..10_000, priority: integer()}
end
