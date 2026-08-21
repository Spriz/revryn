defmodule BillingCore.Domain.Canonical do
  @moduledoc """
  Deterministic canonical JSON encoding and SHA-256 content hashing
  (SPEC §12.2, §13.5).

  Rules:

    * object keys are sorted lexicographically (binary order);
    * `Decimal` values are normalized to a plain decimal string with no
      exponent notation and no trailing zeros (`1.500` → `"1.5"`, `1E+2` →
      `"100"`);
    * dates and datetimes serialize as ISO 8601 strings (datetimes in UTC);
    * `Money` serializes as `{"currency": ..., "minorUnits": ...}`;
    * atom keys/values serialize as strings;
    * arrays keep caller-supplied order — stable ordering is the caller's
      responsibility;
    * floats are rejected (INV-006).
  """

  alias BillingCore.Domain.{Money, Period}
  alias Decimal, as: D

  @doc "Canonical JSON encoding as iodata-flattened binary."
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> normalize() |> Jason.encode!()

  @doc "Lowercase hex SHA-256 of the canonical encoding."
  @spec hash(term()) :: String.t()
  def hash(term) do
    :sha256
    |> :crypto.hash(encode!(term))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Normalizes a term into a shape whose `Jason` encoding is canonical:
  maps become key-sorted ordered maps, decimals/dates/money become strings
  or plain maps.
  """
  @spec normalize(term()) :: term()
  def normalize(%D{} = d), do: decimal_string(d)
  def normalize(%Date{} = d), do: Date.to_iso8601(d)

  def normalize(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  def normalize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  def normalize(%Money{} = m) do
    Jason.OrderedObject.new(currency: m.currency, minorUnits: m.minor_units)
  end

  def normalize(%Period{} = p) do
    Jason.OrderedObject.new(
      endExclusive: Date.to_iso8601(p.end_date_exclusive),
      start: Date.to_iso8601(p.start_date)
    )
  end

  def normalize(%_{} = struct) do
    struct |> Map.from_struct() |> normalize()
  end

  def normalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {key_string(k), normalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  def normalize(value) when is_float(value),
    do:
      raise(
        ArgumentError,
        "floats are prohibited in canonical encoding (INV-006): #{inspect(value)}"
      )

  def normalize(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def normalize(value), do: value

  @doc """
  Canonical decimal string: no exponent, no trailing zeros, `-0` collapses to
  `"0"`.
  """
  @spec decimal_string(D.t()) :: String.t()
  def decimal_string(%D{} = d) do
    normalized = D.normalize(d)

    normalized =
      if D.eq?(normalized, D.new(0)), do: D.new(0), else: normalized

    D.to_string(normalized, :normal)
  end

  defp key_string(k) when is_binary(k), do: k
  defp key_string(k) when is_atom(k), do: Atom.to_string(k)

  defp key_string(k),
    do: raise(ArgumentError, "canonical map keys must be strings or atoms, got: #{inspect(k)}")
end
