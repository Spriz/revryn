defmodule BillingCore.Repo.Migrations.CreateCustomers do
  use Ecto.Migration

  @moduledoc """
  Billing customers plus immutable customer version snapshots
  (SPEC §13.3 `customers` / `customer_versions`, BC-US-030).
  """

  def up do
    create table(:customers, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :external_id, :text, null: false
      add :status, :text, null: false, default: "active"
      add :current_version, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customers, :customers_status_check,
             check: "status in ('active', 'archived')",
             prefix: "billing"
           )

    create unique_index(:customers, [:team_id, :external_id], prefix: "billing")

    create table(:customer_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :customer_id, references(:customers, type: :uuid), null: false
      add :version, :bigint, null: false
      add :legal_name, :text, null: false
      add :address_line, :text
      add :zip, :text
      add :city, :text
      add :country, :"char(2)", null: false
      add :email, :text, null: false
      add :vat_number, :text
      add :currency_preference, :"char(3)"
      add :snapshot, :map, null: false
      add :content_hash, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:customer_versions, [:team_id, :customer_id, :version], prefix: "billing")

    # INV: customer snapshots are immutable, append-only history.
    execute """
    CREATE TRIGGER customer_versions_append_only
      BEFORE UPDATE OR DELETE ON billing.customer_versions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS customer_versions_append_only ON billing.customer_versions"
    drop table(:customer_versions, prefix: "billing")
    drop table(:customers, prefix: "billing")
  end
end
