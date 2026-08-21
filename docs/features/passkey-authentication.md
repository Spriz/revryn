---
id: passkey-authentication
title: Passkey authentication
status: supported
public: true
owners: [billing-domain]
graphql: []
tests:
  integration:
    - test/workflows/authentication_test.exs
adrs:
  - SPEC.md §19.2, BC-US-145, BC-US-146
---

# Passkey authentication

## Purpose

Passwordless sign-in with WebAuthn/FIDO2 passkeys as the primary factor,
TOTP as an optional step-up factor, and single-use recovery codes as the
recovery path. Sessions are revocable server-side records carrying an
authentication strength.

## User outcomes

- A user registers with email + passkey and signs in email-first: the
  server issues a challenge listing exactly that user's credentials.
- Users with TOTP enabled must enter a valid code after the passkey; the
  session is upgraded to `passkey_plus_totp` strength.
- A user who lost their authenticator signs in with a recovery code
  (consumed exactly once, `recovery`-strength session).
- The security page manages passkeys, TOTP, recovery codes, and sessions
  ("sign out other devices").

## Actors and permissions

Global users only — identity is organization/team-agnostic (SPEC §13.4).
Authorization is separate and membership-based (`BillingCore.Orgs`).

## Domain terminology

- **Ceremony** — a WebAuthn registration (attestation) or authentication
  (assertion) exchange against a short-lived challenge.
- **Session strength** — `passkey`, `passkey_plus_totp`, or `recovery`.
- **Recovery code batch** — 10 codes generated together; a new batch
  invalidates all unconsumed codes of previous batches.

## Workflows

1. **Passkey registration (BC-US-145)** — email → `registration_challenge`
   (origin/RP ID from `config :billing_core, :webauthn`, 120 s validity,
   attestation `none`, user verification `preferred`) → browser attestation
   → `verify_registration` persists the credential (COSE key, sign count,
   backup flags, transports, name). Credential IDs are globally unique.
2. **Sign-in (email-first)** — `authentication_challenge` allows exactly the
   user's non-revoked credentials → `verify_authentication` checks the
   assertion via Wax and the signature counter, then updates `sign_count`
   and `last_used_at`. `POST /session` hands the LiveView-issued token to
   the HTTP session and attaches IP/user-agent metadata.
3. **TOTP enrollment (BC-US-146)** — `enroll_totp` stores the secret
   envelope-encrypted (AES-256-GCM under `credential_cipher_key`; the
   plaintext exists only in the enrollment response for QR/manual entry) →
   `confirm_totp` with a fresh code activates the factor and generates the
   mandatory recovery-code batch, shown exactly once.
4. **TOTP step-up** — `verify_totp` accepts ±1 period (30 s) of drift and
   atomically advances `last_timestep`, so a code is never accepted twice
   (`{:error, :code_already_used}`).
5. **TOTP removal** — requires a valid current code; in one transaction the
   factor is revoked, unconsumed recovery codes are invalidated, and all
   sessions of strength `passkey_plus_totp`/`recovery` are revoked.
6. **Recovery** — `consume_recovery_code` sets `consumed_at` atomically
   (single use); `generate_recovery_codes` requires active TOTP and
   invalidates the previous batch.

## State transitions

No formal machine. Credentials/factors: active → revoked (`revoked_at`);
sessions: active → revoked or expired; recovery codes: unconsumed →
consumed; TOTP factors: pending (created) → activated (confirmed).

## Business rules / invariants

- Challenges are short-lived (120 s, re-checked server-side even with a
  stubbed verifier) and single-use — the LiveView takes the challenge
  assign on the first verification attempt.
- A non-increasing WebAuthn signature counter is rejected as a possible
  authenticator clone (`{:error, :sign_count_regression}`); both counters
  at zero means the authenticator implements no counter and is accepted.
- The final active passkey cannot be revoked while no active TOTP factor
  exists (`{:error, :last_credential}`).
- Recovery codes exist only alongside TOTP; only SHA-256 hashes are stored.
- Session tokens are 32 random bytes; only the SHA-256 hash is persisted.
  Default validity is 14 days.
- Federated OIDC identities can be linked (`issuer`/`subject` unique).

## GraphQL contract

None. Authentication is LiveView + `POST/DELETE /session`; GraphQL
authenticates via `Authorization: Bearer <session token>` (SPEC §14.2).

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

Implemented LiveViews: `/register` and `/sign-in` (email-first passkey
ceremonies with TOTP step-up and recovery-code fallback), `/security`
(passkeys, TOTP enrollment/removal, recovery-code regeneration, session
list with single/other revocation; the current session is not revocable
from the list). `BillingCoreWeb.UserAuth.recently_authenticated?/2` gates
step-up-sensitive routes.

## Accounting / ERP effects

None.

## Asynchronous / failure / recovery behavior

All operations are synchronous transactions. Credential and session
revocations are audited inside the same transaction. A registration that
never finished passkey setup can be resumed from the register screen.

## Observability

Audit events: `identity.session.revoked`,
`identity.webauthn_credential.revoked`, `identity.totp_factor.revoked`,
`identity.recovery_code.consumed`.

## Tests

`test/workflows/authentication_test.exs` — full ceremony coverage:
registration, single-use challenges, sign-in, clone detection, TOTP
step-up, recovery codes, security page, session teardown, step-up helpers.

## Security / privacy

Secrets at rest: TOTP seeds AES-256-GCM envelope-encrypted (production key
via `CREDENTIAL_CIPHER_KEY`); recovery codes and session tokens hashed.
Cryptographic WebAuthn verification is isolated behind a `Verifier`
behaviour (default `WaxVerifier`: full origin, RP ID, challenge, signature,
user-presence validation). Errors on sign-in are generic — unknown email
and wrong code fail identically.

## Limitations

- OIDC federated sign-in has persistence (`link_federated_identity`) but no
  login flow/UI yet.
- No WebAuthn attestation policy beyond `none`; no passkey usernameless
  (discoverable-credential-first) flow — sign-in is email-first.
