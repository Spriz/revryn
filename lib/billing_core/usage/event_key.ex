defmodule BillingCore.Usage.EventKey do
  @moduledoc """
  Unpartitioned idempotency reservation for `(team_id, external_event_id)`
  (SPEC §13.3 `usage_event_keys`).

  Inserted first in the ingestion transaction; the unique index is the
  cross-partition uniqueness guard for usage events. Stores the canonical
  payload hash (duplicate-vs-conflict decisions) and the internal event ID
  plus its `occurred_at` partition key for direct partition lookup.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "usage_event_keys" do
    field :team_id, Ecto.UUID
    field :external_event_id, :string
    field :payload_hash, :string
    field :usage_event_id, Ecto.UUID
    field :occurred_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end
end
