defmodule BillingCore.Repo.Migrations.CreateSubscriptionVersions do
  use Ecto.Migration

  @moduledoc """
  Immutable-per-period subscription version snapshots (SPEC §13.3
  `subscription_versions`). No two versions of one subscription may cover
  overlapping effective periods — enforced with a PostgreSQL exclusion
  constraint over a daterange (btree_gist).
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"

    create table(:subscription_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :subscription_id, references(:subscriptions, type: :uuid), null: false
      add :version, :bigint, null: false

      # NOTE: plain uuid on purpose — billing.plan_versions belongs to the
      # catalog migration range; the foreign key is added once it exists.
      add :plan_version_id, :uuid, null: false

      add :quantity, :"numeric(38,18)", null: false
      add :effective_start, :date, null: false
      add :effective_end_exclusive, :date
      add :price_overrides, :map, null: false, default: %{}
      add :cancellation_policy, :text, null: false, default: "end_of_period"
      add :status_reason, :text
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:subscription_versions, :subscription_versions_quantity_check,
             check: "quantity > 0",
             prefix: "billing"
           )

    create constraint(:subscription_versions, :subscription_versions_period_check,
             check:
               "effective_end_exclusive is null or effective_start <= effective_end_exclusive",
             prefix: "billing"
           )

    create unique_index(:subscription_versions, [:team_id, :subscription_id, :version],
             prefix: "billing"
           )

    # INV: effective periods of one subscription never overlap (half-open
    # ranges; a closed version [a, b) never collides with its successor [b, c)).
    execute """
    ALTER TABLE billing.subscription_versions
      ADD CONSTRAINT subscription_versions_no_overlap
      EXCLUDE USING gist (
        subscription_id WITH =,
        daterange(effective_start, coalesce(effective_end_exclusive, 'infinity'::date)) WITH &&
      )
    """
  end

  def down do
    drop table(:subscription_versions, prefix: "billing")
  end
end
