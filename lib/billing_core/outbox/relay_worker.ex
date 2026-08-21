defmodule BillingCore.Outbox.RelayWorker do
  @moduledoc """
  Publishes committed outbox events (SPEC §12.7 steps 7–8).

  Events are broadcast on Phoenix.PubSub topic `"domain_events"` (and a
  team-scoped `"domain_events:<team_id>"` topic) for LiveView refresh and
  in-process consumers, then marked published. Delivery is at-least-once;
  consumers must be idempotent (INV-015).
  """

  use Oban.Worker,
    queue: :outbox,
    max_attempts: 10,
    unique: [period: 5]

  alias BillingCore.Outbox

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for event <- Outbox.pending(200) do
      payload = {:domain_event, event.event_type, event}

      Phoenix.PubSub.broadcast(BillingCore.PubSub, "domain_events", payload)

      if event.team_id do
        Phoenix.PubSub.broadcast(BillingCore.PubSub, "domain_events:#{event.team_id}", payload)
      end

      :telemetry.execute(
        [:billing_core, :outbox, :published],
        %{count: 1},
        %{event_type: event.event_type}
      )

      Outbox.mark_published!(event)
    end

    :ok
  end
end
