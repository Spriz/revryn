defmodule BillingCore.Workflows.FailureMatrixTest do
  @moduledoc """
  BC-TASK-096 acceptance beyond the per-scenario suites: every worker
  declares deterministic retry/terminal behavior, queue pruning never
  erases durable operation history, and process-crash redelivery cannot
  duplicate external effects.

  The provider-failure half of the matrix lives in the workflow suites:
  `invoice_sync_test.exs` (unknown-outcome reconcile-before-repeat-write,
  throttling, blocking, manual retry), `receivable_settlement_test.exs`
  and `customer_credit_close_workflow_test.exs` (voucher replay safety).
  A DB failure between the provider write and the local commit is
  behaviorally identical to a lost response, which those suites cover via
  `FakeERP.inject_unknown_outcome/2`.
  """

  use BillingCore.DataCase, async: false

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Contracts, ERP, Operations}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP.{FakeERP, Sync}

  # SPEC §21.3/INV-041: retries are policy, not reflex. Every Oban worker
  # must appear here with its declared queue and attempt bound; adding a
  # worker without extending this table fails the audit below.
  @worker_declarations %{
    BillingCore.Billing.RunWorker => %{queue: :billing, max_attempts: 5},
    BillingCore.Credits.CloseWorker => %{queue: :erp, max_attempts: 20},
    BillingCore.Credits.SettlementWorker => %{queue: :erp, max_attempts: 20},
    BillingCore.Credits.TerminationDispositionWorker => %{queue: :billing, max_attempts: 10},
    BillingCore.ERP.PollAllWorker => %{queue: :reconciliation, max_attempts: 3},
    BillingCore.ERP.PollWorker => %{queue: :reconciliation, max_attempts: 5},
    BillingCore.ERP.SyncWorker => %{queue: :erp, max_attempts: 20},
    BillingCore.Notifications.DeliveryWorker => %{queue: :email, max_attempts: 8},
    BillingCore.Outbox.RelayWorker => %{queue: :outbox, max_attempts: 10},
    BillingCore.AuditExport.RetentionWorker => %{queue: :maintenance, max_attempts: 3},
    BillingCore.Usage.PartitionWorker => %{queue: :maintenance, max_attempts: 5}
  }

  test "every Oban worker declares an explicit queue and attempt bound" do
    {:ok, modules} = :application.get_key(:billing_core, :modules)

    workers =
      Enum.filter(modules, fn module ->
        Code.ensure_loaded!(module)
        function_exported?(module, :__opts__, 0) and function_exported?(module, :perform, 1)
      end)

    declared = Map.keys(@worker_declarations)

    assert Enum.sort(workers) == Enum.sort(declared), """
    The Oban worker set changed. Every worker must declare deterministic
    retry/terminal behavior and be recorded in @worker_declarations
    (BC-TASK-096): #{inspect(workers -- declared)} missing from the table, \
    #{inspect(declared -- workers)} no longer exist.
    """

    for {module, expected} <- @worker_declarations do
      opts = Map.new(module.__opts__())

      assert opts[:queue] == expected.queue,
             "#{inspect(module)} queue #{inspect(opts[:queue])} != #{inspect(expected.queue)}"

      assert opts[:max_attempts] == expected.max_attempts,
             "#{inspect(module)} must declare max_attempts: #{expected.max_attempts} " <>
               "explicitly, got #{inspect(opts[:max_attempts])}"
    end
  end

  describe "durable history and redelivery" do
    setup do
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
          amount: "500.00"
        )

      {:ok, connection} = ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})
      {:ok, _} = ERP.validate_connection(scope, connection)

      customer = customer_fixture(scope)

      {:ok, _} =
        Contracts.upsert_customer_erp_mapping(scope, customer, %{
          erp_connection_id: connection.id,
          external_customer_number: "1001"
        })

      {:ok, _} =
        BillingCore.Catalog.upsert_product_erp_mapping(scope, product, %{
          erp_connection_id: connection.id,
          external_product_number: "P-1"
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

      %{scope: scope, fake: fake, operation: operation}
    end

    test "queue pruning does not remove durable operation history", %{
      scope: scope,
      operation: operation
    } do
      # Simulate Oban's Pruner having discarded every completed job row.
      {_count, _} = Repo.delete_all("oban_jobs", prefix: "public")

      # The authoritative record survives in full: the operation, its sync
      # attempt, and the inbox/recent listings that serve it.
      survivor = Operations.get!(operation.id)
      assert survivor.state == "succeeded"
      assert survivor.finished_at

      assert Repo.get_by!(BillingCore.ERP.SyncOperation, operation_id: operation.id).state ==
               "succeeded"

      team_id = BillingCore.Scope.team_id!(scope)
      assert Enum.any?(Operations.list_recent(team_id), &(&1.id == operation.id))
    end

    test "process-crash redelivery of a completed job repeats no external write", %{
      fake: fake,
      operation: operation
    } do
      # One draft exists after the successful run.
      assert [draft] = FakeERP.list_documents(fake)

      # An executor crash after commit makes Oban redeliver the same job.
      # The claim guard refuses to re-run a settled operation.
      sync_op = Repo.get_by!(BillingCore.ERP.SyncOperation, operation_id: operation.id)
      assert :ok = Sync.execute(sync_op.id)

      assert Operations.get!(operation.id).state == "succeeded"
      assert [^draft] = FakeERP.list_documents(fake)
    end
  end
end
