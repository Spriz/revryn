defmodule BillingCore.OperationsTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.Operations
  alias BillingCore.Operations.{Operation, RetryPolicy}
  alias BillingCore.Outbox

  defp create_operation(attrs \\ %{}) do
    Operations.create!(
      Map.merge(
        %{type: "erp.create_draft", actor_type: "system", team_id: Ecto.UUID.generate()},
        attrs
      )
    )
  end

  describe "lifecycle (SPEC §11.3)" do
    test "queued → executing → succeeded with transition evidence" do
      op = create_operation()
      assert op.state == "queued"

      op = Operations.transition!(op, :claim)
      assert op.state == "executing"
      assert op.started_at

      op = Operations.transition!(op, :succeed)
      assert op.state == "succeeded"
      assert op.finished_at

      transitions =
        Repo.all(
          from(t in "operation_transitions",
            prefix: "billing",
            where: t.operation_id == type(^op.id, Ecto.UUID),
            order_by: t.occurred_at,
            select: {t.from_state, t.to_state, t.event}
          )
        )

      assert transitions == [
               {"queued", "executing", "claim"},
               {"executing", "succeeded", "succeed"}
             ]
    end

    test "illegal transitions are rejected" do
      op = create_operation()
      assert {:error, %{reason: :illegal_transition}} = Operations.transition(op, :succeed)

      op = Operations.transition!(op, :claim)
      op = Operations.transition!(op, :succeed)
      assert {:error, %{reason: :terminal_state}} = Operations.transition(op, :claim)
    end

    test "outcome-unknown requires reconciliation before retry" do
      op = create_operation() |> Operations.transition!(:claim)
      op = Operations.record_failure!(op, :outcome_unknown, summary: "timeout after POST")
      assert op.state == "outcome_unknown"

      op = Operations.transition!(op, :reconcile)
      assert op.state == "reconciling"

      op = Operations.transition!(op, :absence_proven)
      assert op.state == "retry_scheduled"
    end
  end

  describe "record_failure!/3 retry policy (SPEC §22.9.1)" do
    test "transient errors schedule retries until attempts are exhausted, then dead-letter" do
      op = create_operation() |> Operations.transition!(:claim)

      op =
        Enum.reduce(1..(RetryPolicy.max_attempts() - 1), op, fn _i, op ->
          op = Operations.record_failure!(op, :transient, summary: "connection reset")
          assert op.state == "retry_scheduled"
          assert op.next_attempt_at
          Operations.transition!(op, :retry)
        end)

      op = Operations.record_failure!(op, :transient, summary: "connection reset")
      assert op.state == "failed"
      assert op.error_class == "transient"

      assert [event] =
               Outbox.pending() |> Enum.filter(&(&1.event_type == "operation.dead_lettered.v1"))

      assert event.aggregate_id == op.id
    end

    test "validation failures dead-letter immediately" do
      op = create_operation() |> Operations.transition!(:claim)
      op = Operations.record_failure!(op, :validation, code: "missing_mapping")
      assert op.state == "failed"
    end

    test "authorization failures block for remediation, then requeue" do
      op = create_operation() |> Operations.transition!(:claim)
      op = Operations.record_failure!(op, :authorization, blocked_reason: "credentials_revoked")
      assert op.state == "blocked"
      assert op.blocked_reason == "credentials_revoked"

      op = Operations.transition!(op, :remediate)
      assert op.state == "queued"
    end

    test "throttling honors provider retry_after" do
      op = create_operation() |> Operations.transition!(:claim)
      before = DateTime.utc_now()
      op = Operations.record_failure!(op, :throttled, retry_after: 300)
      assert op.state == "retry_scheduled"
      assert DateTime.diff(op.next_attempt_at, before) >= 300
    end

    test "failed operations support authorized manual retry" do
      op = create_operation() |> Operations.transition!(:claim)
      op = Operations.record_failure!(op, :terminal, summary: "provider rejected")
      assert op.state == "failed"

      op = Operations.transition!(op, :manual_retry)
      assert op.state == "queued"
    end
  end

  describe "queries" do
    test "runnable returns queued and due retries only" do
      queued = create_operation()

      future_retry =
        create_operation()
        |> Operations.transition!(:claim)
        |> Operations.record_failure!(:throttled, retry_after: 3600)

      due_retry =
        create_operation()
        |> Operations.transition!(:claim)
        |> then(fn op ->
          {:ok, op} =
            Operations.transition(op, :retryable_error, %{
              attempt_count: 1,
              next_attempt_at: DateTime.add(DateTime.utc_now(), -5)
            })

          op
        end)

      ids = Operations.runnable() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ids, queued.id)
      assert MapSet.member?(ids, due_retry.id)
      refute MapSet.member?(ids, future_retry.id)
    end

    test "failure_inbox lists actionable states for a team" do
      team_id = Ecto.UUID.generate()

      blocked =
        create_operation(%{team_id: team_id})
        |> Operations.transition!(:claim)
        |> Operations.record_failure!(:authorization, blocked_reason: "credentials")

      _succeeded =
        create_operation(%{team_id: team_id})
        |> Operations.transition!(:claim)
        |> Operations.transition!(:succeed)

      _other_team = create_operation()

      assert [%Operation{id: id}] = Operations.failure_inbox(team_id)
      assert id == blocked.id
    end
  end
end
