defmodule BillingCore.AuditExport.RetentionWorker do
  @moduledoc """
  Nightly retention enforcement (SPEC §20, BC-TASK-072). Prunes the
  allowlisted operational tables and each team's opted-in billed raw
  usage; financial evidence is structurally out of reach.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _counts = BillingCore.AuditExport.Retention.enforce()
    _usage_counts = BillingCore.AuditExport.Retention.enforce_raw_usage()
    :ok
  end
end
