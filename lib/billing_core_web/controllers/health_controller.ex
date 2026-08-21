defmodule BillingCoreWeb.HealthController do
  @moduledoc """
  Liveness and readiness endpoints (SPEC §22.6).

  `/health/live` answers whether the release process can serve requests and
  performs no external dependency check. `/health/ready` answers whether this
  node may safely receive normal work: database connectivity, migration
  compatibility, and queue initialization. Tolerated provider outages do not
  make the node unready; they surface as degraded components.
  """

  use BillingCoreWeb, :controller

  alias BillingCore.Repo

  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def ready(conn, _params) do
    checks = [
      {"database", &database_check/0},
      {"migrations", &migrations_check/0},
      {"queues", &queues_check/0}
    ]

    results =
      Map.new(checks, fn {name, check} ->
        {name,
         case safe_check(check) do
           :ok -> "ok"
           {:error, reason} -> "failed: #{reason}"
         end}
      end)

    if Enum.all?(results, fn {_name, status} -> status == "ok" end) do
      json(conn, %{status: "ok", checks: results})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "unavailable", checks: results})
    end
  end

  defp safe_check(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error) |> String.slice(0, 200)}
  end

  defp database_check do
    case Repo.query("SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "database unreachable"}
    end
  end

  defp migrations_check do
    case Ecto.Migrator.migrations(Repo) do
      migrations when is_list(migrations) ->
        pending = Enum.count(migrations, fn {status, _version, _name} -> status == :down end)
        if pending == 0, do: :ok, else: {:error, "#{pending} pending migrations"}
    end
  end

  defp queues_check do
    case Oban.check_queue(queue: :billing) do
      %{} -> :ok
      _ -> {:error, "oban not started"}
    end
  rescue
    _ -> {:error, "oban not started"}
  end
end
