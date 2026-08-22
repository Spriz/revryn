defmodule BillingCore.Demo.FakeERPInstancesTest do
  use BillingCore.DataCase, async: false

  import BillingCore.OrgsFixtures

  alias BillingCore.{ERP, Repo}
  alias BillingCore.Demo.{FakeERPInstance, FakeERPInstances, Workspace}
  alias BillingCore.ERP.FakeERP

  setup do
    ensure_instance_supervisor()

    %{organization: organization, team: team, owner: owner} = organization_fixture()
    {:ok, scope} = BillingCore.Orgs.resolve_scope(owner, organization.id, team.id)

    {:ok, connection} =
      ERP.create_connection(scope, %{provider: "fake", secret_reference: "demo:test"})

    workspace =
      Repo.insert!(%Workspace{
        team_id: team.id,
        organization_id: organization.id,
        owner_user_id: owner.id,
        scenario_version: "northstar-v1",
        generation: 1,
        state: :active,
        seed_key: "seed-test",
        progress: %{},
        started_at: DateTime.utc_now()
      })

    instance =
      Repo.insert!(%FakeERPInstance{
        team_id: team.id,
        workspace_id: workspace.id,
        erp_connection_id: connection.id,
        state: :active
      })

    on_exit(fn ->
      _ = BillingCore.ERP.FakeERP.InstanceSupervisor.stop(connection.id)
    end)

    %{connection: connection, instance: instance}
  end

  test "starts an isolated connection context and persists a verified snapshot", %{
    connection: connection,
    instance: instance
  } do
    assert {:ok, context} = FakeERPInstances.context_for(connection)
    assert is_pid(context.fake_server)
    assert context.connection_id == connection.id

    assert {:ok, export} = FakeERP.export_snapshot(context.fake_server)
    assert :ok = FakeERPInstances.persist_snapshot(instance.id, export)

    persisted = Repo.get!(FakeERPInstance, instance.id)
    assert persisted.snapshot_sha256 == export.sha256
    assert persisted.snapshot_format_version == export.format_version
    assert is_binary(persisted.snapshot)
    assert persisted.lock_version == 2
  end

  test "archives and stops the provider without deleting its durable record", %{
    connection: connection,
    instance: instance
  } do
    assert {:ok, context} = FakeERPInstances.context_for(connection)
    assert is_pid(context.fake_server)

    assert :ok = FakeERPInstances.archive(instance)
    assert Repo.get!(FakeERPInstance, instance.id).state == :archived
    assert {:error, :not_found} = FakeERPInstances.context_for(connection)
  end

  test "fails loudly instead of replacing a corrupt persisted snapshot with empty state", %{
    connection: connection,
    instance: instance
  } do
    Repo.update!(
      Ecto.Changeset.change(instance,
        snapshot: <<0, 1, 2>>,
        snapshot_sha256: String.duplicate("0", 64)
      )
    )

    assert {:error, :corrupt_snapshot} = FakeERPInstances.context_for(connection)
  end

  test "rejects a non-fake connection before resolving demo runtime state", %{
    connection: connection
  } do
    assert {:error, :invalid_demo_provider} =
             FakeERPInstances.context_for(%{connection | provider: "economic"})
  end

  test "rejects a persisted snapshot whose durable format version differs from its export", %{
    connection: connection,
    instance: instance
  } do
    assert {:ok, context} = FakeERPInstances.context_for(connection)
    assert {:ok, export} = FakeERP.export_snapshot(context.fake_server)
    assert :ok = FakeERPInstances.persist_snapshot(instance.id, export)

    FakeERPInstance
    |> Repo.get!(instance.id)
    |> Ecto.Changeset.change(snapshot_format_version: export.format_version + 1)
    |> Repo.update!()

    assert {:error, :corrupt_snapshot} = FakeERPInstances.context_for(connection)
  end

  test "rejects context resolution when the demo runtime is clustered", %{connection: connection} do
    previous = Application.get_env(:billing_core, :demo_node_lister)
    Application.put_env(:billing_core, :demo_node_lister, fn -> [:demo_peer] end)

    on_exit(fn -> restore_env(:demo_node_lister, previous) end)

    assert {:error, :demo_requires_single_node} = FakeERPInstances.context_for(connection)
  end

  defp ensure_instance_supervisor do
    if Process.whereis(BillingCore.ERP.FakeERP.InstanceSupervisor) == nil do
      start_supervised!({BillingCore.ERP.FakeERP.InstanceSupervisor, []})
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_core, key)
  defp restore_env(key, value), do: Application.put_env(:billing_core, key, value)
end
