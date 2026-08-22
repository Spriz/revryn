defmodule BillingCore.Credits.Close.Approval do
  @moduledoc "Append-only finance approval evidence bound to a close hash."

  use Ecto.Schema

  alias BillingCore.Credits.Close.Close

  @type t :: %__MODULE__{}
  @actions [:approved, :revoked, :reversal_approved]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_close_approvals" do
    field :team_id, Ecto.UUID
    field :action, Ecto.Enum, values: @actions
    field :actor_type, :string
    field :actor_id, :string
    field :reason, :string
    field :close_hash, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :close, Close

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  def actions, do: @actions
end
