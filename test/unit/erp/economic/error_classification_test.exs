defmodule BillingCore.ERP.Economic.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Economic

  @stub __MODULE__.Stub
  @app_secret "app-secret-token-XYZ"
  @grant_token "grant-token-ABC"

  defp context do
    %{
      connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
      team_id: "b7f3f0a4-0000-0000-0000-000000000002",
      provider: :economic,
      credentials: %{app_secret_token: @app_secret, agreement_grant_token: @grant_token},
      plug: {Req.Test, @stub}
    }
  end

  defp invoice do
    %CanonicalInvoice{
      external_reference: "abc:t1:intent-1:v1",
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

  defp stub_status(status, body \\ ~s({"message": "provider says no"}), headers \\ []) do
    Req.Test.stub(@stub, fn conn ->
      headers
      |> Enum.reduce(conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  test "401 maps to authentication" do
    stub_status(401)

    assert {:error, {:authentication, "provider says no"}} =
             Economic.get_document(context(), {:draft, "9"})
  end

  test "403 maps to authorization" do
    stub_status(403)

    assert {:error, {:authorization, "provider says no"}} =
             Economic.get_document(context(), {:draft, "9"})
  end

  test "400 maps to validation with extracted field errors" do
    stub_status(
      400,
      ~s({"message": "Validation failed", "errors": ) <>
        ~s({"lines[0].unitNetPrice": [{"message": "Too many decimals"}]}})
    )

    assert {:error, {:validation, errors}} =
             Economic.create_draft(context(), invoice(), "op:create:x")

    assert errors == [%{field: "lines[0].unitNetPrice", message: "Too many decimals"}]
  end

  test "400 without field errors falls back to the provider message" do
    stub_status(400, ~s({"message": "Malformed body"}))

    assert {:error, {:validation, [%{message: "Malformed body"}]}} =
             Economic.create_draft(context(), invoice(), "op:create:x")
  end

  test "404 maps to not_found" do
    stub_status(404)

    assert {:error, {:not_found, "provider says no"}} =
             Economic.get_document(context(), {:booked, "1077"})
  end

  test "409 maps to conflict" do
    stub_status(409)

    assert {:error, {:conflict, "provider says no"}} =
             Economic.create_draft(context(), invoice(), "op:create:x")
  end

  test "429 maps to rate_limited with Retry-After seconds" do
    stub_status(429, ~s({"message": "slow down"}), [{"retry-after", "17"}])

    assert {:error, {:rate_limited, %{retry_after: 17}}} =
             Economic.get_document(context(), {:draft, "9"})
  end

  test "429 without Retry-After yields retry_after nil" do
    stub_status(429, ~s({"message": "slow down"}))

    assert {:error, {:rate_limited, %{retry_after: nil}}} =
             Economic.get_document(context(), {:draft, "9"})
  end

  test "5xx maps to provider_failure with the status" do
    stub_status(500, ~s({"message": "boom"}))

    assert {:error, {:provider_failure, 500}} =
             Economic.get_document(context(), {:draft, "9"})
  end

  test "transport errors on reads map to provider_failure" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:provider_failure, :timeout}} =
             Economic.get_document(context(), {:draft, "9"})
  end

  test "credential values never appear in returned error terms" do
    stub_status(401, ~s({"message": "authentication failed"}))

    read_result = Economic.get_document(context(), {:draft, "9"})
    write_result = Economic.create_draft(context(), invoice(), "op:create:x")

    for result <- [read_result, write_result] do
      rendered = inspect(result, limit: :infinity, printable_limit: :infinity)
      refute rendered =~ @app_secret
      refute rendered =~ @grant_token
    end
  end
end
