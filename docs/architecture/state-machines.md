# Domain lifecycle state machines

Generated from `BillingCore.Domain.Lifecycles` — do not edit by hand.
Regenerate with:

    mix run --no-start -e 'File.write!("docs/architecture/state-machines.md", BillingCore.Domain.Lifecycles.to_markdown())'

One executable transition table per lifecycle is the only source of
allowed transitions (BC-US-160, INV-046). Invalid transitions fail
deterministically before external side effects, and PostgreSQL — never
BEAM process lifetime — is authoritative for current state (INV-047).
Changing a table changes this document, which is reviewed as product
behavior.

## Subscription (§11.1)

Enforced by BillingCore.Contracts — commands guard transitions before any write. Initial state `scheduled`;
terminal states: `cancelled`.

```mermaid
stateDiagram-v2
  [*] --> scheduled
  active --> active: change
  active --> cancelled: cancel
  active --> paused: pause
  active --> pending_cancellation: cancel_at_period_end
  paused --> active: resume
  pending_cancellation --> cancelled: reach_period_boundary
  scheduled --> active: activate
  scheduled --> cancelled: cancel
  cancelled --> [*]
```
<a id="subscription"></a>

## Invoice intent and ERP synchronization (§11.2)

Enforced by BillingCore.Billing / BillingCore.ERP.Sync — persisted per-intent lifecycle rows. Initial state `frozen`;
terminal states: `superseded`.

```mermaid
stateDiagram-v2
  [*] --> frozen
  approved --> booking_pending: book
  approved --> erp_draft: approval_invalidated
  booking_pending --> erp_booked: booked_reconciled
  booking_pending --> sync_error: sync_failed
  credit_required --> erp_booked: correction_case_created
  erp_booked --> credit_required: correction_approved
  erp_draft --> approved: approve
  erp_draft --> erp_booked: externally_booked
  erp_draft --> erp_draft: draft_updated
  frozen --> superseded: supersede
  frozen --> sync_pending: enqueue_sync
  sync_error --> sync_pending: retry_sync
  sync_pending --> erp_draft: draft_reconciled
  sync_pending --> sync_error: sync_failed
  superseded --> [*]
```
<a id="invoice-intent"></a>

## Durable operation (§11.3)

Enforced by BillingCore.Operations — every external effect runs inside one operation. Initial state `queued`;
terminal states: `succeeded`.

```mermaid
stateDiagram-v2
  [*] --> queued
  blocked --> queued: remediate
  executing --> blocked: block
  executing --> failed: fail
  executing --> outcome_unknown: lose_outcome
  executing --> retry_scheduled: retryable_error
  executing --> succeeded: succeed
  failed --> queued: manual_retry
  outcome_unknown --> reconciling: reconcile
  queued --> executing: claim
  reconciling --> retry_scheduled: absence_proven
  reconciling --> succeeded: effect_found
  retry_scheduled --> executing: retry
  succeeded --> [*]
```
<a id="durable-operation"></a>

## Customer-credit grant projection (§11.4)

Enforced by BillingCore.Credits — projection over the append-only subledger. Initial state `available`;
terminal states: `expired`, `refunded`, `spent`.

```mermaid
stateDiagram-v2
  [*] --> available
  available --> expiry_scheduled: schedule_expiry
  available --> partially_spent: apply_partial
  available --> refund_pending: request_refund
  available --> reserved: reserve
  expiry_scheduled --> available: reverse_expiry
  expiry_scheduled --> expired: expire
  partially_spent --> expiry_scheduled: schedule_expiry
  partially_spent --> refund_pending: request_refund
  partially_spent --> reserved: reserve
  partially_spent --> spent: apply_full
  refund_pending --> refunded: reconcile_refund
  reserved --> available: release
  reserved --> partially_spent: apply_partial
  reserved --> spent: apply_full
  expired --> [*]
  refunded --> [*]
  spent --> [*]
```
<a id="credit-grant"></a>

## Monthly customer-credit close (§11.5, ADR-031)

Enforced by BillingCore.Credits.CloseWorkflow / ClosePosting. Initial state `open`;
terminal states: `reversed`, `superseded`.

```mermaid
stateDiagram-v2
  [*] --> open
  approved --> posting: start_posting
  calculating --> failed: calculation_failed
  calculating --> ready: calculation_succeeded
  closed --> reversal_pending: request_reversal
  failed --> calculating: retry_calculation
  mismatch --> reconciled: remediate
  open --> calculating: begin_calculation
  outcome_unknown --> posted: outcome_found
  outcome_unknown --> posting: retry_posting
  posted --> mismatch: detect_mismatch
  posted --> reconciled: reconcile
  posting --> outcome_unknown: posting_uncertain
  posting --> posted: posting_succeeded
  ready --> approved: approve
  ready --> superseded: supersede
  reconciled --> closed: close
  reversal_pending --> reversed: reversal_reconciled
  reversed --> [*]
  superseded --> [*]
```
<a id="customer-credit-close"></a>

