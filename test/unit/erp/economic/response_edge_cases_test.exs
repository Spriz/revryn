defmodule BillingCore.ERP.Economic.ResponseEdgeCasesTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
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

  defp invoice(overrides \\ []) do
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

  # -- write acknowledgements without usable content ---------------------------

  test "a 2xx create without a draft number is an unknown outcome, not a success" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 201, ~s({})) end)

    assert {:unknown, hint} = Economic.create_draft(context(), invoice(), "op:create:1")
    assert hint.search_by == [{:external_reference, @reference}]
    assert hint.detail =~ "lacked draftInvoiceNumber"
  end

  test "a 2xx create with an empty body is an unknown outcome" do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 201, "") end)

    assert {:unknown, hint} = Economic.create_draft(context(), invoice(), "op:create:1")
    assert hint.search_by == [{:external_reference, @reference}]
  end

  test "non-numeric external ids pass through as strings in the provider body" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:draft_body, Jason.decode!(body, floats: :decimals)})
      json_resp(conn, 201, ~s({}))
    end)

    assert {:unknown, _hint} =
             Economic.create_draft(
               context(),
               invoice(payment_term_external_id: "NET-14"),
               "op:create:1"
             )

    assert_received {:draft_body, body}
    assert body["paymentTerms"] == %{"paymentTermsNumber" => "NET-14"}
  end

  # -- classification fallbacks ------------------------------------------------

  test "auth failures without a provider message fall back to fixed detail" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 401, ~s({})) end)

    assert {:error, {:authentication, detail}} =
             Economic.get_document(context(), {:draft, "9"})

    assert detail == "e-conomic rejected the credentials (401)"
  end

  test "validation without errors or message yields a generic validation error" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 422, ~s({})) end)

    assert {:error, {:validation, [%{message: "validation failed"}]}} =
             Economic.create_draft(context(), invoice(), "op:create:1")
  end

  test "list-shaped provider errors keep every entry, stringifying junk" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(
        conn,
        422,
        ~s({"errors": [{"message": "quantity invalid"}, "period closed", 42]})
      )
    end)

    assert {:error, {:validation, errors}} =
             Economic.create_draft(context(), invoice(), "op:create:1")

    assert errors == [
             %{message: "quantity invalid"},
             %{message: "period closed"},
             %{message: "42"}
           ]
  end

  test "a non-numeric Retry-After header yields retry_after nil" do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "soon")
      |> json_resp(429, ~s({"message": "slow down"}))
    end)

    assert {:error, {:rate_limited, %{retry_after: nil}}} =
             Economic.get_document(context(), {:draft, "9"})
  end
end
