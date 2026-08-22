defmodule BillingCore.ERP.FakeERP.InstanceSupervisor do
  @moduledoc """
  Connection-scoped runtime instances for the stateful fake ERP.

  Each ERP connection is assigned one dynamically supervised fake server. The
  Registry name makes concurrent `ensure_started/2` calls converge without
  relying on callers to coordinate process startup.
  """

  use Supervisor

  alias BillingCore.ERP.FakeERP

  @registry __MODULE__.Registry
  @dynamic_supervisor __MODULE__.DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Starts or returns the sole fake ERP instance for a connection."
  @spec ensure_started(Ecto.UUID.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(connection_id, opts \\ []) when is_binary(connection_id) do
    case fetch(connection_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        start_instance(connection_id, opts)
    end
  end

  @doc "Returns the currently running fake ERP process for a connection."
  @spec fetch(Ecto.UUID.t()) :: {:ok, pid()} | {:error, :not_found}
  def fetch(connection_id) when is_binary(connection_id) do
    case Registry.lookup(@registry, connection_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Builds an adapter connection context for an already-started instance."
  @spec context(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def context(connection_id, base \\ %{}) when is_binary(connection_id) and is_map(base) do
    with {:ok, pid} <- fetch(connection_id) do
      {:ok,
       base
       |> Map.put(:connection_id, connection_id)
       |> Map.put(:provider, :fake_erp)
       |> Map.put(:fake_server, pid)}
    end
  end

  @doc "Stops one connection-scoped fake ERP instance, if it is running."
  @spec stop(Ecto.UUID.t()) :: :ok | {:error, :not_found | term()}
  def stop(connection_id) when is_binary(connection_id) do
    with {:ok, pid} <- fetch(connection_id) do
      DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
    end
  end

  defp start_instance(connection_id, opts) do
    child_spec = %{
      id: {:fake_erp, connection_id},
      start: {FakeERP, :start_link, [Keyword.put(opts, :name, via(connection_id))]},
      # A restarted child would receive the startup snapshot captured in this
      # child spec. Let the next context resolution hydrate a fresh process
      # from durable storage instead of reviving stale in-memory state.
      restart: :temporary,
      type: :worker
    }

    case DynamicSupervisor.start_child(@dynamic_supervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:already_present, _child}} ->
        fetch(connection_id)

      {:error, _reason} = error ->
        # A competing caller can win the Registry race just before the dynamic
        # supervisor returns. Prefer the registered instance in that case.
        case fetch(connection_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, :not_found} -> error
        end
    end
  end

  defp via(connection_id), do: {:via, Registry, {@registry, connection_id}}
end
