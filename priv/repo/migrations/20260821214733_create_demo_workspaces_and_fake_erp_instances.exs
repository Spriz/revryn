defmodule BillingCore.Repo.Migrations.CreateDemoWorkspacesAndFakeErpInstances do
  use Ecto.Migration

  @moduledoc """
  Durable ownership and isolation records for Revryn's synthetic demo ERP.

  Financial rows are never reset or deleted. A replay archives its workspace
  and provider instance, then creates a new generation.
  """

  def up do
    create table(:demo_workspaces, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid, prefix: "billing"), null: false

      add :organization_id,
          references(:organizations, type: :uuid, prefix: "billing"),
          null: false

      add :owner_user_id, references(:users, type: :uuid, prefix: "billing"), null: false
      add :scenario_version, :text, null: false, default: "northstar-v1"
      add :generation, :integer, null: false
      add :state, :text, null: false, default: "provisioning"
      add :seed_key, :text, null: false
      add :progress, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :reset_at, :utc_datetime_usec

      add :predecessor_workspace_id,
          references(:demo_workspaces, type: :uuid, prefix: "billing")

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:demo_workspaces, :demo_workspaces_generation_check,
             prefix: "billing",
             check: "generation > 0"
           )

    create constraint(:demo_workspaces, :demo_workspaces_state_check,
             prefix: "billing",
             check: "state in ('provisioning','active','completed','failed','archived')"
           )

    create unique_index(:demo_workspaces, [:owner_user_id, :generation], prefix: "billing")

    create unique_index(:demo_workspaces, [:owner_user_id],
             prefix: "billing",
             where: "state in ('provisioning','active')",
             name: :demo_workspaces_one_active_owner_idx
           )

    create unique_index(:demo_workspaces, [:team_id],
             prefix: "billing",
             where: "state in ('provisioning','active')",
             name: :demo_workspaces_one_active_team_idx
           )

    create index(:demo_workspaces, [:team_id, :state], prefix: "billing")
    create index(:demo_workspaces, [:predecessor_workspace_id], prefix: "billing")

    create table(:fake_erp_instances, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid, prefix: "billing"), null: false

      add :workspace_id,
          references(:demo_workspaces, type: :uuid, prefix: "billing"),
          null: false

      add :erp_connection_id,
          references(:erp_connections, type: :uuid, prefix: "billing"),
          null: false

      add :snapshot, :binary
      add :snapshot_sha256, :text
      add :snapshot_format_version, :integer, null: false, default: 1
      add :lock_version, :bigint, null: false, default: 1
      add :state, :text, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:fake_erp_instances, :fake_erp_instances_state_check,
             prefix: "billing",
             check: "state in ('active','archived')"
           )

    create constraint(:fake_erp_instances, :fake_erp_instances_snapshot_version_check,
             prefix: "billing",
             check: "snapshot_format_version > 0 and lock_version > 0"
           )

    create constraint(:fake_erp_instances, :fake_erp_instances_snapshot_hash_check,
             prefix: "billing",
             check:
               "(snapshot is null and snapshot_sha256 is null) or (snapshot is not null and snapshot_sha256 is not null)"
           )

    create unique_index(:fake_erp_instances, [:workspace_id], prefix: "billing")
    create unique_index(:fake_erp_instances, [:erp_connection_id], prefix: "billing")
    create index(:fake_erp_instances, [:team_id, :state], prefix: "billing")

    execute """
    CREATE OR REPLACE FUNCTION billing.enforce_demo_workspace_team_scope()
    RETURNS trigger AS $$
    DECLARE expected_organization_id uuid;
    BEGIN
      SELECT organization_id INTO expected_organization_id
      FROM billing.teams WHERE id = NEW.team_id;

      IF expected_organization_id IS NULL OR expected_organization_id <> NEW.organization_id THEN
        RAISE EXCEPTION 'demo workspace organization must own its team';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER demo_workspaces_team_scope
      BEFORE INSERT OR UPDATE ON billing.demo_workspaces
      FOR EACH ROW EXECUTE FUNCTION billing.enforce_demo_workspace_team_scope();
    """

    execute """
    CREATE OR REPLACE FUNCTION billing.enforce_fake_erp_instance_team_scope()
    RETURNS trigger AS $$
    DECLARE workspace_team_id uuid;
    DECLARE connection_team_id uuid;
    BEGIN
      SELECT team_id INTO workspace_team_id
      FROM billing.demo_workspaces WHERE id = NEW.workspace_id;
      SELECT team_id INTO connection_team_id
      FROM billing.erp_connections WHERE id = NEW.erp_connection_id;

      IF workspace_team_id IS NULL OR connection_team_id IS NULL OR
         workspace_team_id <> NEW.team_id OR connection_team_id <> NEW.team_id THEN
        RAISE EXCEPTION 'fake ERP instance team must match workspace and ERP connection teams';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER fake_erp_instances_team_scope
      BEFORE INSERT OR UPDATE ON billing.fake_erp_instances
      FOR EACH ROW EXECUTE FUNCTION billing.enforce_fake_erp_instance_team_scope();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS fake_erp_instances_team_scope ON billing.fake_erp_instances"
    execute "DROP FUNCTION IF EXISTS billing.enforce_fake_erp_instance_team_scope()"
    execute "DROP TRIGGER IF EXISTS demo_workspaces_team_scope ON billing.demo_workspaces"
    execute "DROP FUNCTION IF EXISTS billing.enforce_demo_workspace_team_scope()"
    drop table(:fake_erp_instances, prefix: "billing")
    drop table(:demo_workspaces, prefix: "billing")
  end
end
