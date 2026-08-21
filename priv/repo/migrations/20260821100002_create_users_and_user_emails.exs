defmodule BillingCore.Repo.Migrations.CreateUsersAndUserEmails do
  use Ecto.Migration

  @moduledoc """
  Global user identity and verified email addresses (SPEC §13.3, §19.2).
  `users` is global and carries no organization/team role. `user_emails`
  supports multiple verified addresses with exactly one primary per user.
  """

  def change do
    create table(:users, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :status, :text, null: false, default: "active"
      add :platform_admin, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:users, :users_status_check,
             check: "status in ('active', 'disabled')",
             prefix: "billing"
           )

    create table(:user_emails, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :email, :citext, null: false
      add :verified_at, :utc_datetime_usec
      add :primary, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:user_emails, [:email], prefix: "billing")
    create index(:user_emails, [:user_id], prefix: "billing")

    # At most one primary email per user.
    create unique_index(:user_emails, [:user_id],
             prefix: "billing",
             where: ~s("primary"),
             name: :user_emails_one_primary_per_user_idx
           )
  end
end
