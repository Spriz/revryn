defmodule BillingCore.Metrics do
  @moduledoc """
  Prometheus-compatible metrics definitions (SPEC §22.3, INV-039).

  Metrics use bounded-cardinality dimensions only: team IDs, customer IDs,
  invoice IDs, and free-form provider messages are prohibited as labels —
  those belong in correlated logs/traces. The exporter serves
  `GET /metrics` on the port configured under
  `config :billing_core, :metrics_port` (default 9568), independent of the
  application endpoint.
  """

  import Telemetry.Metrics

  @doc "Domain + framework metrics for the Prometheus exporter."
  def metrics do
    [
      # HTTP (from Phoenix telemetry)
      counter("billing.http.requests.total",
        event_name: [:phoenix, :endpoint, :stop],
        description: "HTTP requests served",
        tags: [:status_class],
        tag_values: &http_tags/1
      ),
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500]]
      ),

      # Database
      distribution("billing_core.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1000]]
      ),
      distribution("billing_core.repo.query.queue_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 50, 100]]
      ),

      # Oban (SPEC §22.3 oban_* family)
      counter("oban.job.stop.duration",
        name: "oban.jobs.completed.total",
        tags: [:queue],
        tag_values: &oban_tags/1
      ),
      counter("oban.job.exception.duration",
        name: "oban.jobs.errored.total",
        tags: [:queue],
        tag_values: &oban_tags/1
      ),
      distribution("oban.job.stop.duration",
        unit: {:native, :millisecond},
        tags: [:queue],
        tag_values: &oban_tags/1,
        reporter_options: [buckets: [10, 100, 1000, 10_000, 60_000]]
      ),

      # Durable operations (SPEC §22.9.4)
      counter("billing_core.operation.transition.count",
        name: "billing.operations.transitions.total",
        tags: [:type, :to_state]
      ),

      # Outbox
      counter("billing_core.outbox.published.count",
        name: "billing.outbox.published.total",
        tags: [:event_type]
      ),

      # BEAM
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.system_counts.process_count")
    ]
  end

  defp http_tags(%{conn: conn}) do
    %{status_class: "#{div(conn.status || 0, 100)}xx"}
  end

  defp http_tags(_), do: %{status_class: "unknown"}

  defp oban_tags(%{job: %{queue: queue}}), do: %{queue: queue}
  defp oban_tags(_), do: %{queue: "unknown"}
end
