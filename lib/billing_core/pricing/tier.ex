defmodule BillingCore.Pricing.Tier do
  @moduledoc """
  One tier of a volume or graduated tier schema (SPEC §10.3–§10.4).

  Boundaries are decimal quantities with explicit inclusive/exclusive
  semantics: `from` is inclusive, `to` is exclusive, so a tier covers
  `from <= Q < to`; `to: nil` marks the final unbounded tier (`Q >= from`).

  ## Normative boundary rule (SPEC §23.2, volume boundary rows)

  For volume tier selection, a quantity exactly on a boundary `B` selects the
  tier whose `from == B` (the upper tier): tier bounds are half-open on the
  upper side, mirroring the domain's half-open date periods (SPEC §9.2).
  `B - ε` selects the lower tier and `B + ε` the upper tier.

  `flat_fee_minor` is an optional non-negative flat fee in **minor units of
  the rating request currency**, applied when the tier applies (volume: the
  selected tier; graduated: tiers with `quantity_i > 0`, SPEC §10.4).
  """

  alias BillingCore.Pricing.Schema
  alias Decimal, as: D

  @enforce_keys [:from, :unit_rate]
  defstruct [:from, :to, :unit_rate, flat_fee_minor: 0]

  @type t :: %__MODULE__{
          from: D.t(),
          to: D.t() | nil,
          unit_rate: D.t(),
          flat_fee_minor: non_neg_integer()
        }

  @doc """
  Whether the tier contains quantity `q`: `from <= q < to`, with `to: nil`
  meaning unbounded. A quantity exactly on a boundary belongs to the tier
  whose `from` equals it (see the moduledoc boundary rule).
  """
  @spec contains?(t(), D.t()) :: boolean()
  def contains?(%__MODULE__{} = tier, %D{} = q) do
    D.compare(q, tier.from) != :lt and (is_nil(tier.to) or D.compare(q, tier.to) == :lt)
  end

  @doc "Parses one tier map; `\"to\"` is omitted (or nil) for the unbounded tier."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(%{} = map) do
    to_result =
      case Map.get(map, "to") do
        nil -> {:ok, nil}
        _present -> Schema.fetch_non_neg_decimal(map, "to")
      end

    case Schema.collect([
           Schema.fetch_non_neg_decimal(map, "from"),
           to_result,
           Schema.fetch_non_neg_decimal(map, "unit_rate"),
           Schema.fetch_non_neg_int(map, "flat_fee_minor", 0)
         ]) do
      {:ok, [from, to, unit_rate, flat_fee_minor]} ->
        {:ok,
         %__MODULE__{from: from, to: to, unit_rate: unit_rate, flat_fee_minor: flat_fee_minor}}

      {:error, _reasons} = error ->
        error
    end
  end

  def from_map(_other), do: {:error, [:invalid_tier]}

  @doc "Parses a list of tier maps, tagging failures with the tier index."
  @spec parse_list(term()) :: {:ok, [t()]} | {:error, [Schema.reason()]}
  def parse_list(tiers) when is_list(tiers) do
    tiers
    |> Enum.with_index()
    |> Enum.map(fn {tier_map, index} ->
      case from_map(tier_map) do
        {:ok, tier} -> {:ok, tier}
        {:error, reasons} -> {:error, {:tier, index, reasons}}
      end
    end)
    |> Schema.collect()
  end

  def parse_list(_other), do: {:error, [:invalid_tiers]}

  @doc "Versioned-map representation; the unbounded tier omits `\"to\"`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tier) do
    base = %{
      "from" => Schema.decimal_string(tier.from),
      "unit_rate" => Schema.decimal_string(tier.unit_rate),
      "flat_fee_minor" => tier.flat_fee_minor
    }

    if tier.to, do: Map.put(base, "to", Schema.decimal_string(tier.to)), else: base
  end

  @doc """
  Validates a tier schema (SPEC §10.4): tiers are contiguous from 0 with no
  gaps or overlaps, every tier except the last is bounded with `from < to`,
  the last tier is unbounded (`to: nil`), and rates/flat fees are
  non-negative. All failures are accumulated.
  """
  @spec validate_tiers(term()) :: :ok | {:error, [Schema.reason()]}
  def validate_tiers([]), do: {:error, [:empty_tiers]}

  def validate_tiers([_ | _] = tiers) do
    if Enum.all?(tiers, &valid_shape?/1) do
      count = length(tiers)

      field_errors =
        tiers
        |> Enum.with_index()
        |> Enum.flat_map(&field_errors(&1, count))

      contiguity_errors =
        tiers
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {[lower, upper], index} ->
          if is_nil(lower.to) or D.eq?(lower.to, upper.from),
            do: [],
            else: [{:not_contiguous, index}]
        end)

      case field_errors ++ contiguity_errors do
        [] -> :ok
        errors -> {:error, errors}
      end
    else
      {:error, [:invalid_tier]}
    end
  end

  def validate_tiers(_other), do: {:error, [:invalid_tiers]}

  defp valid_shape?(%__MODULE__{from: %D{}, unit_rate: %D{}, to: to, flat_fee_minor: fee}),
    do: (is_nil(to) or is_struct(to, D)) and is_integer(fee)

  defp valid_shape?(_other), do: false

  defp field_errors({tier, index}, count) do
    last? = index == count - 1

    List.flatten([
      negative_unit_rate_errors(tier, index),
      negative_flat_fee_errors(tier, index),
      first_tier_start_errors(tier, index),
      last_tier_bound_errors(tier, last?),
      unbounded_before_last_errors(tier, index, last?),
      empty_tier_errors(tier, index)
    ])
  end

  defp negative_unit_rate_errors(tier, index) do
    if D.compare(tier.unit_rate, D.new(0)) == :lt, do: [{:negative_unit_rate, index}], else: []
  end

  defp negative_flat_fee_errors(tier, index) do
    if tier.flat_fee_minor < 0, do: [{:negative_flat_fee, index}], else: []
  end

  defp first_tier_start_errors(tier, index) do
    if index == 0 and not D.eq?(tier.from, D.new(0)), do: [:tiers_must_start_at_zero], else: []
  end

  defp last_tier_bound_errors(tier, last?) do
    if last? and not is_nil(tier.to), do: [:last_tier_must_be_unbounded], else: []
  end

  defp unbounded_before_last_errors(tier, index, last?) do
    if not last? and is_nil(tier.to), do: [{:unbounded_tier_before_last, index}], else: []
  end

  defp empty_tier_errors(tier, index) do
    if not is_nil(tier.to) and D.compare(tier.from, tier.to) != :lt,
      do: [{:empty_tier, index}],
      else: []
  end
end
