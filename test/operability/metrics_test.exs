defmodule BillingCore.MetricsTest do
  @moduledoc """
  Prometheus metric definitions (SPEC §22.3, INV-039): the exporter spec
  list covers the required families, labels stay bounded-cardinality, and
  the tag derivations classify rather than leak.

  Regression guard: `telemetry_metrics` silently drops a `:name` rename
  option, which once shipped two metrics under the same
  `oban.job.stop.duration` name. Intended names must be the first argument
  with `event_name:` pointing at the source event — these tests pin the
  exported names AND their uniqueness.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Metrics

  defp find_by_name!(module, name) do
    Enum.find(
      Metrics.metrics(),
      &(&1.__struct__ == module and Enum.join(&1.name, ".") == name)
    ) || raise "#{inspect(module)} metric #{name} not defined"
  end

  test "metrics/0 builds valid exporter specs covering the required families" do
    metrics = Metrics.metrics()

    assert Enum.all?(metrics, fn metric ->
             match?(%Telemetry.Metrics.Counter{}, metric) or
               match?(%Telemetry.Metrics.Distribution{}, metric) or
               match?(%Telemetry.Metrics.LastValue{}, metric)
           end)

    names = Enum.map(metrics, &Enum.join(&1.name, "."))

    for expected <- [
          # HTTP + database
          "billing.http.requests.total",
          "phoenix.endpoint.stop.duration",
          "billing_core.repo.query.total_time",
          "billing_core.repo.query.queue_time",
          # Oban job families
          "oban.jobs.completed.total",
          "oban.jobs.errored.total",
          "oban.job.stop.duration",
          # Durable operations + outbox
          "billing.operations.transitions.total",
          "billing.outbox.published.total",
          # BEAM
          "vm.memory.total",
          "vm.system_counts.process_count"
        ] do
      assert expected in names, "missing metric #{expected}"
    end

    # No two metrics may share an exported name within the same type —
    # Prometheus registries reject duplicate registrations.
    duplicates =
      metrics
      |> Enum.frequencies_by(&{&1.__struct__, Enum.join(&1.name, ".")})
      |> Enum.filter(fn {_key, count} -> count > 1 end)

    assert duplicates == []
  end

  test "labels stay bounded-cardinality (INV-039)" do
    forbidden = [:team_id, :customer_id, :invoice_id, :provider_message, :path]

    for metric <- Metrics.metrics(), tag <- metric.tags do
      refute tag in forbidden, "#{Enum.join(metric.name, ".")} labels by #{tag}"
    end
  end

  test "http requests are labeled by status class only" do
    metric = find_by_name!(Telemetry.Metrics.Counter, "billing.http.requests.total")

    assert metric.event_name == [:phoenix, :endpoint, :stop]
    assert metric.tags == [:status_class]
    assert metric.tag_values.(%{conn: %Plug.Conn{status: 204}}) == %{status_class: "2xx"}
    assert metric.tag_values.(%{conn: %Plug.Conn{status: 503}}) == %{status_class: "5xx"}
    # A conn that crashed before a status was set still yields a label.
    assert metric.tag_values.(%{conn: %Plug.Conn{status: nil}}) == %{status_class: "0xx"}
    # Metadata without a conn (unexpected emitter) degrades, never raises.
    assert metric.tag_values.(%{}) == %{status_class: "unknown"}
  end

  test "oban job counters are labeled by queue with a bounded fallback" do
    for {name, event} <- [
          {"oban.jobs.completed.total", [:oban, :job, :stop]},
          {"oban.jobs.errored.total", [:oban, :job, :exception]}
        ] do
      metric = find_by_name!(Telemetry.Metrics.Counter, name)

      assert metric.event_name == event
      assert metric.tags == [:queue]
      assert metric.tag_values.(%{job: %{queue: "billing"}}) == %{queue: "billing"}
      assert metric.tag_values.(%{}) == %{queue: "unknown"}
    end
  end
end
