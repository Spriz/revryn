# Test-coverage report — 2026-08-22

Method: `mix test --cover` (BEAM line coverage; used as the measurable
proxy for branch coverage — every uncovered branch shows as uncovered
lines). Reproduce with `mix test --cover`; per-module HTML with exact
uncovered lines lands in `cover/`.

## Before → after

| Measure | Baseline | After |
|---|---|---|
| Total line coverage | 84.50% | **94.59%** |
| Tests (properties) | 758 (16) | **1378 (16)** |
| Modules at 100% | 92 of 253 | **157 of 255** |
| Modules at 0% | 13 | **0** |
| Lowest hand-written module | 18.2% (WaxVerifier) | 75% (see below) |

The two remaining sub-75% figures are compiler artifacts, not code:
`BillingCoreWeb` (the `use`-macro definition module) and `ErrorHTML`
(framework-generated metadata functions); both carry comments where their
tests live. Every remaining sub-90% module is dominated by either
generated metadata lines or branches documented as unreachable (below).

## What was added (620 tests, two passes)

1. **Zero-coverage closures** — billing-run fan-out worker (per-team
   fan-out, timezone fallback, replay convergence), poll scheduler,
   retention worker, health/webhook/page controllers (including webhook
   dedupe under the partial unique index), the ERP env-secret provider
   (SPEC §19.5), metrics definitions, and the three secret-redacting
   `Inspect` implementations (`inspect/1` must never leak token hashes or
   TOTP ciphertext).
2. **GraphQL layer to ~100%** — crash-shielding middleware (stable
   `INTERNAL_ERROR` + correlation ID, no exception leak), every scalar
   parse/serialize branch, the complete error-mapping table, authz/scope
   middleware, context plug (bearer/correlation/document-size guard),
   complexity-cap rejection; then every resolver error path over real
   HTTP (not-found, denial, illegal transitions, idempotent replay,
   version conflicts, dead-letter retry through the API, atomic
   batch-limit rejection).
3. **Domain branch completion** — close calculation (every
   liability-effect clause, exact integer minor units, ordering and
   prior-period reclassification), intent machine transitions, §22.9.1
   retry-policy classification, idempotency semantics through the public
   API, WebAuthn verification against fabricated-but-real cryptographic
   material, pricing model/schema validation, and the schema/enum
   surfaces.
4. **Durable posting chains** — settlement and close posting: unknown-
   outcome recovery, absence-proven retry (exactly once), conflicting/
   tampered/vanished read-backs, classification chains, remediation
   convergence; ERP sync guards, poll reconciliation, release doctor
   seeded failures; LiveView error/denial/empty/event branches across all
   operational screens.

## Defects found by this work (all fixed, with regression tests)

1. **Discounts never applied in previews** — the preview queried discount
   assignments with `subscription_id` AND `contract_id` conjunctively
   while an assignment targets exactly one (BC-US-060), so the whole
   discount branch was dead code. Fixed with per-target lookups plus the
   previously missing half-open effectivity-window filter.
2. **Discount result-shape crash** hidden behind (1): the engine returns
   `{:ok, %Result{}}`; the preview consumed it as a bare struct.
3. **Stuck reconciliation** — a provider error while proving an unknown
   outcome had no legal path: `record_failure!/3` crashes on a
   `reconciling` operation, `manual_retry` only accepts `failed`, and the
   workers' claim refused `reconciling` — permanently stuck financial
   operations. Sync and SettlementPosting now park the operation in
   `reconciling`, snooze, and resume the reconciliation (proven
   end-to-end: parked → provider recovers → exactly-once completion).
4. **Prometheus duplicate metric names** — `telemetry_metrics` silently
   drops the `:name` option, so two Oban metrics shipped under one name
   and the SPEC §22.3 metric names never applied; a uniqueness test now
   pins the corrected names.
5. **Voucher mixed-currency raise** — `FinanceVoucher.validate/1` raised
   from `Money.sum!/2` instead of returning `:currency_mismatch`.

## Deliberately uncovered (documented as comments at the test sites)

- Races the SQL sandbox makes impossible (idempotency's concurrent-winner
  replay; a Registry re-registration window).
- Defensive dead arms of exhaustive constructs (e.g. `already_present`
  from a DynamicSupervisor, contradictory taxonomy combinations).
- Branches needing real external systems: certificate-chain WebAuthn
  attestation (covered by Playwright's virtual authenticator per SPEC
  §23.10), an unreachable database for doctor's rescue paths,
  `System.stop/1`.
- Compiler/framework-generated metadata functions with no runtime
  semantics.
