defmodule BillingCore.Repo.Migrations.CreateInvoiceChainsAndIntents do
  use Ecto.Migration

  @moduledoc """
  Invoice chains, immutable invoice intents and lines, and the mutable
  lifecycle projection with append-only transition evidence
  (SPEC §13.3, §11.2, INV-013).
  """

  def up do
    create table(:invoice_chains, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :current_intent_id, :uuid
      add :status, :text, null: false, default: "active"
      add :version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:invoice_chains, :invoice_chains_status_check,
             prefix: "billing",
             check: "status in ('active','abandoned','booked','corrected')"
           )

    create table(:invoice_intents, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :invoice_chain_id, references(:invoice_chains, type: :uuid, prefix: "billing"),
        null: false

      add :billing_run_id, references(:billing_runs, type: :uuid, prefix: "billing")
      add :customer_id, references(:customers, type: :uuid, prefix: "billing"), null: false
      add :customer_version, :bigint, null: false
      add :contract_id, references(:contracts, type: :uuid, prefix: "billing")
      add :currency, :string, size: 3, null: false
      add :invoice_date, :date, null: false
      add :intent_version, :integer, null: false
      add :supersedes_invoice_intent_id, :uuid
      add :document_kind, :text, null: false, default: "invoice"
      add :canonical_snapshot, :map, null: false
      add :content_hash, :text, null: false
      add :net_amount_minor, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :frozen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:invoice_intents, [:team_id, :invoice_chain_id, :intent_version],
             prefix: "billing"
           )

    create constraint(:invoice_intents, :invoice_intents_version_check,
             prefix: "billing",
             check: "intent_version > 0"
           )

    create constraint(:invoice_intents, :invoice_intents_kind_check,
             prefix: "billing",
             check: "document_kind in ('invoice','credit_note')"
           )

    create index(:invoice_intents, [:customer_id], prefix: "billing")
    create index(:invoice_intents, [:billing_run_id], prefix: "billing")

    execute """
    CREATE TRIGGER invoice_intents_append_only
      BEFORE UPDATE OR DELETE ON billing.invoice_intents
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """

    # The chain's current pointer must reference an intent of its own chain
    # (deferred so the chain and first intent can commit together).
    execute """
    ALTER TABLE billing.invoice_chains
      ADD CONSTRAINT invoice_chains_current_intent_fk
      FOREIGN KEY (current_intent_id) REFERENCES billing.invoice_intents(id)
      DEFERRABLE INITIALLY DEFERRED;
    """

    execute """
    CREATE OR REPLACE FUNCTION billing.invoice_chain_pointer_check() RETURNS trigger AS $$
    DECLARE
      intent_chain uuid;
      intent_team uuid;
    BEGIN
      IF NEW.current_intent_id IS NOT NULL THEN
        SELECT invoice_chain_id, team_id INTO intent_chain, intent_team
          FROM billing.invoice_intents WHERE id = NEW.current_intent_id;
        IF intent_chain IS DISTINCT FROM NEW.id OR intent_team IS DISTINCT FROM NEW.team_id THEN
          RAISE EXCEPTION 'invoice chain current_intent must belong to the same chain and team';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE CONSTRAINT TRIGGER invoice_chain_pointer_guard
      AFTER INSERT OR UPDATE ON billing.invoice_chains
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION billing.invoice_chain_pointer_check();
    """

    create table(:invoice_lines, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing"),
        null: false

      add :line_key, :text, null: false
      add :source_charge_id, references(:charges, type: :uuid, prefix: "billing")
      add :adjusts_line_id, :uuid
      add :product_id, :uuid, null: false
      add :product_version, :bigint, null: false
      add :description, :text, null: false
      add :quantity, :decimal, precision: 38, scale: 18, null: false
      add :display_unit, :text
      add :amount_minor, :bigint, null: false
      add :currency, :string, size: 3, null: false
      add :recognition_mode, :text, null: false
      add :service_start, :date
      add :service_end_exclusive, :date
      add :calculation_trace, :map, null: false
      add :ordinal, :integer, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:invoice_lines, [:team_id, :invoice_intent_id, :line_key],
             prefix: "billing"
           )

    create constraint(:invoice_lines, :invoice_lines_recognition_check,
             prefix: "billing",
             check: """
             (recognition_mode = 'point_in_time' and service_start is null and service_end_exclusive is null)
             or
             (recognition_mode = 'over_time' and service_start is not null and service_end_exclusive is not null and service_start < service_end_exclusive)
             """
           )

    execute """
    CREATE TRIGGER invoice_lines_append_only
      BEFORE UPDATE OR DELETE ON billing.invoice_lines
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """

    create table(:invoice_intent_lifecycle, primary_key: false, prefix: "billing") do
      add :invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing"),
        primary_key: true

      add :team_id, :uuid, null: false
      add :current_state, :text, null: false, default: "frozen"
      add :version, :bigint, null: false, default: 1
      add :latest_operation_id, :uuid
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:invoice_intent_lifecycle, :intent_lifecycle_state_check,
             prefix: "billing",
             check:
               "current_state in ('frozen','superseded','sync_pending','erp_draft','approved','booking_pending','erp_booked','sync_error','credit_required')"
           )

    create table(:invoice_intent_state_transitions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true

      add :invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing"),
        null: false

      add :from_state, :text, null: false
      add :to_state, :text, null: false
      add :event, :text, null: false
      add :actor_type, :text, null: false
      add :actor_id, :text
      add :reason, :text
      add :causation_id, :uuid
      add :occurred_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:invoice_intent_state_transitions, [:invoice_intent_id, :occurred_at],
             prefix: "billing"
           )

    execute """
    CREATE TRIGGER intent_transitions_append_only
      BEFORE UPDATE OR DELETE ON billing.invoice_intent_state_transitions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    drop table(:invoice_intent_state_transitions, prefix: "billing")
    drop table(:invoice_intent_lifecycle, prefix: "billing")
    execute "DROP TRIGGER IF EXISTS invoice_lines_append_only ON billing.invoice_lines"
    drop table(:invoice_lines, prefix: "billing")
    execute "DROP TRIGGER IF EXISTS invoice_chain_pointer_guard ON billing.invoice_chains"
    execute "DROP FUNCTION IF EXISTS billing.invoice_chain_pointer_check()"
    execute "ALTER TABLE billing.invoice_chains DROP CONSTRAINT invoice_chains_current_intent_fk"
    execute "DROP TRIGGER IF EXISTS invoice_intents_append_only ON billing.invoice_intents"
    drop table(:invoice_intents, prefix: "billing")
    drop table(:invoice_chains, prefix: "billing")
  end
end
