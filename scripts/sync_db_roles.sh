#!/usr/bin/env bash
# Make the database's two roles match .env, on every start.
#
# demscore is the superuser the postgres image creates from POSTGRES_USER. It
# owns the data, and only the deployment scripts use it, over the unix socket.
# POSTGRES_PASSWORD only does anything the first time the pg_data volume is
# initialised; after that the password lives in the volume, and editing .env
# leaves the role behind. Nothing over the socket notices, because the postgres
# image's pg_hba.conf trusts it; ogr2ogr in setup_mapserver_hex_service.sh,
# which connects over TCP, fails with
#   FATAL: password authentication failed for user "demscore"
#
# demscore_reader is what mapserver and web-backend connect as: SELECT on the
# demscore schema and nothing else, read-only transactions, and a statement
# timeout, so a request that reaches the database can neither change it nor
# hold a query open indefinitely. Its tables are recreated by every import, so
# the SELECT grant is a default privilege on what demscore creates in the
# schema, not only a grant on what is there now.
#
# The statements arrive on stdin so the passwords never reach a process list.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"
READER_USER="demscore_reader"
# The same fallback compose.yml applies, so an unset value still lines up.
PASSWORD="${POSTGRES_PASSWORD:-demscore}"
READER_PASSWORD="${DEMSCORE_READER_PASSWORD:-}"

if [[ -z "$READER_PASSWORD" ]]; then
  echo "DEMSCORE_READER_PASSWORD is not set in .env; ./deploy.sh start generates it." >&2
  exit 1
fi

for _ in {1..30}; do
  if podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
  echo "Database is not ready after timeout; cannot sync the database roles." >&2
  exit 1
fi

# Double up single quotes for the SQL literal. standard_conforming_strings is
# on, so a backslash is already itself.
escaped_password="${PASSWORD//\'/\'\'}"
escaped_reader_password="${READER_PASSWORD//\'/\'\'}"

podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q <<SQL
SET client_min_messages = warning;
ALTER ROLE "${PG_USER}" WITH PASSWORD '${escaped_password}';

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${READER_USER}') THEN
    CREATE ROLE ${READER_USER};
  END IF;
END
\$\$;
ALTER ROLE ${READER_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD '${escaped_reader_password}';
ALTER ROLE ${READER_USER} SET default_transaction_read_only = on;
ALTER ROLE ${READER_USER} SET statement_timeout = '30s';
ALTER ROLE ${READER_USER} SET idle_in_transaction_session_timeout = '60s';

-- Every role may create temporary tables by default. The reader needs none,
-- and the scripts that do run as the superuser.
REVOKE TEMPORARY ON DATABASE "${PG_DB}" FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS demscore;
GRANT USAGE ON SCHEMA demscore TO ${READER_USER};
GRANT SELECT ON ALL TABLES IN SCHEMA demscore TO ${READER_USER};
ALTER DEFAULT PRIVILEGES FOR ROLE "${PG_USER}" IN SCHEMA demscore
  GRANT SELECT ON TABLES TO ${READER_USER};
SQL

echo "Database roles '${PG_USER}' and '${READER_USER}' now authenticate with the passwords in .env."
