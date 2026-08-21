defmodule BillingCoreWeb.ErpWebhookController do
  @moduledoc """
  Untrusted ERP webhook ingress (SPEC §17.11, INV-010).

  The connection is resolved from a high-entropy endpoint token (stored only
  as a hash); the payload is persisted redacted with a hash, deduplicated by
  provider event ID, and answered promptly. A webhook is a hint: it enqueues
  an authoritative provider read and never directly transitions accounting
  state.
  """

  use BillingCoreWeb, :controller

  import Ecto.Query

  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP.{Connection, WebhookReceipt}
  alias BillingCore.Repo

  @max_body_bytes 64 * 1024

  def receive(conn, %{"endpoint_token" => token} = params) do
    payload = Map.drop(params, ["endpoint_token"])

    with {:ok, connection} <- resolve_connection(token),
         :ok <- check_size(payload) do
      persist_receipt(connection, payload)
      send_resp(conn, 200, "ok")
    else
      {:error, :unknown_token} ->
        # Do not reveal which tokens exist.
        send_resp(conn, 404, "not found")

      {:error, :too_large} ->
        send_resp(conn, 413, "payload too large")
    end
  end

  defp resolve_connection(token) do
    token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    case Repo.one(from c in Connection, where: c.webhook_token_hash == ^token_hash) do
      nil -> {:error, :unknown_token}
      connection -> {:ok, connection}
    end
  end

  defp check_size(payload) do
    if byte_size(:erlang.term_to_binary(payload)) > @max_body_bytes,
      do: {:error, :too_large},
      else: :ok
  end

  defp persist_receipt(connection, payload) do
    provider_event_id = payload["eventId"] || payload["id"]

    receipt = %WebhookReceipt{
      provider: connection.provider,
      team_id: connection.team_id,
      erp_connection_id: connection.id,
      provider_event_id: provider_event_id && to_string(provider_event_id),
      received_at: DateTime.utc_now(),
      headers_redacted: %{},
      payload_redacted: redact(payload),
      payload_hash: Canonical.hash(payload),
      processing_state: "received"
    }

    case Repo.insert(receipt) do
      {:ok, receipt} ->
        # Hint → authoritative read (INV-010): follow up with a poll of the
        # affected documents.
        %{"erp_connection_id" => connection.id, "receipt_id" => receipt.id}
        |> BillingCore.ERP.PollWorker.new()
        |> Oban.insert!()

        :ok

      {:error, _changeset} ->
        # Duplicate provider event ID — already durably received.
        :ok
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint =~ "webhook_receipts_connection_event_id",
        do: :ok,
        else: reraise(e, __STACKTRACE__)
  end

  # Keep only routing/diagnostic fields; the authoritative read supplies the
  # accounting evidence (SPEC §13.3 webhook_receipts).
  defp redact(payload) do
    Map.take(payload, ["eventType", "event", "draftInvoiceNumber", "bookedInvoiceNumber"])
  end
end
