defmodule BillingCore.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  @moduledoc """
  Durable product-level operations for asynchronous work whose failure matters
  to users, finance workflows, external side effects, or the audit trail
  (SPEC §22.9.2, INV-040/041/042). Oban rows are execution machinery;
  this table is the authoritative user-visible lifecycle.
  """

  def change do
    create table(:operations, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid
      add :organization_id, :uuid
      add :type, :text, null: false

      add :state, :text,
        null: false,
        default: "queued"

      add :actor_type, :text, null: false
      add :actor_id, :text
      add :target_type, :text
      add :target_id, :uuid
      add :correlation_id, :uuid
      add :causation_id, :uuid
      add :idempotency_key_hash, :text
      add :attempt_count, :integer, null: false, default: 0
      add :error_class, :text
      add :safe_error_code, :text
      add :safe_error_summary, :text
      add :next_attempt_at, :utc_datetime_usec
      add :blocked_reason, :text
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :version, :bigint, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:operations, :operations_state_check,
             prefix: "billing",
             check:
               "state in ('queued','executing','succeeded','retry_scheduled','outcome_unknown','reconciling','blocked','failed')"
           )

    create index(:operations, [:team_id, :state], prefix: "billing")
    create index(:operations, [:target_type, :target_id], prefix: "billing")
    create index(:operations, [:correlation_id], prefix: "billing")

    create index(:operations, [:state, :next_attempt_at],
             prefix: "billing",
             where: "state in ('retry_scheduled','queued')",
             name: :operations_runnable_idx
           )

    create table(:operation_transitions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true

      add :operation_id,
          references(:operations, type: :uuid, prefix: "billing", on_delete: :restrict),
          null: false

      add :from_state, :text, null: false
      add :to_state, :text, null: false
      add :event, :text, null: false
      add :reason, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:operation_transitions, [:operation_id, :occurred_at], prefix: "billing")
  end
end
