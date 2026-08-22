defmodule BillingCore.ERP.Economic.ReferenceResolutionTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
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

  defp invoice do
    %CanonicalInvoice{
      external_reference: @reference,
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Example ApS", vat_zone_external_id: "1"},
      payment_term_external_id: "14",
      layout_external_id: "21",
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

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  # -- update_draft by external reference ------------------------------------

  test "update_draft by external reference resolves the draft and PUTs it" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/invoices/drafts"} ->
          json_resp(conn, 200, ~s({"collection": [{"draftInvoiceNumber": 42}]}))

        {"GET", "/invoices/booked"} ->
          json_resp(conn, 200, ~s({"collection": []}))

        {"GET", "/invoices/drafts/42"} ->
          json_resp(conn, 200, full_payload(:draft, 42))

        {"PUT", "/invoices/drafts/42"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:put_body, Jason.decode!(body, floats: :decimals)})
          json_resp(conn, 200, full_payload(:draft, 42))
      end
    end)

    assert {:ok, %Document{state: :draft, external_draft_id: "42"}} =
             Economic.update_draft(
               context(),
               {:external_reference, @reference},
               invoice(),
               "op:update:1"
             )

    assert_received {:put_body, body}
    assert body["draftInvoiceNumber"] == 42
  end

  test "update_draft by reference of an already-booked invoice conflicts" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/invoices/drafts" ->
          json_resp(conn, 200, ~s({"collection": []}))

        "/invoices/booked" ->
          json_resp(conn, 200, ~s({"collection": [{"bookedInvoiceNumber": 1077}]}))

        "/invoices/booked/1077" ->
          json_resp(conn, 200, full_payload(:booked, 1077))
      end
    end)

    assert {:error, {:conflict, detail}} =
             Economic.update_draft(
               context(),
               {:external_reference, @reference},
               invoice(),
               "op:update:1"
             )

    assert detail =~ "1077"
  end

  test "update_draft by an unknown reference is not_found" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 200, ~s({"collection": []}))
    end)

    assert {:error, {:not_found, detail}} =
             Economic.update_draft(
               context(),
               {:external_reference, @reference},
               invoice(),
               "op:update:1"
             )

    assert detail =~ @reference
  end

  test "search failures propagate as classified errors for update and get by reference" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 500, ~s({"message": "boom"}))
    end)

    assert {:error, {:provider_failure, 500}} =
             Economic.update_draft(
               context(),
               {:external_reference, @reference},
               invoice(),
               "op:update:1"
             )

    assert {:error, {:provider_failure, 500}} =
             Economic.get_document(context(), {:external_reference, @reference})
  end

  test "a transport loss during the PUT itself is an unknown outcome carrying both refs" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:unknown, hint} =
             Economic.update_draft(context(), {:draft, "99"}, invoice(), "op:update:1")

    assert {:draft, "99"} in hint.search_by
    assert {:external_reference, @reference} in hint.search_by
    assert hint.detail =~ "timeout"
  end

  # -- find/get by external reference ----------------------------------------

  test "get_document by reference uses a complete search hit without refetching" do
    Req.Test.stub(@stub, fn conn ->
      send(self(), {:request, conn.request_path})

      case conn.request_path do
        "/invoices/drafts" ->
          json_resp(conn, 200, ~s({"collection": [#{full_payload(:draft, 42)}]}))

        "/invoices/booked" ->
          json_resp(conn, 200, ~s({"collection": []}))
      end
    end)

    assert {:ok, %Document{state: :draft, external_draft_id: "42"} = document} =
             Economic.get_document(context(), {:external_reference, @reference})

    assert document.external_reference == @reference

    assert_received {:request, "/invoices/drafts"}
    assert_received {:request, "/invoices/booked"}
    refute_received {:request, _other}
  end

  test "a search hit without an invoice number is a provider failure" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/invoices/drafts" -> json_resp(conn, 200, ~s({"collection": [{"note": "corrupt"}]}))
        "/invoices/booked" -> json_resp(conn, 200, ~s({"collection": []}))
      end
    end)

    assert {:error, {:provider_failure, detail}} =
             Economic.find_document(context(), @reference)

    assert detail =~ "lacked an invoice number"
  end

  test "a transport failure during search is a provider failure" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:provider_failure, :timeout}} =
             Economic.find_document(context(), @reference)
  end

  # -- booking outcomes -------------------------------------------------------

  test "a 2xx booking response without a booked number is an unknown outcome" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:booking_body, Jason.decode!(body)})
      json_resp(conn, 200, ~s({}))
    end)

    # Integer draft ids are accepted and serialized as provider numbers.
    assert {:unknown, hint} =
             Economic.book_document(context(), {:draft, 421}, %{delivery_mode: :none}, "op:1")

    assert hint.search_by == [{:draft, "421"}]
    assert hint.detail =~ "lacked bookedInvoiceNumber"

    assert_received {:booking_body, body}
    assert body == %{"draftInvoice" => %{"draftInvoiceNumber" => 421}}
  end

  test "booked but failing read-back is unknown with the booked number first" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/invoices/booked"} ->
          json_resp(conn, 201, ~s({"bookedInvoiceNumber": 1077}))

        {"GET", "/invoices/booked/1077"} ->
          json_resp(conn, 500, ~s({"message": "boom"}))
      end
    end)

    assert {:unknown, hint} =
             Economic.book_document(context(), {:draft, "421"}, %{delivery_mode: :none}, "op:1")

    assert [{:booked, "1077"}, {:draft, "421"}] = hint.search_by
    assert hint.detail =~ "read-back failed"
  end

  test "a booking rejection classifies like any provider error" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 422, ~s({"message": "Accounting period closed"}))
    end)

    assert {:error, {:validation, [%{message: "Accounting period closed"}]}} =
             Economic.book_document(context(), {:draft, "421"}, %{delivery_mode: :none}, "op:1")
  end

  # -- book_document by external reference -----------------------------------

  test "book_document by reference resolves the draft and books it" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/invoices/drafts"} ->
          json_resp(conn, 200, ~s({"collection": [{"draftInvoiceNumber": 42}]}))

        {"GET", "/invoices/booked"} ->
          json_resp(conn, 200, ~s({"collection": []}))

        {"GET", "/invoices/drafts/42"} ->
          json_resp(conn, 200, full_payload(:draft, 42))

        {"POST", "/invoices/booked"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:booking_body, Jason.decode!(body)})
          json_resp(conn, 201, ~s({"bookedInvoiceNumber": 1077}))

        {"GET", "/invoices/booked/1077"} ->
          json_resp(conn, 200, full_payload(:booked, 1077))
      end
    end)

    assert {:ok, %Document{state: :booked, external_booked_number: "1077"}} =
             Economic.book_document(
               context(),
               {:external_reference, @reference},
               %{delivery_mode: :none},
               "op:1"
             )

    assert_received {:booking_body, %{"draftInvoice" => %{"draftInvoiceNumber" => 42}}}
  end

  test "book_document by reference of an already-booked invoice conflicts" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/invoices/drafts" ->
          json_resp(conn, 200, ~s({"collection": []}))

        "/invoices/booked" ->
          json_resp(conn, 200, ~s({"collection": [{"bookedInvoiceNumber": 1077}]}))

        "/invoices/booked/1077" ->
          json_resp(conn, 200, full_payload(:booked, 1077))
      end
    end)

    assert {:error, {:conflict, detail}} =
             Economic.book_document(
               context(),
               {:external_reference, @reference},
               %{delivery_mode: :none},
               "op:1"
             )

    assert detail =~ "already booked as 1077"
  end

  test "book_document by an unknown reference is not_found" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 200, ~s({"collection": []}))
    end)

    assert {:error, {:not_found, detail}} =
             Economic.book_document(
               context(),
               {:external_reference, @reference},
               %{delivery_mode: :none},
               "op:1"
             )

    assert detail =~ @reference
  end

  test "book_document by reference propagates search failures" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 500, ~s({"message": "boom"}))
    end)

    assert {:error, {:provider_failure, 500}} =
             Economic.book_document(
               context(),
               {:external_reference, @reference},
               %{delivery_mode: :none},
               "op:1"
             )
  end
end
