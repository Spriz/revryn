defmodule BillingCore.Repo.Migrations.CreateTeamSettingsVersions do
  use Ecto.Migration

  @moduledoc """
  Immutable, versioned snapshots of team settings (SPEC §13.3
  `team_settings_versions`). Each snapshot carries a canonical SHA-256 hash;
  UPDATE/DELETE are rejected at the database (append-only history).
  """

  def up do
    create table(:team_settings_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :version, :bigint, null: false
      add :settings, :map, null: false
      add :settings_hash, :text, null: false
      add :created_by, references(:users, type: :uuid)
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:team_settings_versions, [:team_id, :version], prefix: "billing")

    # Snapshots are immutable — reuses billing.reject_mutation() from the
    # infrastructure migration.
    execute """
    CREATE TRIGGER team_settings_versions_append_only
      BEFORE UPDATE OR DELETE ON billing.team_settings_versions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS team_settings_versions_append_only ON billing.team_settings_versions"
    )

    drop table(:team_settings_versions, prefix: "billing")
  end
end
