defmodule BillingCore.Repo.Migrations.CreateUsageQuarantine do
  use Ecto.Migration

  @moduledoc """
  Quarantine for usage events rejected by ingestion policy rather than
  silently discarded (BC-US-050, SPEC §18.5 `manual_review`). One row per
  `(team, external_event_id)`; `resolved_at` records when the entry was
  handled (finance decision, or a later successful re-ingest of the same
  external event ID). `received_at` is assigned by PostgreSQL clock time,
  as with `usage_events`.
  """

  def change do
    create table(:usage_quarantine, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :external_event_id, :text, null: false
      add :reason, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :received_at, :utc_datetime_usec, null: false, default: fragment("clock_timestamp()")
      add :resolved_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:usage_quarantine, :usage_quarantine_reason_check,
             prefix: "billing",
             check:
               "reason in ('too_old','too_far_future','unknown_subscription','unknown_metric','oversized_properties')"
           )

    create unique_index(:usage_quarantine, [:team_id, :external_event_id], prefix: "billing")
    create index(:usage_quarantine, [:team_id, :reason], prefix: "billing")
  end
end
