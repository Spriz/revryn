defmodule BillingCore.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    metrics_children =
      if Application.get_env(:billing_core, :start_metrics_exporter, true) do
        [
          {TelemetryMetricsPrometheus,
           metrics: BillingCore.Metrics.metrics(),
           port: Application.get_env(:billing_core, :metrics_port, 9568)}
        ]
      else
        []
      end

    children = [
      BillingCoreWeb.Telemetry,
      BillingCore.Repo,
      {DNSCluster, query: Application.get_env(:billing_core, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:billing_core, Oban)},
      {Phoenix.PubSub, name: BillingCore.PubSub},
      # Start to serve requests, typically the last entry
      BillingCoreWeb.Endpoint
    ]

    children = metrics_children ++ children

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BillingCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BillingCoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
