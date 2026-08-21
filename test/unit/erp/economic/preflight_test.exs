defmodule BillingCore.ERP.Economic.PreflightTest do
  use ExUnit.Case, async: true

  alias BillingCore.ERP.Economic

  @stub __MODULE__.Stub

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
        team_id: "b7f3f0a4-0000-0000-0000-000000000002",
        provider: :economic,
        credentials: %{
          app_secret_token: "app-secret-token-XYZ",
          agreement_grant_token: "grant-token-ABC"
        },
        plug: {Req.Test, @stub}
      },
      extra
    )
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  @self_payload """
  {
    "agreementNumber": 123456,
    "baseCurrency": "DKK",
    "modules": [{"name": "Accruals"}, {"name": "Invoicing"}],
    "application": {"requiredRoles": [{"name": "Sales"}, {"name": "Bookkeeping"}]}
  }
  """

  @accounting_years """
  {
    "collection": [
      {"year": "2025", "fromDate": "2025-01-01", "toDate": "2025-12-31", "closed": true},
      {"year": "2026", "fromDate": "2026-01-01", "toDate": "2026-12-31", "closed": false}
    ]
  }
  """

  defp stub_happy_provider do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, @self_payload)
        "/layouts/21" -> json_resp(conn, 200, ~s({"layoutNumber": 21}))
        "/payment-terms/14" -> json_resp(conn, 200, ~s({"paymentTermsNumber": 14}))
        "/products/SAAS-ANNUAL" -> json_resp(conn, 200, ~s({"productNumber": "SAAS-ANNUAL"}))
        "/products/GONE" -> json_resp(conn, 404, ~s({"message": "No such product"}))
        "/customers/1001" -> json_resp(conn, 200, ~s({"customerNumber": 1001}))
        "/accounting-years" -> json_resp(conn, 200, @accounting_years)
      end
    end)
  end

  test "capabilities are static and complete" do
    assert {:ok, capabilities} = Economic.capabilities(context())

    assert capabilities == %{
             supports_draft_invoices: true,
             supports_draft_updates: true,
             supports_booking: true,
             supports_invoice_webhooks: true,
             supports_line_accrual_periods: true,
             supports_customer_provisioning: true,
             supported_delivery_modes: [:none, :email, :einvoice],
             amount_scale: 2,
             quantity_scale: 2
           }
  end

  test "preflight runs all checks and collects evidence" do
    stub_happy_provider()

    input = %{
      product_external_ids: ["SAAS-ANNUAL"],
      customer_external_ids: ["1001"],
      required_dates: [~D[2026-09-15]]
    }

    mappings = %{mappings: %{layout_external_id: "21", payment_term_external_id: "14"}}

    assert {:ok, result} = Economic.preflight(context(mappings), input)

    by_check = Enum.group_by(result.checks, & &1.check)

    assert [%{status: :pass, detail: agreement_detail}] = by_check[:agreement]
    assert agreement_detail =~ "123456"
    assert agreement_detail =~ "DKK"
    assert [%{status: :pass}] = by_check[:modules]
    assert [%{status: :pass}] = by_check[:roles]
    assert [%{status: :pass}] = by_check[:layout]
    assert [%{status: :pass}] = by_check[:payment_terms]
    assert [%{status: :pass}] = by_check[:product]
    assert [%{status: :pass}] = by_check[:customer]
    assert [%{status: :pass, detail: period_detail}] = by_check[:accounting_periods]
    assert period_detail =~ "open accounting year 2026"

    assert result.capabilities.supports_line_accrual_periods
    assert result.evidence.agreement_number == "123456"
    assert result.evidence.base_currency == "DKK"
    assert length(result.evidence.accounting_years) == 2
  end

  test "a missing product fails its own check without failing the preflight" do
    stub_happy_provider()

    assert {:ok, result} =
             Economic.preflight(context(), %{product_external_ids: ["SAAS-ANNUAL", "GONE"]})

    product_checks = Enum.filter(result.checks, &(&1.check == :product))
    assert [%{status: :pass}, %{status: :fail, detail: detail}] = product_checks
    assert detail =~ "GONE"
  end

  test "a date in a closed year fails; a missing closed flag warns" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" ->
          json_resp(conn, 200, @self_payload)

        "/accounting-years" ->
          json_resp(conn, 200, """
          {
            "collection": [
              {"year": "2025", "fromDate": "2025-01-01", "toDate": "2025-12-31", "closed": true},
              {"year": "2026", "fromDate": "2026-01-01", "toDate": "2026-12-31"}
            ]
          }
          """)
      end
    end)

    assert {:ok, result} =
             Economic.preflight(context(), %{required_dates: [~D[2025-06-01], ~D[2026-06-01]]})

    period_checks = Enum.filter(result.checks, &(&1.check == :accounting_periods))
    assert [%{status: :fail}, %{status: :warn}] = period_checks
  end

  test "authentication failure aborts the preflight entirely" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 401, ~s({"message": "authentication failed"}))
    end)

    assert {:error, {:authentication, _detail}} = Economic.preflight(context(), %{})
  end
end
