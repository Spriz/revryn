defmodule BillingCoreWeb.PageControllerTest do
  use BillingCoreWeb.ConnCase, async: true

  test "GET / redirects unauthenticated visitors to sign-in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/sign-in"
  end

  test "the home action renders the welcome page" do
    # PageController has no route (the root path serves DashboardLive), so
    # the action is invoked through the controller's plug pipeline directly.
    conn =
      build_conn(:get, "/")
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> Phoenix.Controller.put_format("html")
      |> BillingCoreWeb.PageController.call(BillingCoreWeb.PageController.init(:home))

    assert html_response(conn, 200) =~ "Phoenix Framework"
  end
end
