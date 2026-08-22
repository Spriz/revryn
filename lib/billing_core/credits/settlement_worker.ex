defmodule BillingCore.Credits.SettlementWorker do
  @moduledoc "Oban executor for durable receivable-settlement ERP operations."

  use Oban.Worker, queue: :erp, max_attempts: 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sync_operation_id" => sync_operation_id}}) do
    BillingCore.Credits.SettlementPosting.execute(sync_operation_id)
  end
end
