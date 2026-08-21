defmodule BillingCore.Pricing.Model.StandardMetered do
  @moduledoc """
  Standard metered charge (SPEC §10.2): `aggregated_quantity × unit_rate`.

  `unit_rate` is a non-negative `Decimal` per-unit price in major currency
  units. The aggregated quantity comes from the rating request and may be
  negative for usage corrections; rounding stays symmetric (SPEC §23.2,
  negative amount rounding).
  """

  alias BillingCore.Pricing.Schema
  alias Decimal, as: D

  @type_name "standard_metered"

  @enforce_keys [:unit_rate]
  defstruct [:unit_rate]

  @type t :: %__MODULE__{unit_rate: D.t()}

  @doc "Type discriminator used in versioned definition maps."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc "Parses and validates a versioned definition map (SPEC §9.6)."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(map) do
    with :ok <- Schema.check_header(map, @type_name),
         {:ok, [unit_rate]} <- Schema.collect([Schema.fetch_decimal(map, "unit_rate")]) do
      validate(%__MODULE__{unit_rate: unit_rate})
    end
  end

  @doc "Validates value rules: the unit rate may be zero but not negative."
  @spec validate(t()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def validate(%__MODULE__{unit_rate: %D{} = rate} = model) do
    if D.compare(rate, D.new(0)) == :lt do
      {:error, [{:negative, "unit_rate"}]}
    else
      {:ok, model}
    end
  end

  def validate(%__MODULE__{}), do: {:error, [{:invalid_decimal, "unit_rate"}]}

  @doc "Versioned JSON-safe definition map (`schema_version: 1`, SPEC §9.6)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model) do
    Map.put(Schema.header(@type_name), "unit_rate", Schema.decimal_string(model.unit_rate))
  end
end
