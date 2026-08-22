defmodule BillingCoreWeb.StubQueueProducer do
  @moduledoc """
  Minimal stand-in for an Oban queue producer. The test env runs Oban with
  `testing: :manual`, so no real producers exist; registering under the
  real registry key for the billing queue lets the readiness check observe
  an initialized queue exactly as it would in a running release.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: Oban.Registry.via(Oban, {:producer, "billing"}))
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:check, _from, state) do
    {:reply, %{queue: "billing", running: [], paused: false}, state}
  end
end

defmodule BillingCoreWeb.HealthControllerTest do
  @moduledoc """
  Liveness and readiness endpoints (SPEC §22.6): liveness never touches
  dependencies; readiness reports each dependency check and answers 503
  until all of them pass.
  """

  use BillingCoreWeb.ConnCase, async: false

  test "GET /health/live answers ok without any dependency checks", %{conn: conn} do
    conn = get(conn, ~p"/health/live")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /health/ready is ok when database, migrations, and queues all pass", %{conn: conn} do
    start_supervised!(BillingCoreWeb.StubQueueProducer)

    conn = get(conn, ~p"/health/ready")

    assert %{"status" => "ok", "checks" => checks} = json_response(conn, 200)
    assert checks == %{"database" => "ok", "migrations" => "ok", "queues" => "ok"}
  end

  test "GET /health/ready reports unavailable while queues are not initialized", %{conn: conn} do
    # `testing: :manual` keeps Oban's producers stopped — exactly the
    # not-ready-for-traffic state §22.6 wants surfaced, with the healthy
    # components still reported individually.
    conn = get(conn, ~p"/health/ready")

    assert %{"status" => "unavailable", "checks" => checks} = json_response(conn, 503)
    assert checks["database"] == "ok"
    assert checks["migrations"] == "ok"
    assert checks["queues"] == "failed: oban not started"
  end

  # The database-unreachable and pending-migrations branches (and the
  # safe_check rescue that guards them) require tearing down the Repo or an
  # unmigrated database, which the sandboxed suite cannot do without taking
  # down every other test on the shared connection pool.
end
