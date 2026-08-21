defmodule BillingCore.ERP.PollAllWorker do
  @moduledoc """
  Cron entry point for the §17.12 polling fallback: fans out one
  `BillingCore.ERP.PollWorker` job per active ERP connection.
  """

  use Oban.Worker, queue: :reconciliation, max_attempts: 3, unique: [period: 300]

  import Ecto.Query

  alias BillingCore.ERP.Connection
  alias BillingCore.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    connections =
      Repo.all(from c in Connection, where: c.status == "active", select: c.id)

    for connection_id <- connections do
      %{"erp_connection_id" => connection_id}
      |> BillingCore.ERP.PollWorker.new()
      |> Oban.insert!()
    end

    :ok
  end
end
