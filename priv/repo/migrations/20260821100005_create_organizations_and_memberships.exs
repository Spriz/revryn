defmodule BillingCore.Repo.Migrations.CreateOrganizationsAndMemberships do
  use Ecto.Migration

  @moduledoc """
  Organizations and explicit organization memberships (SPEC §13.3, §6.3).
  Role grants are explicit arrays constrained to the canonical organization
  roles; at most one ACTIVE membership per (organization, user).
  """

  def change do
    create table(:organizations, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :slug, :text, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :security_policy, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:organizations, :organizations_status_check,
             check: "status in ('active', 'disabled')",
             prefix: "billing"
           )

    create unique_index(:organizations, [:slug], prefix: "billing")

    create table(:organization_memberships, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :organization_id, references(:organizations, type: :uuid), null: false
      add :user_id, references(:users, type: :uuid), null: false
      add :roles, {:array, :text}, null: false
      add :status, :text, null: false, default: "active"
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:organization_memberships, :organization_memberships_status_check,
             check: "status in ('active', 'suspended', 'removed')",
             prefix: "billing"
           )

    create constraint(:organization_memberships, :organization_memberships_roles_check,
             check:
               "roles <@ ARRAY['organization_owner', 'organization_admin', 'organization_member']::text[] AND cardinality(roles) > 0",
             prefix: "billing"
           )

    # At most one ACTIVE membership per (organization, user); historical
    # removed/suspended rows are retained.
    create unique_index(:organization_memberships, [:organization_id, :user_id],
             prefix: "billing",
             where: "status = 'active'",
             name: :organization_memberships_one_active_idx
           )

    create index(:organization_memberships, [:user_id], prefix: "billing")
  end
end
