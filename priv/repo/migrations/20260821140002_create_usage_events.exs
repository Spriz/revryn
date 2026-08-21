defmodule BillingCore.Repo.Migrations.CreateUsageEvents do
  use Ecto.Migration

  @moduledoc """
  Append-only usage event payload table (SPEC §13.3 `usage_events` —
  normative SQL), range-partitioned by month on `occurred_at` with primary
  key `(occurred_at, id)`.

  `received_at` is assigned by PostgreSQL `clock_timestamp()` — the API never
  accepts it — so frozen billing cutoffs are based on trusted server time.
  Corrections are immutable `void` rows (plus optional replacement
  measurements) that copy the original's `occurred_at` for partition locality
  and record their own `received_at` for cutoff semantics.

  No DEFAULT partition exists on purpose (SPEC §13.1 requires explicit,
  observable monthly partitions): inserting a row whose `occurred_at` falls
  outside the explicitly created partitions raises
  `no partition of relation "usage_events" found for row`. Partitions are
  created ahead of time by `billing.ensure_usage_partition/1` (next
  migration) and the maintenance worker.

  The two partial unique indexes live on the partitioned parent so they apply
  to every partition; partitioned unique indexes must include the partition
  key, which both do via `occurred_at` (voids/replacements copy the
  original's `occurred_at`, so uniqueness per original measurement holds).
  """

  def up do
    execute """
    CREATE TABLE billing.usage_events (
      id uuid NOT NULL,
      team_id uuid NOT NULL,
      external_event_id text NOT NULL,
      event_kind text NOT NULL CHECK (event_kind IN ('measurement', 'void')),
      subscription_id uuid NOT NULL,
      metric_code text NOT NULL,
      occurred_at timestamptz NOT NULL,
      received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      value numeric(38,18),
      properties jsonb NOT NULL DEFAULT '{}'::jsonb,
      payload_hash text NOT NULL,
      status text NOT NULL DEFAULT 'effective'
        CHECK (status IN ('effective', 'voided', 'quarantined')),
      voids_event_id uuid,
      replacement_for_event_id uuid,
      PRIMARY KEY (occurred_at, id),
      CHECK (
        (event_kind = 'measurement' AND value IS NOT NULL AND voids_event_id IS NULL)
        OR
        (event_kind = 'void' AND value IS NULL AND voids_event_id IS NOT NULL
          AND replacement_for_event_id IS NULL)
      )
    ) PARTITION BY RANGE (occurred_at)
    """

    # At most one effective void per original measurement (SPEC §13.3).
    execute """
    CREATE UNIQUE INDEX usage_events_one_void_per_measurement_uq
      ON billing.usage_events (occurred_at, team_id, voids_event_id)
      WHERE event_kind = 'void'
    """

    execute """
    CREATE UNIQUE INDEX usage_events_one_replacement_per_measurement_uq
      ON billing.usage_events (occurred_at, team_id, replacement_for_event_id)
      WHERE replacement_for_event_id IS NOT NULL
    """

    # Rating/aggregation access paths: service-period membership by metric and
    # the frozen evidence set by received_at (SPEC §13.1).
    execute """
    CREATE INDEX usage_events_team_sub_metric_occurred_idx
      ON billing.usage_events (team_id, subscription_id, metric_code, occurred_at)
    """

    execute """
    CREATE INDEX usage_events_team_received_idx
      ON billing.usage_events (team_id, received_at)
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS billing.usage_events"
  end
end
