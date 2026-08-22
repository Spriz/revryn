defmodule BillingCore.Credits.TerminationDispositionWorker do
  @moduledoc """
  Durable trigger for remaining-credit disposition after a subscription
  cancellation (BC-US-109). Enqueued transactionally with the cancellation;
  unique per subscription so replays converge.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 10,
    unique: [fields: [:args, :worker], period: 60]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id}}) do
    case BillingCore.Credits.TerminationDisposition.evaluate(subscription_id) do
      {:ok, _summary} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
