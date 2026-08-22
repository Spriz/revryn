defmodule BillingCore.DemoWorkspaceScenarioTest do
  @moduledoc """
  Workflow documentation for the guided Northstar scenario (BC-US-166,
  SPEC §34): the demo workspace builds its commercial model through the
  ordinary catalog/contract commands, drives the first invoice through the
  ordinary preview/freeze/sync/approve/book commands against the
  connection-scoped fake ERP, derives journey state exclusively from durable
  rows, and survives interruption, provider restart, and provider failure.
  """

  use BillingCore.DataCase, async: false

  import BillingCore.IdentityFixtures

  alias BillingCore.{Catalog, Contracts, Credits, Demo, Operations}
  alias BillingCore.Billing.Preview
  alias BillingCore.Credits.Close, as: CloseKernel
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.Demo.{FakeERPInstances, Scenario}
  alias BillingCore.ERP.FakeERP
  alias BillingCore.ERP.FakeERP.InstanceSupervisor
  alias BillingCore.ERP.Sync

  setup do
    user = user_fixture()
    {:ok, bundle} = Demo.start_workspace(user)

    on_exit(fn -> stop_if_running(bundle.connection.id) end)

    %{user: user, bundle: bundle, scope: bundle.scope}
  end

  test "the commercial model builds idempotently through ordinary commands and records refs",
       %{user: user, bundle: bundle, scope: scope} do
    assert %{commercial: %{state: :not_started}, invoice: %{state: :locked}} =
             Scenario.status(bundle)

    assert {:ok, refs} = Scenario.build_commercial_model(bundle)

    # Real catalog/contract rows exist, created by the ordinary commands.
    {:ok, [product]} = Catalog.list_products(scope)
    assert product.code == "northstar-platform"
    assert product.recognition_mode == :over_time

    anchor = Scenario.anchor_date(bundle.workspace)

    {:ok, subscription} =
      Contracts.get_subscription_by_external_id(scope, "northstar-subscription")

    assert subscription.id == refs["subscription_id"]
    assert subscription.start_date == anchor

    # Completion is recorded on the workspace as artifact references.
    {:ok, resumed} = Demo.active_workspace(user)
    assert resumed.workspace.progress["commercial_model"] == refs

    # Re-running converges on the same artifacts without duplication.
    assert {:ok, ^refs} = Scenario.build_commercial_model(bundle)
    assert {:ok, [_product]} = Catalog.list_products(scope)
    {:ok, customers} = Contracts.list_customers(scope)
    assert [%{external_id: "northstar-fjordlys", current_version: 1}] = customers

    assert %{commercial: %{state: :complete}, invoice: %{state: :not_started}} =
             Scenario.status(bundle)
  end

  test "an interrupted commercial build resumes without duplicating artifacts",
       %{bundle: bundle, scope: scope} do
    # Interruption left only the product behind (created through the same
    # ordinary command the scenario uses).
    {:ok, _product} =
      Catalog.create_product(scope, %{
        code: "northstar-platform",
        name: "Northstar Platform",
        recognition_mode: :over_time,
        service_period_source: :billing_period
      })

    assert %{commercial: %{state: :partial}} = Scenario.status(bundle)

    assert {:ok, _refs} = Scenario.build_commercial_model(bundle)

    {:ok, products} = Catalog.list_products(scope)
    assert length(products) == 1
    assert %{commercial: %{state: :complete}} = Scenario.status(bundle)
  end

  test "the first invoice books in the connection-scoped provider with authoritative read-back",
       %{user: user, bundle: bundle, scope: scope} do
    # Activation evidence: first-time step completions emit their
    # time-from-workspace-start measurement (BC-US-166).
    parent = self()
    handler_id = "demo-activation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:billing_core, :demo, :step_completed],
        fn _event, measurements, metadata, _config ->
          send(parent, {:activation, metadata.step, measurements.seconds_since_start})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, refs} = Scenario.build_commercial_model(bundle)
    assert_receive {:activation, "commercial_model", seconds} when is_integer(seconds)
    anchor = Scenario.anchor_date(bundle.workspace)
    service_end = Date.shift(anchor, month: 12)

    # Ordinary preview → freeze, exactly as the subscription page runs it.
    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    assert preview.blockers == []
    assert [line] = preview.lines
    assert line.amount_minor == 12_000_000
    assert line.service_start == anchor
    assert line.service_end_exclusive == service_end
    {:ok, intent} = Preview.freeze(scope, preview)

    assert {:ok, %{invoice: %{state: :frozen}}} = Scenario.observe(bundle)

    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    assert %{invoice: %{state: :sync_pending}} = Scenario.status(bundle)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert {:ok, %{invoice: %{state: :erp_draft} = draft_phase}} = Scenario.observe(bundle)
    assert draft_phase.refs["external_draft_number"]

    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "demo walkthrough")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    assert %{invoice: %{state: :booking_pending}} = Scenario.status(bundle)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    assert {:ok, %{invoice: %{state: :erp_booked, refs: booked_refs}}} = Scenario.observe(bundle)
    assert booked_refs["external_booked_number"]
    assert booked_refs["reconciled_at"]
    assert booked_refs["net_amount_minor"] == 12_000_000

    # The evidence points at the isolated per-connection provider instance.
    {:ok, ctx} = FakeERPInstances.context_for(bundle.connection)
    {:ok, booked} = FakeERP.get_document(ctx, {:booked, booked_refs["external_booked_number"]})
    assert booked.state == :booked
    assert [booked_line] = booked.lines
    assert booked_line.recognition == {:over_time, anchor, service_end}

    # Durable completion is recorded on the workspace for the guided page,
    # and the first completion emitted its activation measurement exactly
    # once — a later observe of unchanged refs does not re-emit.
    assert_receive {:activation, "first_invoice", _seconds}
    {:ok, resumed} = Demo.active_workspace(user)
    assert resumed.workspace.progress["first_invoice"] == booked_refs
    {:ok, _journey} = Scenario.observe(bundle)
    refute_receive {:activation, "first_invoice", _}, 50
  end

  test "the goodwill credit unlocks only after booking and lands in the subledger idempotently",
       %{user: user, bundle: bundle, scope: scope} do
    {:ok, refs} = Scenario.build_commercial_model(bundle)

    # Locked until the invoice phase reaches a booked, reconciled document.
    assert %{credit: %{state: :locked}} = Scenario.status(bundle)
    assert {:error, :locked} = Scenario.record_customer_credit(bundle)

    book_first_invoice!(bundle, refs)
    assert %{credit: %{state: :not_started}} = Scenario.status(bundle)

    assert {:ok, credit_refs} = Scenario.record_customer_credit(bundle)
    assert credit_refs["origin_type"] == "goodwill"
    assert credit_refs["granted_minor"] == 250_000

    # The subledger rows exist through the ordinary read APIs.
    {:ok, [credit_account]} = Credits.list_accounts_for_customer(scope, refs["customer_id"])
    assert credit_account.id == credit_refs["credit_account_id"]
    assert credit_account.available_minor == 250_000
    {:ok, [grant]} = Credits.list_grants(scope, credit_account)
    assert grant.id == credit_refs["grant_id"]
    assert :ok = Credits.reconcile_account(credit_account.id)

    # Idempotent: replaying converges on the same grant and balance.
    assert {:ok, ^credit_refs} = Scenario.record_customer_credit(bundle)
    {:ok, [credit_account]} = Credits.list_accounts_for_customer(scope, refs["customer_id"])
    assert credit_account.available_minor == 250_000
    {:ok, [_only_grant]} = Credits.list_grants(scope, credit_account)

    # Durable completion is recorded on the workspace for the guided page.
    {:ok, resumed} = Demo.active_workspace(user)
    assert resumed.workspace.progress["customer_credit"] == credit_refs
    assert %{credit: %{state: :complete}} = Scenario.status(bundle)
  end

  test "the aggregate close completes the guided story with a reconciled voucher",
       %{user: user, bundle: bundle, scope: scope} do
    {:ok, refs} = Scenario.build_commercial_model(bundle)

    # Locked until the credit movement exists.
    assert %{close: %{state: :locked}} = Scenario.status(bundle)

    book_first_invoice!(bundle, refs)
    {:ok, _credit_refs} = Scenario.record_customer_credit(bundle)
    assert %{close: %{state: :not_started}} = Scenario.status(bundle)

    # The ordinary close commands, exactly as the credit-closes surface
    # runs them, against the connection-scoped demo provider.
    month_start = Date.beginning_of_month(Date.utc_today())

    {:ok, policy} =
      CloseKernel.create_policy(scope, %{
        version: 1,
        effective_from: month_start,
        journal_number: 1,
        liability_account_number: 2990,
        posting_mode: :single_offset,
        default_offset_account_number: 5890,
        post_zero_delta: false,
        vat_neutral: true,
        created_by: scope.user.id
      })

    {:ok, close} =
      CloseWorkflow.generate(scope, %{
        currency: "DKK",
        period_start: month_start,
        period_end_exclusive: Date.add(Date.end_of_month(month_start), 1),
        transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
        policy_version_id: policy.id,
        bootstrap_opening_minor: 0
      })

    assert %{close: %{state: :ready}} = Scenario.status(bundle)

    {:ok, _approved} = CloseWorkflow.approve(scope, close, reason: "demo close review")
    {:ok, _operation} = CloseWorkflow.request_posting(scope, close)
    assert %{close: %{state: :posting}} = Scenario.status(bundle)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    assert {:ok, %{close: %{state: :reconciled, refs: reconciled_refs}}} =
             Scenario.observe(bundle)

    assert reconciled_refs["external_voucher_number"]
    assert reconciled_refs["closing_minor"] == 250_000

    {:ok, _closed} = CloseWorkflow.close_period(scope, close)
    assert {:ok, %{close: %{state: :closed, refs: closed_refs}}} = Scenario.observe(bundle)
    assert closed_refs["closed_at"]

    # Durable completion is recorded on the workspace for the guided page.
    {:ok, resumed} = Demo.active_workspace(user)
    assert resumed.workspace.progress["aggregate_close"] == closed_refs
  end

  test "a provider restart between freeze and draft creation resumes deterministically",
       %{user: user, bundle: bundle, scope: scope} do
    {:ok, refs} = Scenario.build_commercial_model(bundle)
    anchor = Scenario.anchor_date(bundle.workspace)
    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    {:ok, intent} = Preview.freeze(scope, preview)

    # Interruption: the in-memory provider instance goes away entirely.
    :ok = InstanceSupervisor.stop(bundle.connection.id)

    # A fresh session resumes the same workspace and derives the same state.
    {:ok, resumed} = Demo.resume_workspace(user)
    assert resumed.workspace.id == bundle.workspace.id
    assert {:ok, %{invoice: %{state: :frozen}}} = Scenario.observe(resumed)

    # The next durable operation rehydrates the provider from its snapshot.
    {:ok, _operation} = Sync.request_synchronization(resumed.scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert {:ok, %{invoice: %{state: :erp_draft}}} = Scenario.observe(resumed)
  end

  test "a provider failure surfaces as needs-attention and recovers through ordinary retry",
       %{bundle: bundle, scope: scope} do
    {:ok, refs} = Scenario.build_commercial_model(bundle)
    anchor = Scenario.anchor_date(bundle.workspace)
    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    {:ok, intent} = Preview.freeze(scope, preview)

    {:ok, provider} = InstanceSupervisor.fetch(bundle.connection.id)

    :ok =
      FakeERP.inject_failure(
        provider,
        :create_draft,
        {:error, {:validation, %{field: "customer"}}}
      )

    {:ok, operation} = Sync.request_synchronization(scope, intent)
    Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(operation.id).state == "failed"
    assert {:ok, %{invoice: %{state: :sync_error}}} = Scenario.observe(bundle)

    # BC-US-106 remediation path, with the injected failure consumed.
    {:ok, _operation} = Sync.retry_operation(scope, Operations.get!(operation.id))
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert {:ok, %{invoice: %{state: :erp_draft}}} = Scenario.observe(bundle)
  end

  defp book_first_invoice!(bundle, refs) do
    scope = bundle.scope
    anchor = Scenario.anchor_date(bundle.workspace)
    {:ok, preview} = Preview.for_subscription(scope, refs["subscription_id"], anchor)
    {:ok, intent} = Preview.freeze(scope, preview)
    {:ok, _operation} = Sync.request_synchronization(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(scope, intent, reason: "demo walkthrough")
    {:ok, _operation} = Sync.request_booking(scope, intent)
    %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    intent
  end

  defp stop_if_running(connection_id) do
    case InstanceSupervisor.stop(connection_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
