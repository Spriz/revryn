defmodule BillingCore.Outbox do
  @moduledoc """
  Transactional outbox for versioned domain events (SPEC §11.7, §15,
  INV-048/049).

  Events are appended in the same transaction as the domain change and later
  relayed by the outbox consumer. Event types are past-tense versioned facts,
  e.g. `invoice_intent.frozen.v1`.
  """

  import Ecto.Query

  alias BillingCore.Repo
  alias BillingCore.Outbox.Event

  defmodule Event do
    @moduledoc false
    use Ecto.Schema

    @schema_prefix "billing"
    @primary_key {:id, Ecto.UUID, autogenerate: true}
    schema "outbox_events" do
      field :event_type, :string
      field :occurred_at, :utc_datetime_usec
      field :team_id, Ecto.UUID
      field :aggregate_type, :string
      field :aggregate_id, Ecto.UUID
      field :aggregate_version, :integer
      field :correlation_id, Ecto.UUID
      field :causation_id, Ecto.UUID
      field :payload, :map
      field :published_at, :utc_datetime_usec
      field :publish_attempts, :integer
      field :created_at, :utc_datetime_usec
    end
  end

  @event_type_format ~r/^[a-z0-9_]+(\.[a-z0-9_]+)+\.v\d+$/

  @doc """
  Appends a domain event to the outbox in the current transaction.

  Required opts: `:aggregate` (`{type, id}`). Optional: `:team_id`,
  `:aggregate_version`, `:correlation_id`, `:causation_id`, `:payload`.
  """
  @spec emit!(String.t(), keyword()) :: Event.t()
  def emit!(event_type, opts) do
    unless Regex.match?(@event_type_format, event_type) do
      raise ArgumentError,
            "event type must be a past-tense versioned fact like " <>
              "`invoice_intent.frozen.v1`, got: #{inspect(event_type)}"
    end

    {aggregate_type, aggregate_id} = Keyword.fetch!(opts, :aggregate)

    # Coalesced relay job commits with the event (SPEC §12.7 step 5).
    %{} |> BillingCore.Outbox.RelayWorker.new() |> Oban.insert!()

    Repo.insert!(%Event{
      event_type: event_type,
      occurred_at: DateTime.utc_now(),
      team_id: Keyword.get(opts, :team_id),
      aggregate_type: to_string(aggregate_type),
      aggregate_id: aggregate_id,
      aggregate_version: Keyword.get(opts, :aggregate_version),
      correlation_id: Keyword.get(opts, :correlation_id),
      causation_id: Keyword.get(opts, :causation_id),
      payload: Keyword.get(opts, :payload, %{}),
      publish_attempts: 0
    })
  end

  @doc "Unpublished events in occurrence order, for the relay worker."
  @spec pending(pos_integer()) :: [Event.t()]
  def pending(limit \\ 100) do
    Event
    |> where([e], is_nil(e.published_at))
    |> order_by([e], asc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Marks an event published."
  @spec mark_published!(Event.t()) :: Event.t()
  def mark_published!(%Event{} = event) do
    event
    |> Ecto.Changeset.change(
      published_at: DateTime.utc_now(),
      publish_attempts: event.publish_attempts + 1
    )
    |> Repo.update!()
  end
end
