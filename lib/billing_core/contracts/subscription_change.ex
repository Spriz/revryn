defmodule BillingCore.Contracts.SubscriptionChange do
  @moduledoc """
  Append-only subscription command record (SPEC §13.3 `subscription_changes`).

  Each row evidences one accepted command: type, effective date, the caller's
  idempotency key (unique per subscription), the acting principal, the
  canonical command payload, and its result. Replays compare canonical
  payloads against this record.
  """

  use Ecto.Schema

  alias BillingCore.Contracts.Subscription

  @type t :: %__MODULE__{}

  @change_types [:start, :quantity_change, :plan_change, :pause, :resume, :cancel, :correction]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "subscription_changes" do
    field :team_id, Ecto.UUID
    field :change_type, Ecto.Enum, values: @change_types
    field :effective_date, :date
    field :idempotency_key, :string
    field :actor_reference, :string
    field :payload, :map, default: %{}
    field :result, :map, default: %{}

    belongs_to :subscription, Subscription

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Allowed command types."
  def change_types, do: @change_types
end
