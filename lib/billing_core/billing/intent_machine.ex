defmodule BillingCore.Billing.IntentMachine do
  @moduledoc """
  Invoice-intent lifecycle state machine (SPEC §11.2).

  Intents are persisted only once frozen, so the machine's initial state is
  `frozen` (the spec's `preview` state is an unpersisted concept). The
  immutable intent snapshot never carries this state; it lives in
  `invoice_intent_lifecycle` with append-only transition evidence.
  """

  alias BillingCore.Domain.StateMachine

  @machine StateMachine.new(:invoice_intent,
             initial: :frozen,
             transitions: [
               {:frozen, :supersede, :superseded},
               {:frozen, :enqueue_sync, :sync_pending},
               {:sync_pending, :draft_reconciled, :erp_draft},
               {:sync_pending, :sync_failed, :sync_error},
               {:erp_draft, :draft_updated, :erp_draft},
               {:erp_draft, :approve, :approved},
               # BC-US-086: a draft booked directly inside the ERP becomes
               # erp_booked only after the authoritative fetch reconciles.
               {:erp_draft, :externally_booked, :erp_booked},
               {:approved, :book, :booking_pending},
               {:booking_pending, :booked_reconciled, :erp_booked},
               {:booking_pending, :sync_failed, :sync_error},
               {:erp_booked, :correction_approved, :credit_required},
               {:credit_required, :correction_case_created, :erp_booked},
               # Recovery: a failed sync can retry back into pending after
               # remediation (BC-US-106) — modeled explicitly so the operator
               # path is legal.
               {:sync_error, :retry_sync, :sync_pending},
               # An approved draft whose external hash drifted must fall back
               # to draft state for re-reconciliation (BC-US-084: any
               # subsequent draft change invalidates approval).
               {:approved, :approval_invalidated, :erp_draft}
             ],
             terminal: [:superseded]
           )

  @spec machine() :: StateMachine.t()
  def machine, do: @machine

  @spec transition(atom() | String.t(), atom()) ::
          {:ok, atom()} | {:error, StateMachine.TransitionError.t()}
  def transition(from, event) when is_binary(from) do
    transition(String.to_existing_atom(from), event)
  end

  def transition(from, event) when is_atom(from) do
    StateMachine.transition(@machine, from, event)
  end

  @spec states() :: [atom()]
  def states, do: StateMachine.states(@machine)

  @spec to_mermaid() :: String.t()
  def to_mermaid, do: StateMachine.to_mermaid(@machine)
end
