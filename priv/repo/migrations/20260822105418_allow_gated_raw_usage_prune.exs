defmodule BillingCore.Repo.Migrations.AllowGatedRawUsagePrune do
  use Ecto.Migration

  @moduledoc """
  SPEC §20: raw usage carries team-configurable retention after invoice
  freeze. Ordinary DELETE stays prohibited; the retention enforcer opens a
  transaction-scoped gate (`SET LOCAL billing.raw_usage_prune = 'on'`)
  that this dedicated trigger honors. The gate never survives the
  transaction, so no other code path can delete usage rows, and the dedup
  ledger (`usage_event_keys`) remains fully append-only.
  """

  def up do
    execute "DROP TRIGGER IF EXISTS usage_events_no_delete ON billing.usage_events"

    execute """
    CREATE OR REPLACE FUNCTION billing.usage_events_gated_delete() RETURNS trigger AS $$
    BEGIN
      IF current_setting('billing.raw_usage_prune', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'DELETE on %.% is prohibited: raw usage is deletable only through the retention enforcer', TG_TABLE_SCHEMA, TG_TABLE_NAME;
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER usage_events_no_delete
      BEFORE DELETE ON billing.usage_events
      FOR EACH ROW EXECUTE FUNCTION billing.usage_events_gated_delete();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS usage_events_no_delete ON billing.usage_events"
    execute "DROP FUNCTION IF EXISTS billing.usage_events_gated_delete()"

    execute """
    CREATE TRIGGER usage_events_no_delete
      BEFORE DELETE ON billing.usage_events
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end
end
