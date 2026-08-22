defmodule BillingCore.Demo.FakeERPInstances do
  @moduledoc """
  Bridges a persisted demo fake-ERP instance to its supervised process.

  The process is replaceable after a restart: its export map is persisted with
  optimistic locking and supplied to the sibling instance supervisor on the
  next `context_for/1` call. It is deliberately single-node only; clustered
  BEAM nodes would create split-brain fake-provider state.
  """

  import Ecto.Query

  alias BillingCore.{Repo}
  alias BillingCore.Demo.FakeERPInstance
  alias BillingCore.ERP.Connection

  @snapshot_format_version 1

  @spec context_for(Connection.t()) ::
          {:ok, map()} | {:error, :not_found | :team_mismatch | term()}
  def context_for(%Connection{} = connection) do
    with :ok <- demo_enabled_result(),
         :ok <- single_node_result(),
         :ok <- ensure_fake_provider(connection),
         %FakeERPInstance{} = instance <- active_instance(connection),
         :ok <- ensure_team_consistency(instance, connection),
         {:ok, snapshot} <- decode_snapshot(instance),
         {:ok, pid} <-
           BillingCore.ERP.FakeERP.InstanceSupervisor.ensure_started(connection.id,
             snapshot: snapshot,
             persist_snapshot: &persist_snapshot(instance.id, &1)
           ),
         {:ok, context} <-
           BillingCore.ERP.FakeERP.InstanceSupervisor.context(connection.id, %{
             connection_id: connection.id,
             team_id: connection.team_id
           }) do
      _ = pid
      {:ok, context}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec archive(FakeERPInstance.t()) :: :ok | {:error, term()}
  def archive(%FakeERPInstance{} = instance) do
    result =
      Repo.transaction(fn ->
        locked =
          Repo.one!(from i in FakeERPInstance, where: i.id == ^instance.id, lock: "FOR UPDATE")

        if locked.state == :archived do
          locked
        else
          locked
          |> Ecto.Changeset.change(state: :archived)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> Repo.update!()
        end
      end)

    case result do
      {:ok, _instance} ->
        case BillingCore.ERP.FakeERP.InstanceSupervisor.stop(instance.erp_connection_id) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec persist_snapshot(Ecto.UUID.t(), map()) :: :ok | {:error, term()}
  def persist_snapshot(
        instance_id,
        %{format_version: version, payload: _payload, sha256: sha256} = export
      )
      when is_integer(version) and version > 0 and is_binary(sha256) do
    bytes = :erlang.term_to_binary(export, [:deterministic])

    case fetch_active_instance(instance_id) do
      nil -> {:error, :not_found}
      instance -> store_verified_snapshot(instance, export, bytes)
    end
  end

  def persist_snapshot(_instance_id, _export), do: {:error, :invalid_snapshot}

  defp fetch_active_instance(instance_id) do
    Repo.one(from i in FakeERPInstance, where: i.id == ^instance_id and i.state == :active)
  end

  defp store_verified_snapshot(
         instance,
         %{format_version: version, sha256: sha256} = export,
         bytes
       ) do
    expected_sha256 = binary_sha256(export.payload)

    if version == @snapshot_format_version and sha256 == expected_sha256 do
      update_snapshot_columns(instance, bytes, sha256, version)
    else
      {:error, :snapshot_hash_mismatch}
    end
  end

  defp update_snapshot_columns(instance, bytes, sha256, version) do
    instance
    |> Ecto.Changeset.change(
      snapshot: bytes,
      snapshot_sha256: sha256,
      snapshot_format_version: version
    )
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp active_instance(%Connection{id: connection_id}) do
    Repo.one(
      from i in FakeERPInstance,
        where: i.erp_connection_id == ^connection_id and i.state == :active
    )
  end

  defp ensure_team_consistency(%FakeERPInstance{team_id: team_id}, %Connection{team_id: team_id}),
    do: :ok

  defp ensure_team_consistency(_, _), do: {:error, :team_mismatch}

  defp decode_snapshot(%FakeERPInstance{
         snapshot: nil,
         snapshot_sha256: nil,
         snapshot_format_version: @snapshot_format_version
       }),
       do: {:ok, nil}

  defp decode_snapshot(%FakeERPInstance{snapshot: nil}), do: {:error, :corrupt_snapshot}

  defp decode_snapshot(%FakeERPInstance{
         snapshot: bytes,
         snapshot_sha256: stored_sha256,
         snapshot_format_version: stored_version
       })
       when is_binary(bytes) and is_binary(stored_sha256) do
    case decode_snapshot_bytes(bytes) do
      {:ok, export} -> validate_decoded_export(export, stored_sha256, stored_version)
      :error -> {:error, :corrupt_snapshot}
    end
  end

  defp decode_snapshot(_), do: {:error, :corrupt_snapshot}

  defp decode_snapshot_bytes(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp validate_decoded_export(
         %{format_version: version, payload: payload, sha256: sha256} = export,
         stored_sha256,
         stored_version
       )
       when is_integer(version) and version > 0 and is_binary(payload) and is_binary(sha256) do
    if export_matches_stored?(version, payload, sha256, stored_sha256, stored_version),
      do: {:ok, export},
      else: {:error, :corrupt_snapshot}
  end

  defp validate_decoded_export(_other, _stored_sha256, _stored_version),
    do: {:error, :corrupt_snapshot}

  defp export_matches_stored?(version, payload, sha256, stored_sha256, stored_version) do
    version == @snapshot_format_version and stored_version == version and
      sha256 == stored_sha256 and sha256 == binary_sha256(payload)
  end

  defp ensure_fake_provider(%Connection{provider: "fake"}), do: :ok
  defp ensure_fake_provider(_), do: {:error, :invalid_demo_provider}

  defp single_node_result do
    if BillingCore.Demo.single_node?(), do: :ok, else: {:error, :demo_requires_single_node}
  end

  defp demo_enabled_result do
    if BillingCore.Demo.enabled?(), do: :ok, else: {:error, :demo_disabled}
  end

  defp binary_sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
