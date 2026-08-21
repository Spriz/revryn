defmodule BillingCore.Repo.Migrations.CreateAccountTeamCustomers do
  use Ecto.Migration

  @moduledoc """
  Mapping of an organization account to its team-specific billing customer
  projection (SPEC §13.3 `account_team_customers`, BC-US-142). Unique per
  (account, team) in the baseline model.
  """

  def change do
    create table(:account_team_customers, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :account_id, references(:accounts, type: :uuid), null: false
      add :team_id, references(:teams, type: :uuid), null: false
      # No foreign key on customer_id: billing.customers is owned by a later
      # migration range (customer domain). The reference is validated at the
      # application layer until that table exists.
      add :customer_id, :uuid, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:account_team_customers, [:account_id, :team_id], prefix: "billing")
    create index(:account_team_customers, [:team_id], prefix: "billing")
  end
end
