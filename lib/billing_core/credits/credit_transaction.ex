defmodule BillingCore.Credits.CreditTransaction do
  @moduledoc """
  Append-only customer-credit ledger row (SPEC §13.3
  `customer_credit_transactions`, INV-051). Amounts are strictly positive;
  the `transaction_type` fixes the sign of its effect on the projection:

    * `grant` — +available
    * `reserve` — available → reserved
    * `release` — reserved → available
    * `apply` — −reserved and −grant remaining
    * `refund` / `expire` — −available and −grant remaining
    * `adjust` — manual correction; `metadata` carries `"target"`
      (`"available"` / `"reserved"`) and `"direction"`
      (`"increase"` / `"decrease"`)

  `(team_id, idempotency_key)` is unique; multi-grant commands write one row
  per grant with derived keys and carry the caller's key as
  `metadata["batch_key"]` for replay detection.
  """

  use Ecto.Schema

  alias BillingCore.Credits.{CreditAccount, CreditGrant}

  @type t :: %__MODULE__{}

  @transaction_types [:grant, :reserve, :release, :apply, :refund, :expire, :adjust]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_transactions" do
    field :team_id, Ecto.UUID
    field :transaction_type, Ecto.Enum, values: @transaction_types
    field :amount_minor, :integer
    field :currency, :string
    field :idempotency_key, :string
    field :invoice_intent_id, Ecto.UUID
    field :operation_id, Ecto.UUID
    field :reason_code, :string
    field :actor_reference, :string
    field :occurred_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :credit_account, CreditAccount
    belongs_to :grant, CreditGrant

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Valid ledger transaction types."
  def transaction_types, do: @transaction_types
end
