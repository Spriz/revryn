defmodule BillingCore.Repo.Migrations.CreatePlanVersions do
  use Ecto.Migration

  @moduledoc """
  Plan versions (SPEC §13.3 `plan_versions`, BC-US-013/014).

  Drafts are mutable and deletable. Published versions are immutable at the
  database: the only permitted UPDATE on a published row is the retirement
  transition (`status` `published` → `retired` with every other column
  unchanged), and only draft rows may be deleted.
  """

  def up do
    create table(:plan_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :plan_id, references(:plans, type: :uuid), null: false
      add :version, :bigint, null: false
      add :status, :text, null: false, default: "draft"
      add :currency, :"char(3)", null: false
      add :interval_unit, :text, null: false
      add :interval_count, :integer, null: false
      add :billing_timing, :text, null: false
      add :effective_from, :date
      add :definition, :map, null: false, default: %{}
      add :content_hash, :text
      add :published_at, :utc_datetime_usec
      add :published_by, :uuid
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:plan_versions, :plan_versions_status_check,
             check: "status in ('draft', 'published', 'retired')",
             prefix: "billing"
           )

    create constraint(:plan_versions, :plan_versions_interval_unit_check,
             check: "interval_unit in ('month', 'day')",
             prefix: "billing"
           )

    create constraint(:plan_versions, :plan_versions_interval_count_check,
             check: "interval_count > 0",
             prefix: "billing"
           )

    create constraint(:plan_versions, :plan_versions_billing_timing_check,
             check: "billing_timing in ('in_advance', 'in_arrears')",
             prefix: "billing"
           )

    create unique_index(:plan_versions, [:team_id, :plan_id, :version], prefix: "billing")

    # INV: published plan versions are immutable (BC-US-014). The single
    # allowed post-publication transition is retirement; drafts stay mutable.
    execute """
    CREATE OR REPLACE FUNCTION billing.protect_published_plan_version() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'draft' THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'DELETE on billing.plan_versions is prohibited: only drafts may be deleted';
      END IF;

      IF OLD.status = 'draft' THEN
        RETURN NEW;
      END IF;

      IF OLD.status = 'published' AND NEW.status = 'retired'
         AND to_jsonb(OLD) - 'status' - 'updated_at' = to_jsonb(NEW) - 'status' - 'updated_at' THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'UPDATE on billing.plan_versions is prohibited: published versions are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER plan_versions_protect_published
      BEFORE UPDATE OR DELETE ON billing.plan_versions
      FOR EACH ROW EXECUTE FUNCTION billing.protect_published_plan_version();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS plan_versions_protect_published ON billing.plan_versions"
    drop table(:plan_versions, prefix: "billing")
    execute "DROP FUNCTION IF EXISTS billing.protect_published_plan_version()"
  end
end
