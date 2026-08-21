defmodule BillingCore.Repo.Migrations.CreateDiscountAssignments do
  use Ecto.Migration

  @moduledoc """
  Attachment of an immutable discount version to a contract or subscription
  for an effective interval (SPEC §13.3 `discount_assignments`). Assignments
  are deactivated prospectively, never rewritten retroactively.

  `contract_id` and `subscription_id` are intentionally plain uuids without
  foreign keys: the contracts migration range owns those tables.
  """

  def change do
    create table(:discount_assignments, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false

      add :discount_version_id, references(:discount_versions, type: :uuid), null: false

      add :contract_id, :uuid
      add :subscription_id, :uuid
      add :status, :text, null: false, default: "active"
      add :effective_from, :date, null: false
      add :effective_until_exclusive, :date
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:discount_assignments, :discount_assignments_status_check,
             check: "status in ('active', 'deactivated')",
             prefix: "billing"
           )

    # INV: scope is explicit — exactly one target (BC-US-060).
    create constraint(:discount_assignments, :discount_assignments_exactly_one_target_check,
             check:
               "(contract_id is not null and subscription_id is null) or " <>
                 "(contract_id is null and subscription_id is not null)",
             prefix: "billing"
           )

    create constraint(:discount_assignments, :discount_assignments_effective_interval_check,
             check:
               "effective_until_exclusive is null or effective_from < effective_until_exclusive",
             prefix: "billing"
           )

    create index(:discount_assignments, [:team_id, :contract_id], prefix: "billing")
    create index(:discount_assignments, [:team_id, :subscription_id], prefix: "billing")
    create index(:discount_assignments, [:discount_version_id], prefix: "billing")
  end
end
