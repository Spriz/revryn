defmodule BillingCore.Soak.SustainedLoadTest do
  @moduledoc """
  Sustained mixed-load soak (BC-TASK-077). Excluded from the default run;
  execute with

      SOAK_ITERATIONS=200 mix test --only soak

  Each iteration ingests usage, previews, freezes, and fully synchronizes
  one invoice through the fake provider. The suite asserts that every
  durable operation settles, no ERP work accumulates in the queue, and
  BEAM memory stays bounded across the run — the qualitative §21
  properties; production-scale duration runs on production-like hardware
  (docs/reviews/capacity-v1.md).
  """

  use BillingCore.DataCase, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.UsageFixtures

  alias BillingCore.{Contracts, ERP, Operations, Usage}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP.{FakeERP, Sync}

  test "sustained mixed load settles every operation with bounded memory" do
    iterations = String.to_integer(System.get_env("SOAK_ITERATIONS", "20"))

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
        interval_count: 1,
        billing_timing: :in_advance,
        amount: "250.00"
      )

    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, _} = ERP.validate_connection(scope, connection)

    {:ok, _} =
      BillingCore.Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "SOAK-1"
      })

    {:ok, _} = Usage.ensure_partitions(2)
    usage_subscription = usage_subscription_fixture(scope)

    baseline_memory = :erlang.memory(:total)

    for i <- 1..iterations do
      {:ok, %{status: :accepted}} =
        Usage.ingest_event(scope, valid_usage_event_attrs(usage_subscription))

      customer = customer_fixture(scope)

      {:ok, _} =
        Contracts.upsert_customer_erp_mapping(scope, customer, %{
          erp_connection_id: connection.id,
          external_customer_number: "9#{i}"
        })

      contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-08-01]})

      {:ok, subscription} =
        Contracts.start_subscription(scope, %{
          external_id: unique_subscription_external_id(),
          contract_id: contract.id,
          plan_version_id: plan_version.id,
          start_date: ~D[2026-08-01],
          quantity: Decimal.new(1)
        })

      {:ok, preview} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])
      {:ok, intent} = Preview.freeze(scope, preview)
      {:ok, operation} = Sync.request_synchronization(scope, intent)

      assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
      assert Operations.get!(operation.id).state == "succeeded"
    end

    # Nothing left in flight, and heap growth stays proportionate.
    team_id = BillingCore.Scope.team_id!(scope)
    assert Operations.failure_inbox(team_id) == []

    growth = :erlang.memory(:total) - baseline_memory
    IO.puts("\n[soak] #{iterations} iterations; BEAM memory growth #{div(growth, 1_048_576)} MiB")
    assert growth < 512 * 1_048_576
  end
end
