defmodule BillingCore.Pricing.Model.VolumeTier do
  @moduledoc """
  Volume tier pricing (SPEC §10.3): the single tier containing the total
  quantity `Q` prices the whole quantity:

      unrounded_amount = Q × selected_tier.unit_rate + selected_tier.flat_fee

  Tier selection is half-open (`from <= Q < to`); a quantity exactly on a
  boundary selects the tier whose `from` equals it — see
  `BillingCore.Pricing.Tier` for the normative boundary rule. Tiers must be
  contiguous from 0 with an unbounded last tier, so every non-negative
  quantity selects exactly one tier.
  """

  alias BillingCore.Pricing.{Schema, Tier}

  @type_name "volume_tier"

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
