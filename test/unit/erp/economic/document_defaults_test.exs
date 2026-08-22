defmodule BillingCore.ERP.Economic.DocumentDefaultsTest do
  @moduledoc """
  e-conomic requires `layout`, `paymentTerms`, and `recipient.vatZone` on
  every draft and does not default them from the customer server-side
  (proven by live sandbox certification: 400 "Required properties are
  missing"). When the canonical invoice does not carry them, the adapter
  resolves them from the mapped customer's record; explicit values win.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Economic

  @stub __MODULE__.Stub
  @reference "abc:t1:intent-defaults:v1"

  defp context do
    %{
      connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
      team_id: "b7f3f0a4-0000-0000-0000-000000000002",
      provider: :economic,
      credentials: %{app_secret_token: "app", agreement_grant_token: "grant"},
      plug: {Req.Test, @stub}
    }
  end

  defp invoice(overrides) do
    base = %CanonicalInvoice{
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

    struct!(base, overrides)
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  @customer_body ~s({
    "customerNumber": 1001,
    "layout": {"layoutNumber": 21},
    "paymentTerms": {"paymentTermsNumber": 14},
    "vatZone": {"vatZoneNumber": 1}
  })

  @draft_body ~s({"draftInvoiceNumber": 77, "date": "2026-09-01",
    "currency": "DKK", "references": {"other": "abc:t1:intent-defaults:v1"},
    "recipient": {"name": "Example ApS"}})

  test "missing layout/terms/vatZone are resolved from the mapped customer" do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/customers/1001" ->
          json_resp(conn, 200, @customer_body)

        "/invoices/drafts" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:draft_payload, Jason.decode!(raw)})
          json_resp(conn, 201, @draft_body)

        "/invoices/drafts/77" ->
          json_resp(conn, 200, @draft_body)
      end
    end)

    assert {:ok, _document} = Economic.create_draft(context(), invoice([]), "op:defaults:1")

    assert_receive {:draft_payload, payload}
    assert payload["layout"] == %{"layoutNumber" => 21}
    assert payload["paymentTerms"] == %{"paymentTermsNumber" => 14}
    assert payload["recipient"]["vatZone"] == %{"vatZoneNumber" => 1}
  end

  test "explicit values are never overridden by the customer's defaults" do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/invoices/drafts" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:draft_payload, Jason.decode!(raw)})
          json_resp(conn, 201, @draft_body)

        "/invoices/drafts/77" ->
          json_resp(conn, 200, @draft_body)
      end
    end)

    explicit =
      invoice(
        recipient: %{legal_name: "Example ApS", vat_zone_external_id: "2"},
        payment_term_external_id: "30",
        layout_external_id: "9"
      )

    # No /customers request happens at all (the stub would crash on it).
    assert {:ok, _document} = Economic.create_draft(context(), explicit, "op:defaults:2")

    assert_receive {:draft_payload, payload}
    assert payload["layout"] == %{"layoutNumber" => 9}
    assert payload["paymentTerms"] == %{"paymentTermsNumber" => 30}
    assert payload["recipient"]["vatZone"] == %{"vatZoneNumber" => 2}
  end

  test "a customer without a layout falls back to the agreement's first layout" do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/customers/1001" ->
          json_resp(conn, 200, ~s({
            "customerNumber": 1001,
            "paymentTerms": {"paymentTermsNumber": 14},
            "vatZone": {"vatZoneNumber": 1}
          }))

        "/layouts" ->
          json_resp(conn, 200, ~s({"collection": [{"layoutNumber": 19}]}))

        "/invoices/drafts" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:draft_payload, Jason.decode!(raw)})
          json_resp(conn, 201, @draft_body)

        "/invoices/drafts/77" ->
          json_resp(conn, 200, @draft_body)
      end
    end)

    assert {:ok, _document} = Economic.create_draft(context(), invoice([]), "op:defaults:5")

    assert_receive {:draft_payload, payload}
    assert payload["layout"] == %{"layoutNumber" => 19}
    assert payload["paymentTerms"] == %{"paymentTermsNumber" => 14}
    assert payload["recipient"]["vatZone"] == %{"vatZoneNumber" => 1}
  end

  test "a failing customer lookup classifies like any provider read error" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/customers/1001" -> json_resp(conn, 500, ~s({"message": "boom"}))
      end
    end)

    assert {:error, {:provider_failure, _detail}} =
             Economic.create_draft(context(), invoice([]), "op:defaults:3")
  end

  test "a partially configured invoice fills only the missing fields" do
    parent = self()

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/customers/1001" ->
          json_resp(conn, 200, @customer_body)

        "/invoices/drafts" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:draft_payload, Jason.decode!(raw)})
          json_resp(conn, 201, @draft_body)

        "/invoices/drafts/77" ->
          json_resp(conn, 200, @draft_body)
      end
    end)

    partial = invoice(layout_external_id: "9")

    assert {:ok, _document} = Economic.create_draft(context(), partial, "op:defaults:4")

    assert_receive {:draft_payload, payload}
    assert payload["layout"] == %{"layoutNumber" => 9}
    assert payload["paymentTerms"] == %{"paymentTermsNumber" => 14}
    assert payload["recipient"]["vatZone"] == %{"vatZoneNumber" => 1}
  end
end
