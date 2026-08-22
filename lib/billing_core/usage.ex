defmodule BillingCore.Usage do
  @moduledoc """
  Usage ingestion, correction, and aggregation (SPEC §8.4 Epic D,
  BC-US-050…055, §13.3 `usage_event_keys`/`usage_events`, §18.5).

  Every public function takes a `BillingCore.Scope`; ingestion and
  corrections require `integration_client`, `billing_admin`, or `team_admin`,
  reads/preview also admit `finance_operator` and `auditor`. All queries are
  constrained by the scope's team.

  Structural rules enforced here:

    * ingestion is idempotent by `(team, external_event_id)` through the
      unpartitioned `usage_event_keys` reservation: an identical canonical
      payload replay returns the original (`:duplicate`), a different payload
      is `{:error, :conflict}` (BC-US-050);
    * `received_at` is assigned by PostgreSQL `clock_timestamp()` and never
      accepted from callers — frozen cutoffs rest on trusted server time;
    * events outside configurable age limits, with oversized properties, or
      referencing an unknown subscription are quarantined, never silently
      discarded (BC-US-050, §18.5);
    * batches process each event in its own transaction — partial failure
      never rolls back valid independent events — and emit ONE
      `usage_batch.accepted.v1` outbox event per accepted batch (BC-US-051);
    * corrections are immutable void rows plus optional replacement
      measurements, never edits or deletes; at most one effective void per
      measurement, guarded by a partial unique index (BC-US-052);
    * aggregation at a frozen cutoff is a deterministic pure read: a
      measurement counts iff it was received on or before the cutoff and has
      no void received on or before that same cutoff (BC-US-053/054/055).

  Configuration (module config, not team settings):

      config :billing_core, BillingCore.Usage,
        max_age_days: 90,        # older occurred_at → quarantined :too_old
        max_future_hours: 24,    # future occurred_at → :too_far_future
        max_batch_size: 1000,    # larger batches → {:error, :batch_too_large}
        max_properties_bytes: 65_536  # → quarantined :oversized_properties

  Partitioning: `usage_events` has explicit monthly partitions and no DEFAULT
  partition (SPEC §13.1) — inserting an event whose `occurred_at` falls
  outside the created partitions raises. `ensure_partitions/1` (and
  `BillingCore.Usage.PartitionWorker`) keep coverage rolling ahead;
  operators must keep partitions covering the accepted age window.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Outbox, Repo, Scope}
  alias BillingCore.Contracts.Subscription
  alias BillingCore.Domain.{Canonical, Period}
  alias BillingCore.Usage.{Event, EventKey, QuarantineEntry}

  @ingest_roles [:integration_client, :billing_admin, :team_admin]
  @read_roles @ingest_roles ++ [:finance_operator, :auditor]

  @aggregations [:sum, :count, :max, :unique_count]

  @default_months_ahead 2

  @type ingest_result ::
          %{status: :accepted, usage_event_id: Ecto.UUID.t(), received_at: DateTime.t()}
          | %{status: :duplicate, usage_event_id: Ecto.UUID.t()}
          | %{status: :quarantined, reason: atom(), quarantine_id: Ecto.UUID.t()}

  ## Ingestion (BC-US-050)

  @doc """
  Ingests a single usage measurement.

  `attrs` (map or keyword): `:external_event_id`, `:metric_code`,
  `:occurred_at` (UTC `DateTime` or ISO 8601 string), `:value` (`Decimal`,
  integer, or decimal string) are required, plus a subscription reference —
  `:subscription_id` (internal UUID) or `:subscription_external_id`.
  `:properties` (map) defaults to `%{}` and is stored in canonical form.
  A caller-supplied `:received_at` is ignored.

  Returns `{:ok, result}` where `result.status` is `:accepted`, `:duplicate`
  (identical canonical replay — the original event ID is returned, no new
  row), or `:quarantined` (with `:reason` — `:unknown_subscription`,
  `:too_old`, `:too_far_future`, or `:oversized_properties`).
  `{:error, :conflict}` when the external event ID was already used with a
  different payload; `{:error, {:invalid_event, message}}` for malformed
  attrs. Raises if `occurred_at` falls outside the created monthly
  partitions (see the module doc).
  """
  @spec ingest_event(Scope.t(), map() | keyword()) ::
          {:ok, ingest_result()}
          | {:error, :unauthorized | :conflict | {:invalid_event, String.t()}}
  def ingest_event(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, @ingest_roles) do
      do_ingest(scope, Scope.team_id!(scope), attrs)
    end
  end

  @doc """
  Ingests a batch of usage events with per-event independence (BC-US-051).

  Each event runs in its own transaction and preserves its own idempotency
  semantics; one failing event never rolls back its siblings. Batches larger
  than the configured cap return `{:error, :batch_too_large}` without
  processing anything.

  Returns `{:ok, %{accepted: n, duplicate: n, rejected: [...],
  quarantined: [...]}}` where `rejected`/`quarantined` carry per-item maps
  (`:index`, `:external_event_id`, `:reason`, and `:detail` for rejections).
  When at least one event is accepted, exactly ONE `usage_batch.accepted.v1`
  outbox event is emitted with the batch counts — never one per event.
  """
  @spec ingest_batch(Scope.t(), [map() | keyword()]) ::
          {:ok,
           %{
             accepted: non_neg_integer(),
             duplicate: non_neg_integer(),
             rejected: [map()],
             quarantined: [map()]
           }}
          | {:error, :unauthorized | :batch_too_large}
  def ingest_batch(%Scope{} = scope, events) when is_list(events) do
    with :ok <- authorize(scope, @ingest_roles),
         :ok <- ensure_batch_size(events) do
      team_id = Scope.team_id!(scope)
      summary = summarize_batch(scope, team_id, events)
      emit_batch_accepted!(scope, team_id, summary)
      {:ok, summary}
    end
  end

  defp ensure_batch_size(events) do
    if length(events) > max_batch_size(), do: {:error, :batch_too_large}, else: :ok
  end

  defp summarize_batch(scope, team_id, events) do
    events
    |> Enum.with_index()
    |> Enum.reduce(
      %{accepted: 0, duplicate: 0, rejected: [], quarantined: []},
      fn {attrs, index}, acc ->
        classify_batch_item(acc, index, attrs, safe_ingest(scope, team_id, attrs))
      end
    )
    |> Map.update!(:rejected, &Enum.reverse/1)
    |> Map.update!(:quarantined, &Enum.reverse/1)
  end

  defp emit_batch_accepted!(scope, team_id, summary) do
    if summary.accepted > 0 do
      {:ok, _} =
        Repo.transaction(fn ->
          Outbox.emit!("usage_batch.accepted.v1",
            aggregate: {"usage_batch", Ecto.UUID.generate()},
            team_id: team_id,
            correlation_id: scope.correlation_id,
            payload: %{
              accepted: summary.accepted,
              duplicate: summary.duplicate,
              rejected: length(summary.rejected),
              quarantined: length(summary.quarantined)
            }
          )
        end)
    end

    :ok
  end

  ## Correction (BC-US-052)

  @doc """
  Voids an effective measurement without deleting history.

  `external_event_id` identifies the original measurement;
  `opts[:void_event_id]` (required) is the void's OWN team-scoped external
  event ID — the idempotency key of the correction itself. Optional
  `opts[:replacement]` submits the replacement measurement in the same
  transaction: `%{external_event_id: ..., value: ...}` plus optional
  `:metric_code` (defaults to the original's) and `:properties`. Both the
  void and the replacement copy the original's `occurred_at` (partition
  locality) and record their own server-assigned `received_at` (cutoff
  semantics).

  Runs in one locked transaction resolving the original through
  `usage_event_keys` `FOR UPDATE`. Replaying the same void external ID is
  idempotent (`{:ok, :already_voided}`); a second, different void of the same
  measurement is `{:error, :already_voided}`. Emits `usage_event.voided.v1`.
  Recalculation/credit-rebill of affected billing periods is driven by that
  event downstream (BC-US-052).
  """
  @spec void_event(Scope.t(), String.t(), map() | keyword()) ::
          {:ok,
           %{
             status: :voided,
             void_event_id: Ecto.UUID.t(),
             original_event_id: Ecto.UUID.t(),
             replacement_event_id: Ecto.UUID.t() | nil,
             received_at: DateTime.t()
           }}
          | {:ok, :already_voided}
          | {:error, term()}
  def void_event(%Scope{} = scope, external_event_id, opts \\ [])
      when is_binary(external_event_id) do
    opts = Map.new(opts)

    with :ok <- authorize(scope, @ingest_roles),
         {:ok, void_external_id} <- require_void_event_id(opts) do
      team_id = Scope.team_id!(scope)
      replacement = Map.get(opts, :replacement)

      Repo.transaction(fn ->
        void_event_in_txn(scope, team_id, external_event_id, void_external_id, replacement)
      end)
    end
  end

  defp void_event_in_txn(scope, team_id, external_event_id, void_external_id, replacement) do
    key = lock_event_key(team_id, external_event_id) || Repo.rollback(:not_found)
    original = fetch_original_measurement!(team_id, key)
    existing_void = find_existing_void(team_id, original)
    apply_void_decision(scope, team_id, original, existing_void, void_external_id, replacement)
  end

  defp fetch_original_measurement!(team_id, key) do
    original =
      Repo.one(
        from e in Event,
          where:
            e.team_id == ^team_id and e.id == ^key.usage_event_id and
              e.occurred_at == ^key.occurred_at
      ) || Repo.rollback(:not_found)

    unless original.event_kind == :measurement, do: Repo.rollback(:not_a_measurement)

    original
  end

  defp find_existing_void(team_id, original) do
    Repo.one(
      from e in Event,
        where:
          e.team_id == ^team_id and e.event_kind == :void and
            e.voids_event_id == ^original.id and e.occurred_at == ^original.occurred_at
    )
  end

  defp apply_void_decision(scope, team_id, original, existing_void, void_external_id, replacement) do
    cond do
      existing_void && existing_void.external_event_id == void_external_id ->
        # Idempotent replay of the same correction.
        :already_voided

      existing_void ->
        # At most one effective void per measurement (BC-US-052).
        Repo.rollback(:already_voided)

      original.status != :effective ->
        Repo.rollback(:not_effective)

      true ->
        insert_void(scope, team_id, original, void_external_id, replacement)
    end
  end

  ## Aggregation preview (BC-US-053/054/055)

  @doc """
  Aggregates a subscription metric over a billing period at a frozen cutoff.
  Pure read — no billing side effects; reproducible for a fixed cutoff.

  An event belongs to `period` when the DATE of its `occurred_at` converted
  to the team's billing time zone (SPEC §9.2) falls inside the half-open date
  period. Zone conversion uses the configured time zone database (`tz`); if
  a team's zone is unknown to it, the UTC date is a documented graceful
  fallback.

  Evidence set (BC-US-052/054): a measurement counts iff its `received_at`
  is on or before `cutoff` AND it has no void received on or before that same
  cutoff — a void received after the cutoff does NOT remove the measurement
  from that cutoff's evidence. Replacement measurements are ordinary
  measurements (counted when received before the cutoff). Measurements in
  the period but received after the cutoff are reported as `excluded_late`.

  `opts`: `:aggregation` — `:sum` (default), `:count`, `:max`, or
  `:unique_count`; `:unique_property` — the properties key whose distinct
  values `:unique_count` counts (default `"unique_id"`).

  Returns `{:ok, %{quantity: Decimal, event_count: n, first_occurred_at: dt,
  last_occurred_at: dt, excluded_late: n, aggregation: atom, cutoff: dt}}`.
  """
  @spec aggregate(Scope.t(), Subscription.t(), String.t(), Period.t(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, :unauthorized | :unknown_aggregation}
  def aggregate(
        %Scope{} = scope,
        %Subscription{} = subscription,
        metric_code,
        %Period{} = period,
        %DateTime{} = cutoff,
        opts \\ []
      )
      when is_binary(metric_code) do
    aggregation = Keyword.get(opts, :aggregation, :sum)
    unique_property = Keyword.get(opts, :unique_property, "unique_id")

    with :ok <- authorize(scope, @read_roles),
         :ok <- ensure_same_team(scope, subscription.team_id),
         :ok <- ensure_known_aggregation(aggregation) do
      team_id = Scope.team_id!(scope)
      time_zone = team_time_zone(scope)

      # Generous UTC instant window: any instant whose team-local date falls
      # in the period lies within one day of the period's UTC bounds.
      window_start = DateTime.new!(Date.add(period.start_date, -1), ~T[00:00:00], "Etc/UTC")
      window_end = DateTime.new!(Date.add(period.end_date_exclusive, 1), ~T[00:00:00], "Etc/UTC")

      in_period =
        Repo.all(
          from e in Event,
            where:
              e.team_id == ^team_id and e.subscription_id == ^subscription.id and
                e.metric_code == ^metric_code and e.event_kind == :measurement and
                e.occurred_at >= ^window_start and e.occurred_at < ^window_end,
            order_by: [asc: e.occurred_at, asc: e.id]
        )
        |> Enum.filter(&Period.contains_date?(period, local_date(&1.occurred_at, time_zone)))

      {on_time, late} =
        Enum.split_with(in_period, &(DateTime.compare(&1.received_at, cutoff) != :gt))

      voided_ids = voided_before_cutoff(team_id, on_time, window_start, window_end, cutoff)
      included = Enum.reject(on_time, &MapSet.member?(voided_ids, &1.id))

      {:ok,
       %{
         quantity: quantity(aggregation, included, unique_property),
         event_count: length(included),
         first_occurred_at: included |> List.first() |> occurred_or_nil(),
         last_occurred_at: included |> List.last() |> occurred_or_nil(),
         excluded_late: length(late),
         aggregation: aggregation,
         cutoff: cutoff
       }}
    end
  end

  ## Partition maintenance (SPEC §13.1)

  @doc "Default number of months ahead maintained by `ensure_partitions/1`."
  @spec default_months_ahead() :: pos_integer()
  def default_months_ahead, do: @default_months_ahead

  @doc """
  Idempotently ensures monthly `usage_events` partitions exist for the
  current month through `months_ahead` months ahead, via the database
  function `billing.ensure_usage_partition/1`. Returns the partition names.
  """
  @spec ensure_partitions(non_neg_integer()) :: {:ok, [String.t()]}
  def ensure_partitions(months_ahead \\ @default_months_ahead)
      when is_integer(months_ahead) and months_ahead >= 0 do
    this_month = Date.beginning_of_month(Date.utc_today())

    names =
      for n <- 0..months_ahead do
        month_start = Period.add_months(this_month, n, 1)

        %{rows: [[name]]} =
          Repo.query!("SELECT billing.ensure_usage_partition($1)", [month_start])

        name
      end

    {:ok, names}
  end

  ## Ingestion internals

  defp do_ingest(scope, team_id, attrs) do
    with {:ok, event} <- normalize_event(attrs) do
      case resolve_subscription(team_id, event.subscription_ref) do
        nil ->
          quarantine(scope, team_id, event, :unknown_subscription)

        %Subscription{} = subscription ->
          cond do
            too_old?(event.occurred_at) ->
              quarantine(scope, team_id, event, :too_old)

            too_far_future?(event.occurred_at) ->
              quarantine(scope, team_id, event, :too_far_future)

            oversized_properties?(event.properties) ->
              quarantine(scope, team_id, event, :oversized_properties)

            true ->
              insert_measurement(team_id, event, subscription)
          end
      end
    end
  end

  # Batch wrapper: per-event independence must survive storage-level raises
  # (e.g. an occurred_at outside the created partitions) without losing the
  # sibling results that already committed in their own transactions.
  defp safe_ingest(scope, team_id, attrs) do
    do_ingest(scope, team_id, attrs)
  rescue
    e in [Postgrex.Error] ->
      {:error, {:storage_error, Exception.message(e)}}
  end

  defp classify_batch_item(acc, index, attrs, result) do
    external_event_id = Map.new(attrs)[:external_event_id]

    case result do
      {:ok, %{status: :accepted}} ->
        %{acc | accepted: acc.accepted + 1}

      {:ok, %{status: :duplicate}} ->
        %{acc | duplicate: acc.duplicate + 1}

      {:ok, %{status: :quarantined, reason: reason}} ->
        item = %{index: index, external_event_id: external_event_id, reason: reason}
        %{acc | quarantined: [item | acc.quarantined]}

      {:error, :conflict} ->
        item = %{index: index, external_event_id: external_event_id, reason: :conflict}
        %{acc | rejected: [item | acc.rejected]}

      {:error, {:invalid_event, detail}} ->
        item = %{
          index: index,
          external_event_id: external_event_id,
          reason: :invalid_event,
          detail: detail
        }

        %{acc | rejected: [item | acc.rejected]}

      {:error, {:storage_error, detail}} ->
        item = %{
          index: index,
          external_event_id: external_event_id,
          reason: :storage_error,
          detail: detail
        }

        %{acc | rejected: [item | acc.rejected]}
    end
  end

  defp insert_measurement(team_id, event, subscription) do
    payload_hash = Canonical.hash(canonical_payload(event, subscription.id))
    event_id = Ecto.UUID.generate()

    Repo.transaction(fn ->
      # ON CONFLICT DO NOTHING keeps the reservation race-safe without
      # aborting the surrounding transaction on a unique violation.
      {inserted, _} =
        Repo.insert_all(
          EventKey,
          [
            %{
              id: Ecto.UUID.generate(),
              team_id: team_id,
              external_event_id: event.external_event_id,
              payload_hash: payload_hash,
              usage_event_id: event_id,
              occurred_at: event.occurred_at,
              created_at: DateTime.utc_now()
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:team_id, :external_event_id]
        )

      case inserted do
        0 ->
          key =
            Repo.get_by!(EventKey, team_id: team_id, external_event_id: event.external_event_id)

          if key.payload_hash == payload_hash do
            # BC-US-050: identical payload replay returns the original.
            %{status: :duplicate, usage_event_id: key.usage_event_id}
          else
            Repo.rollback(:conflict)
          end

        1 ->
          inserted_event =
            Repo.insert!(%Event{
              id: event_id,
              team_id: team_id,
              external_event_id: event.external_event_id,
              event_kind: :measurement,
              subscription_id: subscription.id,
              metric_code: event.metric_code,
              occurred_at: event.occurred_at,
              value: event.value,
              properties: event.properties,
              payload_hash: payload_hash,
              status: :effective
            })

          # A previously quarantined submission of this external ID is now
          # resolved by the accepted re-ingest.
          Repo.update_all(
            from(q in QuarantineEntry,
              where:
                q.team_id == ^team_id and q.external_event_id == ^event.external_event_id and
                  is_nil(q.resolved_at)
            ),
            set: [resolved_at: DateTime.utc_now()]
          )

          %{
            status: :accepted,
            usage_event_id: inserted_event.id,
            received_at: inserted_event.received_at
          }
      end
    end)
  end

  defp quarantine(scope, team_id, event, reason) do
    Repo.transaction(fn ->
      entry_id = Ecto.UUID.generate()

      {inserted, _} =
        Repo.insert_all(
          QuarantineEntry,
          [
            %{
              id: entry_id,
              team_id: team_id,
              external_event_id: event.external_event_id,
              reason: to_string(reason),
              payload: quarantine_payload(event),
              created_at: DateTime.utc_now()
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:team_id, :external_event_id]
        )

      case inserted do
        0 ->
          existing =
            Repo.get_by!(QuarantineEntry,
              team_id: team_id,
              external_event_id: event.external_event_id
            )

          %{
            status: :quarantined,
            reason: String.to_existing_atom(existing.reason),
            quarantine_id: existing.id
          }

        1 ->
          Audit.record!(scope, "usage.event.quarantined",
            aggregate: {"usage_quarantine", entry_id},
            payload: %{external_event_id: event.external_event_id, reason: reason}
          )

          %{status: :quarantined, reason: reason, quarantine_id: entry_id}
      end
    end)
  end

  ## Void internals

  defp insert_void(scope, team_id, original, void_external_id, replacement) do
    void_hash =
      Canonical.hash(%{
        "kind" => "void",
        "void_event_id" => void_external_id,
        "voids_external_event_id" => original.external_event_id
      })

    void_id = reserve_event_key!(team_id, void_external_id, void_hash, original.occurred_at)

    void =
      Repo.insert!(%Event{
        id: void_id,
        team_id: team_id,
        external_event_id: void_external_id,
        event_kind: :void,
        subscription_id: original.subscription_id,
        metric_code: original.metric_code,
        occurred_at: original.occurred_at,
        value: nil,
        properties: %{},
        payload_hash: void_hash,
        status: :effective,
        voids_event_id: original.id
      })

    # Lifecycle projection only; all payload columns stay frozen (the
    # database trigger rejects any other change).
    original
    |> Ecto.Changeset.change(status: :voided)
    |> Repo.update!()

    replacement_event = replacement && insert_replacement(team_id, original, replacement)

    Audit.record!(scope, "usage.event.voided",
      aggregate: {"usage_event", original.id},
      payload: %{
        external_event_id: original.external_event_id,
        void_event_id: void_external_id,
        replacement_event_id: replacement_event && replacement_event.id
      }
    )

    Outbox.emit!("usage_event.voided.v1",
      aggregate: {"usage_event", original.id},
      team_id: team_id,
      correlation_id: scope.correlation_id,
      payload: %{
        external_event_id: original.external_event_id,
        subscription_id: original.subscription_id,
        metric_code: original.metric_code,
        occurred_at: DateTime.to_iso8601(original.occurred_at),
        void_event_id: void_external_id,
        replacement_event_id: replacement_event && replacement_event.id,
        replacement_external_event_id: replacement_event && replacement_event.external_event_id
      }
    )

    %{
      status: :voided,
      void_event_id: void.id,
      original_event_id: original.id,
      replacement_event_id: replacement_event && replacement_event.id,
      received_at: void.received_at
    }
  end

  defp insert_replacement(team_id, original, replacement) do
    replacement = Map.new(replacement)

    external_event_id =
      case replacement[:external_event_id] do
        id when is_binary(id) and id != "" -> id
        _missing -> Repo.rollback(:missing_replacement_event_id)
      end

    value = to_decimal(replacement[:value]) || Repo.rollback(:invalid_replacement_value)
    metric_code = replacement[:metric_code] || original.metric_code

    properties =
      case normalize_properties(Map.get(replacement, :properties, %{})) do
        {:ok, properties} -> properties
        {:error, _} -> Repo.rollback(:invalid_replacement_properties)
      end

    payload_hash =
      Canonical.hash(%{
        "external_event_id" => external_event_id,
        "metric_code" => metric_code,
        "occurred_at" => original.occurred_at,
        "properties" => properties,
        "subscription_id" => original.subscription_id,
        "value" => value
      })

    replacement_id =
      reserve_event_key!(team_id, external_event_id, payload_hash, original.occurred_at)

    Repo.insert!(%Event{
      id: replacement_id,
      team_id: team_id,
      external_event_id: external_event_id,
      event_kind: :measurement,
      subscription_id: original.subscription_id,
      metric_code: metric_code,
      occurred_at: original.occurred_at,
      value: value,
      properties: properties,
      payload_hash: payload_hash,
      status: :effective,
      replacement_for_event_id: original.id
    })
  end

  # Reserves `(team, external_id)` for a correction row inside the void
  # transaction; an ID already claimed by a different event is a conflict.
  defp reserve_event_key!(team_id, external_id, payload_hash, occurred_at) do
    event_id = Ecto.UUID.generate()

    {inserted, _} =
      Repo.insert_all(
        EventKey,
        [
          %{
            id: Ecto.UUID.generate(),
            team_id: team_id,
            external_event_id: external_id,
            payload_hash: payload_hash,
            usage_event_id: event_id,
            occurred_at: occurred_at,
            created_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:team_id, :external_event_id]
      )

    if inserted == 1, do: event_id, else: Repo.rollback(:conflict)
  end

  defp require_void_event_id(opts) do
    case opts[:void_event_id] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :missing_void_event_id}
    end
  end

  defp lock_event_key(team_id, external_event_id) do
    Repo.one(
      from k in EventKey,
        where: k.team_id == ^team_id and k.external_event_id == ^external_event_id,
        lock: "FOR UPDATE"
    )
  end

  ## Aggregation internals

  defp voided_before_cutoff(_team_id, [], _window_start, _window_end, _cutoff), do: MapSet.new()

  defp voided_before_cutoff(team_id, measurements, window_start, window_end, cutoff) do
    ids = Enum.map(measurements, & &1.id)

    # Voids copy the original's occurred_at, so the same partition window
    # applies. Only voids received on or before the cutoff remove their
    # measurement from this cutoff's evidence set (BC-US-052).
    Repo.all(
      from e in Event,
        where:
          e.team_id == ^team_id and e.event_kind == :void and e.voids_event_id in ^ids and
            e.occurred_at >= ^window_start and e.occurred_at < ^window_end and
            e.received_at <= ^cutoff,
        select: e.voids_event_id
    )
    |> MapSet.new()
  end

  defp quantity(:sum, included, _unique_property) do
    Enum.reduce(included, Decimal.new(0), &Decimal.add(&2, &1.value))
  end

  defp quantity(:count, included, _unique_property), do: Decimal.new(length(included))

  defp quantity(:max, included, _unique_property) do
    Enum.reduce(included, Decimal.new(0), &Decimal.max(&2, &1.value))
  end

  defp quantity(:unique_count, included, unique_property) do
    included
    |> Enum.map(&Map.get(&1.properties, unique_property))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
    |> Decimal.new()
  end

  defp ensure_known_aggregation(aggregation) when aggregation in @aggregations, do: :ok
  defp ensure_known_aggregation(_aggregation), do: {:error, :unknown_aggregation}

  defp occurred_or_nil(nil), do: nil
  defp occurred_or_nil(%Event{occurred_at: occurred_at}), do: occurred_at

  # Period assignment converts the instant to the team billing time zone
  # (SPEC §9.2) via the configured time zone database and takes the local
  # DATE. Should a team zone be unknown to that database, the UTC date is
  # the documented graceful fallback rather than a hard failure.
  defp local_date(%DateTime{} = occurred_at, time_zone) do
    case DateTime.shift_zone(occurred_at, time_zone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _} -> DateTime.to_date(occurred_at)
    end
  end

  ## Normalization

  defp normalize_event(attrs) do
    attrs = Map.new(attrs)

    with {:ok, external_event_id} <- require_string(attrs, :external_event_id),
         {:ok, metric_code} <- require_string(attrs, :metric_code),
         {:ok, occurred_at} <- normalize_occurred_at(attrs[:occurred_at]),
         {:ok, value} <- normalize_value(attrs[:value]),
         {:ok, properties} <- normalize_properties(Map.get(attrs, :properties, %{})),
         {:ok, subscription_ref} <- subscription_ref(attrs) do
      {:ok,
       %{
         external_event_id: external_event_id,
         metric_code: metric_code,
         occurred_at: occurred_at,
         value: value,
         properties: properties,
         subscription_ref: subscription_ref
       }}
    end
  end

  defp require_string(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:invalid_event, "#{key} is required"}}
    end
  end

  defp normalize_occurred_at(%DateTime{} = occurred_at),
    do: {:ok, DateTime.shift_zone!(occurred_at, "Etc/UTC")}

  defp normalize_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, occurred_at, _offset} -> {:ok, occurred_at}
      {:error, _} -> {:error, {:invalid_event, "occurred_at must be an ISO 8601 UTC datetime"}}
    end
  end

  defp normalize_occurred_at(_value),
    do: {:error, {:invalid_event, "occurred_at must be a UTC DateTime"}}

  defp normalize_value(value) do
    case to_decimal(value) do
      %Decimal{} = decimal -> {:ok, decimal}
      nil -> {:error, {:invalid_event, "value must be a decimal"}}
    end
  end

  # Canonical storage/hash form: encoding through the canonical encoder and
  # decoding back yields exactly what a later jsonb read returns, so replay
  # hash comparisons are stable (atom keys become strings, Decimals become
  # canonical strings). Floats are rejected per INV-006.
  defp normalize_properties(properties) when is_map(properties) do
    {:ok, properties |> Canonical.encode!() |> Jason.decode!()}
  rescue
    ArgumentError ->
      {:error, {:invalid_event, "properties must be a JSON object without floats"}}
  end

  defp normalize_properties(_properties),
    do: {:error, {:invalid_event, "properties must be a map"}}

  defp subscription_ref(attrs) do
    cond do
      is_binary(attrs[:subscription_id]) ->
        {:ok, {:id, attrs[:subscription_id]}}

      is_binary(attrs[:subscription_external_id]) ->
        {:ok, {:external_id, attrs[:subscription_external_id]}}

      true ->
        {:error, {:invalid_event, "subscription_id or subscription_external_id is required"}}
    end
  end

  defp resolve_subscription(team_id, {:id, id}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Subscription, id: uuid, team_id: team_id)
      :error -> nil
    end
  end

  defp resolve_subscription(team_id, {:external_id, external_id}) do
    Repo.get_by(Subscription, external_id: external_id, team_id: team_id)
  end

  defp canonical_payload(event, subscription_id) do
    %{
      "external_event_id" => event.external_event_id,
      "metric_code" => event.metric_code,
      "occurred_at" => event.occurred_at,
      "properties" => event.properties,
      "subscription_id" => subscription_id,
      "value" => event.value
    }
  end

  defp quarantine_payload(event) do
    %{
      "external_event_id" => event.external_event_id,
      "metric_code" => event.metric_code,
      "occurred_at" => event.occurred_at,
      "properties" => event.properties,
      "subscription_ref" => quarantine_subscription_ref(event.subscription_ref),
      "value" => event.value
    }
    |> Canonical.encode!()
    |> Jason.decode!()
  end

  defp quarantine_subscription_ref({:id, id}), do: %{"subscription_id" => to_string(id)}

  defp quarantine_subscription_ref({:external_id, external_id}),
    do: %{"subscription_external_id" => external_id}

  ## Policy limits (module config, SPEC §18.5 / BC-US-050/051)

  defp too_old?(occurred_at) do
    limit = DateTime.add(DateTime.utc_now(), -max_age_days() * 86_400, :second)
    DateTime.compare(occurred_at, limit) == :lt
  end

  defp too_far_future?(occurred_at) do
    limit = DateTime.add(DateTime.utc_now(), max_future_hours() * 3_600, :second)
    DateTime.compare(occurred_at, limit) == :gt
  end

  defp oversized_properties?(properties) do
    byte_size(Jason.encode!(properties)) > max_properties_bytes()
  end

  defp config, do: Application.get_env(:billing_core, __MODULE__, [])
  defp max_age_days, do: Keyword.get(config(), :max_age_days, 90)
  defp max_future_hours, do: Keyword.get(config(), :max_future_hours, 24)
  defp max_batch_size, do: Keyword.get(config(), :max_batch_size, 1000)
  defp max_properties_bytes, do: Keyword.get(config(), :max_properties_bytes, 65_536)

  ## Shared helpers

  defp authorize(%Scope{} = scope, roles) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, roles) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp ensure_same_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :unauthorized}
  end

  defp team_time_zone(%Scope{team: %{time_zone: time_zone}}) when is_binary(time_zone),
    do: time_zone

  defp team_time_zone(%Scope{}), do: "Etc/UTC"

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = decimal), do: decimal
  defp to_decimal(int) when is_integer(int), do: Decimal.new(int)

  defp to_decimal(binary) when is_binary(binary) do
    case Decimal.parse(binary) do
      {decimal, ""} -> decimal
      _partial -> nil
    end
  end

  defp to_decimal(_other), do: nil
end
