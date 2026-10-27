#!/usr/bin/env bash
# Bring the databases in the pg_data volume up to the db image they now run
# under, on every start. A no-op when nothing has changed.
#
# A new postgis image tag (compose.yml) can change two things the volume keeps
# from the image it was created under:
#
# - Extension versions. New PostGIS libraries arrive with the image, but the
#   extension's SQL objects stay at the version they were created with until
#   ALTER EXTENSION ... UPDATE. postgis goes before postgis_topology, which
#   depends on it.
# - The collation version. The image's C library defines how text sorts, and a
#   newer one can sort some strings differently, which leaves a text index
#   ordered by the old rules. Postgres warns on every connection until the
#   database's recorded version is refreshed, and refreshing it without
#   rebuilding the indexes would only silence the warning. So: REINDEX, then
#   REFRESH COLLATION VERSION. It takes a few minutes, once per image change.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"

for _ in {1..30}; do
  if podman compose exec -T db pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

psql_in() {
  local db="$1"
  shift
  podman compose exec -T db psql -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 -q "$@"
}

# Every connection to a database with a stale collation version prints the same
# three-line warning, which is the thing this script is fixing. Anything else
# on stderr is kept.
without_collation_warning() {
  grep -vE '^WARNING:  database ".*" has a collation version mismatch$|^DETAIL:  The database was created using collation version|^HINT:  Rebuild all objects in this database that use the default collation' >&2 || true
}

psql_in "$PG_DB" 2> >(without_collation_warning) <<'SQL'
DO $$
DECLARE
  ext record;
BEGIN
  FOR ext IN
    SELECT x.extname, x.extversion, a.default_version
    FROM pg_extension x
    JOIN pg_available_extensions a ON a.name = x.extname
    WHERE x.extversion IS DISTINCT FROM a.default_version
    ORDER BY x.extname <> 'postgis', x.extname
  LOOP
    RAISE NOTICE 'Updating extension % from % to %', ext.extname, ext.extversion, ext.default_version;
    EXECUTE format('ALTER EXTENSION %I UPDATE', ext.extname);
  END LOOP;
END
$$;
SQL

# template0 accepts no connections and holds no data.
stale_dbs="$(psql_in "$PG_DB" -At -c "
  SELECT datname FROM pg_database
  WHERE datallowconn
    AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)
  ORDER BY datname" 2> >(without_collation_warning))"

for db in $stale_dbs; do
  echo "Database ${db} was created under another C library's collation; rebuilding its indexes..."
  psql_in "$db" -c "REINDEX DATABASE \"${db}\"" 2> >(without_collation_warning)
  psql_in "$db" -c "ALTER DATABASE \"${db}\" REFRESH COLLATION VERSION" 2> >(without_collation_warning)
done
