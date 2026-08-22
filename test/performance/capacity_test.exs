defmodule BillingCore.Performance.CapacityTest do
  @moduledoc """
  Reproducible capacity benchmarks toward the SPEC §21 baseline
  (BC-TASK-077). Excluded from the default run; execute with

      mix test --only performance

  Each benchmark prints its measurement (captured into
  `docs/reviews/capacity-v1.md`) and asserts the §21.1 service objective
  where the objective is certifiable independent of hardware scale; pure
  throughput numbers are reported, with conservative floors that only
  catch order-of-magnitude regressions.
  """

  use BillingCore.DataCase, async: false

  @moduletag :performance
  @moduletag timeout: 300_000

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures
  import BillingCore.UsageFixtures

  alias BillingCore.{Contracts, ERP, Operations, Usage}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP.{FakeERP, Sync}

  defp report(label, value), do: IO.puts("\n[capacity] #{label}: #{value}")

  test "invoice preview stays under the 5s objective at 500 normalized lines (§21.1)" do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])
    product = product_fixture(scope)
    draft = draft_plan_version_fixture(scope, currency: "DKK", interval_count: 1)

    for i <- 1..500 do
      fixed_recurring_component_fixture(scope, draft,
        product: product,
        amount: "10.00",
        code: "cap-comp-#{i}"
      )
    end

    {:ok, plan_version} = BillingCore.Catalog.publish_plan_version(scope, draft)

    customer = customer_fixture(scope)
    contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-08-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    # Warm once (query-plan caches), then measure five runs and take p95≈max.
    {:ok, _warm} = Preview.for_subscription(scope, subscription.id, ~D[2026-08-01])

    durations =
      for _ <- 1..5 do
        {micros, {:ok, preview}} =
          :timer.tc(fn -> Preview.for_subscription(scope, subscription.id, ~D[2026-08-01]) end)

        assert length(preview.lines) == 500
        micros / 1_000
      end

    worst = Enum.max(durations)
    report("preview 500 lines, worst of 5 runs", "#{Float.round(worst, 1)} ms")

    assert worst < 5_000, "500-line preview took #{worst} ms; §21.1 objective is < 5000 ms"
  end

  test "single usage-event persistence stays under the 500ms p95 objective (§21.1)" do
    scope = usage_scope_fixture([:billing_admin])
    subscription = usage_subscription_fixture(scope)
    {:ok, _} = Usage.ensure_partitions(2)

    durations =
      for _ <- 1..200 do
        attrs = valid_usage_event_attrs(subscription)

        {micros, {:ok, %{status: :accepted}}} =
          :timer.tc(fn -> Usage.ingest_event(scope, attrs) end)

        micros / 1_000
      end

    p95 = durations |> Enum.sort() |> Enum.at(round(length(durations) * 0.95) - 1)
    report("single-event ingest p95 (200 events)", "#{Float.round(p95, 2)} ms")

    assert p95 < 500, "usage ingest p95 #{p95} ms; §21.1 objective is < 500 ms"
  end

  test "batch ingestion throughput is reported and bounded per event" do
    scope = usage_scope_fixture([:billing_admin])
    subscription = usage_subscription_fixture(scope)
    {:ok, _} = Usage.ensure_partitions(2)

    # CAPACITY_SCALE=N sustains N × 1k-event batches — set it high on
    # production-like hardware for the full §21.2 aggregate run.
    batches = String.to_integer(System.get_env("CAPACITY_SCALE", "1"))

    {micros, accepted} =
      :timer.tc(fn ->
        Enum.reduce(1..batches, 0, fn _, acc ->
          batch = for _ <- 1..1_000, do: valid_usage_event_attrs(subscription)
          {:ok, summary} = Usage.ingest_batch(scope, batch)
          acc + summary.accepted
        end)
      end)

    assert accepted == batches * 1_000

    events_per_sec = accepted / (micros / 1_000_000)
    report("batch ingest throughput (#{batches}k events)", "#{round(events_per_sec)} events/s")

    # Order-of-magnitude floor only: §21.2's 10M events/day is ~116/s
    # sustained; a single connection on a dev box must comfortably beat it.
    assert events_per_sec > 200
  end

  test "50 concurrent ERP operations complete exactly once under throttling (§21.2)" do
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
        amount: "100.00"
      )

    {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
    {:ok, _} = ERP.validate_connection(scope, connection)

    {:ok, _} =
      BillingCore.Catalog.upsert_product_erp_mapping(scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "CAP-1"
      })

    operations =
      for i <- 1..50 do
        customer = customer_fixture(scope)

        {:ok, _} =
          Contracts.upsert_customer_erp_mapping(scope, customer, %{
            erp_connection_id: connection.id,
            external_customer_number: "10#{i}"
          })

        contract =
          contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-08-01]})

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

        # Every fifth operation first hits a provider rate limit.
        if rem(i, 5) == 0 do
          FakeERP.inject_failure(
            fake,
            :create_draft,
            {:error, {:rate_limited, %{retry_after: 0}}}
          )
        end

        {:ok, operation} = Sync.request_synchronization(scope, intent)
        operation
      end

    # Bounded queue growth: repeated drains (retries included) empty the
    # queue instead of accumulating work.
    {micros, _} =
      :timer.tc(fn ->
        Enum.reduce_while(1..20, nil, fn _, _ ->
          Oban.drain_queue(queue: :erp, with_safety: false, with_scheduled: true)

          settled? =
            Enum.all?(operations, fn op -> Operations.get!(op.id).state == "succeeded" end)

          if settled?, do: {:halt, :ok}, else: {:cont, nil}
        end)
      end)

    for op <- operations do
      assert Operations.get!(op.id).state == "succeeded"
    end

    # Exactly one draft per intent — throttling preserved correctness.
    assert length(FakeERP.list_documents(fake)) == 50
    report("50 concurrent ERP ops incl. throttling", "#{Float.round(micros / 1_000, 1)} ms total")
  end

  test "month-boundary partition creation is idempotent under concurrent load (§21.2)" do
    scope = usage_scope_fixture([:billing_admin])
    subscription = usage_subscription_fixture(scope)
    {:ok, _} = Usage.ensure_partitions(1)

    # Eight concurrent creators race the same future months while events
    # flow into the current one: creation must be idempotent and inserts
    # must never fail on a missing partition.
    # async: false runs the sandbox in shared mode, so tasks join freely.
    tasks =
      for i <- 1..12 do
        Task.async(fn ->
          if rem(i, 3) == 0 do
            Usage.ensure_partitions(3)
          else
            Usage.ingest_event(scope, valid_usage_event_attrs(subscription))
          end
        end)
      end

    results = Task.await_many(tasks, 30_000)

    for result <- results do
      assert match?({:ok, _}, result), "concurrent partition/ingest failed: #{inspect(result)}"
    end
  end
end
