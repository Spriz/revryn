defmodule BillingCore.Repo.Migrations.CreateErpTables do
  use Ecto.Migration

  @moduledoc """
  ERP connections, external documents, durable sync operations, webhook
  receipts, and approval records (SPEC §13.3).

  Deviation from the §13.3 provider check: `'fake'` is allowed in addition to
  `'economic'` so release E2E and Playwright suites can run against the
  stateful fake ERP (SPEC §23.5/23.6) with the complete persistence path.
  """

  def up do
    create table(:erp_connections, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid, prefix: "billing"), null: false
      add :provider, :text, null: false
      add :external_agreement_id, :text
      add :secret_reference, :text, null: false
      add :status, :text, null: false, default: "unvalidated"
      add :capabilities, :map, null: false, default: %{}
      add :capabilities_hash, :text
      add :preflight_result, :map
      add :last_validated_at, :utc_datetime_usec
      add :webhook_token_hash, :text
      add :version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:erp_connections, [:team_id, :provider], prefix: "billing")

    create constraint(:erp_connections, :erp_connections_provider_check,
             prefix: "billing",
             check: "provider in ('economic','fake')"
           )

    create constraint(:erp_connections, :erp_connections_status_check,
             prefix: "billing",
             check: "status in ('unvalidated','active','action_required','disabled')"
           )

    create table(:erp_documents, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :erp_connection_id, references(:erp_connections, type: :uuid, prefix: "billing"),
        null: false

      add :invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing"),
        null: false

      add :document_type, :text, null: false
      add :state, :text, null: false, default: "pending"
      add :external_draft_number, :text
      add :external_booked_number, :text
      add :external_reference, :text, null: false
      add :last_external_snapshot, :map
      add :last_external_hash, :text
      add :last_reconciled_at, :utc_datetime_usec
      add :version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:erp_documents, [:team_id, :erp_connection_id, :external_reference],
             prefix: "billing"
           )

    # Must permit multiple NULLs (SPEC §13.3): partial unique index.
    create unique_index(:erp_documents, [:team_id, :erp_connection_id, :external_booked_number],
             prefix: "billing",
             where: "external_booked_number is not null",
             name: :erp_documents_booked_number_uq
           )

    create constraint(:erp_documents, :erp_documents_type_check,
             prefix: "billing",
             check: "document_type in ('invoice','credit_note')"
           )

    create constraint(:erp_documents, :erp_documents_state_check,
             prefix: "billing",
             check:
               "state in ('pending','syncing','draft','booked','reconciliation_failed','missing')"
           )

    create index(:erp_documents, [:invoice_intent_id], prefix: "billing")

    create table(:sync_operations, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :erp_document_id, references(:erp_documents, type: :uuid, prefix: "billing"),
        null: false

      add :operation_id, references(:operations, type: :uuid, prefix: "billing"), null: false
      add :operation_type, :text, null: false
      add :operation_key, :text, null: false
      add :idempotency_key, :text, null: false
      add :request_hash, :text, null: false
      add :request_metadata, :map, null: false, default: %{}
      add :response_metadata, :map
      add :state, :text, null: false, default: "queued"
      add :attempt_count, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec
      add :last_error, :map
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :completed_at, :utc_datetime_usec
    end

    create unique_index(:sync_operations, [:team_id, :operation_key], prefix: "billing")
    create unique_index(:sync_operations, [:team_id, :idempotency_key], prefix: "billing")
    create index(:sync_operations, [:erp_document_id], prefix: "billing")

    create table(:webhook_receipts, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :team_id, :uuid, null: false
      add :erp_connection_id, :uuid, null: false
      add :provider_event_id, :text
      add :received_at, :utc_datetime_usec, null: false
      add :headers_redacted, :map, null: false, default: %{}
      add :payload_redacted, :map, null: false, default: %{}
      add :payload_hash, :text, null: false
      add :processing_state, :text, null: false, default: "received"
    end

    create unique_index(:webhook_receipts, [:erp_connection_id, :provider_event_id],
             prefix: "billing",
             where: "provider_event_id is not null",
             name: :webhook_receipts_connection_event_id_uq
           )

    create table(:approval_records, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing"),
        null: false

      add :action, :text, null: false
      add :actor_type, :text, null: false
      add :actor_id, :text
      add :reason, :text
      add :intent_hash, :text, null: false
      add :erp_draft_hash, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:approval_records, :approval_records_action_check,
             prefix: "billing",
             check: "action in ('approved','revoked')"
           )

    create index(:approval_records, [:invoice_intent_id, :occurred_at], prefix: "billing")

    execute """
    CREATE TRIGGER approval_records_append_only
      BEFORE UPDATE OR DELETE ON billing.approval_records
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS approval_records_append_only ON billing.approval_records"
    drop table(:approval_records, prefix: "billing")
    drop table(:webhook_receipts, prefix: "billing")
    drop table(:sync_operations, prefix: "billing")
    drop table(:erp_documents, prefix: "billing")
    drop table(:erp_connections, prefix: "billing")
  end
end
