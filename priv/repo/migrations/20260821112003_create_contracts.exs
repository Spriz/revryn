defmodule BillingCore.Repo.Migrations.CreateContracts do
  use Ecto.Migration

  @moduledoc """
  Contracts (stable aggregate) plus immutable contract versions
  (SPEC §13.3 `contracts`/`contract_versions`, BC-US-033).
  """

  def up do
    create table(:contracts, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :customer_id, references(:customers, type: :uuid), null: false
      add :external_reference, :text, null: false
      add :status, :text, null: false, default: "active"
      add :currency, :"char(3)", null: false
      add :start_date, :date, null: false
      add :end_date_exclusive, :date
      add :current_version, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:contracts, :contracts_status_check,
             check: "status in ('draft', 'active', 'ended')",
             prefix: "billing"
           )

    create constraint(:contracts, :contracts_period_check,
             check: "end_date_exclusive is null or start_date < end_date_exclusive",
             prefix: "billing"
           )

    create unique_index(:contracts, [:team_id, :external_reference], prefix: "billing")
    create index(:contracts, [:customer_id], prefix: "billing")

    create table(:contract_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :contract_id, references(:contracts, type: :uuid), null: false
      add :version, :bigint, null: false
      add :customer_version, :bigint, null: false
      add :currency, :"char(3)", null: false
      add :effective_start, :date, null: false
      add :effective_end_exclusive, :date
      add :metadata, :map, null: false, default: %{}
      add :content_hash, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:contract_versions, [:team_id, :contract_id, :version], prefix: "billing")

    # INV: contract changes are append-only versions (BC-US-033).
    execute """
    CREATE TRIGGER contract_versions_append_only
      BEFORE UPDATE OR DELETE ON billing.contract_versions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS contract_versions_append_only ON billing.contract_versions"
    drop table(:contract_versions, prefix: "billing")
    drop table(:contracts, prefix: "billing")
  end
end
