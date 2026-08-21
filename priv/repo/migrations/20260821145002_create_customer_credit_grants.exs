defmodule BillingCore.Repo.Migrations.CreateCustomerCreditGrants do
  use Ecto.Migration

  @moduledoc """
  Customer-credit grants (SPEC §13.3 `customer_credit_grants`, §11.4,
  BC-US-107): immutable original value (`granted_minor`, origin references)
  plus the mutable §11.4 projection (`status`, `remaining_minor`,
  `reserved_minor`) derived from the append-only transaction ledger.
  """

  def change do
    create table(:customer_credit_grants, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :credit_account_id,
          references(:customer_credit_accounts, type: :uuid, prefix: "billing"),
          null: false

      add :origin_type, :text, null: false
      add :origin_id, :uuid
      add :origin_invoice_line_id, :uuid
      add :granted_minor, :bigint, null: false
      add :currency, :"char(3)", null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :disposition_policy_version_id, :uuid
      add :metadata, :map, null: false, default: %{}

      # §11.4 grant projection (the ledger remains the audit evidence).
      add :status, :text, null: false, default: "available"
      add :remaining_minor, :bigint, null: false
      add :reserved_minor, :bigint, null: false, default: 0
      add :version, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customer_credit_grants, :customer_credit_grants_granted_check,
             check: "granted_minor > 0",
             prefix: "billing"
           )

    create constraint(:customer_credit_grants, :customer_credit_grants_remaining_check,
             check: "remaining_minor >= 0",
             prefix: "billing"
           )

    create constraint(:customer_credit_grants, :customer_credit_grants_reserved_check,
             check: "reserved_minor >= 0",
             prefix: "billing"
           )

    create constraint(:customer_credit_grants, :customer_credit_grants_status_check,
             check:
               "status in ('available','reserved','partially_spent','spent'," <>
                 "'refund_pending','refunded','expiry_scheduled','expired')",
             prefix: "billing"
           )

    create index(:customer_credit_grants, [:credit_account_id], prefix: "billing")
    create index(:customer_credit_grants, [:team_id, :status], prefix: "billing")
  end
end
