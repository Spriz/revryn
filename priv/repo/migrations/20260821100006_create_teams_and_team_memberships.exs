defmodule BillingCore.Repo.Migrations.CreateTeamsAndTeamMemberships do
  use Ecto.Migration

  @moduledoc """
  Teams — the hard tenancy/isolation boundary (SPEC §13.3 `teams`, §9.1.1) —
  and explicit team memberships with canonical team roles (SPEC §6.3).
  """

  def change do
    create table(:teams, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :organization_id, references(:organizations, type: :uuid), null: false
      add :name, :text, null: false
      add :slug, :text, null: false
      add :legal_name, :text, null: false
      add :base_currency, :"char(3)", null: false
      add :time_zone, :text, null: false
      add :locale, :text, null: false
      add :status, :text, null: false, default: "active"
      add :settings_version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:teams, :teams_status_check,
             check: "status in ('active', 'disabled')",
             prefix: "billing"
           )

    create unique_index(:teams, [:organization_id, :slug], prefix: "billing")

    create table(:team_memberships, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :user_id, references(:users, type: :uuid), null: false
      add :roles, {:array, :text}, null: false
      add :status, :text, null: false, default: "active"
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:team_memberships, :team_memberships_status_check,
             check: "status in ('active', 'suspended', 'removed')",
             prefix: "billing"
           )

    create constraint(:team_memberships, :team_memberships_roles_check,
             check:
               "roles <@ ARRAY['team_admin', 'billing_admin', 'finance_operator', 'auditor', 'integration_client']::text[] AND cardinality(roles) > 0",
             prefix: "billing"
           )

    # At most one ACTIVE membership per (team, user).
    create unique_index(:team_memberships, [:team_id, :user_id],
             prefix: "billing",
             where: "status = 'active'",
             name: :team_memberships_one_active_idx
           )

    create index(:team_memberships, [:user_id], prefix: "billing")
  end
end
