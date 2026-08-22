defmodule BillingCore.ERP.Economic.PreflightDegradedTest do
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

  defp check(result, name), do: Enum.filter(result.checks, &(&1.check == name))

  defp empty_years(conn), do: json_resp(conn, 200, ~s({"collection": []}))

  test "a non-auth /self failure degrades the agreement check without aborting" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 500, ~s({"message": "boom"}))
        "/accounting-years" -> empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :fail, detail: detail}] = check(result, :agreement)
    assert detail =~ "status 500"
    assert [%{status: :pass, detail: period_detail}] = check(result, :accounting_periods)
    assert period_detail =~ "0 accounting year(s) visible"
    assert result.evidence == %{accounting_years: []}
  end

  test "a transport failure on /self degrades the agreement check without aborting" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> Req.Test.transport_error(conn, :econnrefused)
        "/accounting-years" -> empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :fail, detail: detail}] = check(result, :agreement)
    assert detail =~ "econnrefused"
  end

  test "modules reported as bare strings pass; junk entries and missing roles degrade gracefully" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" ->
          json_resp(conn, 200, ~s({"agreementNumber": 1, "modules": ["Accruals", 42]}))

        "/accounting-years" ->
          empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :pass, detail: "modules: Accruals"}] = check(result, :modules)
    assert [%{status: :warn, detail: roles_detail}] = check(result, :roles)
    assert roles_detail =~ "did not report application roles"
    assert result.evidence.modules == ["Accruals"]
  end

  test "absent modules warn; roles render strings and numbers alike" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" ->
          json_resp(
            conn,
            200,
            ~s({"agreementNumber": 1, "application": ) <>
              ~s({"requiredRoles": [{"name": "Sales"}, "Bookkeeping", 7.5]}})
          )

        "/accounting-years" ->
          empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :warn, detail: modules_detail}] = check(result, :modules)
    assert modules_detail =~ "did not report modules"
    assert [%{status: :pass, detail: roles_detail}] = check(result, :roles)
    assert roles_detail =~ "Sales, Bookkeeping, 7.5"
  end

  test "modules without Accruals warn about over-time lines" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" ->
          json_resp(conn, 200, ~s({"agreementNumber": 1, "modules": [{"name": "Invoicing"}]}))

        "/accounting-years" ->
          empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :warn, detail: detail}] = check(result, :modules)
    assert detail =~ "Accruals module not reported"
    assert detail =~ "Invoicing"
  end

  test "a 403 on a mapping check aborts the preflight as authorization" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/layouts/21" -> json_resp(conn, 403, ~s({"message": "no access"}))
      end
    end)

    mappings = %{mappings: %{layout_external_id: "21"}}

    assert {:error, {:authorization, "no access"}} =
             Economic.preflight(context(mappings), %{})
  end

  test "a 401 on a resource check aborts the preflight as authentication" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/customers/1001" -> json_resp(conn, 401, ~s({"message": "expired grant"}))
      end
    end)

    assert {:error, {:authentication, "expired grant"}} =
             Economic.preflight(context(), %{customer_external_ids: ["1001"]})
  end

  test "a non-auth resource lookup failure fails only that check" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/products/P1" -> json_resp(conn, 500, ~s({"message": "boom"}))
        "/accounting-years" -> empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{product_external_ids: ["P1"]})

    assert [%{status: :fail, detail: detail}] = check(result, :product)
    assert detail =~ "lookup failed with status 500"
  end

  test "a transport failure on a resource lookup fails only that check" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/products/P1" -> Req.Test.transport_error(conn, :timeout)
        "/accounting-years" -> empty_years(conn)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{product_external_ids: ["P1"]})

    assert [%{status: :fail, detail: detail}] = check(result, :product)
    assert detail =~ "lookup failed: timeout"
  end

  test "empty id lists produce no resource checks at all" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/accounting-years" -> empty_years(conn)
      end
    end)

    assert {:ok, result} =
             Economic.preflight(context(), %{
               product_external_ids: [],
               customer_external_ids: []
             })

    assert check(result, :product) == []
    assert check(result, :customer) == []
  end

  test "a non-auth /accounting-years failure degrades the period check" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/accounting-years" -> json_resp(conn, 503, ~s({"message": "maintenance"}))
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :fail, detail: detail}] = check(result, :accounting_periods)
    assert detail =~ "status 503"
  end

  test "a transport failure on /accounting-years degrades the period check" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" -> json_resp(conn, 200, ~s({"agreementNumber": 1}))
        "/accounting-years" -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{status: :fail, detail: detail}] = check(result, :accounting_periods)
    assert detail =~ "timeout"
  end

  test "a date outside every visible accounting year fails its period check" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" ->
          json_resp(conn, 200, ~s({"agreementNumber": 1}))

        "/accounting-years" ->
          json_resp(
            conn,
            200,
            ~s({"collection": [{"year": "2026", "fromDate": "2026-01-01", ) <>
              ~s("toDate": "2026-12-31", "closed": false}]})
          )
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{required_dates: [~D[2024-06-01]]})

    assert [%{status: :fail, detail: detail}] = check(result, :accounting_periods)
    assert detail =~ "falls in no visible accounting year"
  end

  test "accounting years with unparsable or missing dates are dropped from evidence" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/self" ->
          json_resp(conn, 200, ~s({"agreementNumber": 1}))

        "/accounting-years" ->
          json_resp(
            conn,
            200,
            ~s({"collection": [) <>
              ~s({"year": "2026", "fromDate": "2026-01-01", "toDate": "2026-12-31"}, ) <>
              ~s({"year": "2027", "fromDate": "not-a-date", "toDate": "2027-12-31"}, ) <>
              ~s({"year": "2028"}]})
          )
      end
    end)

    assert {:ok, result} = Economic.preflight(context(), %{})

    assert [%{year: "2026"}] = result.evidence.accounting_years
  end
end
