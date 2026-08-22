defmodule BillingCoreWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "metrics/0 defines well-formed reporter metric specs" do
    metrics = BillingCoreWeb.Telemetry.metrics()

    for metric <- metrics do
      assert metric.__struct__ in [
               Telemetry.Metrics.Summary,
               Telemetry.Metrics.Counter,
               Telemetry.Metrics.Sum
             ]

      assert is_list(metric.name) and metric.name != []
    end

    names = Enum.map(metrics, &Enum.join(&1.name, "."))

    # The Phoenix/Ecto/VM baseline plus the domain metrics the SPEC calls out.
    assert "phoenix.endpoint.stop.duration" in names
    assert "billing_core.repo.query.total_time" in names
    assert "vm.memory.total" in names
    assert "billing_core.demo.step_completed.seconds_since_start" in names
    assert "billing_core.customer_credit_close.reconciled.count" in names
  end

  test "the telemetry supervisor is running under the app with its poller" do
    # Started by BillingCore.Application; the sole child is the periodic
    # measurements poller.
    assert pid = Process.whereis(BillingCoreWeb.Telemetry)
    assert [{_id, _child, :worker, _}] = Supervisor.which_children(pid)
  end
end
