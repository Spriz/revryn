defmodule BillingCore.Repo.Migrations.AddCreditCloseCorrectionKinds do
  @moduledoc """
  ADR-031: customer-credit close corrections are compensating close rows.

  Adds `close_kind` (regular | reversal | replacement) and turns the
  period-uniqueness index into a partial one — exactly one *active*
  regular/replacement close per team/currency/month, while reversal rows
  and superseded/reversed rows are exempt. The immutability trigger learns
  the new frozen column.
  """

  use Ecto.Migration

  def up do
    alter table(:customer_credit_closes, prefix: "billing") do
      add :close_kind, :text, null: false, default: "regular"
    end

    create constraint(:customer_credit_closes, :customer_credit_closes_kind_check,
             prefix: "billing",
             check: "close_kind in ('regular','reversal','replacement')"
           )

    create constraint(:customer_credit_closes, :customer_credit_closes_reversal_link_check,
             prefix: "billing",
             check: "close_kind = 'regular' or reversal_of_close_id is not null"
           )

    drop unique_index(
           :customer_credit_closes,
           [:team_id, :currency, :period_start, :period_end_exclusive],
           prefix: "billing"
         )

    execute """
    CREATE UNIQUE INDEX customer_credit_closes_active_period_uq
      ON billing.customer_credit_closes
      (team_id, currency, period_start, period_end_exclusive)
      WHERE state NOT IN ('superseded','reversed') AND close_kind <> 'reversal';
    """

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
          NEW.reversal_of_close_id IS DISTINCT FROM OLD.reversal_of_close_id OR
          NEW.close_kind IS DISTINCT FROM OLD.close_kind
        ) THEN
        RAISE EXCEPTION 'customer credit close financial snapshot is immutable after ready';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  def down do
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

    execute "DROP INDEX billing.customer_credit_closes_active_period_uq;"

    create unique_index(
             :customer_credit_closes,
             [:team_id, :currency, :period_start, :period_end_exclusive],
             prefix: "billing"
           )

    drop constraint(:customer_credit_closes, :customer_credit_closes_reversal_link_check,
           prefix: "billing"
         )

    drop constraint(:customer_credit_closes, :customer_credit_closes_kind_check,
           prefix: "billing"
         )

    alter table(:customer_credit_closes, prefix: "billing") do
      remove :close_kind
    end
  end
end
