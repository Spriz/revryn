defmodule BillingCore.Pricing.Model.FixedRecurring do
  @moduledoc """
  Fixed recurring charge (SPEC §10.1): `unit_price × quantity`, prorated by
  `active_days / period_days` for partial periods. Proration applies only to
  this model.

  `unit_price` is a non-negative `Decimal` in major currency units; credits
  are expressed by negating a rated result
  (`BillingCore.Pricing.Engine.negate/1`), never by negative rates.
  """

  alias BillingCore.Pricing.Schema
  alias Decimal, as: D

  @type_name "fixed_recurring"

  @enforce_keys [:unit_price]
  defstruct [:unit_price]

  @type t :: %__MODULE__{unit_price: D.t()}

  @doc "Type discriminator used in versioned definition maps."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc "Parses and validates a versioned definition map (SPEC §9.6)."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(map) do
    with :ok <- Schema.check_header(map, @type_name),
         {:ok, [unit_price]} <- Schema.collect([Schema.fetch_decimal(map, "unit_price")]) do
      validate(%__MODULE__{unit_price: unit_price})
    end
  end

  @doc "Validates value rules: the unit price may be zero but not negative."
  @spec validate(t()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def validate(%__MODULE__{unit_price: %D{} = price} = model) do
    if D.compare(price, D.new(0)) == :lt do
      {:error, [{:negative, "unit_price"}]}
    else
      {:ok, model}
    end
  end

  def validate(%__MODULE__{}), do: {:error, [{:invalid_decimal, "unit_price"}]}

  @doc "Versioned JSON-safe definition map (`schema_version: 1`, SPEC §9.6)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model) do
    Map.put(Schema.header(@type_name), "unit_price", Schema.decimal_string(model.unit_price))
  end
end
