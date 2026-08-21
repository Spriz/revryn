defmodule BillingCore.Repo.Migrations.CreatePlans do
  use Ecto.Migration

  @moduledoc """
  Plans own the stable team-scoped plan code (SPEC §13.3 `plans`,
  BC-US-013). Version content lives in `plan_versions`.
  """

  def change do
    create table(:plans, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :code, :text, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :current_version, :bigint, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:plans, :plans_status_check,
             check: "status in ('active', 'archived')",
             prefix: "billing"
           )

    create unique_index(:plans, [:team_id, :code], prefix: "billing")
  end
end
