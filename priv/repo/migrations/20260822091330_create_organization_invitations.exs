defmodule BillingCore.Repo.Migrations.CreateOrganizationInvitations do
  @moduledoc """
  BC-US-144: single-use, expiring, hashed-at-rest invitations scoped to the
  intended organization/team memberships.
  """

  use Ecto.Migration

  def change do
    create table(:organization_invitations, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true

      add :organization_id, references(:organizations, type: :uuid, prefix: "billing"),
        null: false

      add :team_id, references(:teams, type: :uuid, prefix: "billing")
      add :email, :text, null: false
      add :organization_roles, {:array, :text}, null: false, default: []
      add :team_roles, {:array, :text}, null: false, default: []
      add :token_hash, :text, null: false
      add :invited_by, :uuid
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :accepted_user_id, :uuid
      add :revoked_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:organization_invitations, [:token_hash], prefix: "billing")
    create index(:organization_invitations, [:organization_id], prefix: "billing")
    create index(:organization_invitations, [:email], prefix: "billing")

    create constraint(:organization_invitations, :organization_invitations_roles_check,
             prefix: "billing",
             check:
               "cardinality(organization_roles) > 0 or (team_id is not null and cardinality(team_roles) > 0)"
           )
  end
end
