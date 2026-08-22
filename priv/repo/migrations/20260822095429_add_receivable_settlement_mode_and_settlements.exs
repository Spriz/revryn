defmodule BillingCore.Repo.Migrations.AddReceivableSettlementModeAndSettlements do
  use Ecto.Migration

  @moduledoc """
  Receivable-settlement mode and customer-credit settlement records
  (SPEC §9.4.1, BC-US-108).

  The close posting-policy version — the accountant-approved, versioned
  accounting policy — now declares which system owns open receivables.
  Automatic credit application is blocked until a mode is certified.
  Each credit application produces exactly one settlement record that must
  reconcile exactly once, distinct from the subledger, the invoice, and
  the monthly liability close.
  """

  def up do
    # ERP documents gain the settlement-voucher shape: intent-linked like an
    # invoice, voucher-carrying like a close posting.
    drop constraint(:erp_documents, :erp_documents_type_check, prefix: "billing")
    drop constraint(:erp_documents, :erp_documents_source_check, prefix: "billing")

    create constraint(:erp_documents, :erp_documents_type_check,
             prefix: "billing",
             check:
               "document_type in ('invoice','credit_note','finance_voucher','settlement_voucher')"
           )

    create constraint(:erp_documents, :erp_documents_source_check,
             prefix: "billing",
             check:
               "(document_type in ('invoice','credit_note','settlement_voucher') and invoice_intent_id is not null and customer_credit_close_id is null) or " <>
                 "(document_type = 'finance_voucher' and invoice_intent_id is null and customer_credit_close_id is not null)"
           )

    alter table(:customer_credit_close_policy_versions, prefix: "billing") do
      add :settlement_mode, :text, null: false, default: "none"
      add :settlement_clearing_account_number, :integer
      add :settlement_contra_account_number, :integer
    end

    create constraint(
             :customer_credit_close_policy_versions,
             :credit_close_policy_settlement_mode_check,
             prefix: "billing",
             check: "settlement_mode in ('none','erp_customer_settlement','external_reference')"
           )

    create constraint(
             :customer_credit_close_policy_versions,
             :credit_close_policy_settlement_accounts_check,
             prefix: "billing",
             check: """
             settlement_mode <> 'erp_customer_settlement'
             OR (settlement_clearing_account_number IS NOT NULL
                 AND settlement_contra_account_number IS NOT NULL)
             """
           )

    create table(:customer_credit_settlements, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid, prefix: "billing"), null: false

      add :invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing"),
        null: false

      add :credit_account_id,
          references(:customer_credit_accounts, type: :uuid, prefix: "billing"), null: false

      add :policy_version_id,
          references(:customer_credit_close_policy_versions, type: :uuid, prefix: "billing"),
          null: false

      add :currency, :text, null: false
      add :amount_minor, :bigint, null: false
      add :mode, :text, null: false
      add :state, :text, null: false, default: "pending"
      add :external_reference, :text
      add :operation_id, :uuid
      add :external_voucher_number, :text
      add :reconciled_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:customer_credit_settlements, [:invoice_intent_id],
             prefix: "billing",
             name: :customer_credit_settlements_intent_uq
           )

    create index(:customer_credit_settlements, [:team_id, :state], prefix: "billing")
    create index(:customer_credit_settlements, [:credit_account_id], prefix: "billing")

    create constraint(
             :customer_credit_settlements,
             :customer_credit_settlements_amount_check,
             prefix: "billing",
             check: "amount_minor > 0"
           )

    create constraint(
             :customer_credit_settlements,
             :customer_credit_settlements_mode_check,
             prefix: "billing",
             check: "mode in ('erp_customer_settlement','external_reference')"
           )

    create constraint(
             :customer_credit_settlements,
             :customer_credit_settlements_state_check,
             prefix: "billing",
             check: "state in ('pending','reconciled')"
           )

    execute """
    CREATE OR REPLACE FUNCTION billing.customer_credit_settlements_guard()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'customer credit settlements are immutable accounting records';
      END IF;

      IF NEW.team_id IS DISTINCT FROM OLD.team_id
         OR NEW.invoice_intent_id IS DISTINCT FROM OLD.invoice_intent_id
         OR NEW.credit_account_id IS DISTINCT FROM OLD.credit_account_id
         OR NEW.policy_version_id IS DISTINCT FROM OLD.policy_version_id
         OR NEW.currency IS DISTINCT FROM OLD.currency
         OR NEW.amount_minor IS DISTINCT FROM OLD.amount_minor
         OR NEW.mode IS DISTINCT FROM OLD.mode
         OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'customer credit settlement identity fields are immutable';
      END IF;

      IF OLD.state = 'reconciled' AND NEW.state IS DISTINCT FROM OLD.state THEN
        RAISE EXCEPTION 'a reconciled customer credit settlement is terminal';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER customer_credit_settlements_guard
    BEFORE UPDATE OR DELETE ON billing.customer_credit_settlements
    FOR EACH ROW EXECUTE FUNCTION billing.customer_credit_settlements_guard()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS customer_credit_settlements_guard ON billing.customer_credit_settlements"

    execute "DROP FUNCTION IF EXISTS billing.customer_credit_settlements_guard()"

    drop table(:customer_credit_settlements, prefix: "billing")

    drop constraint(
           :customer_credit_close_policy_versions,
           :credit_close_policy_settlement_accounts_check,
           prefix: "billing"
         )

    drop constraint(
           :customer_credit_close_policy_versions,
           :credit_close_policy_settlement_mode_check,
           prefix: "billing"
         )

    alter table(:customer_credit_close_policy_versions, prefix: "billing") do
      remove :settlement_mode
      remove :settlement_clearing_account_number
      remove :settlement_contra_account_number
    end

    drop constraint(:erp_documents, :erp_documents_type_check, prefix: "billing")
    drop constraint(:erp_documents, :erp_documents_source_check, prefix: "billing")

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
  end
end
