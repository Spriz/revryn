defmodule BillingCore.Operations.RetryPolicy do
  @moduledoc """
  Error classification and retry policy for asynchronous operations
  (SPEC §21.3, §22.9.1, INV-041). Retries are policy, not reflex.
  """

  @typedoc "SPEC §22.9.1 error classes."
  @type error_class ::
          :transient
          | :throttled
          | :dependency_unavailable
          | :validation
          | :authorization
          | :conflict
          | :outcome_unknown
          | :poison
          | :terminal

  # SPEC §21.3 default ERP retry schedule in seconds (attempt 1 is immediate).
  @erp_backoff_seconds [0, 5, 30, 120, 600, 1800, 7200]
  @max_attempts length(@erp_backoff_seconds)

  @doc "Maximum automatic attempts before dead-letter (SPEC §21.3)."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Decides the automatic behavior after a failure of `error_class` on attempt
  `attempt` (1-based). Returns:

    * `{:retry, delay_seconds}` — schedule a retry (jitter already applied);
    * `:reconcile` — outcome unknown; reconcile before any retry (INV-008/009);
    * `:block` — user-fixable precondition; wait for remediation;
    * `:fail` — terminal for automation; requires authorized manual retry.

  A `retry_after` from provider throttling metadata overrides the schedule.
  """
  @spec decide(error_class(), pos_integer(), keyword()) ::
          {:retry, non_neg_integer()} | :reconcile | :block | :fail
  def decide(error_class, attempt, opts \\ [])

  def decide(:outcome_unknown, _attempt, _opts), do: :reconcile
  def decide(:validation, _attempt, _opts), do: :fail
  def decide(:terminal, _attempt, _opts), do: :fail
  def decide(:authorization, _attempt, _opts), do: :block
  def decide(:conflict, _attempt, _opts), do: :block

  def decide(:poison, attempt, _opts) do
    # Minimal bounded retry for possible transient serialization flukes.
    if attempt < 2, do: {:retry, jittered(5)}, else: :fail
  end

  def decide(:throttled, attempt, opts) do
    cond do
      attempt >= max_attempts() ->
        :fail

      retry_after = Keyword.get(opts, :retry_after) ->
        {:retry, retry_after + jitter_for(retry_after)}

      true ->
        {:retry, delay_for(attempt)}
    end
  end

  def decide(class, attempt, _opts) when class in [:transient, :dependency_unavailable] do
    if attempt >= max_attempts(), do: :fail, else: {:retry, delay_for(attempt)}
  end

  @doc "Backoff delay in seconds for the NEXT attempt after `attempt` failures, with jitter."
  @spec delay_for(pos_integer()) :: non_neg_integer()
  def delay_for(attempt) when attempt >= 1 do
    base = Enum.at(@erp_backoff_seconds, min(attempt, @max_attempts - 1))
    jittered(base)
  end

  defp jittered(base), do: base + jitter_for(base)

  # Up to 20% jitter, minimum 1 second for non-immediate delays.
  defp jitter_for(0), do: 0
  defp jitter_for(base), do: :rand.uniform(max(div(base, 5), 1))
end
