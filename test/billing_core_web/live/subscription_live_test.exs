defmodule BillingCoreWeb.SubscriptionLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.Contracts

  setup %{conn: conn} do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    plan_version =
      published_plan_version_fixture(scope,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        billing_timing: :in_advance,
        amount: "500.00"
      )

    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id, currency: "DKK"})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.utc_today(),
        quantity: Decimal.new(2)
      })

    %{
      conn: log_in_user(conn, scope.user),
      scope: scope,
      subscription: subscription,
      path: "/teams/#{scope.team.id}/subscriptions/#{subscription.id}"
    }
  end

  test "index lists the subscription", %{conn: conn, scope: scope, subscription: subscription} do
    {:ok, view, _html} = live(conn, ~p"/teams/#{scope.team.id}/subscriptions")
    assert has_element?(view, "#subscriptions", subscription.external_id)
  end

  test "detail renders versions and change history", %{conn: conn, path: path} do
    {:ok, view, html} = live(conn, path)

    assert has_element?(view, "#subscription-version-1")
    assert has_element?(view, "#subscription-changes", "start")
    assert html =~ "Invoice preview"
  end

  describe "actions" do
    test "change quantity appends a version (BC-US-036)", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#change-quantity-form", quantity: %{quantity: "5"})
      |> render_submit()

      assert has_element?(view, "#subscription-version-2", "5")
      assert has_element?(view, "#subscription-changes", "quantity_change")
    end

    test "an invalid quantity flashes instead of crashing", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      html =
        view
        |> form("#change-quantity-form", quantity: %{quantity: ""})
        |> render_submit()

      assert html =~ "valid quantity"
      refute has_element?(view, "#subscription-version-2")
    end

    test "pause then resume (BC-US-039)", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      view |> element("#pause-subscription") |> render_click()
      assert has_element?(view, "#resume-subscription")

      view |> element("#resume-subscription") |> render_click()
      assert has_element?(view, "#pause-subscription")
    end

    test "end-of-period cancellation requires the period end date", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      html =
        view
        |> form("#cancel-form", cancel: %{mode: "end_of_period", period_end_date: ""})
        |> render_submit()

      assert html =~ "period end date"

      period_end = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()

      view
      |> form("#cancel-form", cancel: %{mode: "end_of_period", period_end_date: period_end})
      |> render_submit()

      assert has_element?(view, "#subscription-changes", "cancel")
      assert render(view) =~ "pending cancellation"
    end
  end

  describe "invoice preview (BC-US-068/069)" do
    test "renders lines, totals, and traces for the billing period", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#preview-form", preview: %{date: Date.to_iso8601(Date.utc_today())})
      |> render_submit()

      assert has_element?(view, "#preview-lines")
      assert has_element?(view, "#preview-totals", "1,000.00 DKK")
      assert has_element?(view, "#preview-line-0-trace")
      assert has_element?(view, "#freeze-button")
    end

    test "freeze redirects to the new intent page", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#preview-form", preview: %{date: Date.to_iso8601(Date.utc_today())})
      |> render_submit()

      view |> element("#freeze-button") |> render_click()

      {redirect_path, flash} = assert_redirect(view)
      assert redirect_path =~ ~r"^/teams/#{scope.team.id}/invoices/"
      assert flash["info"] =~ "frozen"
    end

    test "a date without an effective version flashes an error", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      html =
        view
        |> form("#preview-form",
          preview: %{date: Date.utc_today() |> Date.add(-30) |> Date.to_iso8601()}
        )
        |> render_submit()

      assert html =~ "No subscription version is effective"
    end
  end
end
