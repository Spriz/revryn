defmodule BillingCore.Credits.Close.Movement do
  @moduledoc "Immutable aggregate movement evidence for a credit close."

  use Ecto.Schema

  alias BillingCore.Credits.Close.Close

  @type t :: %__MODULE__{}
  @movement_types [
    :grant,
    :reserve,
    :release,
    :apply,
    :refund,
    :expire,
    :positive_adjustment,
    :negative_adjustment,
    :prior_period_adjustment
  ]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_close_movements" do
    field :team_id, Ecto.UUID
    field :movement_type, Ecto.Enum, values: @movement_types
    field :amount_minor, :integer
    field :liability_effect_minor, :integer
    field :transaction_count, :integer
    field :contra_account_number, :integer

    belongs_to :close, Close

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @spec movement_types() :: [atom()]
  def movement_types, do: @movement_types
end
