defmodule BillingCore.ERP.Economic.BookAndUpdateTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Document
  alias BillingCore.ERP.Economic

  @stub __MODULE__.Stub
  @reference "abc:t1:intent-1:v1"
  @operation_key "op:book:intent-1:v1:attempt-1"

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

  defp invoice do
    %CanonicalInvoice{
      external_reference: @reference,
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Example ApS"},
      invoice_date: ~D[2026-09-01],
      currency: "DKK",
      lines: [
        %Line{
          order: 0,
          line_key: "l1",
          product_external_id: "SETUP",
          description: "Onboarding setup",
          amount: Money.new!("DKK", 50_000),
          recognition: :point_in_time
        }
      ]
    }
  end

  @booked_payload """
  {
    "bookedInvoiceNumber": 1077,
    "date": "2026-09-01",
    "currency": "DKK",
    "customer": {"customerNumber": 1001},
    "references": {"other": "abc:t1:intent-1:v1"},
    "lines": [
      {"sortKey": 1, "product": {"productNumber": "SETUP"}, "description": "Onboarding setup",
       "quantity": 1, "unitNetPrice": 500.00}
    ]
  }
  """

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  test "books a draft with sendBy for email delivery and returns the booked document" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/invoices/booked"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:booking_request, conn, body})
          json_resp(conn, 201, ~s({"bookedInvoiceNumber": 1077}))

        {"GET", "/invoices/booked/1077"} ->
          json_resp(conn, 200, @booked_payload)
      end
    end)

    assert {:ok, %Document{state: :booked, external_booked_number: "1077"}} =
             Economic.book_document(
               context(),
               {:draft, "421"},
               %{delivery_mode: :email},
               @operation_key
             )

    assert_received {:booking_request, conn, raw_body}
    assert Plug.Conn.get_req_header(conn, "idempotency-key") == [@operation_key]

    assert Jason.decode!(raw_body) == %{
             "draftInvoice" => %{"draftInvoiceNumber" => 421},
             "sendBy" => "email"
           }
  end

  test "omits sendBy for delivery mode none and maps einvoice to ean" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/invoices/booked"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:booking_body, Jason.decode!(body)})
          json_resp(conn, 201, ~s({"bookedInvoiceNumber": 1077}))

        {"GET", "/invoices/booked/1077"} ->
          json_resp(conn, 200, @booked_payload)
      end
    end)

    assert {:ok, _document} =
             Economic.book_document(context(), {:draft, "421"}, %{delivery_mode: :none}, "op:1")

    assert_received {:booking_body, none_body}
    refute Map.has_key?(none_body, "sendBy")

    assert {:ok, _document} =
             Economic.book_document(
               context(),
               {:draft, "421"},
               %{delivery_mode: :einvoice},
               "op:2"
             )

    assert_received {:booking_body, einvoice_body}
    assert einvoice_body["sendBy"] == "ean"
  end

  test "transport timeout on booking returns unknown with searchable refs" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:unknown, hint} =
             Economic.book_document(
               context(),
               {:draft, "421"},
               %{delivery_mode: :none, external_reference: @reference},
               @operation_key
             )

    assert {:draft, "421"} in hint.search_by
    assert {:external_reference, @reference} in hint.search_by
  end

  test "booking a booked ref is a conflict" do
    assert {:error, {:conflict, _detail}} =
             Economic.book_document(context(), {:booked, "1077"}, %{delivery_mode: :none}, "op:1")
  end

  test "update_draft does a full PUT replacement and 404 maps to not_found" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:update_request, conn, Jason.decode!(body, floats: :decimals)})
      json_resp(conn, 404, ~s({"message": "Draft not found"}))
    end)

    assert {:error, {:not_found, "Draft not found"}} =
             Economic.update_draft(context(), {:draft, "99"}, invoice(), "op:update:1")

    assert_received {:update_request, conn, body}
    assert conn.method == "PUT"
    assert conn.request_path == "/invoices/drafts/99"
    assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["op:update:1"]
    assert body["draftInvoiceNumber"] == 99
    assert body["references"] == %{"other" => @reference}
    assert [%{"unitNetPrice" => unit}] = body["lines"]
    assert unit == Decimal.new("500.00")
  end

  test "update_draft of a booked ref is a conflict" do
    assert {:error, {:conflict, _detail}} =
             Economic.update_draft(context(), {:booked, "1077"}, invoice(), "op:update:2")
  end
end
