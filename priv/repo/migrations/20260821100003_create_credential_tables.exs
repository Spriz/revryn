defmodule BillingCore.Repo.Migrations.CreateCredentialTables do
  use Ecto.Migration

  @moduledoc """
  Authentication material split into dedicated tables (SPEC §13.3, §19.2):
  WebAuthn credentials, TOTP factors, recovery codes, and OIDC federated
  identities. No reusable passwords are ever stored.
  """

  def change do
    create table(:webauthn_credentials, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :credential_id, :bytea, null: false
      add :public_key, :bytea, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :backup_eligible, :boolean
      add :backup_state, :boolean
      add :transports, {:array, :text}
      add :name, :text, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:webauthn_credentials, [:credential_id], prefix: "billing")
    create index(:webauthn_credentials, [:user_id], prefix: "billing")

    create table(:totp_factors, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :secret_ciphertext, :bytea, null: false
      add :activated_at, :utc_datetime_usec
      add :last_timestep, :bigint
      add :revoked_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:totp_factors, [:user_id], prefix: "billing")

    create table(:recovery_codes, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :code_hash, :text, null: false
      add :batch, :integer, null: false
      add :consumed_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:recovery_codes, [:user_id, :batch], prefix: "billing")

    create table(:federated_identities, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :issuer, :text, null: false
      add :subject, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:federated_identities, [:issuer, :subject], prefix: "billing")
    create index(:federated_identities, [:user_id], prefix: "billing")
  end
end
