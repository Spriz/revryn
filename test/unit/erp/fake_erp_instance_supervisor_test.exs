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
