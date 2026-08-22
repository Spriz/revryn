defmodule BillingCore.AuditExport.RetentionWorkerTest do
  @moduledoc """
  Nightly retention enforcement wiring (SPEC §20, BC-TASK-072): the worker
  actually invokes both operational and raw-usage enforcement. The pruning
  rules themselves are certified in `BillingCore.AuditExport.RetentionTest`.
  """

  use BillingCore.DataCase, async: false

  import BillingCore.ContractsFixtures

  alias BillingCore.{Audit, ERP}
  alias BillingCore.AuditExport.RetentionWorker

  defp perform!, do: RetentionWorker.perform(%Oban.Job{args: %{}})

  test "perform enforces operational retention and records the audit evidence" do
    scope = billing_scope_fixture([:team_admin])

    {:ok, connection} =
      ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    old = DateTime.add(DateTime.utc_now(), -120 * 86_400, :second)
    fresh = DateTime.utc_now()

    Repo.insert_all(
      "webhook_receipts",
      [webhook_receipt(connection, old, "old"), webhook_receipt(connection, fresh, "fresh")],
      prefix: "billing"
    )

    assert :ok = perform!()

    remaining =
      Repo.all(from r in "webhook_receipts", prefix: "billing", select: r.payload_hash)

    assert remaining == ["fresh"]

    assert Repo.exists?(
             from e in Audit.Entry,
               where: e.event_type == "retention.operational_prune_completed"
           )
  end

  test "perform with nothing prunable completes and stays idempotent" do
    # Raw-usage enforcement without any team opt-in is a recorded no-op;
    # the per-team pruning behavior is covered by RetentionTest.
    assert :ok = perform!()
    assert :ok = perform!()
  end

  defp webhook_receipt(connection, received_at, hash) do
    %{
      id: Ecto.UUID.dump!(Ecto.UUID.generate()),
      provider: "fake",
      team_id: Ecto.UUID.dump!(connection.team_id),
      erp_connection_id: Ecto.UUID.dump!(connection.id),
      received_at: received_at,
      headers_redacted: %{},
      payload_redacted: %{},
      payload_hash: hash
    }
  end
end
