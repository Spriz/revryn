defmodule BillingCore.Domain.Money do
  @moduledoc """
  Money as integer minor units plus an ISO 4217 currency code.

  Invariants (SPEC INV-006, §9.3):

    * currency amounts are signed integer minor units — binary floating point
      is prohibited anywhere in the domain;
    * intermediate quantities and rates are `Decimal`s;
    * rounding to currency precision happens only at documented boundaries and
      uses half-away-from-zero;
    * allocation residuals use largest remainder with a stable tie-breaker.
  """

  alias Decimal, as: D

  @enforce_keys [:currency, :minor_units]
  defstruct [:currency, :minor_units]

  @type currency :: String.t()
  @type t :: %__MODULE__{currency: currency(), minor_units: integer()}

  # Minor-unit exponents for currencies whose scale differs from the default 2.
  # The domain does not assume two decimals globally (SPEC §9.3).
  @zero_decimal ~w(BIF CLP DJF GNF ISK JPY KMF KRW PYG RWF UGX VND VUV XAF XOF XPF)
  @three_decimal ~w(BHD IQD JOD KWD LYD OMR TND)

  @currency_format ~r/^[A-Z]{3}$/

  @spec valid_currency?(String.t()) :: boolean()
  def valid_currency?(code) when is_binary(code), do: Regex.match?(@currency_format, code)
  def valid_currency?(_), do: false

  @doc "Minor-unit exponent for a currency (2 for DKK/EUR, 0 for JPY, 3 for BHD…)."
  @spec exponent(currency()) :: non_neg_integer()
  def exponent(code) when code in @zero_decimal, do: 0
  def exponent(code) when code in @three_decimal, do: 3
  def exponent(_code), do: 2

  @spec new!(currency(), integer()) :: t()
  def new!(currency, minor_units) when is_integer(minor_units) do
    unless valid_currency?(currency) do
      raise ArgumentError, "invalid ISO 4217 currency code: #{inspect(currency)}"
    end

    %__MODULE__{currency: currency, minor_units: minor_units}
  end

  @spec zero(currency()) :: t()
  def zero(currency), do: new!(currency, 0)

  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{minor_units: mu}), do: mu == 0

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{minor_units: mu}), do: mu < 0

  @spec add!(t(), t()) :: t()
  def add!(%__MODULE__{currency: c, minor_units: a}, %__MODULE__{currency: c, minor_units: b}) do
    %__MODULE__{currency: c, minor_units: a + b}
  end

  def add!(%__MODULE__{currency: c1}, %__MODULE__{currency: c2}) do
    raise ArgumentError, "cannot add money in different currencies: #{c1} and #{c2}"
  end

  @spec subtract!(t(), t()) :: t()
  def subtract!(%__MODULE__{} = a, %__MODULE__{} = b), do: add!(a, negate(b))

  @spec negate(t()) :: t()
  def negate(%__MODULE__{} = m), do: %{m | minor_units: -m.minor_units}

  @spec sum!([t()], currency()) :: t()
  def sum!(monies, currency) when is_list(monies) do
    Enum.reduce(monies, zero(currency), &add!(&2, &1))
  end

  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{currency: c, minor_units: a}, %__MODULE__{currency: c, minor_units: b}) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @doc """
  Rounds a major-unit `Decimal` amount to a `Money` at the currency's minor-unit
  scale using half-away-from-zero. This is the single documented boundary where
  currency rounding occurs (SPEC §9.3, INV-012 requires the caller to record the
  rounding delta from the trace).
  """
  @spec round_major(D.t(), currency()) :: t()
  def round_major(%D{} = major, currency) do
    exp = exponent(currency)

    minor =
      major
      |> D.mult(pow10(exp))
      |> D.round(0, :half_up)
      |> D.to_integer()

    new!(currency, minor)
  end

  @doc """
  Rounding delta in minor units introduced by `round_major/2`, as a `Decimal`:
  `rounded_minor - exact_minor`. Recorded in calculation traces (INV-012).
  """
  @spec rounding_delta_minor(D.t(), currency()) :: D.t()
  def rounding_delta_minor(%D{} = major, currency) do
    exp = exponent(currency)
    exact_minor = D.mult(major, pow10(exp))
    rounded = round_major(major, currency)
    D.sub(D.new(rounded.minor_units), exact_minor)
  end

  @doc "Major-unit decimal representation, e.g. `Money{DKK, 12345}` → `123.45`."
  @spec to_major_decimal(t()) :: D.t()
  def to_major_decimal(%__MODULE__{currency: c, minor_units: mu}) do
    exp = exponent(c)
    D.div(D.new(mu), pow10(exp))
  end

  @doc """
  Allocates `money` across weights using largest remainder with stable index
  order as the tie-breaker (SPEC §9.3, §10.9). Weights are `{id, Decimal}`
  pairs; ties in remainder are broken by ascending `id` term order, so callers
  must pass stable identifiers (e.g. line IDs). Returns `{id, Money}` pairs in
  the input order. The allocations always sum exactly to the input amount.

  Raises when the weights are empty or sum to zero.
  """
  @spec allocate!(t(), [{term(), D.t()}]) :: [{term(), t()}]
  def allocate!(%__MODULE__{} = money, weights) when is_list(weights) and weights != [] do
    total_weight = weights |> Enum.map(&elem(&1, 1)) |> Enum.reduce(D.new(0), &D.add/2)

    if D.eq?(total_weight, D.new(0)) do
      raise ArgumentError, "cannot allocate money across weights summing to zero"
    end

    amount = D.new(money.minor_units)

    exact_shares =
      Enum.map(weights, fn {id, w} ->
        {id, amount |> D.mult(w) |> D.div(total_weight)}
      end)

    # Floor toward negative infinity so remainders are always in [0, 1).
    floored =
      Enum.map(exact_shares, fn {id, exact} ->
        floor_int = decimal_floor_int(exact)
        {id, floor_int, D.sub(exact, D.new(floor_int))}
      end)

    floor_sum = floored |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    residual = money.minor_units - floor_sum

    ranked =
      floored
      |> Enum.with_index()
      |> Enum.sort_by(fn {{id, _floor, rem}, _idx} -> {D.negate(rem), id} end)

    bumped_indices =
      ranked
      |> Enum.take(residual)
      |> Enum.map(fn {_entry, idx} -> idx end)
      |> MapSet.new()

    floored
    |> Enum.with_index()
    |> Enum.map(fn {{id, floor_int, _rem}, idx} ->
      bump = if MapSet.member?(bumped_indices, idx), do: 1, else: 0
      {id, new!(money.currency, floor_int + bump)}
    end)
  end

  defp decimal_floor_int(%D{} = d) do
    truncated = D.round(d, 0, :down)

    floored =
      if D.eq?(truncated, d) or not D.negative?(d) do
        truncated
      else
        D.sub(truncated, D.new(1))
      end

    D.to_integer(floored)
  end

  defp pow10(0), do: D.new(1)
  defp pow10(n) when n > 0, do: D.new(Integer.pow(10, n))
end
