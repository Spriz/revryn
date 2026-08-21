defmodule BillingCore.Pricing.EligibleLine do
  @moduledoc """
  A charge line eligible for discounts (SPEC §10.7):

    * `id` — stable, non-empty string; it is the allocation tie-break order
      for largest-remainder residuals (SPEC §9.3, §10.9);
    * `amount` — the line's current pre-discount `Money`, non-negative;
    * `service_period` / `recognition_mode` — metadata that materialized
      discount lines inherit (SPEC §9.4, §10.8).
  """

  alias BillingCore.Domain.{Money, Period}

  @enforce_keys [:id, :amount]
  defstruct [:id, :amount, :service_period, :recognition_mode]

  @type recognition_mode :: :point_in_time | :over_time | String.t() | nil

  @type t :: %__MODULE__{
          id: String.t(),
          amount: Money.t(),
          service_period: Period.t() | nil,
          recognition_mode: recognition_mode()
        }
end
