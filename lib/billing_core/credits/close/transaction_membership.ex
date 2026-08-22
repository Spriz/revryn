defmodule BillingCore.Credits.Close.TransactionMembership do
  @moduledoc """
  Immutable membership of one append-only ledger row in exactly one close.

  `ledger_ordinal` records the deterministic order used in the frozen report.
  """

  use Ecto.Schema

  alias BillingCore.Credits.{Close.Close, CreditTransaction}

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "credit_close_transaction_memberships" do
    belongs_to :close, Close, primary_key: true
    belongs_to :transaction, CreditTransaction, primary_key: true
    field :ledger_ordinal, :integer

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end
end
