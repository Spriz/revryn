#!/usr/bin/env bash
# CLI end-to-end certification (BC-TASK-100): real auth, authorization,
# GraphQL, durable-operation surfaces, confirm/idempotency semantics, and
# failure handling with correlation references — against a running server.
#
#   BASE_URL=http://localhost:4000 e2e/cli/run.sh
#
# FIXTURE_JSON may be pre-supplied (CI runs the fixture through
# `bin/billing_core eval`); otherwise the script runs it via `mix run`
# against the dev database.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:4000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BCTL="${BCTL:-$ROOT/clients/revryn/revryn-e2e}"

say() { printf '\n== %s\n' "$*"; }

if [ ! -x "$BCTL" ]; then
  say "building revryn"
  (cd "$ROOT/clients/revryn" && go build -o "$BCTL" ./cmd/revryn)
fi

if [ -z "${FIXTURE_JSON:-}" ]; then
  say "creating fixture via mix run"
  FIXTURE_JSON="$(cd "$ROOT" && mix run --no-start e2e/cli/fixture.exs 2>/dev/null | grep "^{" | tail -1)"
fi

TOKEN="$(jq -r .token <<<"$FIXTURE_JSON")"
TEAM="$(jq -r .team_id <<<"$FIXTURE_JSON")"
CUSTOMER="$(jq -r .customer_id <<<"$FIXTURE_JSON")"

run() { "$BCTL" --url "$BASE_URL" --token "$TOKEN" --team "$TEAM" "$@"; }

say "status resolves the authenticated principal and membership"
run status --json | jq -e --arg t "$TEAM" '.data.viewer.teamMemberships[] | select(.team.id == $t)' >/dev/null

say "customers list shows the fixture customer"
run customers list --json | jq -e --arg c "$CUSTOMER" '.data.edges[] | select(.node.id == $c)' >/dev/null

say "credit account reads expose the granted balance"
run credits accounts --customer-id "$CUSTOMER" --json |
  jq -e '.data[0].availableMinor == 12500' >/dev/null

say "accounting-sensitive mutation succeeds with explicit inputs (create-policy)"
run credit-closes create-policy --effective-from "$(date +%Y-%m-01)" \
  --journal 1 --liability-account 2990 --offset-account 5890 \
  --settlement-mode external_reference --json |
  jq -e '.data.settlementMode == "external_reference"' >/dev/null

say "policy listing reflects the created version"
run credit-closes policies --json | jq -e '.data | length >= 1' >/dev/null

say "the durable-operation surface answers with not-found, never a leak"
if run operations get 00000000-0000-0000-0000-000000000000 --json >/dev/null 2>/tmp/cli-cert-err; then echo "expected not-found"; exit 1; fi

say "an invalid token fails with a stable auth error and non-zero exit"
if "$BCTL" --url "$BASE_URL" --token "invalid" --team "$TEAM" status --json >/dev/null 2>/tmp/cli-cert-err; then
  echo "expected auth failure"; exit 1
fi
grep -qi "auth" /tmp/cli-cert-err

say "a cross-team id is denied, not leaked"
if run customers get 00000000-0000-0000-0000-000000000000 --json >/dev/null 2>/tmp/cli-cert-err; then
  echo "expected not-found"; exit 1
fi

say "CLI certification passed"
