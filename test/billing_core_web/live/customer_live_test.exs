defmodule BillingCoreWeb.CustomerLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.ContractsFixtures
  import BillingCore.OrgsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{Credits, Orgs}
  alias BillingCore.ERP

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  describe "index" do
    test "shows an empty state, then created customers", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/customers")
      assert has_element?(view, "#no-customers")

      view
      |> form("#new-customer-form",
        customer: %{
          external_id: "cust-ui-1",
          legal_name: "Acme ApS",
          email: "billing@acme.example",
          country: "DK"
        }
      )
      |> render_submit()

      assert has_element?(view, "#customers", "cust-ui-1")
      refute has_element?(view, "#no-customers")
    end

    test "rejects an invalid country with a flash, not a crash", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/customers")

      html =
        view
        |> form("#new-customer-form",
          customer: %{
            external_id: "cust-bad",
            legal_name: "Bad Country",
            email: "x@example.com",
            country: "Denmark"
          }
        )
        |> render_submit()

      assert html =~ "country"
      refute has_element?(view, "#customers", "cust-bad")
    end
  end

  describe "show" do
    test "renders version history and records a new version on edit", %{
      conn: conn,
      scope: scope
    } do
      customer = customer_fixture(scope, %{legal_name: "Before ApS"})

      {:ok, view, html} = live(conn, ~p"/teams/#{scope.team.id}/customers/#{customer.id}")

      assert html =~ "Before ApS"
      assert has_element?(view, "#customer-version-1")

      view
      |> form("#edit-customer-form", customer: %{legal_name: "After ApS"})
      |> render_submit()

      assert has_element?(view, "#customer-version-2", "After ApS")
    end

    test "an unchanged edit is an idempotent no-op", %{conn: conn, scope: scope} do
      customer = customer_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/customers/#{customer.id}")

      html = view |> form("#edit-customer-form") |> render_submit()

      assert html =~ "already up to date"
      refute has_element?(view, "#customer-version-2")
    end

    test "upserts the ERP customer mapping (BC-US-031)", %{conn: conn, scope: scope} do
      customer = customer_fixture(scope)

      {:ok, _connection} =
        ERP.create_connection(scope, %{provider: "fake", secret_reference: "unused"})

      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/customers/#{customer.id}")

      view
      |> form("#customer-mapping-form", mapping: %{external_customer_number: "1001"})
      |> render_submit()

      assert has_element?(view, "#customer-mappings", "1001")
    end

    test "shows linked credit-account balances (BC-US-108)", %{conn: conn, scope: scope} do
      customer = customer_fixture(scope)
      account = account_fixture(scope.organization)
      {:ok, _projection} = Orgs.project_account_to_team(account, scope.team, customer.id)
      {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")

      {:ok, _grant} =
        Credits.grant_credit(scope, %{
          credit_account_id: credit_account.id,
          origin_type: "manual",
          amount_minor: 25_000,
          currency: "DKK",
          idempotency_key: "ui-grant-1"
        })

      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/customers/#{customer.id}")

      assert has_element?(view, "#credit-account-#{credit_account.id}", "250.00 DKK")
    end

    test "another team's customer is not reachable", %{conn: conn, scope: scope} do
      other_scope = billing_scope_fixture()
      other_customer = customer_fixture(other_scope)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/teams/#{scope.team.id}/customers/#{other_customer.id}")

      assert to == "/teams/#{scope.team.id}/customers"
    end
  end
end
