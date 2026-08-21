#!/usr/bin/env bash
# Billing Core image entrypoint (SPEC §24.6–24.7, INV-020).
#
# Roles:
#   all-in-one   supervised PostgreSQL + migrations + web + workers
#   web          Phoenix endpoint (+ workers unless WORKER_QUEUES=none)
#   worker       release without the HTTP endpoint (WEB_SERVER=false)
#   migrate      run pending migrations and exit
#   doctor       redacted configuration/dependency diagnostics
#   backup       create a backup archive (see billing-core-backup)
#   restore      restore from a backup archive (see billing-core-restore)
#   smoke-test   boot checks against a running instance
set -euo pipefail

ROLE="${1:-all-in-one}"
shift || true

DATA_DIR="${DATA_DIR:-/data}"
PGDATA="${PGDATA:-$DATA_DIR/postgres}"
PGVERSION_DIR="$(ls /usr/lib/postgresql | sort -V | tail -1)"
PGBIN="/usr/lib/postgresql/${PGVERSION_DIR}/bin"

log() { echo "[billing-core] $*" >&2; }

require_free_space() {
  # SPEC §24.7: startup filesystem validation.
  local free_kb
  free_kb=$(df -k "$DATA_DIR" | awk 'NR==2 {print $4}')
  if [ "${free_kb:-0}" -lt 262144 ]; then
    log "FATAL: less than 256MB free space on $DATA_DIR"
    exit 1
  fi
}

start_postgres() {
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"

  if [ ! -s "$PGDATA/PG_VERSION" ]; then
    log "initializing bundled PostgreSQL cluster in $PGDATA"
    gosu postgres "$PGBIN/initdb" -D "$PGDATA" --auth-local=trust --auth-host=scram-sha-256 >/dev/null
    echo "listen_addresses = '127.0.0.1'" >> "$PGDATA/postgresql.conf"
  fi

  log "starting bundled PostgreSQL"
  gosu postgres "$PGBIN/pg_ctl" -D "$PGDATA" -w -t 60 start

  gosu postgres "$PGBIN/psql" -tc "SELECT 1 FROM pg_roles WHERE rolname='billing'" | grep -q 1 ||
    gosu postgres "$PGBIN/psql" -c "CREATE ROLE billing LOGIN PASSWORD 'billing'"
  gosu postgres "$PGBIN/psql" -tc "SELECT 1 FROM pg_database WHERE datname='billing_core'" | grep -q 1 ||
    gosu postgres "$PGBIN/createdb" -O billing billing_core
}

stop_postgres() {
  log "stopping bundled PostgreSQL"
  gosu postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w -t 60 stop || true
}

run_release() {
  exec gosu app /app/bin/billing_core "$@"
}

case "$ROLE" in
  all-in-one)
    require_free_space
    export DATABASE_URL="${DATABASE_URL:-ecto://billing:billing@127.0.0.1/billing_core}"
    start_postgres

    # Graceful drain: stop the release before PostgreSQL on termination.
    app_pid=""
    term_handler() {
      log "termination signal received; draining application"
      if [ -n "$app_pid" ]; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
      fi
      stop_postgres
      exit 0
    }
    trap term_handler TERM INT

    log "running migrations"
    gosu app /app/bin/billing_core eval "BillingCore.Release.migrate()"

    log "starting Billing Core (all-in-one)"
    gosu app /app/bin/billing_core start &
    app_pid=$!
    wait "$app_pid"
    stop_postgres
    ;;

  web)
    run_release start
    ;;

  worker)
    export WEB_SERVER=false
    run_release start
    ;;

  migrate)
    exec gosu app /app/bin/billing_core eval "BillingCore.Release.migrate()"
    ;;

  doctor)
    exec gosu app /app/bin/billing_core eval "BillingCore.Release.doctor()"
    ;;

  backup)
    exec /usr/local/bin/billing-core-backup "$@"
    ;;

  restore)
    exec /usr/local/bin/billing-core-restore "$@"
    ;;

  smoke-test)
    URL="${SMOKE_URL:-http://127.0.0.1:4000}"
    log "smoke-testing $URL"
    curl -fsS "$URL/health/live" >/dev/null
    curl -fsS "$URL/health/ready" >/dev/null
    log "smoke test passed"
    ;;

  *)
    log "unknown role: $ROLE"
    log "supported: all-in-one web worker migrate doctor backup restore smoke-test"
    exit 64
    ;;
esac
