defmodule BillingCore.Credits.CreditAccount do
  @moduledoc """
  Customer-credit subledger account (SPEC §13.3 `customer_credit_accounts`,
  INV-050): one per team + commercial account + currency.

  `available_minor` / `reserved_minor` are projections of the append-only
  `customer_credit_transactions` ledger, updated atomically with each ledger
  row under a `FOR UPDATE` lock on this row. `Credits.reconcile_account/1`
  recomputes them from the ledger and fails loudly on divergence.
  """

  use Ecto.Schema

  alias BillingCore.Orgs.Account

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_accounts" do
    field :team_id, Ecto.UUID
    field :currency, :string
    field :available_minor, :integer, default: 0
    field :reserved_minor, :integer, default: 0
    field :version, :integer, default: 1

    belongs_to :account, Account

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end
end
