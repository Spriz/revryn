defmodule BillingCore.Catalog.PriceComponent do
  @moduledoc """
  One price component of a plan version (SPEC §13.3 `price_components`,
  BC-US-013/015…021).

  `pricing_definition` is the canonical `schema_version: 1` map produced by
  `BillingCore.Pricing.Model.to_map/1`; `pricing_model` is the model's type
  discriminator. Both are set programmatically by the catalog context after
  the definition has been validated with `BillingCore.Pricing.Model.from_map/1`.
  The component pins `product_id` + `product_version` and snapshots its
  recognition policy.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.{PlanVersion, Product}

  @type t :: %__MODULE__{}

  @usage_models ~w(standard_metered volume_tier graduated_tier package)

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "price_components" do
    field :team_id, Ecto.UUID
    field :code, :string
    field :product_version, :integer
    field :pricing_model, :string
    field :pricing_definition, :map, default: %{}
    field :recognition_mode, Ecto.Enum, values: [:point_in_time, :over_time]

    field :service_period_source, Ecto.Enum,
      values: [:billing_period, :subscription_period, :explicit]

    field :proration_policy, Ecto.Enum, values: [:prorate, :full_period], default: :prorate
    field :rendering_policy, Ecto.Enum, values: [:per_tier, :summarized], default: :summarized
    field :metric_code, :string
    field :aggregation, Ecto.Enum, values: [:sum, :count, :max, :unique_count]
    field :ordinal, :integer

    belongs_to :plan_version, PlanVersion
    belongs_to :product, Product

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Pricing models that rate measured usage and therefore need a metric."
  @spec usage_models() :: [String.t()]
  def usage_models, do: @usage_models

  @doc """
  Changeset for context-normalized attrs: `:pricing_model` and
  `:pricing_definition` are never raw user input — the catalog context sets
  them from a definition already validated with
  `BillingCore.Pricing.Model.from_map/1`.
  """
  def changeset(component, attrs) do
    component
    |> cast(attrs, [
      :code,
      :product_id,
      :product_version,
      :pricing_model,
      :pricing_definition,
      :recognition_mode,
      :service_period_source,
      :proration_policy,
      :rendering_policy,
      :metric_code,
      :aggregation,
      :ordinal
    ])
    |> validate_required([
      :code,
      :product_id,
      :product_version,
      :pricing_model,
      :pricing_definition,
      :recognition_mode,
      :proration_policy,
      :rendering_policy,
      :ordinal
    ])
    |> validate_length(:code, max: 100)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_.-]*$/,
      message: "must be lowercase alphanumeric with `_`, `.`, `-`"
    )
    |> validate_number(:product_version, greater_than: 0)
    |> validate_recognition()
    |> validate_usage_metric()
    |> unique_constraint([:team_id, :plan_version_id, :code],
      error_key: :code,
      message: "code already used by another component of this plan version"
    )
  end

  # INV: `over_time` requires a service-period derivation rule (BC-US-011,
  # SPEC §9.4) — mirrored by the database CHECK constraint.
  defp validate_recognition(changeset) do
    case get_field(changeset, :recognition_mode) do
      :over_time ->
        validate_required(changeset, [:service_period_source],
          message: "is required for over_time recognition"
        )

      _mode ->
        changeset
    end
  end

  # INV: usage-based models always name the metric they rate (BC-US-017) —
  # mirrored by the database CHECK constraint.
  defp validate_usage_metric(changeset) do
    if get_field(changeset, :pricing_model) in @usage_models do
      validate_required(changeset, [:metric_code, :aggregation],
        message: "is required for usage-based pricing models"
      )
    else
      changeset
    end
  end
end
