defmodule BillingCore.ApplicationTest do
  @moduledoc """
  OTP application callbacks. `start/2` itself (including the
  `:start_metrics_exporter` child branch) is exercised by the running test
  application and cannot be re-invoked here without stopping and restarting
  `:billing_core` mid-suite, which would tear down the shared Repo/Endpoint.
  """

  use ExUnit.Case, async: false

  test "config_change/3 forwards to the endpoint and returns :ok" do
    # Hot-upgrade callback: with no changed or removed keys the endpoint
    # reload is a no-op and the contract is to return :ok.
    assert BillingCore.Application.config_change([], [], []) == :ok
  end

  test "config_change/3 tolerates changes unrelated to the endpoint" do
    assert BillingCore.Application.config_change([unrelated: :value], [], [:also_unrelated]) ==
             :ok
  end

  test "the supervision tree is running with its configured children" do
    children = Supervisor.which_children(BillingCore.Supervisor)
    ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

    assert BillingCoreWeb.Telemetry in ids
    assert BillingCore.Repo in ids
    assert BillingCoreWeb.Endpoint in ids
    assert Oban in ids

    # Test config disables the Prometheus exporter child.
    refute Application.get_env(:billing_core, :start_metrics_exporter, true)
    refute TelemetryMetricsPrometheus in ids
  end
end
