defmodule BillingCore.Usage.AggregationTest do
  @moduledoc """
  Aggregation date-assignment and determinism (BC-US-053/054/055, SPEC §9.2).

  Period assignment converts each event's `occurred_at` instant to the team
  billing time zone (via the configured `tz` database) and tests the
  resulting local DATE against the half-open date period. Should a team
  carry a zone unknown to the database, the UTC date is the documented
  graceful fallback.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.Usage
  alias BillingCore.Usage.Event
  alias BillingCore.Domain.Period

  import BillingCore.UsageFixtures

  setup do
    scope = usage_scope_fixture()
    subscription = usage_subscription_fixture(scope)
    %{scope: scope, subscription: subscription}
  end

  # Inserts a measurement row directly (bypassing ingestion age limits) so
  # date-assignment can be probed at instants outside the ±90d/24h window.
  defp insert_measurement!(scope, subscription, occurred_at, value) do
    Repo.insert!(%Event{
      id: Ecto.UUID.generate(),
      team_id: scope.team.id,
      external_event_id: unique_usage_event_id(),
      event_kind: :measurement,
      subscription_id: subscription.id,
      metric_code: "api_calls",
      occurred_at: occurred_at,
      value: value,
      properties: %{},
      payload_hash: "test",
      status: :effective
    })
  end

  describe "date assignment in the team billing time zone (SPEC §9.2)" do
    # The team default zone is Europe/Copenhagen; DST ended 2026-10-25, so
    # October 2026 starts at 2026-09-30T22:00Z (CEST, +2) but ends at
    # 2026-10-31T23:00Z (CET, +1).
    @october Period.new!(~D[2026-10-01], ~D[2026-11-01])
    @november Period.new!(~D[2026-11-01], ~D[2026-12-01])

    test "an instant late in the UTC month belongs to the team-local next month", ctx do
      # 2026-10-31T23:30Z is 2026-11-01 00:30 CET — November in Copenhagen,
      # even though the UTC date is still October 31
      boundary_instant = ~U[2026-10-31 23:30:00.000000Z]

      assert {:ok, shifted} = DateTime.shift_zone(boundary_instant, ctx.scope.team.time_zone)
      assert DateTime.to_date(shifted) == ~D[2026-11-01]

      insert_measurement!(ctx.scope, ctx.subscription, boundary_instant, Decimal.new("7"))
      cutoff = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, october} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", @october, cutoff)

      assert october.event_count == 0
      assert Decimal.eq?(october.quantity, Decimal.new(0))

      assert {:ok, november} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", @november, cutoff)

      assert november.event_count == 1
      assert Decimal.eq?(november.quantity, Decimal.new(7))
    end

    test "membership is half-open on the local date, with DST-dependent UTC boundaries", ctx do
      # end of October: local midnight is 23:00Z because DST ended Oct 25
      insert_measurement!(
        ctx.scope,
        ctx.subscription,
        ~U[2026-10-31 22:59:59.999999Z],
        Decimal.new("1")
      )

      insert_measurement!(
        ctx.scope,
        ctx.subscription,
        ~U[2026-10-31 23:00:00.000000Z],
        Decimal.new("10")
      )

      # start of October: local midnight is 22:00Z (still CEST, +2)
      insert_measurement!(
        ctx.scope,
        ctx.subscription,
        ~U[2026-09-30 22:00:00.000000Z],
        Decimal.new("100")
      )

      insert_measurement!(
        ctx.scope,
        ctx.subscription,
        ~U[2026-09-30 21:59:59.999999Z],
        Decimal.new("1000")
      )

      cutoff = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, october} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", @october, cutoff)

      # the 22:59:59.999999Z (Oct 31 local) and 22:00Z (Oct 1 local) events
      assert october.event_count == 2
      assert Decimal.eq?(october.quantity, Decimal.new(101))

      assert {:ok, november} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", @november, cutoff)

      assert Decimal.eq?(november.quantity, Decimal.new(10))
    end

    test "an unknown team zone falls back to the UTC date instead of failing" do
      # graceful documented fallback: a zone the tz database does not know
      %{organization: organization, team: team} =
        BillingCore.OrgsFixtures.organization_fixture(%{time_zone: "Not/AZone"})

      scope =
        BillingCore.ContractsFixtures.team_scope_fixture(organization, team, [:billing_admin])

      subscription = usage_subscription_fixture(scope, %{time_zone: "Etc/UTC"})

      assert {:error, _} = DateTime.shift_zone(~U[2026-10-31 23:30:00.000000Z], team.time_zone)

      insert_measurement!(
        scope,
        subscription,
        ~U[2026-10-31 23:30:00.000000Z],
        Decimal.new("7")
      )

      cutoff = DateTime.add(DateTime.utc_now(), 60, :second)

      # by UTC date the event stays in October
      assert {:ok, october} = Usage.aggregate(scope, subscription, "api_calls", @october, cutoff)
      assert october.event_count == 1
      assert Decimal.eq?(october.quantity, Decimal.new(7))
    end
  end

  describe "determinism (BC-US-053/055)" do
    test "the same frozen cutoff always produces the identical result", ctx do
      base = DateTime.add(DateTime.utc_now(), -86_400, :second)

      period =
        Period.new!(Date.add(DateTime.to_date(base), -1), Date.add(DateTime.to_date(base), 2))

      ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
        external_event_id: "evt-det-1",
        occurred_at: base,
        value: Decimal.new("1.5")
      })

      ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
        external_event_id: "evt-det-2",
        occurred_at: DateTime.add(base, 30, :second),
        value: Decimal.new("2.5")
      })

      cutoff = Repo.get_by!(Event, external_event_id: "evt-det-2").received_at

      assert {:ok, first} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", period, cutoff)

      assert {:ok, second} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", period, cutoff)

      assert first == second
      assert Decimal.eq?(first.quantity, Decimal.new(4))

      # even after a later correction, the frozen cutoff reproduces the
      # exact same evidence set (the void was received after the cutoff)
      assert {:ok, %{status: :voided}} =
               Usage.void_event(ctx.scope, "evt-det-1", void_event_id: "void-det-1")

      assert {:ok, third} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", period, cutoff)

      assert third == first
    end
  end
end
