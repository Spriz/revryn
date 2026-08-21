defmodule BillingCore.Usage.PartitionWorker do
  @moduledoc """
  Maintenance worker keeping `billing.usage_events` monthly partitions
  created ahead of time (SPEC §13.1: at least two months ahead by an
  idempotent maintenance job).

  Calls `BillingCore.Usage.ensure_partitions/1` for the current month through
  `months_ahead` months (default 2). Scheduling (cron) is wired separately;
  the worker itself is idempotent and safe to run at any frequency.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 5

  alias BillingCore.Usage

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    months_ahead = Map.get(args, "months_ahead", Usage.default_months_ahead())
    {:ok, _partitions} = Usage.ensure_partitions(months_ahead)
    :ok
  end
end
