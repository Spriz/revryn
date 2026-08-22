defmodule BillingCore.Repo.Migrations.CreateCustomerCreditCloses do
  use Ecto.Migration

  @moduledoc """
  Monthly customer-credit close persistence (SPEC §11.5, §13.3, §17.16).

  Close inputs and evidence are append-only. The close row remains mutable
  only for its explicitly persisted lifecycle; calculation fields are frozen
  by the application before approval/posting.
  """

  def up do
    alter table(:customer_credit_transactions, prefix: "billing") do
      add :accounting_effective_on, :date
    end

    execute """
    UPDATE billing.customer_credit_transactions
    SET accounting_effective_on = (occurred_at AT TIME ZONE 'UTC')::date
    WHERE accounting_effective_on IS NULL
    """

    alter table(:customer_credit_transactions, prefix: "billing") do
      modify :accounting_effective_on, :date, null: false
    end

    create index(
             :customer_credit_transactions,
             [:team_id, :currency, :accounting_effective_on, :occurred_at, :id],
             prefix: "billing",
             name: :customer_credit_transactions_close_cutoff_idx
           )

    create table(:customer_credit_close_policy_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :version, :integer, null: false
      add :effective_from, :date, null: false
      add :journal_number, :integer, null: false
      add :liability_account_number, :integer, null: false
      add :posting_mode, :text, null: false
      add :default_offset_account_number, :integer
      add :movement_account_map, :map, null: false, default: %{}
      add :post_zero_delta, :boolean, null: false, default: false
      add :vat_neutral, :boolean, null: false, default: true
      add :created_by, :uuid
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(
             :customer_credit_close_policy_versions,
             :credit_close_policy_posting_mode_check,
             prefix: "billing",
             check: "posting_mode in ('single_offset','movement_class')"
           )

    create constraint(
             :customer_credit_close_policy_versions,
             :credit_close_policy_vat_neutral_check,
             prefix: "billing",
             check: "vat_neutral"
           )

    create constraint(
             :customer_credit_close_policy_versions,
             :credit_close_policy_account_mapping_check,
             prefix: "billing",
             check:
               "(posting_mode = 'single_offset' and default_offset_account_number is not null) or " <>
                 "(posting_mode = 'movement_class' and movement_account_map <> '{}'::jsonb)"
           )

    create unique_index(:customer_credit_close_policy_versions, [:team_id, :version],
             prefix: "billing"
           )

    create table(:customer_credit_closes, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :currency, :"char(3)", null: false
      add :period_start, :date, null: false
      add :period_end_exclusive, :date, null: false
      add :transaction_cutoff, :utc_datetime_usec, null: false

      add :policy_version_id,
          references(:customer_credit_close_policy_versions, type: :uuid, prefix: "billing"),
          null: false

      add :state, :text, null: false, default: "open"
      add :opening_minor, :bigint, null: false
      add :closing_minor, :bigint, null: false
      add :net_change_minor, :bigint, null: false
      add :economic_liability_line_minor, :bigint, null: false
      add :ledger_transaction_count, :bigint, null: false
      add :ledger_snapshot_hash, :text, null: false
      add :report_sha256, :text
      add :report_storage_key, :text
      add :operation_id, :uuid
      add :erp_document_id, :uuid
      add :previous_close_id, references(:customer_credit_closes, type: :uuid, prefix: "billing")

      add :reversal_of_close_id,
          references(:customer_credit_closes, type: :uuid, prefix: "billing")

      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :closed_at, :utc_datetime_usec
    end

    create constraint(:customer_credit_closes, :customer_credit_closes_state_check,
             prefix: "billing",
             check:
               "state in ('open','calculating','ready','approved','posting','outcome_unknown','posted','reconciled','closed','failed','mismatch','superseded','reversal_pending','reversed')"
           )

    create constraint(:customer_credit_closes, :customer_credit_closes_period_check,
             prefix: "billing",
             check: "period_start < period_end_exclusive"
           )

    create constraint(:customer_credit_closes, :customer_credit_closes_opening_check,
             prefix: "billing",
             check: "opening_minor >= 0 and closing_minor >= 0 and ledger_transaction_count >= 0"
           )

    create constraint(:customer_credit_closes, :customer_credit_closes_net_change_check,
             prefix: "billing",
             check: "net_change_minor = closing_minor - opening_minor"
           )

    create constraint(:customer_credit_closes, :customer_credit_closes_liability_sign_check,
             prefix: "billing",
             check: "economic_liability_line_minor = opening_minor - closing_minor"
           )

    create unique_index(
             :customer_credit_closes,
             [:team_id, :currency, :period_start, :period_end_exclusive],
             prefix: "billing"
           )

    create index(:customer_credit_closes, [:team_id, :currency, :state], prefix: "billing")
    create index(:customer_credit_closes, [:previous_close_id], prefix: "billing")
    create index(:customer_credit_closes, [:reversal_of_close_id], prefix: "billing")

    create table(:customer_credit_close_movements, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :close_id, references(:customer_credit_closes, type: :uuid, prefix: "billing"),
        null: false

      add :movement_type, :text, null: false
      add :amount_minor, :bigint, null: false
      add :liability_effect_minor, :bigint, null: false
      add :transaction_count, :bigint, null: false
      add :contra_account_number, :integer
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customer_credit_close_movements, :credit_close_movements_type_check,
             prefix: "billing",
             check:
               "movement_type in ('grant','reserve','release','apply','refund','expire','positive_adjustment','negative_adjustment','prior_period_adjustment')"
           )

    create constraint(:customer_credit_close_movements, :credit_close_movements_amount_check,
             prefix: "billing",
             check: "amount_minor >= 0 and transaction_count >= 0"
           )

    # PostgreSQL considers NULL values distinct in ordinary unique indexes.
    # A missing contra account is meaningful here, so coalesce it only for the
    # uniqueness key; valid account numbers are positive in finance policy.
    execute """
    CREATE UNIQUE INDEX credit_close_movements_close_type_contra_uq
      ON billing.customer_credit_close_movements
      (close_id, movement_type, COALESCE(contra_account_number, -2147483648));
    """

    create table(:credit_close_transaction_memberships, primary_key: false, prefix: "billing") do
      add :close_id, references(:customer_credit_closes, type: :uuid, prefix: "billing"),
        primary_key: true

      add :transaction_id,
          references(:customer_credit_transactions, type: :uuid, prefix: "billing"),
          primary_key: true

      add :ledger_ordinal, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:credit_close_transaction_memberships, [:transaction_id],
             prefix: "billing"
           )

    create unique_index(:credit_close_transaction_memberships, [:close_id, :ledger_ordinal],
             prefix: "billing"
           )

    create table(:customer_credit_close_approvals, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :close_id, references(:customer_credit_closes, type: :uuid, prefix: "billing"),
        null: false

      add :action, :text, null: false
      add :actor_type, :text, null: false
      add :actor_id, :text
      add :reason, :text
      add :close_hash, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customer_credit_close_approvals, :credit_close_approvals_action_check,
             prefix: "billing",
             check: "action in ('approved','revoked','reversal_approved')"
           )

    create index(:customer_credit_close_approvals, [:close_id, :occurred_at], prefix: "billing")

    create table(:customer_credit_close_evidence, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :close_id, references(:customer_credit_closes, type: :uuid, prefix: "billing"),
        null: false

      add :evidence_type, :text, null: false
      add :storage_key, :text
      add :sha256, :text, null: false
      add :content_type, :text
      add :bytes, :binary
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customer_credit_close_evidence, :credit_close_evidence_type_check,
             prefix: "billing",
             check:
               "evidence_type in ('canonical_json','csv_detail','pdf_summary','manifest','erp_voucher','erp_attachment','reconciliation')"
           )

    create constraint(:customer_credit_close_evidence, :credit_close_evidence_report_bytes_check,
             prefix: "billing",
             check:
               "evidence_type not in ('canonical_json','csv_detail','pdf_summary','manifest') or bytes is not null"
           )

    create unique_index(:customer_credit_close_evidence, [:close_id, :evidence_type, :sha256],
             prefix: "billing"
           )

    create index(:customer_credit_close_evidence, [:team_id, :close_id], prefix: "billing")

    for table <- [
          :customer_credit_close_policy_versions,
          :customer_credit_close_movements,
          :credit_close_transaction_memberships,
          :customer_credit_close_approvals,
          :customer_credit_close_evidence
        ] do
      execute """
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON billing.#{table}
        FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
      """
    end

    execute """
    CREATE OR REPLACE FUNCTION billing.guard_customer_credit_close_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'customer credit closes are immutable accounting records';
      END IF;

      IF OLD.state IN ('ready','approved','posting','outcome_unknown','posted','reconciled','closed','mismatch','reversal_pending','reversed')
        AND (
          NEW.team_id IS DISTINCT FROM OLD.team_id OR
          NEW.currency IS DISTINCT FROM OLD.currency OR
          NEW.period_start IS DISTINCT FROM OLD.period_start OR
          NEW.period_end_exclusive IS DISTINCT FROM OLD.period_end_exclusive OR
          NEW.transaction_cutoff IS DISTINCT FROM OLD.transaction_cutoff OR
          NEW.policy_version_id IS DISTINCT FROM OLD.policy_version_id OR
          NEW.opening_minor IS DISTINCT FROM OLD.opening_minor OR
          NEW.closing_minor IS DISTINCT FROM OLD.closing_minor OR
          NEW.net_change_minor IS DISTINCT FROM OLD.net_change_minor OR
          NEW.economic_liability_line_minor IS DISTINCT FROM OLD.economic_liability_line_minor OR
          NEW.ledger_transaction_count IS DISTINCT FROM OLD.ledger_transaction_count OR
          NEW.ledger_snapshot_hash IS DISTINCT FROM OLD.ledger_snapshot_hash OR
          NEW.report_sha256 IS DISTINCT FROM OLD.report_sha256 OR
          NEW.report_storage_key IS DISTINCT FROM OLD.report_storage_key OR
          NEW.previous_close_id IS DISTINCT FROM OLD.previous_close_id OR
          NEW.reversal_of_close_id IS DISTINCT FROM OLD.reversal_of_close_id
        ) THEN
        RAISE EXCEPTION 'customer credit close financial snapshot is immutable after ready';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER customer_credit_closes_guard_frozen_snapshot
      BEFORE UPDATE OR DELETE ON billing.customer_credit_closes
      FOR EACH ROW EXECUTE FUNCTION billing.guard_customer_credit_close_mutation();
    """

    # A finance voucher originates from exactly one close, while invoice and
    # credit-note documents continue to originate from exactly one intent.
    drop constraint(:erp_documents, :erp_documents_type_check, prefix: "billing")

    alter table(:erp_documents, prefix: "billing") do
      modify :invoice_intent_id, :uuid, null: true

      add :customer_credit_close_id,
          references(:customer_credit_closes, type: :uuid, prefix: "billing")

      add :external_voucher_number, :text
      add :external_accounting_year, :text
    end

    create constraint(:erp_documents, :erp_documents_type_check,
             prefix: "billing",
             check: "document_type in ('invoice','credit_note','finance_voucher')"
           )

    create constraint(:erp_documents, :erp_documents_source_check,
             prefix: "billing",
             check:
               "(document_type in ('invoice','credit_note') and invoice_intent_id is not null and customer_credit_close_id is null) or " <>
                 "(document_type = 'finance_voucher' and invoice_intent_id is null and customer_credit_close_id is not null)"
           )

    drop constraint(:erp_documents, :erp_documents_state_check, prefix: "billing")

    create constraint(:erp_documents, :erp_documents_state_check,
             prefix: "billing",
             check:
               "state in ('pending','syncing','draft','booked','posted','reconciled','reconciliation_failed','missing')"
           )

    create index(:erp_documents, [:customer_credit_close_id], prefix: "billing")

    create unique_index(
             :erp_documents,
             [:team_id, :erp_connection_id, :external_accounting_year, :external_voucher_number],
             prefix: "billing",
             where:
               "external_accounting_year is not null and external_voucher_number is not null",
             name: :erp_documents_voucher_number_uq
           )

    execute """
    ALTER TABLE billing.customer_credit_closes
      ADD CONSTRAINT customer_credit_closes_erp_document_id_fkey
      FOREIGN KEY (erp_document_id) REFERENCES billing.erp_documents(id);
    """
  end

  def down do
    execute """
    ALTER TABLE billing.customer_credit_closes
      DROP CONSTRAINT IF EXISTS customer_credit_closes_erp_document_id_fkey;
    """

    drop index(
           :erp_documents,
           [:team_id, :erp_connection_id, :external_accounting_year, :external_voucher_number],
           prefix: "billing",
           name: :erp_documents_voucher_number_uq
         )

    drop index(:erp_documents, [:customer_credit_close_id], prefix: "billing")
    drop constraint(:erp_documents, :erp_documents_source_check, prefix: "billing")
    drop constraint(:erp_documents, :erp_documents_type_check, prefix: "billing")
    drop constraint(:erp_documents, :erp_documents_state_check, prefix: "billing")

    # Rollback cannot retain finance vouchers because the previous schema has
    # no source column for them. Remove execution rows before their documents.
    execute """
    DELETE FROM billing.sync_operations
    WHERE erp_document_id IN (
      SELECT id FROM billing.erp_documents WHERE document_type = 'finance_voucher'
    );
    """

    execute "DELETE FROM billing.erp_documents WHERE document_type = 'finance_voucher'"

    alter table(:erp_documents, prefix: "billing") do
      remove :external_accounting_year
      remove :external_voucher_number
      remove :customer_credit_close_id
      modify :invoice_intent_id, :uuid, null: false
    end

    create constraint(:erp_documents, :erp_documents_type_check,
             prefix: "billing",
             check: "document_type in ('invoice','credit_note')"
           )

    create constraint(:erp_documents, :erp_documents_state_check,
             prefix: "billing",
             check:
               "state in ('pending','syncing','draft','booked','reconciliation_failed','missing')"
           )

    execute "DROP TRIGGER IF EXISTS customer_credit_closes_guard_frozen_snapshot ON billing.customer_credit_closes"
    execute "DROP FUNCTION IF EXISTS billing.guard_customer_credit_close_mutation()"
    execute "DROP INDEX IF EXISTS billing.credit_close_movements_close_type_contra_uq"

    for table <- [
          :customer_credit_close_evidence,
          :customer_credit_close_approvals,
          :credit_close_transaction_memberships,
          :customer_credit_close_movements,
          :customer_credit_close_policy_versions
        ] do
      execute "DROP TRIGGER IF EXISTS #{table}_append_only ON billing.#{table}"
    end

    drop table(:customer_credit_close_evidence, prefix: "billing")
    drop table(:customer_credit_close_approvals, prefix: "billing")
    drop table(:credit_close_transaction_memberships, prefix: "billing")
    drop table(:customer_credit_close_movements, prefix: "billing")
    drop table(:customer_credit_closes, prefix: "billing")
    drop table(:customer_credit_close_policy_versions, prefix: "billing")

    drop index(
           :customer_credit_transactions,
           [:team_id, :currency, :accounting_effective_on, :occurred_at, :id],
           prefix: "billing",
           name: :customer_credit_transactions_close_cutoff_idx
         )

    alter table(:customer_credit_transactions, prefix: "billing") do
      remove :accounting_effective_on
    end
  end
end
