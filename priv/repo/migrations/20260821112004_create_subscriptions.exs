defmodule BillingCore.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  @moduledoc """
  Subscription aggregate rows (SPEC §13.3 `subscriptions`, §11.1 state
  machine, BC-US-034/035).
  """

  def change do
    create table(:subscriptions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :external_id, :text, null: false
      add :contract_id, references(:contracts, type: :uuid), null: false
      add :status, :text, null: false
      add :start_date, :date, null: false
      add :end_date_exclusive, :date
      add :billing_anchor_day, :smallint
      add :time_zone, :text, null: false
      add :current_version, :bigint, null: false
      add :version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:subscriptions, :subscriptions_status_check,
             check:
               "status in ('scheduled', 'active', 'paused', 'pending_cancellation', 'cancelled')",
             prefix: "billing"
           )

    create constraint(:subscriptions, :subscriptions_period_check,
             check: "end_date_exclusive is null or start_date < end_date_exclusive",
             prefix: "billing"
           )

    create unique_index(:subscriptions, [:team_id, :external_id], prefix: "billing")
    create index(:subscriptions, [:contract_id], prefix: "billing")
    create index(:subscriptions, [:team_id, :status, :start_date], prefix: "billing")
  end
end
