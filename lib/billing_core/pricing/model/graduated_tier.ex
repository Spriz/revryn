defmodule BillingCore.Pricing.Model.GraduatedTier do
  @moduledoc """
  Graduated tier pricing (SPEC §10.4): each tier prices its own slice of the
  total quantity `Q`:

      quantity_i = max(0, min(Q, tier_i.to) - tier_i.from)
      amount_i   = quantity_i × tier_i.unit_rate + applicable_flat_fee_i

  The final amount is the sum of tier amounts; the flat fee of a tier applies
  only when `quantity_i > 0`. For the unbounded last tier `min(Q, to)` is
  simply `Q`. Tier boundaries use decimal quantities with explicit
  inclusive/exclusive semantics (`BillingCore.Pricing.Tier`); because tiers
  are contiguous from 0, the tier quantities always sum to `Q`
  (SPEC §23.3).
  """

  alias BillingCore.Pricing.{Schema, Tier}

  @type_name "graduated_tier"

  @enforce_keys [:tiers]
  defstruct [:tiers]

  @type t :: %__MODULE__{tiers: [Tier.t()]}

  @doc "Type discriminator used in versioned definition maps."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc "Parses and validates a versioned definition map (SPEC §9.6)."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(map) do
    with :ok <- Schema.check_header(map, @type_name),
         {:ok, tiers} <- fetch_tiers(map) do
      validate(%__MODULE__{tiers: tiers})
    end
  end

  @doc "Validates the tier schema via `BillingCore.Pricing.Tier.validate_tiers/1`."
  @spec validate(t()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def validate(%__MODULE__{tiers: tiers} = model) do
    case Tier.validate_tiers(tiers) do
      :ok -> {:ok, model}
      {:error, _reasons} = error -> error
    end
  end

  @doc "Versioned JSON-safe definition map (`schema_version: 1`, SPEC §9.6)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model) do
    Map.put(Schema.header(@type_name), "tiers", Enum.map(model.tiers, &Tier.to_map/1))
  end

  defp fetch_tiers(map) do
    case Map.fetch(map, "tiers") do
      {:ok, tiers} -> Tier.parse_list(tiers)
      :error -> {:error, [{:missing_field, "tiers"}]}
    end
  end
end
