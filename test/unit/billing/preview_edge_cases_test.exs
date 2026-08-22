defmodule BillingCore.Billing.PreviewEdgeCasesTest do
  @moduledoc """
  Preview rating branches beyond the happy path (SPEC BC-US-068, §7.1):
  skipped components, rating blockers and the freeze guard, discount lines
  (percentage and fixed, SPEC §10.7), day-interval periods, prior-period
  carry-forward without a billed prior invoice (§18.5), and currency-scoped
  credit availability (BC-US-108).
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Catalog, Contracts, Credits, Orgs, Usage}
  alias BillingCore.Billing.Preview

  defp scope_fixture do
    billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
  end

  defp subscribe!(scope, plan_version, attrs) do
    contract =
      contract_fixture(scope, %{start_date: Map.get(attrs, :contract_start, ~D[2026-01-01])})

    {:ok, subscription} =
      Contracts.start_subscription(
        scope,
        attrs
        |> Map.delete(:contract_start)
        |> Map.put_new(:external_id, unique_subscription_external_id())
        |> Map.put_new(:contract_id, contract.id)
        |> Map.put(:plan_version_id, plan_version.id)
        |> Map.put_new(:quantity, Decimal.new(1))
      )

    subscription
  end

  describe "component skipping" do
    test "one-time components never appear in the recurring preview (BC-US-041)" do
      scope = scope_fixture()
      product = product_fixture(scope)
      draft = draft_plan_version_fixture(scope, currency: "DKK", interval_count: 1)

      fixed_recurring_component_fixture(scope, draft,
        product: product,
        amount: "100.00",
        code: "recurring"
      )

      {:ok, _one_time} =
        Catalog.add_price_component(scope, draft, %{
          code: "setup",
          product_id: product.id,
          pricing_definition: %{
            "schema_version" => 1,
            "type" => "one_time",
            "unit_price" => "500.00"
          }
        })

      {:ok, plan_version} = Catalog.publish_plan_version(scope, draft)
      subscription = subscribe!(scope, plan_version, %{start_date: ~D[2026-08-01]})

      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])

      assert preview.blockers == []
      assert [line] = preview.lines
      assert line.line_key =~ ":recurring:"
      # The one-time DKK 500.00 must not leak into the recurring total.
      assert preview.net_amount_minor == 10_000
    end

    test "previewing after the subscription window fails on version resolution first" do
      scope = scope_fixture()

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          amount: "100.00"
        )

      subscription =
        subscribe!(scope, plan_version, %{
          start_date: ~D[2026-08-01],
          end_date_exclusive: ~D[2026-08-15]
        })

      # The subscription version closes at the same boundary as the
      # subscription window, so a preview outside the window is rejected
      # before rating. The rate_fixed/active_period guards for a nil active
      # period (preview.ex `rate_fixed(..., %{active_period: nil})` and the
      # `Period.new {:error, :invalid_period}` fallback) are therefore
      # defensive-only: no public flow can reach rating with an effective
      # version but a disjoint or invalid active window.
      assert {:error, :no_effective_subscription_version} =
               Preview.for_subscription(scope, subscription.id, ~D[2026-09-10])
    end
  end

  describe "rating blockers and the freeze guard" do
    test "a negative usage total on a volume tier blocks the preview, and freeze refuses it" do
      scope = scope_fixture()
      product = product_fixture(scope)

      draft =
        draft_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          billing_timing: :in_arrears
        )

      {:ok, _component} =
        Catalog.add_price_component(scope, draft, %{
          code: "storage",
          product_id: product.id,
          pricing_definition: %{
            "schema_version" => 1,
            "type" => "volume_tier",
            "tiers" => [%{"from" => "0", "unit_rate" => "1.00", "flat_fee_minor" => 0}]
          },
          metric_code: "gb_hours",
          aggregation: :sum
        })

      {:ok, plan_version} = Catalog.publish_plan_version(scope, draft)
      subscription = subscribe!(scope, plan_version, %{start_date: ~D[2026-08-01]})

      # A lone negative correction drives the aggregate below zero; volume
      # tiers cannot price a negative quantity (SPEC §10.3).
      {:ok, %{status: :accepted}} =
        Usage.ingest_event(scope, %{
          external_event_id: "evt-neg-#{System.unique_integer([:positive])}",
          subscription_id: subscription.id,
          metric_code: "gb_hours",
          occurred_at: ~U[2026-08-05 10:00:00.000000Z],
          value: Decimal.new(-5)
        })

      {:ok, preview} =
        Preview.for_subscription(scope, subscription.id, ~D[2026-08-01],
          usage_cutoff: DateTime.utc_now()
        )

      assert [{:rating_failed, "storage", {:negative_quantity, "volume_tier"}}] =
               preview.blockers

      assert preview.lines == []

      # A blocked preview is not freezable (BC-US-069).
      assert {:error, {:blocked, [{:rating_failed, "storage", _reason}]}} =
               Preview.freeze(scope, preview)
    end

    # Blocker branches that cannot be reached through the public API and
    # stay uncovered by design:
    #
    #   * rate_fixed's {:error, reason} -> {:blocked, {:rating_failed, ...}}
    #     — the fixed-path rating request is built entirely from
    #     catalog/contract data the contexts already validated (currency,
    #     Decimal quantity, active ⊆ full period), so Engine.rate/1 cannot
    #     fail there.
    #   * rate_metered's {:error, reason} -> {:blocked,
    #     {:usage_aggregation_failed, ...}} — Usage.aggregate/6 only errors
    #     with :unauthorized or :unknown_aggregation; every role allowed to
    #     preview (contracts/catalog read) is also a usage read role, and
    #     the component's aggregation is a DB-validated enum the usage
    #     context fully supports.
    #   * billed_cutoff_for's non-parsing snapshot cutoff (`_ -> []`) —
    #     freeze always stamps a valid ISO 8601 "usageCutoff" into the
    #     canonical snapshot, so only hand-crafted legacy rows could hit it.
  end

  describe "discount lines (SPEC §10.7)" do
    # Regression guard: an assignment targets EXACTLY ONE of contract or
    # subscription (BC-US-060), and the preview once queried with both
    # filters ANDed — no assignment could ever match, silently disabling
    # every discount in previews. These tests prove both target kinds
    # produce the ADR-008 negative discount line with exact integer math.
    test "a subscription-targeted percentage assignment discounts the preview" do
      scope = scope_fixture()

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          amount: "100.00"
        )

      subscription = subscribe!(scope, plan_version, %{start_date: ~D[2026-08-01]})

      version = percentage_discount_version_fixture(scope, %{basis_points: 1000})

      {:ok, assignment} =
        Catalog.assign_discount(scope, version, %{
          subscription_id: subscription.id,
          effective_from: ~D[2026-08-01]
        })

      assert assignment.status == :active

      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])

      assert [discount_line] =
               Enum.filter(preview.lines, &String.starts_with?(&1.line_key, "discount:"))

      # 10% of DKK 100.00 as a negative normalized line (ADR-008).
      assert discount_line.amount_minor == -1_000
      assert preview.net_amount_minor == 9_000
    end

    test "a contract-targeted fixed assignment discounts the preview" do
      scope = scope_fixture()

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          amount: "100.00"
        )

      contract = contract_fixture(scope, %{start_date: ~D[2026-01-01]})

      {:ok, subscription} =
        Contracts.start_subscription(scope, %{
          external_id: unique_subscription_external_id(),
          contract_id: contract.id,
          plan_version_id: plan_version.id,
          start_date: ~D[2026-08-01],
          quantity: Decimal.new(1)
        })

      version = fixed_discount_version_fixture(scope, %{amount_minor: 5000, currency: "DKK"})

      {:ok, _assignment} =
        Catalog.assign_discount(scope, version, %{
          contract_id: contract.id,
          effective_from: ~D[2026-08-01]
        })

      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])

      assert [discount_line] =
               Enum.filter(preview.lines, &String.starts_with?(&1.line_key, "discount:"))

      assert discount_line.amount_minor == -5_000
      assert preview.net_amount_minor == 5_000
    end

    test "an assignment outside its effective window does not discount" do
      scope = scope_fixture()

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          amount: "100.00"
        )

      subscription = subscribe!(scope, plan_version, %{start_date: ~D[2026-08-01]})
      version = percentage_discount_version_fixture(scope, %{basis_points: 1000})

      # Half-open window that ends before the previewed period starts.
      {:ok, _assignment} =
        Catalog.assign_discount(scope, version, %{
          subscription_id: subscription.id,
          effective_from: ~D[2026-06-01],
          effective_until_exclusive: ~D[2026-08-01]
        })

      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])

      refute Enum.any?(preview.lines, &String.starts_with?(&1.line_key, "discount:"))
      assert preview.net_amount_minor == 10_000
    end
  end

  describe "billing period resolution" do
    test "day-interval plans anchor N-day periods on the subscription start date" do
      scope = scope_fixture()

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_unit: :day,
          interval_count: 7,
          amount: "70.00"
        )

      subscription = subscribe!(scope, plan_version, %{start_date: ~D[2026-08-03]})

      # 2026-08-14 is 11 days in: the second 7-day period [08-10, 08-17).
      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-14])

      assert preview.billing_period.start_date == ~D[2026-08-10]
      assert preview.billing_period.end_date_exclusive == ~D[2026-08-17]
      assert [line] = preview.lines
      assert line.amount_minor == 7000
    end
  end

  describe "prior-period carry-forward (SPEC §18.5)" do
    test "with no billed prior invoice there is nothing to carry forward" do
      scope = scope_fixture()
      product = product_fixture(scope)

      draft =
        draft_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          billing_timing: :in_arrears
        )

      {:ok, _component} =
        Catalog.add_price_component(scope, draft, %{
          code: "api",
          product_id: product.id,
          pricing_definition: %{
            "schema_version" => 1,
            "type" => "standard_metered",
            "unit_rate" => "0.50"
          },
          metric_code: "api_calls",
          aggregation: :sum
        })

      {:ok, plan_version} = Catalog.publish_plan_version(scope, draft)
      subscription = subscribe!(scope, plan_version, %{start_date: ~D[2026-07-01]})

      for {id, occurred_at, value} <- [
            {"jul", ~U[2026-07-10 10:00:00.000000Z], 100},
            {"aug", ~U[2026-08-10 10:00:00.000000Z], 40}
          ] do
        {:ok, %{status: :accepted}} =
          Usage.ingest_event(scope, %{
            external_event_id: "evt-#{id}-#{System.unique_integer([:positive])}",
            subscription_id: subscription.id,
            metric_code: "api_calls",
            occurred_at: occurred_at,
            value: Decimal.new(value)
          })
      end

      # July was never frozen: the August preview bills only August and
      # emits no "prior:" adjustment line — July's usage still belongs to
      # July's own (future) invoice, not a carry-forward.
      {:ok, preview} =
        Preview.for_subscription(scope, subscription.id, ~D[2026-08-01],
          usage_cutoff: DateTime.utc_now()
        )

      assert preview.blockers == []
      assert [line] = preview.lines
      refute line.line_key =~ ":prior:"
      assert Decimal.eq?(line.quantity, Decimal.new(40))
      assert preview.net_amount_minor == 2000
    end
  end

  describe "credit availability (BC-US-108)" do
    test "credit held in another currency is never planned against the invoice" do
      %{organization: organization, team: team} = organization_fixture()

      scope =
        team_scope_fixture(organization, team, [:team_admin, :billing_admin, :finance_operator])

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_count: 1,
          amount: "100.00"
        )

      customer = customer_fixture(scope)
      account = account_fixture(organization)
      {:ok, _} = Orgs.project_account_to_team(account, team, customer.id)

      contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

      {:ok, subscription} =
        Contracts.start_subscription(scope, %{
          external_id: unique_subscription_external_id(),
          contract_id: contract.id,
          plan_version_id: plan_version.id,
          start_date: ~D[2026-08-01],
          quantity: Decimal.new(1)
        })

      BillingCore.CreditsFixtures.settlement_policy_fixture(scope)

      # The customer's account holds EUR credit; the plan bills DKK.
      {:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "EUR")

      {:ok, _grant} =
        Credits.grant_credit(scope, %{
          credit_account_id: credit_account.id,
          origin_type: "unused_prepaid_service",
          amount_minor: 30_000,
          currency: "EUR",
          idempotency_key: "grant-#{System.unique_integer([:positive])}"
        })

      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-09-01])

      assert preview.credit_account == nil
      assert preview.credit_available_minor == 0
      assert preview.credit_planned_minor == 0
      assert preview.net_amount_minor == 10_000
      assert preview.amount_due_minor == 10_000
    end
  end
end
