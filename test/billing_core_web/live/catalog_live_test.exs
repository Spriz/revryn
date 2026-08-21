defmodule BillingCoreWeb.CatalogLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.ERP

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    %{conn: log_in_user(conn, scope.user), scope: scope}
  end

  describe "products" do
    test "creates and deactivates a product (BC-US-010)", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/catalog")
      assert has_element?(view, "#no-products")

      view
      |> form("#new-product-form",
        product: %{code: "platform-fee", name: "Platform fee", recognition_mode: "point_in_time"}
      )
      |> render_submit()

      assert has_element?(view, "#products", "platform-fee")

      {:ok, [product]} = BillingCore.Catalog.list_products(scope)

      view |> element("#deactivate-product-#{product.id}") |> render_click()
      assert has_element?(view, "#products", "inactive")
    end

    test "maps a product to an ERP product number (BC-US-012)", %{conn: conn, scope: scope} do
      product = product_fixture(scope)

      {:ok, _connection} =
        ERP.create_connection(scope, %{provider: "fake", secret_reference: "unused"})

      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/catalog")

      view
      |> form("#product-mapping-form",
        mapping: %{product_id: product.id, external_product_number: "SAAS-1"}
      )
      |> render_submit()

      assert has_element?(view, "#products", "SAAS-1")
    end
  end

  describe "plan versions" do
    test "detail renders components read-only and publishes a draft (BC-US-013/014)", %{
      conn: conn,
      scope: scope
    } do
      draft = draft_plan_version_fixture(scope)
      component = fixed_recurring_component_fixture(scope, draft, amount: "99.00")

      {:ok, view, html} =
        live(conn, ~p"/teams/#{scope.team.id}/catalog/plan-versions/#{draft.id}")

      assert html =~ component.code
      assert has_element?(view, "#component-#{component.id}-definition")

      view |> element("#publish-plan-version") |> render_click()

      assert render(view) =~ "published"
      refute has_element?(view, "#publish-plan-version")
    end

    test "publishing an empty draft renders the domain error", %{conn: conn, scope: scope} do
      draft = draft_plan_version_fixture(scope)

      {:ok, view, _html} =
        live(conn, ~p"/teams/#{scope.team.id}/catalog/plan-versions/#{draft.id}")

      assert has_element?(view, "#no-components")

      html = view |> element("#publish-plan-version") |> render_click()

      assert html =~ "at least one price component"
    end

    test "the catalog page links plan versions", %{conn: conn, scope: scope} do
      published = published_plan_version_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/catalog")

      assert has_element?(view, "#plan-version-link-#{published.id}")
    end
  end
end
