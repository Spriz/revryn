defmodule BillingCore.Repo.Migrations.CreateProductVersions do
  use Ecto.Migration

  @moduledoc """
  Immutable product description and recognition policy snapshots
  (SPEC §13.3 `product_versions`, BC-US-011). Append-only at the database.
  """

  def up do
    create table(:product_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :product_id, references(:products, type: :uuid), null: false
      add :version, :bigint, null: false
      add :name, :text, null: false
      add :description, :text
      add :recognition_mode, :text, null: false
      add :service_period_source, :text
      add :approver_reference, :text
      add :approved_at, :utc_datetime_usec
      add :evidence_reference, :text
      add :snapshot, :map, null: false, default: %{}
      add :content_hash, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:product_versions, :product_versions_recognition_mode_check,
             check: "recognition_mode in ('point_in_time', 'over_time')",
             prefix: "billing"
           )

    create constraint(:product_versions, :product_versions_service_period_source_check,
             check:
               "service_period_source is null or " <>
                 "service_period_source in ('billing_period', 'subscription_period', 'explicit')",
             prefix: "billing"
           )

    # INV: over_time recognition always names its service-period derivation
    # rule (BC-US-011, SPEC §9.4).
    create constraint(:product_versions, :product_versions_over_time_requires_period_source,
             check: "recognition_mode <> 'over_time' or service_period_source is not null",
             prefix: "billing"
           )

    create unique_index(:product_versions, [:team_id, :product_id, :version], prefix: "billing")

    # INV: recognition policy history is append-only — changing policy creates
    # a new version, never rewrites one (BC-US-011).
    execute """
    CREATE TRIGGER product_versions_append_only
      BEFORE UPDATE OR DELETE ON billing.product_versions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS product_versions_append_only ON billing.product_versions"
    drop table(:product_versions, prefix: "billing")
  end
end
