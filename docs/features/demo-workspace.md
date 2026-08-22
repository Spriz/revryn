---
id: demo-workspace
title: Guided demo ERP workspace
status: experimental
public: true
owners: [product-experience, erp-integration, billing-domain]
stories: [BC-US-166]
tasks: [BC-TASK-105]
tests:
  workflow:
    - test/workflows/demo_workspace_test.exs
    - test/workflows/demo_workspace_scenario_test.exs
  liveview:
    - test/billing_core_web/live/first_run_live_test.exs
    - test/billing_core_web/live/demo_live_test.exs
  unit:
    - test/unit/erp/fake_erp_snapshot_test.exs
    - test/unit/erp/fake_erp_instance_supervisor_test.exs
---

# Guided demo ERP workspace

## Product promise

A prospective operator can create an isolated Northstar Studio workspace and
inspect how Revryn connects commercial billing facts to accounting evidence
without supplying e-conomic credentials. The demo is visibly synthetic, but
its provider calls use the same adapter port, durable-operation semantics,
idempotency rules, and authoritative read-back boundary as a real connection.

This is not a seeded metrics dashboard and it is not a testing provider exposed
as if it were production. The experience must teach one coherent cause-and-
effect story and show only artifacts that actually exist.

## Current implementation slice

The current experimental slice provides:

- a purposeful first-run choice between sample books and real e-conomic setup;
- one active demo generation per user, with an ordinary organization, team,
  membership roles, ERP connection, preflight, audit facts, and outbox facts;
- a connection-scoped FakeERP process backed by a versioned, SHA-256-bound
  database snapshot;
- deterministic resume and non-destructive reset into a new generation;
- database guards that keep workspace, team, organization, ERP connection, and
  fake-provider instance ownership consistent;
- the deterministic Northstar commercial model (`BillingCore.Demo.Scenario`):
  one guided action creates the over-time product, published annual prepaid
  plan version, customer, ERP mappings, contract, and subscription through the
  ordinary catalog/contract commands, atomically and idempotently, anchored on
  the workspace's provisioning month; and
- a guided invoice phase that sends the operator to the real subscription and
  invoice surfaces for preview/freeze, draft, approval, and booking, derives
  its sub-state exclusively from the durable intent lifecycle and ERP document
  rows, and records completed phases on the workspace as artifact references
  via `Demo.mark_step/3` (evidence pointers, never the completion truth); and
- a guided customer-credit phase, gated on the booked invoice, that records
  one deterministic goodwill grant through the ordinary account, projection,
  and credit-subledger commands (idempotent by grant idempotency key) and
  links the evidence on the customer surface; and
- a guided aggregate-close phase, gated on the credit movement, that sends
  the operator to the real credit-closes surface for policy setup,
  deterministic generation, exact-hash approval, durable voucher posting
  with report attachment, reconciliation, and period acceptance — derived
  from the durable close lifecycle rows and recorded with voucher and
  report-hash references when the period closes.

The guided commercial → invoice → credit → aggregate close → reconciliation
story is complete end to end. Remaining BC-TASK-105 work — activation
telemetry, Playwright happy/recovery paths, and qualitative user evidence —
is tracked in `TODO.md`.

## Isolation and durability

Each demo workspace has its own team, ERP connection, and fake-provider
instance. Provider state is not stored only in a GenServer: committed drafts,
booked documents, finance vouchers, attachments, reference indexes, and
counters are exported as a versioned snapshot and persisted with a SHA-256
binding. A stopped instance is hydrated from that snapshot on the next access.
Malformed, inconsistent, or hash-mismatched snapshots fail loudly rather than
silently starting empty books.

The demo runtime is intentionally single-node while it uses a local Registry
and DynamicSupervisor. It refuses operation when the BEAM node has connected
peers; multi-node enablement requires a durable distributed lease or explicit
connection-to-node routing first.

Test-only `:fake_erp_context` injection remains available for isolated adapter
tests. Normal application connections resolve by persisted connection ID, so
one demo cannot see another team's provider state.

## Resume and reset

Starting twice converges on the same active or resumable provisioning
generation. Reset does not delete a team, ledger record, ERP document,
operation, close, or evidence file. It archives the workspace/provider
generation, removes the owner's active team membership through the normal
audited organization context, then provisions generation `n + 1` linked to its
predecessor. The archive, membership change, and successor creation are one
database transaction; a failure in that database phase leaves the prior
generation active. Provider startup and preflight happen only after commit. If
that second phase is interrupted, the successor remains in `provisioning` and
the normal resume path completes it without recreating financial facts.

## Deployment control

Guided workspaces are enabled in development and test. Other deployments opt
in explicitly:

```text
REVRYN_DEMO_ERP_ENABLED=true
```

The real workspace Settings page exposes e-conomic only. Demo connections are
created by `BillingCore.Demo`, carry a `demo:<workspace-id>` secret reference,
and never resolve live credentials.

## UX quality bar

The first-run flow uses product-specific copy and a restrained accounting
story. It avoids filler metrics, generic gradients, unexplained fixture floods,
and success states not backed by durable artifacts. New phases must preserve
that rule: every completed step links to its source input, calculation or
movement, operation, provider artifact, and reconciliation evidence.

Before `status: supported`, certification must include clean install,
interruption/resume, reset, returning user, and a recoverable provider failure
in Playwright; time-to-first reconciled invoice and close telemetry; and
recorded qualitative review with representative prospective users.
