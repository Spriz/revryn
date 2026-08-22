defmodule BillingCoreWeb.TeamScopeTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.ContractsFixtures
  import BillingCore.IdentityFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  describe "team scope resolution (SPEC §13.4, INV-024/025)" do
    test "a team member reaches the team overview", %{conn: conn} do
      scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

      {:ok, _view, html} =
        conn
        |> log_in_user(scope.user)
        |> live(~p"/teams/#{scope.team.id}")

      assert html =~ scope.team.name
    end

    test "a non-member is redirected home without detail", %{conn: conn} do
      scope = billing_scope_fixture()
      outsider = user_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               conn
               |> log_in_user(outsider)
               |> live(~p"/teams/#{scope.team.id}")
    end

    test "a member of another team in no shared organization is redirected", %{conn: conn} do
      scope = billing_scope_fixture()
      other_scope = billing_scope_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               conn
               |> log_in_user(other_scope.user)
               |> live(~p"/teams/#{scope.team.id}")
    end

    test "an unauthenticated visitor is sent to sign-in", %{conn: conn} do
      scope = billing_scope_fixture()

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(conn, ~p"/teams/#{scope.team.id}")
    end

    test "a garbage team id redirects home", %{conn: conn} do
      scope = billing_scope_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               conn
               |> log_in_user(scope.user)
               |> live("/teams/not-a-uuid")
    end

    test "mounting without a team_id param halts home (defensive hook clause)" do
      # No router path reaches the hook without `:team_id`; the clause guards
      # against a route added under the hook without the param.
      user = user_fixture()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_user: user}
      }

      assert {:halt, halted} =
               BillingCoreWeb.TeamScope.on_mount(:default, %{}, %{}, socket)

      assert {:redirect, %{to: "/"}} = halted.redirected
      assert Phoenix.Flash.get(halted.assigns.flash, :error) =~ "do not have access"
    end
  end
end
