defmodule BillingCore.Usage.PartitionTest do
  @moduledoc """
  Monthly partition maintenance for `billing.usage_events` (SPEC §13.1,
  §13.3): `billing.ensure_usage_partition/1` is idempotent, the maintenance
  worker keeps months ahead covered, and — because no DEFAULT partition
  exists on purpose — inserting outside the created partitions raises.
  """

  # DDL on the shared partitioned parent takes locks that can block across
  # concurrently open sandbox transactions, so this file is not async.
  use BillingCore.DataCase, async: false

  alias BillingCore.Usage
  alias BillingCore.Usage.{Event, PartitionWorker}

  import BillingCore.UsageFixtures

  defp partition_rows(name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'billing' AND c.relname = $1
        """,
        [name]
      )

    rows
  end

  describe "billing.ensure_usage_partition/1" do
    test "creates the monthly partition once, idempotently, with UTC month bounds" do
      assert partition_rows("usage_events_y2027m03") == []

      # any day of the month resolves to that month's partition
      %{rows: [["usage_events_y2027m03"]]} =
        Repo.query!("SELECT billing.ensure_usage_partition($1)", [~D[2027-03-15]])

      # replaying is a no-op returning the same name
      %{rows: [["usage_events_y2027m03"]]} =
        Repo.query!("SELECT billing.ensure_usage_partition($1)", [~D[2027-03-01]])

      assert [[_name, bounds]] = partition_rows("usage_events_y2027m03")
      assert bounds =~ "2027-03-01"
      assert bounds =~ "2027-04-01"
    end
  end

  describe "Usage.ensure_partitions/1" do
    test "covers the current month through months_ahead, idempotently" do
      assert {:ok, names} = Usage.ensure_partitions(2)
      assert length(names) == 3

      this_month = Date.beginning_of_month(Date.utc_today())

      expected_first =
        "usage_events_y#{this_month.year}m#{String.pad_leading(to_string(this_month.month), 2, "0")}"

      assert hd(names) == expected_first
      assert {:ok, ^names} = Usage.ensure_partitions(2)
    end

    test "the maintenance worker runs it on the maintenance queue" do
      assert %{changes: %{queue: "maintenance"}} = PartitionWorker.new(%{})
      assert :ok = PartitionWorker.perform(%Oban.Job{args: %{}})
      assert :ok = PartitionWorker.perform(%Oban.Job{args: %{"months_ahead" => 3}})
    end
  end

  describe "explicit partitions only (no DEFAULT partition)" do
    test "inserting an occurred_at outside the created partitions raises" do
      scope = usage_scope_fixture()
      subscription = usage_subscription_fixture(scope)

      assert_raise Postgrex.Error, ~r/no partition of relation "usage_events"/, fn ->
        Repo.insert!(%Event{
          id: Ecto.UUID.generate(),
          team_id: scope.team.id,
          external_event_id: unique_usage_event_id(),
          event_kind: :measurement,
          subscription_id: subscription.id,
          metric_code: "api_calls",
          # 2028-01 has no partition
          occurred_at: ~U[2028-01-15 00:00:00.000000Z],
          value: Decimal.new(1),
          properties: %{},
          payload_hash: "test",
          status: :effective
        })
      end
    end
  end
end
