defmodule BillingCoreWeb.GraphQL.Types.Usage do
  @moduledoc """
  Usage ingestion GraphQL types (SPEC §14.5 usage capability, §14.10,
  BC-US-050/051/052/053).
  """

  use Absinthe.Schema.Notation

  ## Objects

  @desc "Result of one ingested usage event."
  object :usage_ingest_outcome do
    field :status, non_null(:string), description: "accepted | duplicate | quarantined"
    field :usage_event_id, :id
    field :quarantine_reason, :string
  end

  @desc "Aggregation preview for a metric over a period at a fixed cutoff (BC-US-053)."
  object :usage_aggregate do
    field :metric_code, non_null(:string)
    field :aggregation, non_null(:string)
    field :quantity, non_null(:decimal)
    field :event_count, non_null(:integer)
    field :excluded_late, non_null(:integer)
    field :first_occurred_at, :datetime
    field :last_occurred_at, :datetime
    field :cutoff, non_null(:datetime)
  end

  ## ingestUsageEvent

  input_object :ingest_usage_event_input do
    field :team_id, non_null(:id)
    field :external_event_id, non_null(:string)
    field :subscription_id, :id
    field :subscription_external_id, :string
    field :metric_code, non_null(:string)
    field :occurred_at, non_null(:datetime)
    field :value, non_null(:decimal)
    field :properties, :json
    field :client_mutation_id, non_null(:string)
  end

  object :ingest_usage_event_success do
    field :outcome, non_null(:usage_ingest_outcome)
    field :duplicate, non_null(:boolean)
    field :client_mutation_id, non_null(:string)
  end

  @desc "The external event ID was already used with a different payload (BC-US-050)."
  object :usage_event_conflict do
    field :code, non_null(:string)
    field :message, non_null(:string)
    field :client_mutation_id, :string
  end

  union :ingest_usage_event_result do
    types([
      :ingest_usage_event_success,
      :usage_event_conflict,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn
      %{__problem__: :validation}, _ -> :validation_problem
      %{__problem__: :authorization}, _ -> :authorization_problem
      %{__problem__: :usage_conflict}, _ -> :usage_event_conflict
      _, _ -> :ingest_usage_event_success
    end)
  end

  ## ingestUsageBatch

  input_object :usage_batch_event_input do
    field :external_event_id, non_null(:string)
    field :subscription_id, :id
    field :subscription_external_id, :string
    field :metric_code, non_null(:string)
    field :occurred_at, non_null(:datetime)
    field :value, non_null(:decimal)
    field :properties, :json
  end

  input_object :ingest_usage_batch_input do
    field :team_id, non_null(:id)
    field :events, non_null(list_of(non_null(:usage_batch_event_input)))
    field :client_mutation_id, non_null(:string)
  end

  object :usage_batch_item_result do
    field :external_event_id, non_null(:string)
    field :status, non_null(:string), description: "accepted | duplicate | rejected | quarantined"
    field :detail, :string
  end

  object :ingest_usage_batch_success do
    field :accepted, non_null(:integer)
    field :duplicate, non_null(:integer)
    field :rejected, non_null(:integer)
    field :quarantined, non_null(:integer)
    field :items, non_null(list_of(non_null(:usage_batch_item_result)))
    field :client_mutation_id, non_null(:string)
  end

  union :ingest_usage_batch_result do
    types([:ingest_usage_batch_success, :validation_problem, :authorization_problem])

    resolve_type(fn
      %{__problem__: :validation}, _ -> :validation_problem
      %{__problem__: :authorization}, _ -> :authorization_problem
      _, _ -> :ingest_usage_batch_success
    end)
  end

  ## voidUsageEvent

  input_object :void_usage_event_input do
    field :team_id, non_null(:id)
    field :external_event_id, non_null(:string), description: "The measurement to void."

    field :void_event_id, non_null(:string),
      description: "External ID of the void itself (idempotency)."

    field :replacement, :usage_batch_event_input,
      description: "Optional corrected measurement submitted with the void (BC-US-052)."

    field :client_mutation_id, non_null(:string)
  end

  object :void_usage_event_success do
    field :status, non_null(:string), description: "voided | already_voided"
    field :client_mutation_id, non_null(:string)
  end

  union :void_usage_event_result do
    types([
      :void_usage_event_success,
      :usage_event_conflict,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn
      %{__problem__: :validation}, _ -> :validation_problem
      %{__problem__: :authorization}, _ -> :authorization_problem
      %{__problem__: :usage_conflict}, _ -> :usage_event_conflict
      _, _ -> :void_usage_event_success
    end)
  end
end
