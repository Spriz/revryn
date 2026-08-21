defmodule BillingCore.Pricing.Schema do
  @moduledoc """
  Shared parsing and validation helpers for versioned pricing model
  definitions (SPEC §9.6).

  A pricing model definition is pure data: a JSON-safe map with string keys,
  `"schema_version" => 1`, a `"type"` discriminator, and decimal values as
  canonical decimal strings (`BillingCore.Domain.Canonical.decimal_string/1`).
  Floats are rejected everywhere (SPEC INV-006).
  """

  alias BillingCore.Domain.Canonical
  alias Decimal, as: D

  @schema_version 1

  @typedoc "Validation failure reason accumulated by `from_map/1` parsers."
  @type reason :: atom() | tuple()

  @doc "Current pricing model schema version (SPEC §9.6)."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Checks the `"schema_version"` and `"type"` header of a definition map,
  accumulating all header failures.
  """
  @spec check_header(term(), String.t()) :: :ok | {:error, [reason()]}
  def check_header(%{} = map, expected_type) do
    version_errors =
      case map do
        %{"schema_version" => @schema_version} -> []
        %{"schema_version" => other} -> [{:unsupported_schema_version, other}]
        _ -> [:missing_schema_version]
      end

    type_errors =
      case map do
        %{"type" => ^expected_type} -> []
        %{"type" => other} -> [{:unexpected_type, other}]
        _ -> [:missing_type]
      end

    case version_errors ++ type_errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def check_header(_other, _expected_type), do: {:error, [:invalid_definition]}

  @doc "Header for `to_map/1` output: schema version plus type discriminator."
  @spec header(String.t()) :: map()
  def header(type), do: %{"schema_version" => @schema_version, "type" => type}

  @doc """
  Fetches a `Decimal` field given as a canonical decimal string, an integer,
  or a `Decimal`. Floats are rejected (INV-006). The result is normalized so
  `from_map/1` → `to_map/1` round-trips are structurally exact.
  """
  @spec fetch_decimal(map(), String.t()) :: {:ok, D.t()} | {:error, reason()}
  def fetch_decimal(map, key) do
    case Map.fetch(map, key) do
      {:ok, %D{coef: coef} = value} when is_integer(coef) -> {:ok, D.normalize(value)}
      {:ok, value} when is_binary(value) -> parse_decimal(value, key)
      {:ok, value} when is_integer(value) -> {:ok, D.new(value)}
      {:ok, _other} -> {:error, {:invalid_decimal, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @doc "Like `fetch_decimal/2` but the value must not be negative (rates may be zero)."
  @spec fetch_non_neg_decimal(map(), String.t()) :: {:ok, D.t()} | {:error, reason()}
  def fetch_non_neg_decimal(map, key) do
    with {:ok, value} <- fetch_decimal(map, key) do
      if D.compare(value, D.new(0)) == :lt, do: {:error, {:negative, key}}, else: {:ok, value}
    end
  end

  @doc "Fetches a non-negative integer field, with an optional default when absent."
  @spec fetch_non_neg_int(map(), String.t(), term()) :: {:ok, term()} | {:error, reason()}
  def fetch_non_neg_int(map, key, default \\ :__required__) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_integer, key}}
      :error when default == :__required__ -> {:error, {:missing_field, key}}
      :error -> {:ok, default}
    end
  end

  @doc """
  Collects field results: all `{:ok, value}` → `{:ok, values}` in order;
  otherwise `{:error, reasons}` with every failure retained (nested reason
  lists are flattened).
  """
  @spec collect([{:ok, term()} | {:error, reason() | [reason()]}]) ::
          {:ok, [term()]} | {:error, [reason()]}
  def collect(results) do
    case for {:error, reason} <- results, do: reason do
      [] -> {:ok, for({:ok, value} <- results, do: value)}
      errors -> {:error, List.flatten(errors)}
    end
  end

  @doc "Canonical decimal string (delegates to `BillingCore.Domain.Canonical`)."
  @spec decimal_string(D.t()) :: String.t()
  defdelegate decimal_string(decimal), to: Canonical

  defp parse_decimal(value, key) do
    case D.parse(value) do
      {%D{coef: coef} = decimal, ""} when is_integer(coef) -> {:ok, D.normalize(decimal)}
      _ -> {:error, {:invalid_decimal, key}}
    end
  end
end
