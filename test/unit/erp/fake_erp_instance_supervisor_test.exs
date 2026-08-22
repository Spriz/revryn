defmodule BillingCore.ERP.FakeERP.InstanceSupervisorTest do
  use ExUnit.Case, async: false

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.{CanonicalInvoice, FakeERP}
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.FakeERP.InstanceSupervisor

  test "isolates instances by ERP connection and builds adapter contexts" do
    connection_a = Ecto.UUID.generate()
    connection_b = Ecto.UUID.generate()

    on_exit(fn ->
      stop_if_running(connection_a)
      stop_if_running(connection_b)
    end)

    assert {:ok, pid_a} = InstanceSupervisor.ensure_started(connection_a)
    assert {:ok, pid_b} = InstanceSupervisor.ensure_started(connection_b)
    refute pid_a == pid_b

    assert {:ok, context} =
             InstanceSupervisor.context(connection_a, %{team_id: Ecto.UUID.generate()})

    assert context.connection_id == connection_a
    assert context.provider == :fake_erp
    assert context.fake_server == pid_a

    ref = Process.monitor(pid_a)
    assert :ok = InstanceSupervisor.stop(connection_a)
    assert_receive {:DOWN, ^ref, :process, ^pid_a, :shutdown}
    await_unregistered(connection_a)
    assert {:ok, ^pid_b} = InstanceSupervisor.fetch(connection_b)
  end

  test "concurrent ensure calls converge on one instance" do
    connection_id = Ecto.UUID.generate()
    on_exit(fn -> stop_if_running(connection_id) end)

    results =
      1..12
      |> Task.async_stream(fn _ -> InstanceSupervisor.ensure_started(connection_id) end,
        max_concurrency: 12,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert [pid | rest] = results
    assert Enum.all?(rest, &(&1 == pid))
    assert {:ok, ^pid} = InstanceSupervisor.fetch(connection_id)
  end

  test "a killed temporary child stays absent until a newer snapshot explicitly rehydrates it" do
    connection_id = Ecto.UUID.generate()
    on_exit(fn -> stop_if_running(connection_id) end)

    initial = snapshot_with_reference("initial-ref")
    assert {:ok, pid} = InstanceSupervisor.ensure_started(connection_id, snapshot: initial)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_unregistered(connection_id)

    newer = snapshot_with_reference("newer-ref", initial)
    assert {:ok, rehydrated} = InstanceSupervisor.ensure_started(connection_id, snapshot: newer)
    refute rehydrated == pid

    context = FakeERP.connection_context(rehydrated)
    assert {:ok, document} = FakeERP.find_document(context, "newer-ref")
    assert document.external_reference == "newer-ref"
  end

  test "the application owns the singleton supervisor; a second start is refused" do
    # The default-name supervisor is started by BillingCore.Application. The
    # Registry/DynamicSupervisor names are global, so a competing start_link
    # must fail instead of silently splitting instance registration.
    assert {:error, {:already_started, pid}} = InstanceSupervisor.start_link()
    assert Process.whereis(InstanceSupervisor) == pid
  end

  test "context/1 defaults the base map and still requires a running instance" do
    connection_id = Ecto.UUID.generate()
    on_exit(fn -> stop_if_running(connection_id) end)

    assert {:error, :not_found} = InstanceSupervisor.context(connection_id)

    assert {:ok, pid} = InstanceSupervisor.ensure_started(connection_id)
    assert {:ok, context} = InstanceSupervisor.context(connection_id)

    assert context == %{
             connection_id: connection_id,
             provider: :fake_erp,
             fake_server: pid
           }
  end

  test "a start failure surfaces the reason instead of registering a broken instance" do
    connection_id = Ecto.UUID.generate()

    # FakeERP validates its startup snapshot before registering anything, so
    # the dynamic supervisor reports the error and nothing is left behind.
    assert {:error, {:invalid_snapshot, :malformed_snapshot}} =
             InstanceSupervisor.ensure_started(connection_id, snapshot: %{bogus: true})

    assert {:error, :not_found} = InstanceSupervisor.fetch(connection_id)

    # The connection is not poisoned: a valid start still works afterwards.
    on_exit(fn -> stop_if_running(connection_id) end)
    assert {:ok, pid} = InstanceSupervisor.ensure_started(connection_id)
    assert {:ok, ^pid} = InstanceSupervisor.fetch(connection_id)
  end

  # Two start_instance/2 branches stay uncovered deliberately:
  #
  #   * `{:error, {:already_present, _child}}` — DynamicSupervisor never
  #     returns :already_present (that is a static Supervisor.start_child
  #     result); the clause is defensive only.
  #   * the `{:ok, pid}` arm of the final fetch fallback — it requires a
  #     competing caller to win the Registry race in the window between this
  #     caller's failed start_child and its follow-up fetch, which cannot be
  #     scheduled deterministically from a test.

  defp snapshot_with_reference(reference, snapshot \\ nil) do
    server = start_supervised!({FakeERP, snapshot: snapshot}, id: {:snapshot_fake_erp, reference})
    context = FakeERP.connection_context(server)

    invoice = %CanonicalInvoice{
      external_reference: reference,
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Example ApS", country: "DK"},
      invoice_date: ~D[2026-08-31],
      currency: "DKK",
      lines: [
        %Line{
          order: 0,
          line_key: reference,
          product_external_id: "SUBSCRIPTION",
          description: "Monthly subscription",
          amount: Money.new!("DKK", 12_500),
          recognition: :point_in_time
        }
      ]
    }

    assert {:ok, _document} = FakeERP.create_draft(context, invoice, "snapshot:#{reference}")
    assert {:ok, exported} = FakeERP.export_snapshot(server)
    exported
  end

  # Registry key cleanup is asynchronous even after the instance's DOWN is
  # observed: the registry partition that monitored the process removes the
  # key in its own time, and `:sys.get_state` on the registry name does not
  # synchronize with that partition. Poll briefly instead.
  defp await_unregistered(connection_id, attempts \\ 100) do
    case InstanceSupervisor.fetch(connection_id) do
      {:error, :not_found} ->
        :ok

      {:ok, _pid} when attempts > 0 ->
        Process.sleep(10)
        await_unregistered(connection_id, attempts - 1)

      {:ok, pid} ->
        flunk("instance #{inspect(pid)} is still registered for #{connection_id}")
    end
  end

  defp stop_if_running(connection_id) do
    case InstanceSupervisor.stop(connection_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
