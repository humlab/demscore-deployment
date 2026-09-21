#!/usr/bin/env bash
# Make the demscore role's password match POSTGRES_PASSWORD in .env.
#
# POSTGRES_PASSWORD only does anything the first time the pg_data volume is
# initialised. After that the password lives in the volume, and editing .env --
# or letting deploy.sh generate one over a volume that a plain dev_up.sh had
# already created with the compose default -- leaves the role behind while
# every container is handed the new value.
#
# The drift is invisible to everything in scripts/, because they all reach the
# database as `podman compose exec db psql`, over the unix socket the postgres
# image's pg_hba.conf trusts. It surfaces only where a container connects over
# TCP, which scram-sha-256 guards: ogr2ogr in setup_mapserver_hex_service.sh
# first, then mapserver and web-backend, all reporting
#   FATAL: password authentication failed for user "demscore"
#
# ALTER ROLE over that same trusted socket closes the gap, and is a no-op when
# the two already agree. The statement arrives on stdin so the password never
# reaches a process list.
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
# The same fallback compose.yml applies, so an unset value still lines up.
PASSWORD="${POSTGRES_PASSWORD:-demscore}"

for _ in {1..30}; do
  if podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
  echo "Database is not ready after timeout; cannot sync the role password." >&2
  exit 1
fi

# Double up single quotes for the SQL literal. standard_conforming_strings is
# on, so a backslash is already itself.
escaped_password="${PASSWORD//\'/\'\'}"
printf 'ALTER ROLE "%s" WITH PASSWORD '"'"'%s'"'"';\n' "$PG_USER" "$escaped_password" \
  | podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q

echo "Database role '${PG_USER}' now authenticates with POSTGRES_PASSWORD from .env."
