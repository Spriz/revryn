defmodule BillingCoreWeb.AdminDashboardTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.IdentityFixtures
  import BillingCoreWeb.WebHelpers

  describe "/admin/dashboard (LiveDashboard behind platform-admin auth)" do
    test "a platform admin reaches the dashboard", %{conn: conn} do
      admin = user_fixture(%{platform_admin: true})

      conn = conn |> log_in_user(admin) |> get("/admin/dashboard")

      assert redirected_to(conn) == "/admin/dashboard/home"

      conn = conn |> recycle() |> log_in_user(admin) |> get("/admin/dashboard/home")
      assert html_response(conn, 200) =~ "Dashboard"
    end

    test "a regular user is turned away", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_user(user) |> get("/admin/dashboard")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Platform administrator"
    end

    test "an unauthenticated visitor is sent to sign-in", %{conn: conn} do
      conn = get(conn, "/admin/dashboard")
      assert redirected_to(conn) == "/sign-in"
    end
  end
end
