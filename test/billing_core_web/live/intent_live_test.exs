defmodule BillingCoreWeb.IntentLiveTest do
  @moduledoc """
  Invoice-intent page over the real sync pipeline: the fake ERP stands in at
  the network boundary; PostgreSQL, contexts, durable operations, and Oban
  jobs are real (SPEC §23.7). Async: false — Oban queues are drained inline
  and the fake ERP context lives in application env.
  """

  use BillingCoreWeb.ConnCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{Billing, Catalog, Contracts}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP
  alias BillingCore.ERP.{FakeERP, Sync}

  setup %{conn: conn} do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    product =
      product_fixture(scope, %{
        recognition_mode: :over_time,
        service_period_source: :billing_period
      })

    plan_version =
      published_plan_version_fixture(scope,
        product: product,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 12,
        billing_timing: :in_advance,
        amount: "120000.00",
        component_code: "annual-platform"
      )

    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, connection} = ERP.validate_connection(scope, connection)

    customer = customer_fixture(scope, %{legal_name: "Example ApS"})

    {:ok, _} =
      Contracts.upsert_customer_erp_mapping(scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    {:ok, _} =
      Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "SAAS-ANNUAL"
      })

    contract =
      contract_fixture(scope, %{
        customer_id: customer.id,
        currency: "DKK",
        start_date: ~D[2026-01-01]
      })

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-09-15],
        quantity: Decimal.new(1)
      })

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-15])
    {:ok, frozen} = Preview.freeze(scope, preview)
    {:ok, intent} = Billing.get_intent(scope, frozen.id)

    %{
      conn: log_in_user(conn, scope.user),
      scope: scope,
      fake: fake,
      intent: intent,
      path: "/teams/#{scope.team.id}/invoices/#{intent.id}"
    }
  end

  test "frozen intent renders lines, traces, hash, and history", %{
    conn: conn,
    path: path,
    intent: intent
  } do
    {:ok, view, html} = live(conn, path)

    assert html =~ "Example ApS"
    assert html =~ "120,000.00 DKK"
    assert has_element?(view, "#intent-state-badge", "frozen")
    assert has_element?(view, "#intent-lines")
    [line] = intent.lines
    assert has_element?(view, "#line-#{line.id}-trace")
    assert has_element?(view, "#intent-transitions", "freeze")
    assert has_element?(view, "#synchronize-button")
    assert has_element?(view, "#erp-document-card", "Not synchronized yet")
  end

  test "synchronize → approve → book → credit walk the lifecycle (BC-US-081/084/085/102)",
       %{conn: conn, path: path, intent: intent} do
    {:ok, view, _html} = live(conn, path)

    # Synchronize: durable operation + worker → reconciled draft
    view |> element("#synchronize-button") |> render_click()
    assert has_element?(view, "#intent-state-badge", "sync pending")

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    relay_events()

    # The domain-event broadcast refreshes the page without navigation.
    assert has_element?(view, "#intent-state-badge", "erp draft")
    assert has_element?(view, "#approve-form")
    assert has_element?(view, "#erp-document-card", "Last reconciled")

    # Approve with a reason (BC-US-084)
    view
    |> form("#approve-form", approve: %{reason: "finance review"})
    |> render_submit()

    assert has_element?(view, "#intent-state-badge", "approved")
    assert has_element?(view, "#book-button")

    # Book (BC-US-085)
    view |> element("#book-button") |> render_click()
    assert has_element?(view, "#intent-state-badge", "booking pending")

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    relay_events()

    assert has_element?(view, "#intent-state-badge", "erp booked")
    assert has_element?(view, "#booked-number")

    # Full credit (BC-US-102): compensating credit note, never mutation
    view
    |> form("#full-credit-form", credit: %{reason: "wrong customer PO"})
    |> render_submit()

    {credit_path, flash} = assert_redirect(view)
    assert flash["info"] =~ "Credit note created"

    {:ok, credit_view, credit_html} = live(conn, credit_path)
    assert credit_html =~ "credit_note"
    assert credit_html =~ "-120,000.00 DKK"
    assert has_element?(credit_view, "#correction-cases")

    # The original intent shows the correction case and remains booked —
    # the correction is a compensating document, never a mutation.
    {:ok, original_view, _html} = live(conn, path)
    assert has_element?(original_view, "#correction-cases", "full_credit")
    assert Billing.intent_state(intent) == "erp_booked"
  end

  test "partial credit allocates per line (BC-US-103)", %{
    conn: conn,
    path: path,
    scope: scope,
    intent: intent
  } do
    book_intent!(scope, intent)

    {:ok, view, _html} = live(conn, path)
    [line] = intent.lines

    view
    |> form("#partial-credit-form", %{
      "partial" => %{"reason" => "goodwill"},
      "amounts" => %{line.line_key => "1000.00"}
    })
    |> render_submit()

    {credit_path, _flash} = assert_redirect(view)
    {:ok, _credit_view, credit_html} = live(conn, credit_path)
    assert credit_html =~ "-1,000.00 DKK"
  end

  test "a duplicate synchronize click flashes instead of crashing (SPEC §23.6)", %{
    conn: conn,
    path: path,
    scope: scope,
    intent: intent
  } do
    {:ok, view, _html} = live(conn, path)

    # The state advances behind this view's back…
    {:ok, _operation} = Sync.request_synchronization(scope, intent)

    # …and the stale button click is rejected gracefully.
    html = view |> element("#synchronize-button") |> render_click()
    assert html =~ "no longer available"
    assert has_element?(view, "#intent-state-badge", "sync pending")
  end

  test "supersede rebuilds from a fresh preview (BC-US-100)", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#supersede-button")
    view |> element("#supersede-button") |> render_click()

    {replacement_path, flash} = assert_redirect(view)
    assert flash["info"] =~ "superseded"

    {:ok, replacement_view, html} = live(conn, replacement_path)
    assert html =~ "intent v2"
    assert has_element?(replacement_view, "#intent-state-badge", "frozen")

    # The superseded original still renders, immutable, with its history.
    {:ok, original_view, _html} = live(conn, path)
    assert has_element?(original_view, "#intent-state-badge", "superseded")
    refute has_element?(original_view, "#synchronize-button")
    assert {:ok, entries} = BillingCore.Billing.list_intents(scope, state: "superseded")
    assert length(entries) == 1
  end

  # Oban's unique window can coalesce relay jobs across drains in a fast
  # test; running the relay directly publishes pending outbox events and
  # broadcasts them on the team topic.
  defp relay_events do
    :ok = BillingCore.Outbox.RelayWorker.perform(%Oban.Job{})
  end

  defp book_intent!(scope, intent) do
    {:ok, _op} = Sync.request_synchronization(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "test")
    {:ok, _op} = Sync.request_booking(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert Billing.intent_state(intent) == "erp_booked"
  end
end
