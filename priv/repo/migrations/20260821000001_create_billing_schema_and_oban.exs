defmodule BillingCore.Repo.Migrations.CreateBillingSchemaAndOban do
  use Ecto.Migration

  @moduledoc """
  Creates the `billing` PostgreSQL schema that owns all domain tables
  (SPEC §13.1) and the Oban job tables (execution machinery, kept in
  `public` — durable domain operations live in `billing.*`).
  """

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS billing")
    Oban.Migration.up()
  end

  def down do
    Oban.Migration.down(version: 1)
    execute("DROP SCHEMA IF EXISTS billing")
  end
end
