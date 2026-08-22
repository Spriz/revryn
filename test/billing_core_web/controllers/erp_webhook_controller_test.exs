defmodule BillingCoreWeb.ErpWebhookControllerTest do
  @moduledoc """
  Untrusted ERP webhook ingress (SPEC §17.11, INV-010): a webhook is only a
  hint. A known endpoint token records a redacted, hashed receipt and
  enqueues the authoritative provider read; duplicates converge; unknown
  tokens reveal nothing; oversized payloads are refused.
  """

  use BillingCoreWeb.ConnCase, async: false

  import Ecto.Query
  import BillingCore.ContractsFixtures

  alias BillingCore.ERP
  alias BillingCore.ERP.WebhookReceipt
  alias BillingCore.Repo

  setup do
    scope = billing_scope_fixture([:team_admin])
    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    token = "whtok-#{System.unique_integer([:positive])}"
    token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    connection =
      connection
      |> Ecto.Changeset.change(webhook_token_hash: token_hash)
      |> Repo.update!()

    %{connection: connection, token: token}
  end

  defp receipts(connection) do
    Repo.all(from r in WebhookReceipt, where: r.erp_connection_id == ^connection.id)
  end

  defp poll_jobs do
    Repo.all(from job in Oban.Job, where: job.worker == "BillingCore.ERP.PollWorker")
  end

  test "a known token records a redacted receipt and enqueues the authoritative read",
       %{conn: conn, connection: connection, token: token} do
    payload = %{
      "eventId" => "evt-1",
      "eventType" => "invoice.booked",
      "bookedInvoiceNumber" => 1042,
      "customerEmail" => "cfo@example.com"
    }

    conn = post(conn, ~p"/webhooks/erp/#{token}", payload)
    assert response(conn, 200) == "ok"

    assert [receipt] = receipts(connection)
    assert receipt.provider == "fake"
    assert receipt.team_id == connection.team_id
    assert receipt.provider_event_id == "evt-1"
    assert receipt.processing_state == "received"
    assert is_binary(receipt.payload_hash)

    # Only routing/diagnostic fields survive redaction — never the endpoint
    # token or payload fields like customer contact data.
    assert receipt.payload_redacted == %{
             "eventType" => "invoice.booked",
             "bookedInvoiceNumber" => 1042
           }

    assert [job] = poll_jobs()
    assert job.args == %{"erp_connection_id" => connection.id, "receipt_id" => receipt.id}
    assert job.queue == "reconciliation"
  end

  test "a replayed provider event converges on one durable receipt",
       %{conn: conn, connection: connection, token: token} do
    payload = %{"eventId" => "evt-dup", "eventType" => "invoice.booked"}

    assert post(conn, ~p"/webhooks/erp/#{token}", payload) |> response(200) == "ok"
    assert post(conn, ~p"/webhooks/erp/#{token}", payload) |> response(200) == "ok"

    assert [_receipt] = receipts(connection)
    # Only the first receipt triggers the follow-up read.
    assert [_job] = poll_jobs()
  end

  test "events without a provider event ID are still recorded, never dropped",
       %{conn: conn, connection: connection, token: token} do
    assert post(conn, ~p"/webhooks/erp/#{token}", %{"eventType" => "draft.updated"})
           |> response(200) == "ok"

    assert post(conn, ~p"/webhooks/erp/#{token}", %{"eventType" => "draft.updated"})
           |> response(200) == "ok"

    receipts = receipts(connection)
    assert length(receipts) == 2
    assert Enum.all?(receipts, &is_nil(&1.provider_event_id))
    assert length(poll_jobs()) == 2
  end

  test "an `id` field is accepted as the provider event identifier",
       %{conn: conn, connection: connection, token: token} do
    assert post(conn, ~p"/webhooks/erp/#{token}", %{"id" => 987, "eventType" => "x"})
           |> response(200) == "ok"

    assert [receipt] = receipts(connection)
    assert receipt.provider_event_id == "987"
  end

  test "an unknown token answers 404 without recording or revealing anything",
       %{conn: conn} do
    conn = post(conn, ~p"/webhooks/erp/not-a-real-token", %{"eventId" => "evt-x"})

    assert response(conn, 404) == "not found"
    assert Repo.aggregate(WebhookReceipt, :count) == 0
    assert poll_jobs() == []
  end

  test "an oversized payload is refused before persistence",
       %{conn: conn, connection: connection, token: token} do
    payload = %{"eventType" => "x", "blob" => String.duplicate("a", 70_000)}

    conn = post(conn, ~p"/webhooks/erp/#{token}", payload)

    assert response(conn, 413) == "payload too large"
    assert receipts(connection) == []
    assert poll_jobs() == []
  end

  # The controller's `{:error, _changeset}` insert branch and the
  # non-matching-constraint reraise are unreachable through the endpoint: the
  # receipt is inserted as a plain struct, so the only constraint that can
  # fire is the partial unique index on (connection, provider_event_id),
  # which raises `Ecto.ConstraintError` and is absorbed by the rescue clause
  # exercised in the replay test above.
end
