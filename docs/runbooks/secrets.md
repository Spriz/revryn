# Secrets (who owns what)

Revryn is open source, so there are two entirely separate secret domains:

1. **Deployment secrets** — owned by whoever deploys Revryn, never by this
   repository.
2. **Maintainer secrets** — the handful this repository's own development
   and certification workflows need, kept age-encrypted in the committed
   `fnox.toml`.

## 1. Deployment secrets (deployer-owned)

The app's contract is deliberately platform-neutral: every production
secret is consumed as an **environment variable name**, and every one of
them also accepts the standard `<NAME>_FILE` indirection — a path to a
file containing the value (`BillingCore.Release.read_secret/1`):

| Variable | Purpose |
|---|---|
| `SECRET_KEY_BASE` / `SECRET_KEY_BASE_FILE` | Phoenix signing (`mix phx.gen.secret`) |
| `DATABASE_URL` / `DATABASE_URL_FILE` | `ecto://USER:PASS@HOST/DATABASE` |
| `CREDENTIAL_CIPHER_KEY` / `…_FILE` | envelope key for the ERP credential vault |
| `SMTP_PASSWORD` / `…_FILE` | relay password (`docs/runbooks/smtp.md`) |

Use whatever your platform provides — all of these end up as env vars or
mounted files, which is exactly the contract:

- **Kubernetes**: `Secret` → `env.valueFrom.secretKeyRef`, or mount and
  point `<NAME>_FILE` at the mounted path.
- **Docker / Compose / Swarm**: `secrets:` mounts under `/run/secrets/…`
  with `<NAME>_FILE=/run/secrets/<name>`.
- **systemd**: `LoadCredential=<name>:/path` and
  `<NAME>_FILE=%d/<name>` — credentials never enter the environment table.
- **A managed secret store** (Vault, AWS/GCP secret managers, …): let its
  agent/CSI driver inject the env var or file.

Prefer the `_FILE` form where available: values stay out of
`/proc/<pid>/environ` and aren't inherited by child processes. e-conomic
credentials for tenant connections are *not* env vars at all — they're
stored envelope-encrypted in PostgreSQL under `CREDENTIAL_CIPHER_KEY`,
and `secret_reference` on an ERP connection names the env var to read at
sync time (SPEC §19.5).

## 2. Maintainer secrets (fnox + age, committed encrypted)

`fnox.toml` at the repo root catalogs the secrets the *repository's own*
workflows need — today the e-conomic sandbox certification credential and
a decryption canary. Values are age-encrypted to the recipients listed in
the file, so the ciphertext is safe to commit; identities never enter the
repo (`.gitignore` guards common file names). Tooling is pinned in
`mise.toml` (`mise install`).

```sh
fnox set ECONOMIC_SANDBOX_APP_SECRET_TOKEN       # prompts hidden, encrypts,
fnox set ECONOMIC_SANDBOX_AGREEMENT_GRANT_TOKEN  # rewrites fnox.toml
fnox get FNOX_SANITY               # prints "ok" iff your identity can decrypt
fnox exec -- mix run --no-start e2e/economic/certify.exs
fnox check                         # config/provider health (no identity needed)
```

Identities resolve from `key_file` (`~/.config/fnox/revryn-age.txt` by
convention) or the `FNOX_AGE_KEY` env var (CI). Create one with
`age-keygen -o ~/.config/fnox/revryn-age.txt && chmod 600 ~/.config/fnox/revryn-age.txt`.

**Adding a maintainer**: append their public `age1…` key to `recipients`,
run `fnox reencrypt`, commit; they verify with `fnox get FNOX_SANITY`.

**Revocation**: removing a recipient does not un-share git history —
treat it as compromise: remove, `fnox reencrypt`, then rotate the actual
values the removed key could read.

Contributors and deployers need no age key: nothing in the default build,
test, or deploy path decrypts anything. CI's `secrets-hygiene` job runs
`fnox check` (no identity required); a fork simply has an empty maintainer
keyring until its owner replaces the recipients with their own.

Decision record: `docs/adr/032-fnox-age-encrypted-repo-secrets.md`.
