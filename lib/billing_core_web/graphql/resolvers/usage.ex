defmodule BillingCoreWeb.GraphQL.Resolvers.Usage do
  @moduledoc """
  Usage ingestion and aggregation resolvers (SPEC §14.5 usage capability,
  §14.10, BC-US-050…053). Ingestion is idempotent by external event ID at
  the domain layer, so no additional idempotency record is kept.
  """

  alias BillingCore.{Contracts, Usage}
  alias BillingCore.Domain.Period
  alias BillingCoreWeb.GraphQL.Errors

  ## ingestUsageEvent (BC-US-050, §14.10)

  def ingest_usage_event(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    case Usage.ingest_event(scope, event_attrs(input)) do
      {:ok, %{status: :accepted} = outcome} ->
        {:ok, success_payload(outcome, false, cmid)}

      {:ok, %{status: :duplicate} = outcome} ->
        {:ok, success_payload(outcome, true, cmid)}

      {:ok, %{status: :quarantined} = outcome} ->
        {:ok, success_payload(outcome, false, cmid)}

      {:error, :conflict} ->
        {:ok, usage_conflict(cmid)}

      {:error, reason} ->
        {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## ingestUsageBatch (BC-US-051)

  def ingest_usage_batch(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id
    events = Enum.map(input.events, &event_attrs/1)

    case Usage.ingest_batch(scope, events) do
      {:ok, result} ->
        items =
          Enum.map(result.rejected, &batch_item(&1, "rejected")) ++
            Enum.map(result.quarantined, &batch_item(&1, "quarantined"))

        {:ok,
         %{
           accepted: result.accepted,
           duplicate: result.duplicate,
           rejected: length(result.rejected),
           quarantined: length(result.quarantined),
           items: items,
           client_mutation_id: cmid
         }}

      {:error, reason} ->
        {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## voidUsageEvent (BC-US-052)

  def void_usage_event(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    opts =
      [void_event_id: input.void_event_id] ++
        case input[:replacement] do
          nil -> []
          replacement -> [replacement: event_attrs(replacement)]
        end

    case Usage.void_event(scope, input.external_event_id, opts) do
      {:ok, :already_voided} ->
        {:ok, %{status: "already_voided", client_mutation_id: cmid}}

      {:ok, _} ->
        {:ok, %{status: "voided", client_mutation_id: cmid}}

      {:error, :already_voided} ->
        {:ok, usage_conflict(cmid, "ALREADY_VOIDED", "a different void already exists")}

      {:error, reason} ->
        {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## usagePreview query (BC-US-053)

  def usage_preview(_parent, args, %{context: %{scope: scope}}) do
    with {:ok, subscription} <- Contracts.get_subscription(scope, args.subscription_id),
         {:ok, period} <- Period.new(args.period_start, args.period_end_exclusive),
         {:ok, aggregate} <-
           Usage.aggregate(
             scope,
             subscription,
             args.metric_code,
             period,
             args[:cutoff] || DateTime.utc_now(),
             aggregation: parse_aggregation(args[:aggregation])
           ) do
      {:ok,
       %{
         metric_code: args.metric_code,
         aggregation: to_string(aggregate.aggregation),
         quantity: aggregate.quantity,
         event_count: aggregate.event_count,
         excluded_late: aggregate.excluded_late,
         first_occurred_at: aggregate.first_occurred_at,
         last_occurred_at: aggregate.last_occurred_at,
         cutoff: aggregate.cutoff
       }}
    else
      {:error, :invalid_period} ->
        Errors.query_error("INVALID_PERIOD", "period start must precede exclusive end")

      {:error, :not_found} ->
        Errors.query_error("NOT_FOUND", "subscription not found")

      {:error, :unauthorized} ->
        Errors.query_error("UNAUTHORIZED", "not allowed")

      {:error, :unknown_aggregation} ->
        Errors.query_error("INVALID_AGGREGATION", "unknown aggregation")
    end
  end

  ## Internals

  defp event_attrs(input) do
    %{
      external_event_id: input.external_event_id,
      metric_code: input.metric_code,
      occurred_at: usec(input.occurred_at),
      value: input.value,
      properties: input[:properties] || %{}
    }
    |> put_subscription_ref(input)
  end

  defp put_subscription_ref(attrs, input) do
    cond do
      id = input[:subscription_id] -> Map.put(attrs, :subscription_id, id)
      ext = input[:subscription_external_id] -> Map.put(attrs, :subscription_external_id, ext)
      true -> attrs
    end
  end

  defp usec(%DateTime{} = dt), do: %{dt | microsecond: {elem(dt.microsecond, 0), 6}}

  defp batch_item(item, status) do
    %{
      external_event_id: item.external_event_id,
      status: status,
      detail: inspect(item.reason)
    }
  end

  defp success_payload(outcome, duplicate, cmid) do
    %{
      outcome: %{
        status: to_string(outcome.status),
        usage_event_id: outcome[:usage_event_id],
        quarantine_reason: outcome[:reason] && to_string(outcome[:reason])
      },
      duplicate: duplicate,
      client_mutation_id: cmid
    }
  end

  defp usage_conflict(
         cmid,
         code \\ "USAGE_EVENT_CONFLICT",
         message \\ "external event ID already used with a different payload"
       ) do
    %{
      __problem__: :usage_conflict,
      code: code,
      message: message,
      client_mutation_id: cmid
    }
  end

  defp parse_aggregation(nil), do: :sum

  defp parse_aggregation(name) when name in ~w(sum count max unique_count),
    do: String.to_existing_atom(name)

  defp parse_aggregation(_), do: :sum
end
