defmodule BillingCore.Repo.Migrations.CreateUsageEventsImmutability do
  use Ecto.Migration

  @moduledoc """
  Database-level immutability for usage events (SPEC §13.1: immutable
  financial tables reject UPDATE and DELETE; lifecycle projections are
  restricted to non-financial state columns).

  Usage event payloads are append-only evidence. The only mutable column is
  `status`, the lifecycle projection flipped to `voided` when a correction
  void lands; everything else — including `received_at`, the basis of frozen
  cutoffs — is frozen at insert. Row triggers on the partitioned parent
  cascade to every partition, present and future.
  """

  def up do
    execute """
    CREATE OR REPLACE FUNCTION billing.usage_events_status_only_update() RETURNS trigger AS $$
    BEGIN
      IF ROW(NEW.id, NEW.team_id, NEW.external_event_id, NEW.event_kind, NEW.subscription_id,
             NEW.metric_code, NEW.occurred_at, NEW.received_at, NEW.value, NEW.properties,
             NEW.payload_hash, NEW.voids_event_id, NEW.replacement_for_event_id)
         IS DISTINCT FROM
         ROW(OLD.id, OLD.team_id, OLD.external_event_id, OLD.event_kind, OLD.subscription_id,
             OLD.metric_code, OLD.occurred_at, OLD.received_at, OLD.value, OLD.properties,
             OLD.payload_hash, OLD.voids_event_id, OLD.replacement_for_event_id) THEN
        RAISE EXCEPTION 'usage events are immutable except lifecycle status';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER usage_events_status_only
      BEFORE UPDATE ON billing.usage_events
      FOR EACH ROW EXECUTE FUNCTION billing.usage_events_status_only_update();
    """

    execute """
    CREATE TRIGGER usage_events_no_delete
      BEFORE DELETE ON billing.usage_events
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS usage_events_no_delete ON billing.usage_events"
    execute "DROP TRIGGER IF EXISTS usage_events_status_only ON billing.usage_events"
    execute "DROP FUNCTION IF EXISTS billing.usage_events_status_only_update()"
  end
end
