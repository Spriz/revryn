# ADR 032: Maintainer secrets committed age-encrypted via fnox; deployment secrets stay deployer-owned

Status: accepted (2026-08-22; scope narrowed to maintainer secrets the same
day — as an OSS project, deployment secrets belong to whoever deploys, so
the repo catalog holds only what the repository's own workflows need)

## Context

Operational secrets (e-conomic sandbox credentials, production runtime
values) lived only in operator shells as exported environment variables.
Nothing reviewable recorded *which* secrets exist, and handing one to a
teammate or CI meant an out-of-band copy. The domain contract (SPEC §19.5)
deliberately keeps `secret_reference` = environment-variable *name*, so any
mechanism that populates process env at start works without code changes.

## Decision

Use [fnox](https://fnox.jdx.dev) with its **age** provider — for
**maintainer secrets only** (the sandbox-certification credential, the
decryption canary). `fnox.toml` at the repo root is committed and holds:
the age public recipients, the declared catalog of those secrets, and
age-encrypted values. Deployment secrets (`SECRET_KEY_BASE`,
`DATABASE_URL`, `CREDENTIAL_CIPHER_KEY`, `SMTP_PASSWORD`) are the
deployer's, supplied via env vars or the standard `<NAME>_FILE`
indirection (`BillingCore.Release.read_secret/1`) from whatever secret
store their platform uses.
Private identities stay outside the repo (`~/.config/fnox/revryn-age.txt`
or `FNOX_AGE_KEY`); `.gitignore` blocks common identity file names.
Processes receive secrets via `fnox exec -- <cmd>`. A committed canary
(`FNOX_SANITY` → `ok`) lets any keyholder self-verify. CI validates the
config with `fnox check`. Tooling is pinned in `mise.toml`.

## Consequences

- The secret *catalog* is reviewable in PRs; values are ciphertext diffs.
- Onboarding = add a recipient + `fnox reencrypt`; revocation = treat as
  compromise and rotate values (git history remains readable to old keys).
- The ERP credential vault, GraphQL layer, and all domain code are
  untouched — fnox only populates environment variables.
- Certification gate 1 becomes turnkey: `fnox set ECONOMIC_SANDBOX_SECRET`
  then `fnox exec -- mix run --no-start e2e/economic/certify.exs`.

Runbook: `docs/runbooks/secrets.md`.
