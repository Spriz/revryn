defmodule BillingCore.Repo.Migrations.CreateInfrastructureTables do
  use Ecto.Migration

  @moduledoc """
  Shared infrastructure: append-only audit log, transactional outbox, and
  idempotency records (SPEC §13.3, §15, INV-008).
  """

  def up do
    create table(:audit_log, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :organization_id, :uuid
      add :team_id, :uuid
      add :actor_type, :text, null: false
      add :actor_id, :text
      add :event_type, :text, null: false
      add :aggregate_type, :text
      add :aggregate_id, :uuid
      add :correlation_id, :uuid
      add :causation_id, :uuid
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:audit_log, [:team_id, :occurred_at], prefix: "billing")
    create index(:audit_log, [:aggregate_type, :aggregate_id], prefix: "billing")
    create index(:audit_log, [:correlation_id], prefix: "billing")

    # INV: audit evidence is append-only — reject UPDATE/DELETE at the database.
    execute """
    CREATE OR REPLACE FUNCTION billing.reject_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% on %.% is prohibited: table is append-only', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER audit_log_append_only
      BEFORE UPDATE OR DELETE ON billing.audit_log
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """

    create table(:outbox_events, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :event_type, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :team_id, :uuid
      add :aggregate_type, :text, null: false
      add :aggregate_id, :uuid, null: false
      add :aggregate_version, :bigint
      add :correlation_id, :uuid
      add :causation_id, :uuid
      add :payload, :map, null: false, default: %{}
      add :published_at, :utc_datetime_usec
      add :publish_attempts, :integer, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:outbox_events, [:published_at, :occurred_at],
             prefix: "billing",
             where: "published_at IS NULL",
             name: :outbox_events_unpublished_idx
           )

    create index(:outbox_events, [:aggregate_type, :aggregate_id], prefix: "billing")

    create table(:idempotency_records, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :command_family, :text, null: false
      add :original_principal_id, :text, null: false
      add :key, :text, null: false
      add :request_hash, :text, null: false
      add :response_status, :integer
      add :response_body, :map
      add :resource_reference, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:idempotency_records, [:team_id, :command_family, :key],
             prefix: "billing"
           )

    create index(:idempotency_records, [:expires_at], prefix: "billing")
  end

  def down do
    drop table(:idempotency_records, prefix: "billing")
    drop table(:outbox_events, prefix: "billing")
    execute "DROP TRIGGER IF EXISTS audit_log_append_only ON billing.audit_log"
    drop table(:audit_log, prefix: "billing")
    execute "DROP FUNCTION IF EXISTS billing.reject_mutation()"
  end
end
