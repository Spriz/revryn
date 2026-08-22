defmodule BillingCore.Operations.RetryPolicyTest do
  @moduledoc """
  SPEC §22.9.1 error-class decision table and the §21.3 backoff schedule
  [0, 5, 30, 120, 600, 1800, 7200] with bounded jitter (up to 20%, min 1s).
  """

  use ExUnit.Case, async: true

  alias BillingCore.Operations.RetryPolicy

  # Jitter is 1..max(div(base, 5), 1) seconds on top of the scheduled base.
  defp assert_backoff({:retry, delay}, base) do
    upper = base + max(div(base, 5), 1)
    assert delay > base and delay <= upper, "expected #{base} < #{delay} <= #{upper}"
  end

  test "max_attempts/0 matches the length of the ERP backoff schedule" do
    assert RetryPolicy.max_attempts() == 7
  end

  test "outcome_unknown must reconcile before any retry (INV-008/009)" do
    assert RetryPolicy.decide(:outcome_unknown, 1) == :reconcile
    assert RetryPolicy.decide(:outcome_unknown, 99) == :reconcile
  end

  test "validation and terminal failures are terminal for automation" do
    assert RetryPolicy.decide(:validation, 1) == :fail
    assert RetryPolicy.decide(:terminal, 1) == :fail
  end

  test "authorization and conflict failures block for remediation" do
    assert RetryPolicy.decide(:authorization, 1) == :block
    assert RetryPolicy.decide(:conflict, 1) == :block
  end

  test "poison gets exactly one bounded retry, then fails" do
    assert_backoff(RetryPolicy.decide(:poison, 1), 5)
    assert RetryPolicy.decide(:poison, 2) == :fail
    assert RetryPolicy.decide(:poison, 5) == :fail
  end

  describe "throttled" do
    test "provider retry_after overrides the schedule, with jitter on top" do
      assert_backoff(RetryPolicy.decide(:throttled, 1, retry_after: 300), 300)
    end

    test "a zero retry_after retries immediately without jitter" do
      assert RetryPolicy.decide(:throttled, 1, retry_after: 0) == {:retry, 0}
    end

    test "falls back to the backoff schedule without provider metadata" do
      assert_backoff(RetryPolicy.decide(:throttled, 2), 30)
    end

    test "fails once attempts are exhausted, even with retry_after" do
      assert RetryPolicy.decide(:throttled, 7) == :fail
      assert RetryPolicy.decide(:throttled, 7, retry_after: 300) == :fail
    end
  end

  describe "transient and dependency_unavailable" do
    test "retry on the schedule until attempts are exhausted" do
      assert_backoff(RetryPolicy.decide(:transient, 1), 5)
      assert_backoff(RetryPolicy.decide(:transient, 3), 120)
      assert_backoff(RetryPolicy.decide(:dependency_unavailable, 4), 600)
    end

    test "fail at and beyond the attempt cap" do
      assert RetryPolicy.decide(:transient, 7) == :fail
      assert RetryPolicy.decide(:transient, 8) == :fail
      assert RetryPolicy.decide(:dependency_unavailable, 7) == :fail
    end
  end

  describe "delay_for/1" do
    test "walks the documented schedule" do
      assert_backoff({:retry, RetryPolicy.delay_for(1)}, 5)
      assert_backoff({:retry, RetryPolicy.delay_for(2)}, 30)
      assert_backoff({:retry, RetryPolicy.delay_for(5)}, 1800)
    end

    test "caps at the final backoff rung for large attempt counts" do
      assert_backoff({:retry, RetryPolicy.delay_for(6)}, 7200)
      assert_backoff({:retry, RetryPolicy.delay_for(50)}, 7200)
    end
  end
end
