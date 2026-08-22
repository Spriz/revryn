#!/usr/bin/env bash
# MCP protocol/authorization/tool-safety certification (BC-TASK-100):
# drives the real stdio server against a running Billing Core — protocol
# handshake, tool discovery with annotations, a read tool with real auth,
# and the confirm gate refusing an accounting-sensitive mutation.
#
#   BASE_URL=http://localhost:4000 e2e/mcp/run.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:4000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BCTL="${BCTL:-$ROOT/clients/revryn/revryn-e2e}"

if [ ! -x "$BCTL" ]; then
  (cd "$ROOT/clients/revryn" && go build -o "$BCTL" ./cmd/revryn)
fi

if [ -z "${FIXTURE_JSON:-}" ]; then
  FIXTURE_JSON="$(cd "$ROOT" && mix run --no-start e2e/cli/fixture.exs 2>/dev/null | grep "^{" | tail -1)"
fi

TOKEN="$(jq -r .token <<<"$FIXTURE_JSON")"
TEAM="$(jq -r .team_id <<<"$FIXTURE_JSON")"

req() { printf '%s\n' "$*"; }

OUT="$( {
  req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cert","version":"1"}}}'
  req '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  req '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  req '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"billing_status","arguments":{}}}'
  req '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"grant_credit","arguments":{"credit_account_id":"00000000-0000-0000-0000-000000000000","origin_type":"goodwill","amount_minor":1,"currency":"DKK","confirm":false}}}'
  sleep 1
} | "$BCTL" mcp serve --url "$BASE_URL" --token "$TOKEN" --team "$TEAM" 2>/dev/null )"

say() { printf '\n== %s\n' "$*"; }

say "handshake returns the billing-core implementation"
grep -q '"name":"billing-core"' <<<"$OUT"

say "tool discovery includes reads with readOnlyHint and mutations without"
jq -es '
  [.[] | select(.id == 2)][0].result.tools as $tools
  | ($tools | map(select(.name == "billing_status"))[0].annotations.readOnlyHint == true)
  and ($tools | map(select(.name == "grant_credit"))[0].annotations.readOnlyHint != true)
  and ($tools | length >= 30)
' <<<"$OUT" | grep -q true

say "a read tool executes with real auth and returns the correlation id"
jq -es '[.[] | select(.id == 3)][0].result.structuredContent.correlationId | length > 0' <<<"$OUT" | grep -q true

say "the confirm gate refuses an accounting-sensitive mutation before any upstream call"
jq -es '[.[] | select(.id == 4)][0].result.isError == true' <<<"$OUT" | grep -q true
grep -q "confirmation required" <<<"$OUT"

say "MCP certification passed"
