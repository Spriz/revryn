defmodule BillingCore.Credits.CloseWorker do
  @moduledoc "Oban executor for durable customer-credit close ERP operations."

  use Oban.Worker, queue: :erp, max_attempts: 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sync_operation_id" => sync_operation_id}}) do
    BillingCore.Credits.ClosePosting.execute(sync_operation_id)
  end
end
