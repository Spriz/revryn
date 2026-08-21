defmodule BillingCore.Repo.Migrations.CreateUsageEventKeys do
  use Ecto.Migration

  @moduledoc """
  Unpartitioned idempotency table for usage ingestion (SPEC §13.3
  `usage_event_keys`). Reserves `(team_id, external_event_id)` before the
  usage payload row is inserted and stores the canonical payload hash plus
  the internal event ID, preserving global team-scoped event uniqueness even
  though `usage_events` payload rows are time-partitioned. `occurred_at` is a
  copy of the event's partition key for direct partition lookup.
  """

  def change do
    create table(:usage_event_keys, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :external_event_id, :text, null: false
      add :payload_hash, :text, null: false
      add :usage_event_id, :uuid, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:usage_event_keys, [:team_id, :external_event_id], prefix: "billing")
    create index(:usage_event_keys, [:team_id, :usage_event_id], prefix: "billing")
  end
end
