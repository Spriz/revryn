defmodule BillingCore.Repo.Migrations.CreateCustomerCreditAccounts do
  use Ecto.Migration

  @moduledoc """
  Customer-credit subledger accounts (SPEC §13.3 `customer_credit_accounts`,
  BC-US-107/108, INV-050): one account per team + commercial account +
  currency. `available_minor` / `reserved_minor` are projections of the
  append-only transaction ledger and must reconcile to it; the `>= 0` checks
  are the database backstop for INV-052 (never below zero).
  """

  def change do
    create table(:customer_credit_accounts, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :account_id, references(:accounts, type: :uuid), null: false
      add :currency, :"char(3)", null: false
      add :available_minor, :bigint, null: false, default: 0
      add :reserved_minor, :bigint, null: false, default: 0
      add :version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customer_credit_accounts, :customer_credit_accounts_available_check,
             check: "available_minor >= 0",
             prefix: "billing"
           )

    create constraint(:customer_credit_accounts, :customer_credit_accounts_reserved_check,
             check: "reserved_minor >= 0",
             prefix: "billing"
           )

    create unique_index(:customer_credit_accounts, [:team_id, :account_id, :currency],
             prefix: "billing"
           )
  end
end
