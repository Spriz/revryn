defmodule BillingCore.ERP.PollAllWorkerTest do
  @moduledoc """
  §17.12 polling fallback scheduler: the cron tick fans out exactly one
  `PollWorker` job per active ERP connection — never for connections that
  are not yet validated or no longer active.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.ContractsFixtures

  alias BillingCore.ERP
  alias BillingCore.ERP.PollAllWorker

  defp perform!, do: PollAllWorker.perform(%Oban.Job{args: %{}})

  defp poll_jobs do
    Repo.all(from job in Oban.Job, where: job.worker == "BillingCore.ERP.PollWorker")
  end

  test "fans out one poll job per active connection, skipping non-active ones" do
    scope = billing_scope_fixture([:team_admin])

    {:ok, active} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "ref-a"})
    active = active |> change(status: "active") |> Repo.update!()

    {:ok, _unvalidated} =
      ERP.create_connection(scope, %{provider: "economic", secret_reference: "ref-b"})

    assert :ok = perform!()

    assert [job] = poll_jobs()
    assert job.args == %{"erp_connection_id" => active.id}
    assert job.queue == "reconciliation"
  end

  test "no active connections is a clean no-op" do
    scope = billing_scope_fixture([:team_admin])
    {:ok, _unvalidated} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    assert :ok = perform!()
    assert poll_jobs() == []
  end
end
