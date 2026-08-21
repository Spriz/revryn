defmodule BillingCore.Workflows.BillingRunTest do
  @moduledoc """
  Workflow documentation: scheduled billing runs select eligible
  subscriptions at their billing boundary, record double-billing-protected
  charges, and consolidate one invoice intent per customer
  (SPEC §18, BC-US-054/066/116).
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Billing, Contracts}
  alias BillingCore.Billing.{Charge, InvoiceLine, Scheduler}

  setup do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    product = product_fixture(scope)

    plan_version =
      published_plan_version_fixture(scope,
        currency: "DKK",
        product: product,
        interval_unit: :month,
        interval_count: 1,
        amount: "1000.00"
      )

    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

    %{scope: scope, plan_version: plan_version, customer: customer, contract: contract}
  end

  defp start_sub!(scope, contract, plan_version, start_date, quantity \\ 1) do
    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: start_date,
        quantity: Decimal.new(quantity)
      })

    subscription
  end

  test "a run bills subscriptions at their boundary and consolidates per customer",
       %{scope: scope, plan_version: plan_version, contract: contract} do
    sub_a = start_sub!(scope, contract, plan_version, ~D[2026-08-01], 1)
    sub_b = start_sub!(scope, contract, plan_version, ~D[2026-08-01], 3)
    # Different anchor: not billable on 2026-09-01.
    sub_c = start_sub!(scope, contract, plan_version, ~D[2026-08-15], 1)

    {:ok, %{run: run, invoiced: [intent], skipped: skipped}} =
      Scheduler.process_regular_run(scope, ~D[2026-09-01])

    assert run.run_key == "2026-09-01:regular:Europe-Copenhagen"
    assert skipped[sub_c.id] == :not_a_billing_boundary

    # One consolidated intent: both boundary subscriptions, one customer.
    lines = Repo.all(from l in InvoiceLine, where: l.invoice_intent_id == ^intent.id)
    assert length(lines) == 2
    assert intent.net_amount_minor == 100_000 + 300_000
    assert intent.billing_run_id == run.id

    line_keys = Enum.map(lines, & &1.line_key) |> Enum.sort()
    assert Enum.any?(line_keys, &String.contains?(&1, sub_a.external_id))
    assert Enum.any?(line_keys, &String.contains?(&1, sub_b.external_id))

    # Every line traces to a recorded charge.
    assert Enum.all?(lines, & &1.source_charge_id)

    charges = Repo.all(from c in Charge, where: c.billing_run_id == ^run.id)
    assert length(charges) == 2
    assert Enum.all?(charges, &(&1.status == "active"))
  end

  test "re-running the same run key never double-bills (SPEC §18.4)",
       %{scope: scope, plan_version: plan_version, contract: contract} do
    sub = start_sub!(scope, contract, plan_version, ~D[2026-08-01])

    {:ok, %{invoiced: [_intent]}} = Scheduler.process_regular_run(scope, ~D[2026-09-01])

    {:ok, %{invoiced: invoiced2, skipped: skipped2}} =
      Scheduler.process_regular_run(scope, ~D[2026-09-01])

    assert invoiced2 == []
    assert skipped2[sub.id] == :occurrence_already_billed

    # Exactly one active charge for the occurrence exists.
    charges = Repo.all(from c in Charge, where: c.subscription_id == ^sub.id)
    assert length(charges) == 1
  end

  test "run closure is refused while intents are unresolved (BC-US-116)",
       %{scope: scope, plan_version: plan_version, contract: contract} do
    _sub = start_sub!(scope, contract, plan_version, ~D[2026-08-01])

    {:ok, %{run: run, invoiced: [intent]}} = Scheduler.process_regular_run(scope, ~D[2026-09-01])

    assert {:error, :unresolved_intents} = Billing.close_run(scope, run)

    # Supersede-abandon path is not needed; simply mark the intent superseded
    # via its machine to resolve the run for this workflow.
    {:ok, _} = Billing.transition_intent(scope, intent, :supersede, reason: "test resolution")
    assert {:ok, closed} = Billing.close_run(scope, run)
    assert closed.status == "closed"
  end

  test "in-arrears plans bill the period ending at the run date (BC-US-015)",
       %{scope: scope, contract: contract} do
    arrears_plan =
      published_plan_version_fixture(scope,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        billing_timing: :in_arrears,
        amount: "2000.00"
      )

    sub = start_sub!(scope, contract, arrears_plan, ~D[2026-08-01])

    # On the period start date nothing is billed…
    {:ok, %{invoiced: none, skipped: skipped}} =
      Scheduler.process_regular_run(scope, ~D[2026-08-01])

    assert none == []
    assert skipped[sub.id] == :not_a_billing_boundary

    # …at the period end, the CLOSED period [08-01, 09-01) is billed.
    {:ok, %{invoiced: [intent]}} = Scheduler.process_regular_run(scope, ~D[2026-09-01])
    assert intent.net_amount_minor == 200_000

    lines = Repo.all(from l in InvoiceLine, where: l.invoice_intent_id == ^intent.id)
    assert [line] = lines
    assert String.contains?(line.line_key, "2026-08-01")
  end

  test "subscriptions of different customers get separate intents",
       %{scope: scope, plan_version: plan_version} do
    customer_b = customer_fixture(scope)
    contract_a = contract_fixture(scope, %{start_date: ~D[2026-01-01]})

    contract_b =
      contract_fixture(scope, %{customer_id: customer_b.id, start_date: ~D[2026-01-01]})

    start_sub!(scope, contract_a, plan_version, ~D[2026-08-01])
    start_sub!(scope, contract_b, plan_version, ~D[2026-08-01])

    {:ok, %{invoiced: intents}} = Scheduler.process_regular_run(scope, ~D[2026-09-01])
    assert length(intents) == 2
    assert intents |> Enum.map(& &1.customer_id) |> Enum.uniq() |> length() == 2
  end
end
