defmodule BillingCore.Repo.Migrations.EnableCitext do
  use Ecto.Migration

  @moduledoc """
  Enables the `citext` extension used for case-insensitive unique email
  storage (SPEC §13.3 `user_emails`).
  """

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS citext")
  end
end
