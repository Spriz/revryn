defmodule BillingCore.Credits.Close.LifecycleTest do
  use ExUnit.Case, async: true

  alias BillingCore.Credits.Close.Lifecycle

  test "implements every recovery path from SPEC 11.5" do
    assert {:ok, :calculating} = Lifecycle.transition(:open, :begin_calculation)
    assert {:ok, :ready} = Lifecycle.transition(:calculating, :calculation_succeeded)
    assert {:ok, :approved} = Lifecycle.transition(:ready, :approve)
    assert {:ok, :posting} = Lifecycle.transition(:approved, :start_posting)
    assert {:ok, :outcome_unknown} = Lifecycle.transition(:posting, :posting_uncertain)
    assert {:ok, :posting} = Lifecycle.transition(:outcome_unknown, :retry_posting)
    assert {:ok, :posted} = Lifecycle.transition(:posting, :posting_succeeded)
    assert {:ok, :mismatch} = Lifecycle.transition(:posted, :detect_mismatch)
    assert {:ok, :reconciled} = Lifecycle.transition(:mismatch, :remediate)
    assert {:ok, :closed} = Lifecycle.transition(:reconciled, :close)
    assert {:ok, :reversal_pending} = Lifecycle.transition(:closed, :request_reversal)
    assert {:ok, :reversed} = Lifecycle.transition(:reversal_pending, :reversal_reconciled)

    assert {:error, %{reason: :terminal_state}} =
             Lifecycle.transition(:reversed, :retry_calculation)
  end

  test "does not permit posting before finance approval" do
    assert {:error, %{reason: :illegal_transition}} = Lifecycle.transition(:ready, :start_posting)
  end
end
