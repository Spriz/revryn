defmodule BillingCore.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  @moduledoc """
  Revocable server-side sessions carrying authentication strength and time
  (SPEC §13.3, §19.2). Only the SHA-256 hash of the session token is stored.
  """

  def change do
    create table(:sessions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :token_hash, :text, null: false
      add :authenticated_at, :utc_datetime_usec, null: false
      add :strength, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :ip, :text
      add :user_agent, :text
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:sessions, :sessions_strength_check,
             check: "strength in ('passkey', 'passkey_plus_totp', 'recovery')",
             prefix: "billing"
           )

    create unique_index(:sessions, [:token_hash], prefix: "billing")
    create index(:sessions, [:user_id], prefix: "billing")
  end
end
