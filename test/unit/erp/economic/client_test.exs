defmodule BillingCore.ERP.Economic.ClientTest do
  use ExUnit.Case, async: true

  alias BillingCore.ERP.Economic.Client

  @stub __MODULE__.Stub

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        credentials: %{app_secret_token: "secret-token", agreement_grant_token: "grant-token"},
        plug: {Req.Test, @stub}
      },
      extra
    )
  end

  test "missing credential values are sent as empty header values, never dropped" do
    Req.Test.stub(@stub, fn conn ->
      send(self(), {:headers, conn})
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert {:ok, %{status: 200}} = Client.get(context(%{credentials: %{}}), "/self")

    assert_received {:headers, conn}
    assert Plug.Conn.get_req_header(conn, "x-appsecrettoken") == [""]
    assert Plug.Conn.get_req_header(conn, "x-agreementgranttoken") == [""]
  end

  test "monetary JSON numbers decode as Decimals, never binary floats (INV-006)" do
    Req.Test.stub(@stub, fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"grossAmount": 12.34}))
    end)

    assert {:ok, %{status: 200, body: body}} = Client.get(context(), "/invoices/booked/1")
    assert body == %{"grossAmount" => Decimal.new("12.34")}
  end

  test "empty response bodies decode to nil" do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

    assert {:ok, %{status: 204, body: nil}} = Client.get(context(), "/x")
  end

  test "non-JSON bodies are returned raw so callers still see the status" do
    Req.Test.stub(@stub, fn conn ->
      Plug.Conn.send_resp(conn, 502, "<html>bad gateway</html>")
    end)

    assert {:ok, %{status: 502, body: "<html>bad gateway</html>"}} =
             Client.get(context(), "/self")
  end

  # The module adapter replaces the transport entirely, so no real HTTP
  # happens even though these contexts carry no :plug key (covering the
  # plug-less base request branch).
  @adapter BillingCore.ERPTest.EconomicClientStubAdapter

  test "without a plug the request still builds; a pre-decoded body passes through" do
    assert {:ok, %{status: 200, body: %{"already" => "decoded"}}} =
             Client.request(Map.delete(context(), :plug),
               method: :get,
               url: "/pre-decoded",
               adapter: @adapter
             )
  end

  test "non-Req transport exceptions with an atom reason reduce to that atom" do
    assert {:error, {:transport, :nxdomain}} =
             Client.request(Map.delete(context(), :plug),
               method: :get,
               url: "/mint-transport-error",
               adapter: @adapter
             )
  end

  test "exceptions without an atom reason reduce to the struct name, leaking nothing" do
    result =
      Client.request(Map.delete(context(), :plug),
        method: :get,
        url: "/non-transport-error",
        adapter: @adapter
      )

    assert {:error, {:transport, RuntimeError}} = result

    rendered = inspect(result, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ "secret-token"
    refute rendered =~ "grant-token"
  end
end
