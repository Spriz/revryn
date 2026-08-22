defmodule BillingCore.Credits.CreditSettlement do
  @moduledoc """
  One receivable settlement produced by one credit application (SPEC §9.4.1).

  The subledger application, the customer invoice, this settlement record,
  and the monthly liability close are four distinct records; the settlement
  is the one that clears the credit-covered receivable exactly once. Its
  identity fields are immutable at the database level; the only permitted
  transition is `pending → reconciled` (terminal), carrying either the ERP
  voucher evidence or the authoritative external reference.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @modes [:erp_customer_settlement, :external_reference]
  @states [:pending, :reconciled]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_settlements" do
    field :team_id, Ecto.UUID
    field :invoice_intent_id, Ecto.UUID
    field :credit_account_id, Ecto.UUID
    field :policy_version_id, Ecto.UUID
    field :currency, :string
    field :amount_minor, :integer
    field :mode, Ecto.Enum, values: @modes
    field :state, Ecto.Enum, values: @states, default: :pending
    field :external_reference, :string
    field :operation_id, Ecto.UUID
    field :external_voucher_number, :string
    field :reconciled_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @spec modes() :: [atom()]
  def modes, do: @modes

  @spec states() :: [atom()]
  def states, do: @states
end
