#!/usr/bin/env bash
# Integrated showcase certification: Personalehuset × Billing Core
# (BC-TASK-094, BC-US-153). Requires a running Billing Core at BASE_URL
# with the demo provider enabled (REVRYN_DEMO_ERP_ENABLED=true).
#
#   BASE_URL=http://localhost:4000 e2e/showcases/run_personalehuset.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:4000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LARAVEL="$ROOT/examples/employee-directory-laravel"
LARAVEL_PORT="${LARAVEL_PORT:-8342}"

say() { printf '\n== %s\n' "$*"; }

gql() { # gql <query> <variables-json>
  curl -sS "$BASE_URL/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$(jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')"
}

require_no_errors() { # require_no_errors <response> <label>
  if jq -e '.errors and (.errors | length > 0)' >/dev/null 2>&1 <<<"$1"; then
    echo "GraphQL errors during $2:"; jq '.errors' <<<"$1"; exit 1
  fi
}

say "fixture: demo workspace team + bearer session"
if [ -z "${FIXTURE_JSON:-}" ]; then
  FIXTURE_JSON="$(cd "$ROOT" && mix run --no-start e2e/showcases/fixture.exs 2>/dev/null | grep '^{' | tail -1)"
fi
TOKEN="$(jq -r .token <<<"$FIXTURE_JSON")"
TEAM="$(jq -r .team_id <<<"$FIXTURE_JSON")"
CONNECTION="$(jq -r .connection_id <<<"$FIXTURE_JSON")"

say "boot Personalehuset in integrated mode"
pkill -f "artisan serve --port=$LARAVEL_PORT" 2>/dev/null || true
sleep 1
DB="$(mktemp /tmp/personale-integrated-XXXX.sqlite3)"
# artisan serve workers read .env reliably; process env does not always
# reach them — write the integration vars into .env and restore on exit.
cp "$LARAVEL/.env" "$LARAVEL/.env.backup-integrated"
{
  echo "DB_DATABASE=$DB"
  echo "PERSONALE_BILLING=integrated"
  echo "BILLING_CORE_URL=$BASE_URL"
  echo "BILLING_CORE_TOKEN=$TOKEN"
  echo "BILLING_CORE_TEAM_ID=$TEAM"
} >> "$LARAVEL/.env"
(cd "$LARAVEL" && mise exec php@8.3 -- php artisan config:clear >/dev/null \
  && mise exec php@8.3 -- php artisan migrate --force >/dev/null \
  && mise exec php@8.3 -- php artisan serve --port="$LARAVEL_PORT" >/tmp/personale-integrated.log 2>&1) &
LARAVEL_PID=$!
trap 'mv "$LARAVEL/.env.backup-integrated" "$LARAVEL/.env" 2>/dev/null || true; pkill -f "artisan serve --port=$LARAVEL_PORT" 2>/dev/null || true; kill $LARAVEL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf "http://localhost:$LARAVEL_PORT/login" >/dev/null 2>&1 && break
  sleep 1
done

say "phase 1: browser certification (usage + live preview traceability)"
SPEC_OUT="$(cd "$ROOT/e2e/showcases/personalehuset" && PERSONALE_URL="http://localhost:$LARAVEL_PORT" npx playwright test --reporter=line 2>&1)" || {
  echo "$SPEC_OUT" | tail -30; exit 1
}
echo "$SPEC_OUT" | grep -E "passed"
ORG_SLUG="$(grep -oE 'INTEGRATED_ORG_SLUG=\S+' <<<"$SPEC_OUT" | cut -d= -f2)"

say "phase 2: reach the fake adapter — map, freeze, synchronize, reconcile"
CUSTOMERS="$(gql 'query($t: ID!, $f: Int){ customers(teamId: $t, first: $f){ edges { node { id externalId } } } }' \
  "$(jq -nc --arg t "$TEAM" '{t: $t, f: 100}')")"
require_no_errors "$CUSTOMERS" "customer lookup"
CUSTOMER_ID="$(jq -r --arg x "personale-$ORG_SLUG" '.data.customers.edges[] | select(.node.externalId == $x) | .node.id' <<<"$CUSTOMERS")"

PRODUCTS="$(gql 'query($t: ID!, $f: Int){ products(teamId: $t, first: $f){ edges { node { id code } } } }' \
  "$(jq -nc --arg t "$TEAM" '{t: $t, f: 100}')")"
PRODUCT_ID="$(jq -r '.data.products.edges[] | select(.node.code == "personale-seat") | .node.id' <<<"$PRODUCTS")"

SUBS="$(gql 'query($t: ID!, $f: Int){ subscriptions(teamId: $t, first: $f){ edges { node { id externalId } } } }' \
  "$(jq -nc --arg t "$TEAM" '{t: $t, f: 100}')")"
SUB_ID="$(jq -r --arg x "personale-$ORG_SLUG" '.data.subscriptions.edges[] | select(.node.externalId == $x) | .node.id' <<<"$SUBS")"

test -n "$CUSTOMER_ID" && test -n "$PRODUCT_ID" && test -n "$SUB_ID"

MAP_C="$(gql 'mutation($i: MapCustomerToErpInput!){ mapCustomerToErp(input: $i){ __typename ... on ValidationProblem { code message } } }' \
  "$(jq -nc --arg t "$TEAM" --arg c "$CUSTOMER_ID" --arg e "$CONNECTION" \
     '{i: {teamId: $t, customerId: $c, erpConnectionId: $e, externalCustomerNumber: "9003", clientMutationId: "showcase-map-c"}}')")"
require_no_errors "$MAP_C" "customer mapping"

MAP_P="$(gql 'mutation($i: MapProductToErpInput!){ mapProductToErp(input: $i){ __typename ... on ValidationProblem { code message } } }' \
  "$(jq -nc --arg t "$TEAM" --arg p "$PRODUCT_ID" --arg e "$CONNECTION" \
     '{i: {teamId: $t, productId: $p, erpConnectionId: $e, externalProductNumber: "PERS-SEAT", clientMutationId: "showcase-map-p"}}')")"
require_no_errors "$MAP_P" "product mapping"
jq -e '.data.mapProductToErp.__typename == "MapProductToErpSuccess"' >/dev/null <<<"$MAP_P"

FREEZE="$(gql 'mutation($i: FreezeInvoiceIntentInput!){ freezeInvoiceIntent(input: $i){ __typename ... on FreezeInvoiceIntentSuccess { invoiceIntent { id state } } ... on ValidationProblem { code message } ... on MappingProblem { code message } } }' \
  "$(jq -nc --arg t "$TEAM" --arg s "$SUB_ID" --arg d "$(date +%Y-%m-%d)" \
     '{i: {teamId: $t, subscriptionId: $s, asOf: $d, idempotencyKey: "showcase-freeze-1", clientMutationId: "showcase-freeze"}}')")"
require_no_errors "$FREEZE" "freeze"
INTENT_ID="$(jq -r '.data.freezeInvoiceIntent.invoiceIntent.id' <<<"$FREEZE")"
test "$INTENT_ID" != "null"

SYNC="$(gql 'mutation($i: SynchronizeInvoiceInput!){ synchronizeInvoice(input: $i){ __typename ... on SynchronizeInvoiceAccepted { operation { id } } ... on ValidationProblem { code message } ... on MappingProblem { code message } } }' \
  "$(jq -nc --arg t "$TEAM" --arg n "$INTENT_ID" \
     '{i: {teamId: $t, invoiceIntentId: $n, idempotencyKey: "showcase-sync-1", clientMutationId: "showcase-sync"}}')")"
require_no_errors "$SYNC" "synchronize"
OP_ID="$(jq -r '.data.synchronizeInvoice.operation.id' <<<"$SYNC")"
test "$OP_ID" != "null"

say "waiting for the draft to reconcile against the fake adapter"
for _ in $(seq 1 30); do
  STATE="$(gql 'query($t: ID!, $n: ID!){ invoiceIntent(teamId: $t, id: $n){ state } }' \
    "$(jq -nc --arg t "$TEAM" --arg n "$INTENT_ID" '{t: $t, n: $n}')" | jq -r '.data.invoiceIntent.state')"
  [ "$STATE" = "erp_draft" ] && break
  sleep 2
done
test "$STATE" = "erp_draft"

say "asserting annual service-period propagation (BC-US-152)"
LINES="$(gql 'query($t: ID!, $n: ID!){ invoiceIntent(teamId: $t, id: $n){ lines { serviceStart serviceEndExclusive } } }' \
  "$(jq -nc --arg t "$TEAM" --arg n "$INTENT_ID" '{t: $t, n: $n}')")"
SPAN_DAYS="$(jq -r '.data.invoiceIntent.lines[0] | ((.serviceEndExclusive | strptime("%Y-%m-%d") | mktime) - (.serviceStart | strptime("%Y-%m-%d") | mktime)) / 86400 | floor' <<<"$LINES")"
echo "service period spans $SPAN_DAYS days"
test "$SPAN_DAYS" -ge 360

say "integrated certification passed — intent $INTENT_ID reconciled as erp_draft"
