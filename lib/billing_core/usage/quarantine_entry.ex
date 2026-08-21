defmodule BillingCore.Usage.QuarantineEntry do
  @moduledoc """
  Usage event held back by ingestion policy instead of being silently
  discarded (BC-US-050, SPEC §18.5 `manual_review`).

  One row per `(team, external_event_id)`. `payload` keeps the canonical
  submitted payload for later review/replay; `resolved_at` is set when
  finance resolves the entry or a later re-submission of the same external
  event ID is accepted. `received_at` is PostgreSQL clock time.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @reasons ~w(too_old too_far_future unknown_subscription unknown_metric oversized_properties)

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "usage_quarantine" do
    field :team_id, Ecto.UUID
    field :external_event_id, :string
    field :reason, :string
    field :payload, :map, default: %{}
    field :received_at, :utc_datetime_usec, read_after_writes: true
    field :resolved_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Valid quarantine reasons (mirrors the database check constraint)."
  def reasons, do: @reasons
end
