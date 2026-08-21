defmodule BillingCore.Pricing.Model do
  @moduledoc """
  Pricing model data types (SPEC §9.6) and their versioned definition maps.

  The seven models — `FixedRecurring`, `OneTime`, `StandardMetered`,
  `VolumeTier`, `GraduatedTier`, `Package`, `MinimumCommit` — are pure data:
  no floats anywhere (INV-006), rates and quantities are `Decimal` (unit
  prices in major currency units), and monetary amounts are integer minor
  units.

  `from_map/1` parses and validates a `schema_version: 1` string-keyed map
  with decimal values as canonical decimal strings; `to_map/1` is its
  inverse. Published schema changes require an engine migration and golden
  test cases (SPEC §9.6).
  """

  alias BillingCore.Pricing.Model.{
    FixedRecurring,
    GraduatedTier,
    MinimumCommit,
    OneTime,
    Package,
    StandardMetered,
    VolumeTier
  }

  alias BillingCore.Pricing.Schema

  @type t ::
          FixedRecurring.t()
          | OneTime.t()
          | StandardMetered.t()
          | VolumeTier.t()
          | GraduatedTier.t()
          | Package.t()
          | MinimumCommit.t()

  @modules_by_type %{
    "fixed_recurring" => FixedRecurring,
    "one_time" => OneTime,
    "standard_metered" => StandardMetered,
    "volume_tier" => VolumeTier,
    "graduated_tier" => GraduatedTier,
    "package" => Package,
    "minimum_commit" => MinimumCommit
  }

  @doc "Parses any versioned pricing model map by its `\"type\"` discriminator."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def from_map(%{"type" => type} = map) do
    case Map.fetch(@modules_by_type, type) do
      {:ok, module} -> module.from_map(map)
      :error -> {:error, [{:unknown_type, type}]}
    end
  end

  def from_map(%{} = _map), do: {:error, [:missing_type]}
  def from_map(_other), do: {:error, [:invalid_definition]}

  @doc "Versioned definition map for any pricing model struct."
  @spec to_map(t()) :: map()
  def to_map(%FixedRecurring{} = model), do: FixedRecurring.to_map(model)
  def to_map(%OneTime{} = model), do: OneTime.to_map(model)
  def to_map(%StandardMetered{} = model), do: StandardMetered.to_map(model)
  def to_map(%VolumeTier{} = model), do: VolumeTier.to_map(model)
  def to_map(%GraduatedTier{} = model), do: GraduatedTier.to_map(model)
  def to_map(%Package{} = model), do: Package.to_map(model)
  def to_map(%MinimumCommit{} = model), do: MinimumCommit.to_map(model)

  @doc "Validates any directly-constructed pricing model struct."
  @spec validate(term()) :: {:ok, t()} | {:error, [Schema.reason()]}
  def validate(%FixedRecurring{} = model), do: FixedRecurring.validate(model)
  def validate(%OneTime{} = model), do: OneTime.validate(model)
  def validate(%StandardMetered{} = model), do: StandardMetered.validate(model)
  def validate(%VolumeTier{} = model), do: VolumeTier.validate(model)
  def validate(%GraduatedTier{} = model), do: GraduatedTier.validate(model)
  def validate(%Package{} = model), do: Package.validate(model)
  def validate(%MinimumCommit{} = model), do: MinimumCommit.validate(model)
  def validate(other), do: {:error, [{:unknown_model, other}]}

  @doc "Type discriminator string for any pricing model struct."
  @spec type(t()) :: String.t()
  def type(%FixedRecurring{}), do: FixedRecurring.type()
  def type(%OneTime{}), do: OneTime.type()
  def type(%StandardMetered{}), do: StandardMetered.type()
  def type(%VolumeTier{}), do: VolumeTier.type()
  def type(%GraduatedTier{}), do: GraduatedTier.type()
  def type(%Package{}), do: Package.type()
  def type(%MinimumCommit{}), do: MinimumCommit.type()
end
