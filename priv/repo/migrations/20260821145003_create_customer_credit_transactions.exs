defmodule BillingCore.Repo.Migrations.CreateCustomerCreditTransactions do
  use Ecto.Migration

  @moduledoc """
  Append-only customer-credit ledger (SPEC §13.3
  `customer_credit_transactions`, INV-051): every balance change is a
  transaction row committed atomically with the projection update. The table
  rejects UPDATE/DELETE at the database level; `(team_id, idempotency_key)`
  is the replay identity.
  """

  def up do
    create table(:customer_credit_transactions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :credit_account_id,
          references(:customer_credit_accounts, type: :uuid, prefix: "billing"),
          null: false

      add :grant_id, references(:customer_credit_grants, type: :uuid, prefix: "billing")
      add :transaction_type, :text, null: false
      add :amount_minor, :bigint, null: false
      add :currency, :"char(3)", null: false
      add :idempotency_key, :text, null: false
      add :invoice_intent_id, :uuid
      add :operation_id, :uuid
      add :reason_code, :text
      add :actor_reference, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:customer_credit_transactions, :customer_credit_transactions_type_check,
             check:
               "transaction_type in ('grant','reserve','release','apply','refund','expire','adjust')",
             prefix: "billing"
           )

    create constraint(:customer_credit_transactions, :customer_credit_transactions_amount_check,
             check: "amount_minor > 0",
             prefix: "billing"
           )

    create unique_index(:customer_credit_transactions, [:team_id, :idempotency_key],
             prefix: "billing"
           )

    create index(:customer_credit_transactions, [:credit_account_id], prefix: "billing")
    create index(:customer_credit_transactions, [:grant_id], prefix: "billing")

    # INV-051: credits never silently disappear — the ledger is append-only.
    execute """
    CREATE TRIGGER customer_credit_transactions_append_only
      BEFORE UPDATE OR DELETE ON billing.customer_credit_transactions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute """
    DROP TRIGGER IF EXISTS customer_credit_transactions_append_only
      ON billing.customer_credit_transactions
    """

    drop table(:customer_credit_transactions, prefix: "billing")
  end
end
