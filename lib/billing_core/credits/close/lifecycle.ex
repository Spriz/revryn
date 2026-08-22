defmodule BillingCore.Credits.Close.Lifecycle do
  @moduledoc "The persisted monthly customer-credit close lifecycle (SPEC §11.5)."

  alias BillingCore.Domain.StateMachine

  @machine StateMachine.new(:customer_credit_close,
             initial: :open,
             transitions: [
               {:open, :begin_calculation, :calculating},
               {:calculating, :calculation_succeeded, :ready},
               {:calculating, :calculation_failed, :failed},
               {:failed, :retry_calculation, :calculating},
               {:ready, :approve, :approved},
               {:ready, :supersede, :superseded},
               {:approved, :start_posting, :posting},
               {:posting, :posting_succeeded, :posted},
               {:posting, :posting_uncertain, :outcome_unknown},
               {:outcome_unknown, :outcome_found, :posted},
               {:outcome_unknown, :retry_posting, :posting},
               {:posted, :reconcile, :reconciled},
               {:posted, :detect_mismatch, :mismatch},
               {:mismatch, :remediate, :reconciled},
               {:reconciled, :close, :closed},
               {:closed, :request_reversal, :reversal_pending},
               {:reversal_pending, :reversal_reconciled, :reversed}
             ],
             terminal: [:superseded, :reversed]
           )

  @spec machine() :: StateMachine.t()
  def machine, do: @machine

  @spec transition(atom(), atom(), map()) ::
          {:ok, atom()} | {:error, StateMachine.TransitionError.t()}
  def transition(state, event, context \\ %{}),
    do: StateMachine.transition(@machine, state, event, context)

  @spec legal_events(atom()) :: [atom()]
  def legal_events(state), do: StateMachine.legal_events(@machine, state)
end
