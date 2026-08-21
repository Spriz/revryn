defmodule BillingCore.Repo.Migrations.CreatePriceComponents do
  use Ecto.Migration

  @moduledoc """
  Price components of a plan version (SPEC §13.3 `price_components`,
  BC-US-013/015…021). The serialized `pricing_definition` is validated
  against the versioned pricing model schema
  (`BillingCore.Pricing.Model`) before persistence.

  Rows share the mutability of their plan version: the context only mutates
  components of draft plan versions, and published versions cannot be
  deleted, so cascade deletion only ever removes draft components.
  """

  def change do
    create table(:price_components, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :plan_version_id, references(:plan_versions, type: :uuid, on_delete: :delete_all),
        null: false

      add :code, :text, null: false
      add :product_id, references(:products, type: :uuid), null: false
      add :product_version, :bigint, null: false
      add :pricing_model, :text, null: false
      add :pricing_definition, :map, null: false, default: %{}
      add :recognition_mode, :text, null: false
      add :service_period_source, :text
      add :proration_policy, :text, null: false, default: "prorate"
      add :rendering_policy, :text, null: false, default: "summarized"
      add :metric_code, :text
      add :aggregation, :text
      add :ordinal, :integer, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:price_components, :price_components_pricing_model_check,
             check:
               "pricing_model in ('fixed_recurring', 'one_time', 'standard_metered', " <>
                 "'volume_tier', 'graduated_tier', 'package', 'minimum_commit')",
             prefix: "billing"
           )

    create constraint(:price_components, :price_components_recognition_mode_check,
             check: "recognition_mode in ('point_in_time', 'over_time')",
             prefix: "billing"
           )

    create constraint(:price_components, :price_components_service_period_source_check,
             check:
               "service_period_source is null or " <>
                 "service_period_source in ('billing_period', 'subscription_period', 'explicit')",
             prefix: "billing"
           )

    # INV: over_time recognition always names its service-period derivation
    # rule (BC-US-011, SPEC §9.4).
    create constraint(:price_components, :price_components_over_time_requires_period_source,
             check: "recognition_mode <> 'over_time' or service_period_source is not null",
             prefix: "billing"
           )

    create constraint(:price_components, :price_components_proration_policy_check,
             check: "proration_policy in ('prorate', 'full_period')",
             prefix: "billing"
           )

    create constraint(:price_components, :price_components_rendering_policy_check,
             check: "rendering_policy in ('per_tier', 'summarized')",
             prefix: "billing"
           )

    # INV: usage-based models always name the metric they rate (BC-US-017).
    create constraint(:price_components, :price_components_usage_requires_metric,
             check:
               "pricing_model not in ('standard_metered', 'volume_tier', " <>
                 "'graduated_tier', 'package') or metric_code is not null",
             prefix: "billing"
           )

    create constraint(:price_components, :price_components_aggregation_check,
             check:
               "aggregation is null or aggregation in ('sum', 'count', 'max', 'unique_count')",
             prefix: "billing"
           )

    create unique_index(:price_components, [:team_id, :plan_version_id, :code], prefix: "billing")
    create index(:price_components, [:product_id], prefix: "billing")
  end
end
