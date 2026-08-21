defmodule BillingCore.Pricing.DiscountLine do
  @moduledoc """
  A materialized negative discount line (SPEC §10.8): references the adjusted
  source line and inherits its service period and recognition mode so the
  caller can copy metadata onto the normalized invoice line.

  `allocation` is the negative `Money` adjustment applied to the source line;
  the allocations of one discount always sum exactly to the (possibly
  clamped) discount amount (SPEC §10.9, §23.3).
  """

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.Pricing.EligibleLine

  @enforce_keys [:discount_id, :source_line_id, :allocation]
  defstruct [
    :discount_id,
    :source_line_id,
    :allocation,
    :service_period,
    :recognition_mode,
    trace: %{}
  ]

  @type t :: %__MODULE__{
          discount_id: String.t(),
          source_line_id: String.t(),
          allocation: Money.t(),
          service_period: Period.t() | nil,
          recognition_mode: EligibleLine.recognition_mode(),
          trace: map()
        }
end
