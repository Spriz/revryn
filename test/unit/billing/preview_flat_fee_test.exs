defmodule BillingCore.Billing.PreviewFlatFeeTest do
  @moduledoc """
  Regression: a minimum-commit component over a zero-rate fixed inner is
  the SPEC §10.6 way to express a quantity-independent flat fee. The
  preview must rate it through the fixed path (it crashed into the
  metered path before) and the amount must not scale with quantity.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Catalog, Contracts}
  alias BillingCore.Billing.Preview

  test "flat base + per-seat component preview at quantity 3" do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    product = product_fixture(scope)
    draft = draft_plan_version_fixture(scope, currency: "DKK", interval_count: 1)

    fixed_recurring_component_fixture(scope, draft,
      product: product,
      amount: "99.00",
      code: "seat"
    )

    {:ok, _base} =
      Catalog.add_price_component(scope, draft, %{
        code: "base",
        product_id: product.id,
        proration_policy: :full_period,
        ordinal: 2,
        pricing_definition: %{
          "schema_version" => 1,
          "type" => "minimum_commit",
          "minimum_amount_minor" => 24_900,
          "inner" => %{
            "schema_version" => 1,
            "type" => "fixed_recurring",
            "unit_price" => "0"
          }
        }
      })

    {:ok, plan_version} = Catalog.publish_plan_version(scope, draft)

    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-08-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(3)
      })

    {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])

    amounts =
      preview.lines
      |> Enum.map(fn line ->
        if String.contains?(line.line_key, ":seat:"),
          do: {:seat, line.amount_minor},
          else: {:base, line.amount_minor}
      end)
      |> Map.new()

    assert amounts[:seat] == 3 * 9_900
    assert amounts[:base] == 24_900, "flat base must not scale with quantity"
    assert preview.net_amount_minor == 3 * 9_900 + 24_900
  end
end
