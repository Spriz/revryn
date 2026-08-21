defmodule BillingCore.Repo.Migrations.CreateProductErpMappings do
  use Ecto.Migration

  @moduledoc """
  Product-to-ERP product number mappings (SPEC §13.3 `product_erp_mappings`,
  BC-US-012). The catalog persists the mapping with `validation_status`
  `pending`; provider validation is performed by the ERP context.

  `erp_connection_id` is intentionally a plain uuid without a foreign key:
  the `erp_connections` table is owned by a later migration range.
  """

  def change do
    create table(:product_erp_mappings, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :product_id, references(:products, type: :uuid), null: false
      add :erp_connection_id, :uuid, null: false
      add :external_product_number, :text, null: false
      add :validation_status, :text, null: false, default: "pending"
      add :external_snapshot, :map
      add :external_snapshot_hash, :text
      add :validated_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:product_erp_mappings, :product_erp_mappings_validation_status_check,
             check: "validation_status in ('pending', 'valid', 'invalid')",
             prefix: "billing"
           )

    create unique_index(:product_erp_mappings, [:team_id, :erp_connection_id, :product_id],
             prefix: "billing",
             name: :product_erp_mappings_connection_product_idx
           )

    # INV: billing cannot silently substitute another product — one external
    # product number maps to at most one product per connection (BC-US-012).
    create unique_index(
             :product_erp_mappings,
             [:team_id, :erp_connection_id, :external_product_number],
             prefix: "billing",
             name: :product_erp_mappings_connection_external_number_idx
           )
  end
end
