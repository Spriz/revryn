defmodule BillingCore.Operations do
  @moduledoc """
  Durable operation lifecycle (SPEC §11.3, §22.9, INV-040/041/042).

  The operation row is authoritative for the user-visible state of
  asynchronous work. Transitions are validated against the §11.3 state
  machine, committed with optimistic locking, and evidenced in
  `operation_transitions`. `record_failure!/3` applies the retry policy so
  callers never hand-roll retry/blocked/dead-letter decisions.
  """

  import Ecto.Query

  alias BillingCore.Domain.StateMachine
  alias BillingCore.Operations.{Operation, RetryPolicy}
  alias BillingCore.Repo

  @machine StateMachine.new(:operation,
             initial: :queued,
             transitions: [
               {:queued, :claim, :executing},
               {:executing, :succeed, :succeeded},
               {:executing, :retryable_error, :retry_scheduled},
               {:retry_scheduled, :retry, :executing},
               {:executing, :lose_outcome, :outcome_unknown},
               {:outcome_unknown, :reconcile, :reconciling},
               {:reconciling, :effect_found, :succeeded},
               {:reconciling, :absence_proven, :retry_scheduled},
               {:executing, :block, :blocked},
               {:blocked, :remediate, :queued},
               {:executing, :fail, :failed},
               {:failed, :manual_retry, :queued}
             ],
             terminal: [:succeeded]
           )

  @doc "The §11.3 operation state machine definition."
  def machine, do: @machine

  @doc "Creates a durable operation in `queued` state."
  @spec create!(map()) :: Operation.t()
  def create!(attrs) do
    attrs
    |> Operation.create_changeset()
    |> Repo.insert!()
  end

  @spec get!(Ecto.UUID.t()) :: Operation.t()
  def get!(id), do: Repo.get!(Operation, id)

  @doc """
  Applies `event` to the operation, committing the new state atomically with
  its transition evidence. Additional field changes go in `attrs`.
  Returns `{:ok, operation}` or `{:error, %StateMachine.TransitionError{}}`.
  """
  @spec transition(Operation.t(), atom(), map()) ::
          {:ok, Operation.t()} | {:error, StateMachine.TransitionError.t()}
  def transition(%Operation{} = operation, event, attrs \\ %{}) do
    from_state = String.to_existing_atom(operation.state)

    with {:ok, to_state} <- StateMachine.transition(@machine, from_state, event) do
      now = DateTime.utc_now()

      lifecycle_attrs =
        case to_state do
          :executing -> %{started_at: operation.started_at || now}
          :succeeded -> %{finished_at: now}
          :failed -> %{finished_at: now}
          _ -> %{}
        end

      result =
        Repo.transaction(fn ->
          updated =
            operation
            |> Operation.update_changeset(
              attrs
              |> Map.merge(lifecycle_attrs)
              |> Map.put(:state, Atom.to_string(to_state))
            )
            |> Repo.update!()

          Repo.insert_all(
            "operation_transitions",
            [
              %{
                id: Ecto.UUID.dump!(Ecto.UUID.generate()),
                operation_id: Ecto.UUID.dump!(operation.id),
                from_state: operation.state,
                to_state: Atom.to_string(to_state),
                event: Atom.to_string(event),
                reason: attrs[:safe_error_summary] || attrs[:blocked_reason],
                occurred_at: now
              }
            ],
            prefix: "billing"
          )

          :telemetry.execute(
            [:billing_core, :operation, :transition],
            %{count: 1},
            %{
              type: updated.type,
              from_state: operation.state,
              to_state: updated.state,
              event: event
            }
          )

          updated
        end)

      case result do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> raise "operation transition failed unexpectedly: #{inspect(reason)}"
      end
    end
  end

  @doc "Bang variant of `transition/3`."
  @spec transition!(Operation.t(), atom(), map()) :: Operation.t()
  def transition!(operation, event, attrs \\ %{}) do
    case transition(operation, event, attrs) do
      {:ok, updated} -> updated
      {:error, error} -> raise "illegal operation transition: #{inspect(error)}"
    end
  end

  @doc """
  Records a failed attempt on an `executing` operation and applies the retry
  policy (SPEC §22.9.1): schedules a retry, demands reconciliation, blocks on
  a user-fixable precondition, or dead-letters. Error details are stored as
  sanitized fields only.
  """
  @spec record_failure!(Operation.t(), RetryPolicy.error_class(), keyword()) :: Operation.t()
  def record_failure!(%Operation{state: "executing"} = operation, error_class, opts \\ []) do
    attempt = operation.attempt_count + 1

    base_attrs = %{
      attempt_count: attempt,
      error_class: Atom.to_string(error_class),
      safe_error_code: Keyword.get(opts, :code),
      safe_error_summary: Keyword.get(opts, :summary)
    }

    case RetryPolicy.decide(error_class, attempt, Keyword.take(opts, [:retry_after])) do
      {:retry, delay_seconds} ->
        transition!(
          operation,
          :retryable_error,
          Map.put(base_attrs, :next_attempt_at, DateTime.add(DateTime.utc_now(), delay_seconds))
        )

      :reconcile ->
        transition!(operation, :lose_outcome, base_attrs)

      :block ->
        transition!(
          operation,
          :block,
          Map.put(base_attrs, :blocked_reason, Keyword.get(opts, :blocked_reason, "precondition"))
        )

      :fail ->
        # Dead-letter fact commits atomically with the failed transition.
        {:ok, failed} =
          Repo.transaction(fn ->
            op = transition!(operation, :fail, base_attrs)

            BillingCore.Outbox.emit!("operation.dead_lettered.v1",
              aggregate: {:operation, op.id},
              team_id: op.team_id,
              correlation_id: op.correlation_id,
              payload: %{type: op.type, error_class: op.error_class, attempts: op.attempt_count}
            )

            op
          end)

        failed
    end
  end

  @doc "Operations ready to run: queued, or retry-scheduled with elapsed timer."
  @spec runnable(pos_integer()) :: [Operation.t()]
  def runnable(limit \\ 100) do
    now = DateTime.utc_now()

    Operation
    |> where(
      [o],
      o.state == "queued" or
        (o.state == "retry_scheduled" and o.next_attempt_at <= ^now)
    )
    |> order_by([o], asc: o.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Failure-inbox listing for a team (SPEC §22.9.3): actionable states."
  @spec failure_inbox(Ecto.UUID.t()) :: [Operation.t()]
  def failure_inbox(team_id) do
    Operation
    |> where([o], o.team_id == ^team_id)
    |> where(
      [o],
      o.state in ["blocked", "failed", "outcome_unknown", "reconciling", "retry_scheduled"]
    )
    |> order_by([o], desc: o.updated_at)
    |> Repo.all()
  end

  @doc """
  Recent operations of a team in any state, newest first (SPEC §22.9.3
  companion listing to `failure_inbox/1`; capped at 100).
  """
  @spec list_recent(Ecto.UUID.t(), pos_integer()) :: [Operation.t()]
  def list_recent(team_id, limit \\ 50) do
    Operation
    |> where([o], o.team_id == ^team_id)
    |> order_by([o], desc: o.inserted_at)
    |> limit(^min(limit, 100))
    |> Repo.all()
  end
end
