defmodule BillingCore.Repo.Migrations.CreateBillingRunsAndCharges do
  use Ecto.Migration

  @moduledoc """
  Billing runs and immutable rated charges (SPEC §13.3, §18).
  """

  def up do
    create table(:billing_runs, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid, prefix: "billing"), null: false
      add :run_key, :text, null: false
      add :invoice_date, :date, null: false
      add :usage_cutoff, :utc_datetime_usec, null: false
      add :settings_version, :bigint, null: false
      add :engine_version, :text, null: false
      add :status, :text, null: false, default: "open"
      add :started_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:billing_runs, [:team_id, :run_key], prefix: "billing")

    create constraint(:billing_runs, :billing_runs_status_check,
             prefix: "billing",
             check: "status in ('open','calculating','calculated','closed','aborted')"
           )

    create table(:charges, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :billing_run_id, references(:billing_runs, type: :uuid, prefix: "billing"), null: false
      add :subscription_id, references(:subscriptions, type: :uuid, prefix: "billing")
      add :charge_instance_id, references(:charge_instances, type: :uuid, prefix: "billing")
      # Catalog references are plain UUIDs; FKs are added by a follow-up
      # migration once the catalog range exists on every environment.
      add :price_component_id, :uuid
      add :component_code, :text, null: false
      add :product_id, :uuid, null: false
      add :product_version, :bigint, null: false
      add :charge_kind, :text, null: false
      add :occurrence_key, :text, null: false
      add :status, :text, null: false, default: "active"
      add :currency, :string, size: 3, null: false
      add :amount_minor, :bigint, null: false
      add :unrounded, :text, null: false
      add :quantity, :decimal, precision: 38, scale: 18, null: false
      add :recognition_mode, :text, null: false
      add :service_start, :date
      add :service_end_exclusive, :date
      add :calculation_trace, :map, null: false
      add :source_hashes, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:charges, :charges_kind_check,
             prefix: "billing",
             check:
               "charge_kind in ('recurring','usage','one_time','adjustment_credit','adjustment_charge')"
           )

    create constraint(:charges, :charges_status_check,
             prefix: "billing",
             check: "status in ('active','superseded','credited')"
           )

    create constraint(:charges, :charges_recognition_check,
             prefix: "billing",
             check: """
             (recognition_mode = 'point_in_time' and service_start is null and service_end_exclusive is null)
             or
             (recognition_mode = 'over_time' and service_start is not null and service_end_exclusive is not null and service_start < service_end_exclusive)
             """
           )

    # SPEC §18.4 — at most one ACTIVE charge per billable occurrence.
    create unique_index(:charges, [:team_id, :occurrence_key],
             prefix: "billing",
             where: "status = 'active'",
             name: :charges_active_occurrence_uq
           )

    create index(:charges, [:billing_run_id], prefix: "billing")
    create index(:charges, [:team_id, :subscription_id], prefix: "billing")

    # Charges are immutable calculation results; only lifecycle status (and
    # updated_at) may change (SPEC §13.1 restricted non-financial columns).
    execute """
    CREATE OR REPLACE FUNCTION billing.charges_status_only_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(NEW.id, NEW.team_id, NEW.billing_run_id, NEW.subscription_id, NEW.charge_instance_id,
             NEW.price_component_id, NEW.component_code, NEW.product_id, NEW.product_version,
             NEW.charge_kind, NEW.occurrence_key, NEW.currency, NEW.amount_minor, NEW.unrounded,
             NEW.quantity, NEW.recognition_mode, NEW.service_start, NEW.service_end_exclusive,
             NEW.calculation_trace, NEW.source_hashes, NEW.created_at)
         IS DISTINCT FROM
         ROW(OLD.id, OLD.team_id, OLD.billing_run_id, OLD.subscription_id, OLD.charge_instance_id,
             OLD.price_component_id, OLD.component_code, OLD.product_id, OLD.product_version,
             OLD.charge_kind, OLD.occurrence_key, OLD.currency, OLD.amount_minor, OLD.unrounded,
             OLD.quantity, OLD.recognition_mode, OLD.service_start, OLD.service_end_exclusive,
             OLD.calculation_trace, OLD.source_hashes, OLD.created_at) THEN
        RAISE EXCEPTION 'charges are immutable except lifecycle status';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER charges_status_only
      BEFORE UPDATE ON billing.charges
      FOR EACH ROW EXECUTE FUNCTION billing.charges_status_only_update();
    """

    execute "CREATE TRIGGER charges_no_delete BEFORE DELETE ON billing.charges FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS charges_no_delete ON billing.charges"
    execute "DROP TRIGGER IF EXISTS charges_status_only ON billing.charges"
    drop table(:charges, prefix: "billing")
    execute "DROP FUNCTION IF EXISTS billing.charges_status_only_update()"
    drop table(:billing_runs, prefix: "billing")
  end
end
