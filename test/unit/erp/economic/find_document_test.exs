defmodule BillingCore.ERP.Economic.FindDocumentTest do
  use ExUnit.Case, async: true

  alias BillingCore.ERP.Document
  alias BillingCore.ERP.Economic

  @stub __MODULE__.Stub
  @reference "abc:t1:intent-1:v1"

  defp context do
    %{
      connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
      team_id: "b7f3f0a4-0000-0000-0000-000000000002",
      provider: :economic,
      credentials: %{
        app_secret_token: "app-secret-token-XYZ",
        agreement_grant_token: "grant-token-ABC"
      },
      plug: {Req.Test, @stub}
    }
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp full_payload(kind, number) do
    number_key =
      case kind do
        :draft -> "draftInvoiceNumber"
        :booked -> "bookedInvoiceNumber"
      end

    """
    {
      "#{number_key}": #{number},
      "date": "2026-09-01",
      "currency": "DKK",
      "customer": {"customerNumber": 1001},
      "references": {"other": "#{@reference}"},
      "lines": [
        {"sortKey": 1, "product": {"productNumber": "SETUP"}, "description": "Onboarding setup",
         "quantity": 1, "unitNetPrice": 500.00}
      ]
    }
    """
  end

  test "returns nil when neither drafts nor booked match" do
    Req.Test.stub(@stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:search, conn.request_path, conn.query_params["filter"]})
      json_resp(conn, 200, ~s({"collection": []}))
    end)

    assert {:ok, nil} = Economic.find_document(context(), @reference)

    expected_filter = "references.other$eq:#{@reference}"
    assert_received {:search, "/invoices/drafts", ^expected_filter}
    assert_received {:search, "/invoices/booked", ^expected_filter}
  end

  test "resolves a draft hit through a full fetch" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/invoices/drafts" ->
          json_resp(conn, 200, ~s({"collection": [{"draftInvoiceNumber": 42}]}))

        "/invoices/booked" ->
          json_resp(conn, 200, ~s({"collection": []}))

        "/invoices/drafts/42" ->
          json_resp(conn, 200, full_payload(:draft, 42))
      end
    end)

    assert {:ok, %Document{state: :draft, external_draft_id: "42"} = document} =
             Economic.find_document(context(), @reference)

    assert document.external_reference == @reference
  end

  test "booked wins when both collections match" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/invoices/drafts" ->
          json_resp(conn, 200, ~s({"collection": [{"draftInvoiceNumber": 42}]}))

        "/invoices/booked" ->
          json_resp(conn, 200, ~s({"collection": [{"bookedInvoiceNumber": 1077}]}))

        "/invoices/booked/1077" ->
          json_resp(conn, 200, full_payload(:booked, 1077))
      end
    end)

    assert {:ok, %Document{state: :booked, external_booked_number: "1077"}} =
             Economic.find_document(context(), @reference)
  end

  test "get_document by external reference errors with not_found when absent" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 200, ~s({"collection": []}))
    end)

    assert {:error, {:not_found, _detail}} =
             Economic.get_document(context(), {:external_reference, @reference})
  end
end
