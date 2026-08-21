defmodule BillingCore.Pricing.Model.MinimumCommit do
  @moduledoc """
  Minimum commit (SPEC §10.6), modeled as a wrapper around another pricing
  model:

      rated_amount           = normal_price(Q)      # the inner model
      final_before_discounts = max(rated_amount, minimum_amount)
      minimum_uplift         = final_before_discounts - rated_amount

  `minimum_amount_minor` is a non-negative integer amount in minor units of
  the rating request currency. The inner model may be any pricing model
  except another minimum commit. The engine exposes `minimum_uplift` and the
  inner rating trace in the charge trace.
  """

  alias BillingCore.Pricing.{Model, Schema}

  @type_name "minimum_commit"

  @enforce_keys [:minimum_amount_minor, :inner]
  defstruct [:minimum_amount_minor, :inner]

  @type t :: %__MODULE__{minimum_amount_minor: non_neg_integer(), inner: Model.t()}

  @doc "Type discriminator used in versioned definition maps."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc "Parses and validates a versioned definition map (SPEC §9.6)."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(map) do
    with :ok <- Schema.check_header(map, @type_name),
         {:ok, [minimum, inner]} <-
           Schema.collect([
             Schema.fetch_non_neg_int(map, "minimum_amount_minor"),
             parse_inner(map)
           ]) do
      validate(%__MODULE__{minimum_amount_minor: minimum, inner: inner})
    end
  end

  @doc """
  Validates value rules: the minimum amount is a non-negative integer and the
  inner model is a valid non-minimum-commit pricing model.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def validate(%__MODULE__{minimum_amount_minor: minimum, inner: inner} = model) do
    cond do
      not (is_integer(minimum) and minimum >= 0) ->
        {:error, [{:invalid_integer, "minimum_amount_minor"}]}

      is_struct(inner, __MODULE__) ->
        {:error, [:nested_minimum_commit]}

      true ->
        case Model.validate(inner) do
          {:ok, _inner} -> {:ok, model}
          {:error, reasons} -> {:error, [{:inner, reasons}]}
        end
    end
  end

  @doc "Versioned JSON-safe definition map (`schema_version: 1`, SPEC §9.6)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model) do
    Schema.header(@type_name)
    |> Map.put("minimum_amount_minor", model.minimum_amount_minor)
    |> Map.put("inner", Model.to_map(model.inner))
  end

  defp parse_inner(map) do
    case Map.fetch(map, "inner") do
      {:ok, %{"type" => @type_name}} ->
        {:error, :nested_minimum_commit}

      {:ok, inner_map} ->
        case Model.from_map(inner_map) do
          {:ok, inner} -> {:ok, inner}
          {:error, reasons} -> {:error, {:inner, reasons}}
        end

      :error ->
        {:error, {:missing_field, "inner"}}
    end
  end
end
