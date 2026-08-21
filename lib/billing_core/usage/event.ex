defmodule BillingCore.Usage.Event do
  @moduledoc """
  Immutable usage event payload row (SPEC §13.3 `usage_events`).

  The table is range-partitioned by month on `occurred_at` with composite
  primary key `(occurred_at, id)`; both fields must therefore be set on every
  struct. `received_at` is assigned by PostgreSQL `clock_timestamp()` and
  read back after insert — it is never accepted from callers (frozen cutoffs
  are based on trusted server time).

  `event_kind` is `measurement` or `void`; a void carries no value, points at
  the original via `voids_event_id`, and copies the original's `occurred_at`
  for partition locality. A replacement measurement points back via
  `replacement_for_event_id`. `status` is the only mutable column (a
  lifecycle projection; database triggers reject any other update).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key false

  schema "usage_events" do
    field :occurred_at, :utc_datetime_usec, primary_key: true
    field :id, Ecto.UUID, primary_key: true
    field :team_id, Ecto.UUID
    field :external_event_id, :string
    field :event_kind, Ecto.Enum, values: [:measurement, :void]
    field :subscription_id, Ecto.UUID
    field :metric_code, :string
    field :received_at, :utc_datetime_usec, read_after_writes: true
    field :value, :decimal
    field :properties, :map, default: %{}
    field :payload_hash, :string
    field :status, Ecto.Enum, values: [:effective, :voided, :quarantined], default: :effective
    field :voids_event_id, Ecto.UUID
    field :replacement_for_event_id, Ecto.UUID
  end
end
