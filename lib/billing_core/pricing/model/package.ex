defmodule BillingCore.Pricing.Model.Package do
  @moduledoc """
  Package pricing (SPEC §10.5): quantity is sold in whole packages:

      packages         = ceil(Q / package_size)
      unrounded_amount = packages × package_price

  `package_size` is a strictly positive `Decimal` quantity; `package_price`
  is a non-negative `Decimal` in major currency units. The ceiling is exact
  integer arithmetic — no floats, no decimal division (SPEC INV-006).
  """

  alias BillingCore.Pricing.Schema
  alias Decimal, as: D

  @type_name "package"

  @enforce_keys [:package_size, :package_price]
  defstruct [:package_size, :package_price]

  @type t :: %__MODULE__{package_size: D.t(), package_price: D.t()}

  @doc "Type discriminator used in versioned definition maps."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc "Parses and validates a versioned definition map (SPEC §9.6)."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(map) do
    with :ok <- Schema.check_header(map, @type_name),
         {:ok, [size, price]} <-
           Schema.collect([
             Schema.fetch_decimal(map, "package_size"),
             Schema.fetch_decimal(map, "package_price")
           ]) do
      validate(%__MODULE__{package_size: size, package_price: price})
    end
  end

  @doc """
  Validates value rules: `package_size` must be strictly positive,
  `package_price` may be zero but not negative.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def validate(%__MODULE__{package_size: %D{} = size, package_price: %D{} = price} = model) do
    errors =
      List.flatten([
        if(D.compare(size, D.new(0)) == :gt, do: [], else: [{:not_positive, "package_size"}]),
        if(D.compare(price, D.new(0)) == :lt, do: [{:negative, "package_price"}], else: [])
      ])

    case errors do
      [] -> {:ok, model}
      _ -> {:error, errors}
    end
  end

  def validate(%__MODULE__{}), do: {:error, [:invalid_package_definition]}

  @doc "Versioned JSON-safe definition map (`schema_version: 1`, SPEC §9.6)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model) do
    Schema.header(@type_name)
    |> Map.put("package_size", Schema.decimal_string(model.package_size))
    |> Map.put("package_price", Schema.decimal_string(model.package_price))
  end
end
