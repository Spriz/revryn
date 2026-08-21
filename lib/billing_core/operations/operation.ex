defmodule BillingCore.Operations.Operation do
  @moduledoc """
  Durable operation row (SPEC §22.9.2). The authoritative user-visible
  lifecycle for asynchronous work; Oban job state is linked execution detail
  and may be pruned independently (SPEC §11.3).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(queued executing succeeded retry_scheduled outcome_unknown reconciling blocked failed)
  @error_classes ~w(transient throttled dependency_unavailable validation authorization conflict outcome_unknown poison terminal)

  schema "operations" do
    field :team_id, Ecto.UUID
    field :organization_id, Ecto.UUID
    field :type, :string
    field :state, :string, default: "queued"
    field :actor_type, :string
    field :actor_id, :string
    field :target_type, :string
    field :target_id, Ecto.UUID
    field :correlation_id, Ecto.UUID
    field :causation_id, Ecto.UUID
    field :idempotency_key_hash, :string
    field :attempt_count, :integer, default: 0
    field :error_class, :string
    field :safe_error_code, :string
    field :safe_error_summary, :string
    field :next_attempt_at, :utc_datetime_usec
    field :blocked_reason, :string
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :version, :integer, default: 1

    timestamps()
  end

  def states, do: @states
  def error_classes, do: @error_classes

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :team_id,
      :organization_id,
      :type,
      :actor_type,
      :actor_id,
      :target_type,
      :target_id,
      :correlation_id,
      :causation_id,
      :idempotency_key_hash,
      :metadata
    ])
    |> validate_required([:type, :actor_type])
    |> validate_format(:type, ~r/^[a-z0-9_.]+$/)
  end

  @doc false
  def update_changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :state,
      :attempt_count,
      :error_class,
      :safe_error_code,
      :safe_error_summary,
      :next_attempt_at,
      :blocked_reason,
      :metadata,
      :started_at,
      :finished_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:error_class, @error_classes ++ [nil])
    |> optimistic_lock(:version)
  end
end
