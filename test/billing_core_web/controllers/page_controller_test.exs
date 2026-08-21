defmodule BillingCoreWeb.PageControllerTest do
  use BillingCoreWeb.ConnCase, async: true

  test "GET / redirects unauthenticated visitors to sign-in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/sign-in"
  end
end
