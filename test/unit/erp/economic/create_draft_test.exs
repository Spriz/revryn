defmodule BillingCore.ERP.Economic.CreateDraftTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Document
  alias BillingCore.ERP.Economic

  @stub __MODULE__.Stub
  @operation_key "op:create:intent-1:v1:attempt-1"
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

  defp invoice(overrides \\ []) do
    base = %CanonicalInvoice{
      external_reference: @reference,
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{
        legal_name: "Example ApS",
        address: "Hovedgaden 1",
        zip: "8000",
        city: "Aarhus",
        country: "DK",
        vat_zone_external_id: "1"
      },
      invoice_date: ~D[2026-09-01],
      currency: "DKK",
      payment_term_external_id: "14",
      layout_external_id: "21",
      delivery_mode: :none,
      lines: [
        %Line{
          order: 0,
          line_key: "sub:1:annual:2026-09-15",
          product_external_id: "SAAS-ANNUAL",
          description: "Annual platform subscription — 2026-09-15 to 2027-09-14",
          amount: Money.new!("DKK", 12_000_000),
          recognition: {:over_time, Period.new!(~D[2026-09-15], ~D[2027-09-15])}
        },
        %Line{
          order: 1,
          line_key: "setup:1",
          product_external_id: "SETUP",
          description: "Onboarding setup",
          amount: Money.new!("DKK", 50_000),
          recognition: :point_in_time
        }
      ]
    }

    struct!(base, overrides)
  end

  @complete_draft_response """
  {
    "draftInvoiceNumber": 421,
    "date": "2026-09-01",
    "currency": "DKK",
    "customer": {"customerNumber": 1001},
    "recipient": {
      "name": "Example ApS",
      "address": "Hovedgaden 1",
      "zip": "8000",
      "city": "Aarhus",
      "country": "DK",
      "vatZone": {"vatZoneNumber": 1}
    },
    "paymentTerms": {"paymentTermsNumber": 14},
    "layout": {"layoutNumber": 21},
    "references": {"other": "abc:t1:intent-1:v1"},
    "lines": [
      {
        "sortKey": 1,
        "product": {"productNumber": "SAAS-ANNUAL"},
        "description": "Annual platform subscription — 2026-09-15 to 2027-09-14",
        "quantity": 1.0,
        "unitNetPrice": 120000.00,
        "accrual": {"startDate": "2026-09-15", "endDate": "2027-09-14"}
      },
      {
        "sortKey": 2,
        "product": {"productNumber": "SETUP"},
        "description": "Onboarding setup",
        "quantity": 1.0,
        "unitNetPrice": 500.00
      }
    ]
  }
  """

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  test "posts the full §17.4/§17.5 mapped body in one request and normalizes the response" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:draft_request, conn, body})
      json_resp(conn, 201, @complete_draft_response)
    end)

    assert {:ok, %Document{} = document} =
             Economic.create_draft(context(), invoice(), @operation_key)

    assert_received {:draft_request, conn, raw_body}

    assert conn.method == "POST"
    assert conn.request_path == "/invoices/drafts"

    # Auth and idempotency headers (SPEC §17.2, §17.7).
    assert Plug.Conn.get_req_header(conn, "x-appsecrettoken") == ["app-secret-token-XYZ"]
    assert Plug.Conn.get_req_header(conn, "x-agreementgranttoken") == ["grant-token-ABC"]
    assert Plug.Conn.get_req_header(conn, "idempotency-key") == [@operation_key]

    # Exact outgoing body. Money travels as bare JSON numbers, decoded here
    # with floats: :decimals so the assertion is float-free (INV-006).
    assert Jason.decode!(raw_body, floats: :decimals) == %{
             "date" => "2026-09-01",
             "currency" => "DKK",
             "customer" => %{"customerNumber" => 1001},
             "recipient" => %{
               "name" => "Example ApS",
               "address" => "Hovedgaden 1",
               "zip" => "8000",
               "city" => "Aarhus",
               "country" => "DK",
               "vatZone" => %{"vatZoneNumber" => 1}
             },
             "paymentTerms" => %{"paymentTermsNumber" => 14},
             "layout" => %{"layoutNumber" => 21},
             "references" => %{"other" => @reference},
             "lines" => [
               %{
                 "sortKey" => 1,
                 "product" => %{"productNumber" => "SAAS-ANNUAL"},
                 "description" => "Annual platform subscription — 2026-09-15 to 2027-09-14",
                 "quantity" => 1,
                 "unitNetPrice" => Decimal.new("120000.00"),
                 "accrual" => %{"startDate" => "2026-09-15", "endDate" => "2027-09-14"}
               },
               %{
                 "sortKey" => 2,
                 "product" => %{"productNumber" => "SETUP"},
                 "description" => "Onboarding setup",
                 "quantity" => 1,
                 "unitNetPrice" => Decimal.new("500.00")
               }
             ]
           }

    # Normalized document from the (complete) creation response.
    assert document.state == :draft
    assert document.external_draft_id == "421"
    assert document.external_reference == @reference
    assert document.customer_external_id == "1001"
    assert [line_one, line_two] = document.lines
    assert line_one.amount == Money.new!("DKK", 12_000_000)
    assert line_one.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}
    assert line_two.recognition == :point_in_time
  end

  test "credit notes send negative unitNetPrice amounts" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:credit_request, body})
      json_resp(conn, 201, @complete_draft_response)
    end)

    credit_note =
      invoice(
        document_type: :credit_note,
        lines: [
          %Line{
            order: 0,
            line_key: "credit:1",
            product_external_id: "SETUP",
            description: "Credit: Onboarding setup",
            amount: Money.new!("DKK", 50_000),
            recognition: :point_in_time
          }
        ]
      )

    assert {:ok, %Document{}} = Economic.create_draft(context(), credit_note, @operation_key)

    assert_received {:credit_request, raw_body}
    assert %{"lines" => [line]} = Jason.decode!(raw_body, floats: :decimals)
    assert line["unitNetPrice"] == Decimal.new("-500.00")
    refute Map.has_key?(line, "accrual")
  end

  test "fetches the draft back when the creation response is incomplete" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/invoices/drafts"} ->
          json_resp(conn, 201, ~s({"draftInvoiceNumber": 421}))

        {"GET", "/invoices/drafts/421"} ->
          json_resp(conn, 200, @complete_draft_response)
      end
    end)

    assert {:ok, %Document{state: :draft, external_draft_id: "421"}} =
             Economic.create_draft(context(), invoice(), @operation_key)
  end

  test "transport timeout on the write returns unknown with the external reference to search by" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:unknown, hint} = Economic.create_draft(context(), invoice(), @operation_key)
    assert {:external_reference, @reference} in hint.search_by
    assert hint.detail =~ "timeout"
  end

  test "read-back failure after a successful write is unknown, not an error" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/invoices/drafts"} ->
          json_resp(conn, 201, ~s({"draftInvoiceNumber": 421}))

        {"GET", "/invoices/drafts/421"} ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:unknown, hint} = Economic.create_draft(context(), invoice(), @operation_key)
    assert {:draft, "421"} in hint.search_by
    assert {:external_reference, @reference} in hint.search_by
  end
end
