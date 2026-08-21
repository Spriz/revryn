defmodule BillingCore.Release do
  @moduledoc """
  Release commands run inside the official image (SPEC §12.2.2, §22.6):

      bin/billing_core eval "BillingCore.Release.migrate()"
      bin/billing_core eval "BillingCore.Release.doctor()"

  `doctor/0` performs redacted configuration and dependency checks and prints
  human-readable text (machine-readable JSON via `doctor(:json)`). It never
  prints secret values.
  """

  @app :billing_core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc "Runs redacted diagnostics; exits non-zero when a required check fails."
  def doctor(format \\ :text) do
    load_app()

    checks =
      [
        check_database(),
        check_migrations(),
        check_secret_key_base(),
        check_clock()
      ]

    case format do
      :json ->
        IO.puts(Jason.encode!(%{checks: Enum.map(checks, &Map.new/1)}))

      _ ->
        for check <- checks do
          status = check[:status] |> to_string() |> String.upcase() |> String.pad_trailing(5)
          IO.puts("[#{status}] #{check[:name]}: #{check[:detail]}")
        end
    end

    if Enum.any?(checks, &(&1[:status] == :fail)) do
      System.stop(1)
    end

    :ok
  end

  defp check_database do
    case Ecto.Migrator.with_repo(BillingCore.Repo, fn repo ->
           repo.query!("SELECT 1", [])
         end) do
      {:ok, _, _} -> %{name: "database", status: :pass, detail: "reachable"}
    end
  rescue
    error ->
      %{name: "database", status: :fail, detail: redact(Exception.message(error))}
  end

  defp check_migrations do
    {:ok, pending, _} =
      Ecto.Migrator.with_repo(BillingCore.Repo, fn repo ->
        repo
        |> Ecto.Migrator.migrations()
        |> Enum.count(fn {status, _v, _n} -> status == :down end)
      end)

    if pending == 0 do
      %{name: "migrations", status: :pass, detail: "up to date"}
    else
      %{name: "migrations", status: :fail, detail: "#{pending} pending migrations"}
    end
  rescue
    error -> %{name: "migrations", status: :fail, detail: redact(Exception.message(error))}
  end

  defp check_secret_key_base do
    secret =
      Application.get_env(@app, BillingCoreWeb.Endpoint, [])
      |> Keyword.get(:secret_key_base)

    cond do
      is_nil(secret) -> %{name: "secret_key_base", status: :fail, detail: "not configured"}
      byte_size(secret) < 64 -> %{name: "secret_key_base", status: :fail, detail: "too short"}
      true -> %{name: "secret_key_base", status: :pass, detail: "configured"}
    end
  end

  defp check_clock do
    drift = abs(System.os_time(:second) - DateTime.to_unix(DateTime.utc_now()))

    if drift < 5 do
      %{name: "clock", status: :pass, detail: "sane"}
    else
      %{name: "clock", status: :warn, detail: "os/runtime drift #{drift}s"}
    end
  end

  # Best-effort scrubbing of connection URLs and obvious secrets from error text.
  defp redact(message) do
    message
    |> String.replace(~r/postgres(ql)?:\/\/\S+/, "postgres://[redacted]")
    |> String.replace(~r/password[=:]\s*\S+/i, "password=[redacted]")
    |> String.slice(0, 300)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
