defmodule BillingCore.Repo.Migrations.CreateUsagePartitionMaintenance do
  use Ecto.Migration

  @moduledoc """
  Idempotent monthly partition maintenance for `billing.usage_events`
  (SPEC §13.1: monthly partitions are created at least two months ahead by an
  idempotent maintenance job; partitions carry the parent's indexes
  automatically because they are declared on the partitioned parent).

  `billing.ensure_usage_partition(month_start date)` creates the partition
  `usage_events_yYYYYmMM` with UTC bounds `[month_start, month_start + 1
  month)` when absent and returns the partition name either way. A concurrent
  duplicate creation is absorbed via the `duplicate_table` handler.

  The initial call range (2026-06 … 2026-12) seeds the months around the
  project's launch window; `BillingCore.Usage.ensure_partitions/1` (called by
  `BillingCore.Usage.PartitionWorker`) keeps rolling coverage ahead of now.
  """

  @initial_months ~w(2026-06-01 2026-07-01 2026-08-01 2026-09-01 2026-10-01 2026-11-01 2026-12-01)

  def up do
    execute """
    CREATE OR REPLACE FUNCTION billing.ensure_usage_partition(month_start date)
    RETURNS text
    LANGUAGE plpgsql
    AS $$
    DECLARE
      first_day date := date_trunc('month', month_start)::date;
      next_month date := (date_trunc('month', month_start) + interval '1 month')::date;
      partition_name text := format(
        'usage_events_y%sm%s', to_char(date_trunc('month', month_start), 'YYYY'),
        to_char(date_trunc('month', month_start), 'MM')
      );
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'billing' AND c.relname = partition_name
      ) THEN
        BEGIN
          EXECUTE format(
            'CREATE TABLE billing.%I PARTITION OF billing.usage_events FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            first_day::timestamp AT TIME ZONE 'UTC',
            next_month::timestamp AT TIME ZONE 'UTC'
          );
        EXCEPTION WHEN duplicate_table THEN
          NULL; -- lost a benign creation race; the partition exists
        END;
      END IF;

      RETURN partition_name;
    END;
    $$
    """

    for month <- @initial_months do
      execute "SELECT billing.ensure_usage_partition(DATE '#{month}')"
    end
  end

  def down do
    execute "DROP FUNCTION IF EXISTS billing.ensure_usage_partition(date)"
  end
end
