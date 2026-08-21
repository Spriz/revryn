defmodule BillingCore.Repo.Migrations.CreateCustomerErpMappings do
  use Ecto.Migration

  @moduledoc """
  Mapping of billing customers to ERP-side customer numbers
  (SPEC §13.3 `customer_erp_mappings`, BC-US-031/032).
  """

  def change do
    create table(:customer_erp_mappings, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :customer_id, references(:customers, type: :uuid), null: false

      # NOTE: plain uuid on purpose — billing.erp_connections belongs to a later
      # (ERP) migration range; the foreign key is added once that table exists.
      add :erp_connection_id, :uuid, null: false

      add :external_customer_number, :text, null: false
      add :validation_status, :text, null: false
      add :external_snapshot, :map
      add :external_snapshot_hash, :text
      add :validated_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:customer_erp_mappings, [:team_id, :erp_connection_id, :customer_id],
             prefix: "billing"
           )

    create unique_index(
             :customer_erp_mappings,
             [:team_id, :erp_connection_id, :external_customer_number],
             prefix: "billing"
           )
  end
end
