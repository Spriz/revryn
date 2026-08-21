defmodule BillingCore.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  Organization-scoped commercial accounts (SPEC §13.3 `accounts`,
  BC-US-142): durable B2B customer identity shared across teams.
  """

  def change do
    create table(:accounts, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :organization_id, references(:organizations, type: :uuid), null: false
      add :external_id, :text, null: false
      add :display_name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:accounts, :accounts_status_check,
             check: "status in ('active', 'archived')",
             prefix: "billing"
           )

    create unique_index(:accounts, [:organization_id, :external_id], prefix: "billing")
  end
end
