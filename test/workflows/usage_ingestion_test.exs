defmodule BillingCore.Workflows.UsageIngestionTest do
  @moduledoc """
  Usage ingestion, correction, and aggregation as documentation
  (BC-US-050…055, SPEC §13.3, §18.5): a usage event is ingested exactly once
  per team-scoped external event ID with server-assigned `received_at`;
  batches keep every event independent and emit one batch fact; corrections
  are immutable void + optional replacement rows whose cutoff semantics keep
  frozen aggregations reproducible; and aggregation previews are pure,
  deterministic reads.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Outbox, Usage}
  alias BillingCore.Domain.{Canonical, Period}
  alias BillingCore.Usage.{Event, QuarantineEntry}

  import BillingCore.ContractsFixtures
  import BillingCore.UsageFixtures

  setup do
    scope = usage_scope_fixture()
    subscription = usage_subscription_fixture(scope)

    # A stable instant safely inside the accepted age window and the created
    # monthly partitions, plus a date period generously containing it.
    base = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
    base_date = DateTime.to_date(base)
    period = Period.new!(Date.add(base_date, -1), Date.add(base_date, 2))

    %{scope: scope, subscription: subscription, base: base, period: period}
  end

  describe "ingesting a usage event (BC-US-050)" do
    test "accepts, then replays as duplicate, then conflicts on a changed payload", ctx do
      attrs =
        valid_usage_event_attrs(ctx.subscription, %{
          external_event_id: "evt-ingest-1",
          occurred_at: ctx.base,
          value: Decimal.new("2.5")
        })

      assert {:ok, %{status: :accepted, usage_event_id: event_id, received_at: received_at}} =
               Usage.ingest_event(ctx.scope, attrs)

      # received_at is trusted PostgreSQL clock time, roughly now
      assert abs(DateTime.diff(DateTime.utc_now(), received_at, :second)) < 60

      # identical canonical replay returns the original, no new row —
      # including a differently written but canonically equal Decimal
      assert {:ok, %{status: :duplicate, usage_event_id: ^event_id}} =
               Usage.ingest_event(ctx.scope, attrs)

      assert {:ok, %{status: :duplicate, usage_event_id: ^event_id}} =
               Usage.ingest_event(ctx.scope, %{attrs | value: Decimal.new("2.50")})

      assert Repo.aggregate(
               from(e in Event, where: e.external_event_id == "evt-ingest-1"),
               :count
             ) == 1

      # same external event ID with a different payload is a conflict
      assert {:error, :conflict} =
               Usage.ingest_event(ctx.scope, %{attrs | value: Decimal.new("9")})
    end

    test "never accepts received_at from the caller", ctx do
      spoofed = ~U[2020-01-01 00:00:00.000000Z]

      attrs =
        valid_usage_event_attrs(ctx.subscription, %{
          occurred_at: ctx.base,
          received_at: spoofed
        })

      assert {:ok, %{status: :accepted, received_at: received_at}} =
               Usage.ingest_event(ctx.scope, attrs)

      assert DateTime.compare(received_at, spoofed) == :gt
    end

    test "resolves the subscription by external ID within the team", ctx do
      attrs =
        ctx.subscription
        |> valid_usage_event_attrs(%{occurred_at: ctx.base})
        |> Map.delete(:subscription_id)
        |> Map.put(:subscription_external_id, ctx.subscription.external_id)

      assert {:ok, %{status: :accepted, usage_event_id: event_id}} =
               Usage.ingest_event(ctx.scope, attrs)

      event = Repo.one!(from e in Event, where: e.id == ^event_id)
      assert event.subscription_id == ctx.subscription.id
    end

    test "quarantines instead of silently discarding (§18.5)", ctx do
      # unknown subscription
      unknown =
        valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base})
        |> Map.delete(:subscription_id)
        |> Map.put(:subscription_external_id, "sub-does-not-exist")

      assert {:ok, %{status: :quarantined, reason: :unknown_subscription, quarantine_id: qid}} =
               Usage.ingest_event(ctx.scope, unknown)

      # replaying the same quarantined event returns the same entry
      assert {:ok, %{status: :quarantined, quarantine_id: ^qid}} =
               Usage.ingest_event(ctx.scope, unknown)

      # outside the configured age limits (defaults: 90 days / 24 hours)
      too_old = DateTime.add(DateTime.utc_now(), -95 * 86_400, :second)

      assert {:ok, %{status: :quarantined, reason: :too_old}} =
               Usage.ingest_event(
                 ctx.scope,
                 valid_usage_event_attrs(ctx.subscription, %{occurred_at: too_old})
               )

      too_future = DateTime.add(DateTime.utc_now(), 48 * 3_600, :second)

      assert {:ok, %{status: :quarantined, reason: :too_far_future}} =
               Usage.ingest_event(
                 ctx.scope,
                 valid_usage_event_attrs(ctx.subscription, %{occurred_at: too_future})
               )

      # oversized properties (default cap 64 KiB)
      assert {:ok, %{status: :quarantined, reason: :oversized_properties}} =
               Usage.ingest_event(
                 ctx.scope,
                 valid_usage_event_attrs(ctx.subscription, %{
                   occurred_at: ctx.base,
                   properties: %{"blob" => String.duplicate("x", 70_000)}
                 })
               )

      assert Repo.aggregate(
               from(q in QuarantineEntry, where: q.team_id == ^ctx.scope.team.id),
               :count
             ) == 4
    end

    test "a later accepted re-ingest resolves the stale quarantine entry", ctx do
      external_event_id = unique_usage_event_id()

      attrs =
        ctx.subscription
        |> valid_usage_event_attrs(%{
          external_event_id: external_event_id,
          occurred_at: ctx.base
        })
        |> Map.delete(:subscription_id)
        |> Map.put(:subscription_external_id, "sub-created-later")

      assert {:ok, %{status: :quarantined, reason: :unknown_subscription}} =
               Usage.ingest_event(ctx.scope, attrs)

      # the subscription arrives; the same event ID is now accepted
      late_subscription =
        usage_subscription_fixture(ctx.scope, %{external_id: "sub-created-later"})

      assert late_subscription.external_id == "sub-created-later"
      assert {:ok, %{status: :accepted}} = Usage.ingest_event(ctx.scope, attrs)

      entry =
        Repo.get_by!(QuarantineEntry,
          team_id: ctx.scope.team.id,
          external_event_id: external_event_id
        )

      assert entry.resolved_at != nil
    end
  end

  describe "batch ingestion (BC-US-051)" do
    test "reports mixed outcomes independently and emits ONE batch event", ctx do
      accepted = valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base})

      unknown =
        ctx.subscription
        |> valid_usage_event_attrs(%{occurred_at: ctx.base})
        |> Map.delete(:subscription_id)
        |> Map.put(:subscription_external_id, "sub-missing")

      invalid = valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base, value: "abc"})

      assert {:ok, summary} =
               Usage.ingest_batch(ctx.scope, [accepted, accepted, unknown, invalid])

      assert summary.accepted == 1
      assert summary.duplicate == 1

      assert [%{index: 2, reason: :unknown_subscription, external_event_id: unknown_id}] =
               summary.quarantined

      assert unknown_id == unknown.external_event_id

      assert [%{index: 3, reason: :invalid_event, detail: "value must be a decimal"}] =
               summary.rejected

      # the accepted event survived its siblings' failures
      assert Repo.aggregate(
               from(e in Event, where: e.external_event_id == ^accepted.external_event_id),
               :count
             ) == 1

      # exactly ONE usage_batch.accepted.v1 for the whole request
      assert [batch_event] =
               Repo.all(
                 from e in Outbox.Event,
                   where:
                     e.event_type == "usage_batch.accepted.v1" and
                       e.team_id == ^ctx.scope.team.id
               )

      assert batch_event.payload == %{
               "accepted" => 1,
               "duplicate" => 1,
               "rejected" => 1,
               "quarantined" => 1
             }
    end

    test "a batch with nothing accepted emits no batch event", ctx do
      invalid = valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base, value: nil})

      assert {:ok, %{accepted: 0, rejected: [_]}} = Usage.ingest_batch(ctx.scope, [invalid])

      assert Repo.all(
               from e in Outbox.Event,
                 where:
                   e.event_type == "usage_batch.accepted.v1" and e.team_id == ^ctx.scope.team.id
             ) == []
    end

    test "the batch size cap is enforced up front", ctx do
      oversized = List.duplicate(%{}, 1001)
      assert {:error, :batch_too_large} = Usage.ingest_batch(ctx.scope, oversized)
      assert Repo.aggregate(QuarantineEntry, :count) == 0
    end
  end

  describe "correction by void (BC-US-052)" do
    test "a void received before the cutoff excludes the measurement; one received after does not",
         ctx do
      %{received_at: measured_at} =
        ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
          external_event_id: "evt-void-target",
          occurred_at: ctx.base,
          value: Decimal.new("5")
        })

      assert {:ok, %{status: :voided, received_at: voided_at}} =
               Usage.void_event(ctx.scope, "evt-void-target", void_event_id: "void-1")

      assert DateTime.compare(voided_at, measured_at) == :gt

      # frozen at the measurement's receipt instant: the void arrived later,
      # so the measurement still belongs to that cutoff's evidence set
      assert {:ok, at_early_cutoff} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", ctx.period, measured_at)

      assert at_early_cutoff.event_count == 1
      assert Decimal.eq?(at_early_cutoff.quantity, Decimal.new(5))

      # frozen at (or after) the void's receipt: the measurement is excluded
      assert {:ok, at_late_cutoff} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", ctx.period, voided_at)

      assert at_late_cutoff.event_count == 0
      assert Decimal.eq?(at_late_cutoff.quantity, Decimal.new(0))

      # the original row is immutable evidence: still queryable, payload intact
      original = Repo.get_by!(Event, external_event_id: "evt-void-target")
      assert original.status == :voided
      assert Decimal.eq?(original.value, Decimal.new(5))

      assert "usage.event.voided" in audit_events(original.id)
      assert "usage_event.voided.v1" in outbox_events(original.id)
    end

    test "replaying the same void is idempotent; a second different void is rejected", ctx do
      ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
        external_event_id: "evt-void-twice",
        occurred_at: ctx.base
      })

      assert {:ok, %{status: :voided}} =
               Usage.void_event(ctx.scope, "evt-void-twice", void_event_id: "void-a")

      assert {:ok, :already_voided} =
               Usage.void_event(ctx.scope, "evt-void-twice", void_event_id: "void-a")

      assert {:error, :already_voided} =
               Usage.void_event(ctx.scope, "evt-void-twice", void_event_id: "void-b")

      # at most one effective void row exists
      original = Repo.get_by!(Event, external_event_id: "evt-void-twice")

      assert Repo.aggregate(
               from(e in Event, where: e.voids_event_id == ^original.id),
               :count
             ) == 1
    end

    test "voiding requires the original to exist in the caller's team", ctx do
      assert {:error, :not_found} =
               Usage.void_event(ctx.scope, "evt-nowhere", void_event_id: "void-x")

      assert {:error, :missing_void_event_id} =
               Usage.void_event(ctx.scope, "evt-nowhere", [])
    end

    test "a replacement is an ordinary measurement counted from its own receipt", ctx do
      ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
        external_event_id: "evt-replace-me",
        occurred_at: ctx.base,
        value: Decimal.new("5")
      })

      assert {:ok, %{status: :voided, replacement_event_id: replacement_id}} =
               Usage.void_event(ctx.scope, "evt-replace-me",
                 void_event_id: "void-r1",
                 replacement: %{external_event_id: "evt-replacement", value: Decimal.new("3")}
               )

      assert replacement_id != nil

      replacement = Repo.get_by!(Event, external_event_id: "evt-replacement")
      original = Repo.get_by!(Event, external_event_id: "evt-replace-me")
      assert replacement.event_kind == :measurement
      assert replacement.replacement_for_event_id == original.id
      # occurred_at copied for partition locality, own received_at
      assert DateTime.compare(replacement.occurred_at, original.occurred_at) == :eq
      assert DateTime.compare(replacement.received_at, original.received_at) == :gt

      # after both the void and replacement are received: net quantity is 3
      cutoff = DateTime.add(replacement.received_at, 1, :second)

      assert {:ok, result} =
               Usage.aggregate(ctx.scope, ctx.subscription, "api_calls", ctx.period, cutoff)

      assert result.event_count == 1
      assert Decimal.eq?(result.quantity, Decimal.new(3))
    end
  end

  describe "aggregation preview (BC-US-053/054)" do
    setup ctx do
      # three measurements on a dedicated metric with distinct instants
      for {suffix, offset, value, unique} <- [
            {"a", 0, "1.5", "user-1"},
            {"b", 60, "2.25", "user-2"},
            {"c", 120, "0.25", "user-1"}
          ] do
        ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
          external_event_id: "evt-agg-#{suffix}",
          metric_code: "storage_gb",
          occurred_at: DateTime.add(ctx.base, offset, :second),
          value: Decimal.new(value),
          properties: %{"unique_id" => unique}
        })
      end

      %{cutoff: DateTime.add(DateTime.utc_now(), 60, :second)}
    end

    test "sum, count, max, and unique_count produce exact decimal results", ctx do
      assert {:ok, sum} =
               Usage.aggregate(
                 ctx.scope,
                 ctx.subscription,
                 "storage_gb",
                 ctx.period,
                 ctx.cutoff
               )

      assert sum.aggregation == :sum
      assert Decimal.eq?(sum.quantity, Decimal.new(4))
      assert Canonical.decimal_string(sum.quantity) == "4"
      assert sum.event_count == 3
      assert sum.excluded_late == 0
      assert DateTime.compare(sum.first_occurred_at, ctx.base) == :eq
      assert DateTime.compare(sum.last_occurred_at, DateTime.add(ctx.base, 120, :second)) == :eq
      assert sum.cutoff == ctx.cutoff

      assert {:ok, count} =
               Usage.aggregate(ctx.scope, ctx.subscription, "storage_gb", ctx.period, ctx.cutoff,
                 aggregation: :count
               )

      assert Decimal.eq?(count.quantity, Decimal.new(3))

      assert {:ok, max} =
               Usage.aggregate(ctx.scope, ctx.subscription, "storage_gb", ctx.period, ctx.cutoff,
                 aggregation: :max
               )

      assert Decimal.eq?(max.quantity, Decimal.new("2.25"))

      assert {:ok, unique} =
               Usage.aggregate(ctx.scope, ctx.subscription, "storage_gb", ctx.period, ctx.cutoff,
                 aggregation: :unique_count
               )

      assert Decimal.eq?(unique.quantity, Decimal.new(2))

      assert {:error, :unknown_aggregation} =
               Usage.aggregate(ctx.scope, ctx.subscription, "storage_gb", ctx.period, ctx.cutoff,
                 aggregation: :median
               )
    end

    test "an event received after the cutoff is excluded and reported late (BC-US-054)", ctx do
      # freeze the cutoff at the receipt instant of the last setup event —
      # a trusted server-clock instant, immune to app/database clock skew
      cutoff = Repo.get_by!(Event, external_event_id: "evt-agg-c").received_at

      # occurred inside the period but received after the frozen cutoff
      ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
        external_event_id: "evt-late",
        metric_code: "storage_gb",
        occurred_at: ctx.base,
        value: Decimal.new("100")
      })

      late = Repo.get_by!(Event, external_event_id: "evt-late")
      assert DateTime.compare(late.received_at, cutoff) == :gt

      assert {:ok, result} =
               Usage.aggregate(ctx.scope, ctx.subscription, "storage_gb", ctx.period, cutoff)

      assert result.event_count == 3
      assert Decimal.eq?(result.quantity, Decimal.new(4))
      assert result.excluded_late == 1

      # at a later cutoff the same event is ordinary evidence
      assert {:ok, later} =
               Usage.aggregate(
                 ctx.scope,
                 ctx.subscription,
                 "storage_gb",
                 ctx.period,
                 DateTime.add(late.received_at, 1, :second)
               )

      assert later.event_count == 4
      assert Decimal.eq?(later.quantity, Decimal.new(104))
      assert later.excluded_late == 0
    end
  end

  describe "team isolation and authorization" do
    test "another team can neither ingest against, void, nor aggregate this team's data", ctx do
      ingested_usage_event_fixture(ctx.scope, ctx.subscription, %{
        external_event_id: "evt-mine",
        occurred_at: ctx.base
      })

      other_scope = usage_scope_fixture()

      # the foreign subscription ID resolves to nothing in the other team
      assert {:ok, %{status: :quarantined, reason: :unknown_subscription}} =
               Usage.ingest_event(
                 other_scope,
                 valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base})
               )

      assert {:error, :not_found} =
               Usage.void_event(other_scope, "evt-mine", void_event_id: "void-steal")

      assert {:error, :unauthorized} =
               Usage.aggregate(
                 other_scope,
                 ctx.subscription,
                 "api_calls",
                 ctx.period,
                 DateTime.utc_now()
               )

      # nothing changed in the owning team
      assert Repo.get_by!(Event, external_event_id: "evt-mine").status == :effective
    end

    test "ingestion requires an ingest role; auditors may still preview", ctx do
      auditor = team_scope_fixture(ctx.scope.organization, ctx.scope.team, [:auditor])

      assert {:error, :unauthorized} =
               Usage.ingest_event(
                 auditor,
                 valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base})
               )

      assert {:error, :unauthorized} = Usage.ingest_batch(auditor, [])

      assert {:error, :unauthorized} =
               Usage.void_event(auditor, "evt-x", void_event_id: "void-x")

      assert {:ok, _result} =
               Usage.aggregate(
                 auditor,
                 ctx.subscription,
                 "api_calls",
                 ctx.period,
                 DateTime.utc_now()
               )

      # machine credentials with integration_client may ingest
      integration =
        team_scope_fixture(ctx.scope.organization, ctx.scope.team, [:integration_client])

      assert {:ok, %{status: :accepted}} =
               Usage.ingest_event(
                 integration,
                 valid_usage_event_attrs(ctx.subscription, %{occurred_at: ctx.base})
               )
    end
  end

  defp audit_events(aggregate_id) do
    Repo.all(from e in Audit.Entry, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end

  defp outbox_events(aggregate_id) do
    Repo.all(from e in Outbox.Event, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end
end
