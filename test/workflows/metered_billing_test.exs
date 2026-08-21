defmodule BillingCore.Workflows.MeteredBillingTest do
  @moduledoc """
  Workflow documentation: metered usage flows from ingestion through
  aggregation at a frozen cutoff into graduated-tier rated invoice lines
  (SPEC Epic D BC-US-050…055, §10.4, BC-US-019).
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Billing, Catalog, Contracts, Usage}
  alias BillingCore.Billing.Preview

  setup do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    product = product_fixture(scope)
    plan = plan_fixture(scope)

    draft =
      draft_plan_version_fixture(scope,
        plan: plan,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        billing_timing: :in_arrears
      )

    # Graduated tiers (SPEC §10.4): 0–100 free, 100–1000 @ 0.50, 1000+ @ 0.25.
    {:ok, _component} =
      Catalog.add_price_component(scope, draft, %{
        code: "api-calls",
        product_id: product.id,
        pricing_definition: %{
          "schema_version" => 1,
          "type" => "graduated_tier",
          "tiers" => [
            %{"from" => "0", "to" => "100", "unit_rate" => "0", "flat_fee_minor" => 0},
            %{"from" => "100", "to" => "1000", "unit_rate" => "0.50", "flat_fee_minor" => 0},
            %{"from" => "1000", "unit_rate" => "0.25", "flat_fee_minor" => 0}
          ]
        },
        metric_code: "api_calls",
        aggregation: :sum
      })

    {:ok, plan_version} = Catalog.publish_plan_version(scope, draft)

    contract = contract_fixture(scope, %{start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    %{scope: scope, subscription: subscription}
  end

  defp ingest!(scope, subscription, external_id, occurred_at, value) do
    {:ok, %{status: :accepted}} =
      Usage.ingest_event(scope, %{
        external_event_id: external_id,
        subscription_id: subscription.id,
        metric_code: "api_calls",
        occurred_at: occurred_at,
        value: Decimal.new(value)
      })
  end

  test "usage aggregates into graduated-tier lines with a full trace",
       %{scope: scope, subscription: subscription} do
    # 1,200 calls in August: 100 free + 900 @ 0.50 + 200 @ 0.25 = 450 + 50 = DKK 500.00
    ingest!(scope, subscription, "evt-1", ~U[2026-08-05 10:00:00.000000Z], 500)
    ingest!(scope, subscription, "evt-2", ~U[2026-08-15 10:00:00.000000Z], 400)
    ingest!(scope, subscription, "evt-3", ~U[2026-08-18 10:00:00.000000Z], 300)

    cutoff = DateTime.utc_now()

    {:ok, preview} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-08-01], usage_cutoff: cutoff)

    assert preview.blockers == []
    assert [line] = preview.lines
    assert Decimal.eq?(line.quantity, Decimal.new(1200))
    assert line.amount_minor == 50_000

    assert line.calculation_trace["usage"]["event_count"] == 3
    assert line.calculation_trace["usage"]["metric_code"] == "api_calls"
    assert is_list(line.calculation_trace["tiers"]) or is_map(line.calculation_trace["tiers"])

    # Freeze and confirm the metered line lands in immutable intent.
    {:ok, intent} = Preview.freeze(scope, preview, usage_cutoff: cutoff)
    assert intent.net_amount_minor == 50_000
    assert Billing.intent_state(intent) == "frozen"
  end

  test "aggregation respects the frozen cutoff: late usage is excluded and visible",
       %{scope: scope, subscription: subscription} do
    ingest!(scope, subscription, "evt-early", ~U[2026-08-05 10:00:00.000000Z], 200)
    cutoff = DateTime.utc_now()

    # This event occurred inside the period but arrives after the cutoff.
    ingest!(scope, subscription, "evt-late", ~U[2026-08-06 10:00:00.000000Z], 999)

    {:ok, preview} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-08-01], usage_cutoff: cutoff)

    assert [line] = preview.lines
    assert Decimal.eq?(line.quantity, Decimal.new(200))
    assert line.calculation_trace["usage"]["excluded_late"] == 1

    # The same cutoff always reproduces the same result (BC-US-055).
    {:ok, preview2} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-08-01], usage_cutoff: cutoff)

    assert preview2.fingerprint == preview.fingerprint
  end

  test "late usage carries forward as a prior-period adjustment (SPEC §18.5)",
       %{scope: scope, subscription: subscription} do
    alias BillingCore.Billing

    # August is billed at an early cutoff with 150 calls (50 billable @ 0.50).
    ingest!(scope, subscription, "cf-1", ~U[2026-08-05 10:00:00.000000Z], 150)
    first_cutoff = DateTime.utc_now()

    {:ok, august} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-08-01], usage_cutoff: first_cutoff)

    {:ok, august_intent} = Preview.freeze(scope, august, usage_cutoff: first_cutoff)
    assert august_intent.net_amount_minor == 2_500

    # A late event for August arrives after that cutoff: 950 more calls.
    # Marginal amount: rate(1100) - rate(150) = (450 + 25) - 25 = DKK 450.00.
    ingest!(scope, subscription, "cf-late", ~U[2026-08-10 10:00:00.000000Z], 950)

    {:ok, september} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-09-01],
        usage_cutoff: DateTime.utc_now()
      )

    adjustment = Enum.find(september.lines, &String.contains?(&1.line_key, "prior:2026-08-01"))
    assert adjustment, "expected a prior-period adjustment line"
    assert adjustment.amount_minor == 45_000
    assert Decimal.eq?(adjustment.quantity, Decimal.new(950))
    assert adjustment.description =~ "Prior-period usage adjustment"
    assert adjustment.calculation_trace["kind"] == "late_usage_carry_forward"
    assert adjustment.service_start == nil or adjustment.service_start == ~D[2026-08-01]

    # Freezing September consumes the carry-forward; a third preview after
    # freezing must NOT repeat it (the September snapshot cutoff advanced past
    # the late event).
    {:ok, _sept_intent} = Preview.freeze(scope, september)

    {:ok, october_view} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-09-01],
        usage_cutoff: DateTime.utc_now()
      )

    _ = Billing
    repeated = Enum.find(october_view.lines, &String.contains?(&1.line_key, "prior:2026-08-01"))
    refute repeated, "a frozen carry-forward must not repeat on later previews"
  end

  test "zero usage produces a zero graduated charge (BC-US-019)",
       %{scope: scope, subscription: subscription} do
    {:ok, preview} =
      Preview.for_subscription(scope, subscription.id, ~D[2026-08-01],
        usage_cutoff: DateTime.utc_now()
      )

    assert [line] = preview.lines
    assert line.amount_minor == 0
    assert Decimal.eq?(line.quantity, Decimal.new(0))
  end
end
