defmodule BillingCore.DemoWorkspaceTest do
  use BillingCore.DataCase, async: false

  import BillingCore.IdentityFixtures

  alias BillingCore.{Demo, Repo}
  alias BillingCore.Demo.{FakeERPInstance, Workspace}
  alias BillingCore.Orgs.TeamMembership

  test "starts an isolated ordinary team workspace and resumes it without duplication" do
    user = user_fixture()

    assert {:ok, first} = Demo.start_workspace(user)
    assert first.workspace.state == :active
    assert first.workspace.generation == 1
    assert first.workspace.scenario_version == "northstar-v1"
    assert first.connection.provider == "fake"
    assert first.connection.status == "active"
    assert Demo.demo_team?(first.team.id)

    assert {:ok, resumed} = Demo.resume_workspace(user)
    assert resumed.workspace.id == first.workspace.id
    assert Repo.aggregate(Workspace, :count) == 1
    assert Repo.aggregate(FakeERPInstance, :count) == 1
  end

  test "reset archives instead of deleting and creates generation two linked to generation one" do
    user = user_fixture()
    assert {:ok, first} = Demo.start_workspace(user)

    assert {:ok, second} = Demo.reset_workspace(user)
    assert second.workspace.generation == 2
    assert second.workspace.predecessor_workspace_id == first.workspace.id
    assert second.workspace.state == :active

    archived = Repo.get!(Workspace, first.workspace.id)
    assert archived.state == :archived
    assert archived.reset_at

    archived_instance = Repo.get_by!(FakeERPInstance, workspace_id: first.workspace.id)
    assert archived_instance.state == :archived

    old_membership =
      Repo.get_by!(TeamMembership, team_id: first.team.id, user_id: user.id)

    assert old_membership.status == :removed
    assert Repo.aggregate(Workspace, :count) == 2
  end

  test "refuses public provisioning when demo ERP is disabled" do
    user = user_fixture()
    previous = Application.get_env(:billing_core, :demo_erp_enabled)
    Application.put_env(:billing_core, :demo_erp_enabled, false)

    on_exit(fn -> Application.put_env(:billing_core, :demo_erp_enabled, previous) end)

    assert {:error, :demo_disabled} = Demo.start_workspace(user)
    assert {:error, :demo_disabled} = Demo.resume_workspace(user)
    assert {:error, :demo_disabled} = Demo.reset_workspace(user)
  end

  test "retains a failed provisioning generation and resumes it after the cause is repaired" do
    user = user_fixture()
    assert {:ok, first} = Demo.start_workspace(user)

    first.workspace
    |> Ecto.Changeset.change(state: :provisioning)
    |> Repo.update!()

    first.connection
    |> Ecto.Changeset.change(provider: "economic", status: "unvalidated")
    |> Repo.update!()

    assert {:error, :invalid_demo_provider} = Demo.resume_workspace(user)
    assert Repo.get!(Workspace, first.workspace.id).state == :provisioning
    assert {:error, :not_found} = Demo.active_workspace(user)

    BillingCore.ERP.Connection
    |> Repo.get!(first.connection.id)
    |> Ecto.Changeset.change(provider: "fake")
    |> Repo.update!()

    assert {:ok, resumed} = Demo.resume_workspace(user)
    assert resumed.workspace.id == first.workspace.id
    assert resumed.workspace.state == :active
    assert Repo.aggregate(Workspace, :count) == 1
  end

  test "rejects disabled users before any demo lifecycle mutation" do
    user = user_fixture()
    disabled = Repo.update!(Ecto.Changeset.change(user, status: :disabled))

    assert {:error, :unauthorized} = Demo.start_workspace(disabled)
    assert {:error, :unauthorized} = Demo.resume_workspace(disabled)
    assert {:error, :unauthorized} = Demo.reset_workspace(disabled)
    assert Repo.aggregate(Workspace, :count) == 0
  end

  test "rejects all public workspace access when demo runtime is clustered" do
    user = user_fixture()
    assert {:ok, bundle} = Demo.start_workspace(user)
    previous = Application.get_env(:billing_core, :demo_node_lister)
    Application.put_env(:billing_core, :demo_node_lister, fn -> [:demo_peer] end)

    on_exit(fn -> restore_env(:demo_node_lister, previous) end)

    assert {:error, :demo_requires_single_node} = Demo.active_workspace(user)
    assert {:error, :demo_requires_single_node} = Demo.resume_workspace(user)
    assert {:error, :demo_requires_single_node} = Demo.workspace_for_scope(bundle.scope)
  end

  test "reset leaves the existing workspace active when its provider cannot be safely resumed" do
    user = user_fixture()
    assert {:ok, first} = Demo.start_workspace(user)
    instance = Repo.get_by!(FakeERPInstance, workspace_id: first.workspace.id)

    Repo.update!(
      Ecto.Changeset.change(instance,
        snapshot: <<255, 0, 255>>,
        snapshot_sha256: String.duplicate("0", 64)
      )
    )

    assert {:error, :corrupt_snapshot} = Demo.reset_workspace(user)
    assert Repo.get!(Workspace, first.workspace.id).state == :active
    assert Repo.aggregate(Workspace, :count) == 1
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_core, key)
  defp restore_env(key, value), do: Application.put_env(:billing_core, key, value)
end
