#!/usr/bin/env bash
set -euo pipefail

# Precomputes the per-variable coverage sparklines the variable list draws under
# each row. The map's own timeline can afford to read coverage live, because it
# only ever needs the one selected variable; the list needs every variable in the
# dataset at once, so it reads a file built here instead of querying at render time.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"
OUT_FILE="${OUT_FILE:-${ROOT_DIR}/webapp/config/variable_coverage.json}"
# Bars per strip. The strip renders around 220px wide, so many more buckets than
# this alias into an unreadable comb, and many fewer blur the ragged starts that
# tell QoG's variables apart. Buckets are capped at one per year further down.
BUCKET_TARGET="${BUCKET_TARGET:-40}"

# shellcheck source=scripts/lib/tools.sh
source "${ROOT_DIR}/scripts/lib/tools.sh"
# Inside the repository, where the tools container that runs the Python below
# can read it.
TMP_DIR="$(tool_tmpdir)"
TMP_TSV="${TMP_DIR}/coverage.tsv"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Reading per-variable, per-year country counts..."
# `country_id IS NOT NULL` matches the web-backend's own coverage query, so the
# strip and the map timeline never disagree about which years a variable covers.
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
  --no-align --tuples-only --field-separator=$'\t' -c "
SELECT v.dataset, v.variable, dv.year::INT, count(DISTINCT dv.country_id)
FROM demscore.variables v
JOIN demscore.dataset_values dv ON dv.variable_id = v.id
WHERE dv.country_id IS NOT NULL
  AND NOT v.hidden
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;" > "$TMP_TSV"

if [[ ! -s "$TMP_TSV" ]]; then
  echo "No coverage rows returned. Load datasets first with scripts/load_demscore_module_vars.sh" >&2
  exit 1
fi

echo "Bucketing coverage into ${BUCKET_TARGET}-step strips..."
run_tool env BUCKET_TARGET="$BUCKET_TARGET" OUT_FILE="$(tool_path "$OUT_FILE")" \
  python3 - "$(tool_path "$TMP_TSV")" <<'PY'
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

bucket_target = int(os.environ["BUCKET_TARGET"])
out_file = os.environ["OUT_FILE"]

# counts[dataset][variable][year] = number of countries reporting that year
counts = defaultdict(lambda: defaultdict(dict))
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        dataset, variable, year, country_count = line.split("\t")
        counts[dataset][variable][int(year)] = int(country_count)

datasets = {}
for dataset, variables in counts.items():
    year_min = min(y for years in variables.values() for y in years)
    year_max = max(y for years in variables.values() for y in years)

    # Density is normalised against the busiest year anywhere in the dataset, so a
    # sample covering 38 countries reads as lighter than one covering 194 rather
    # than each variable's own busiest year being what full height means.
    dataset_max = max(c for years in variables.values() for c in years.values())

    variable_payload = {}
    for variable, years in sorted(variables.items()):
        # Each strip is bucketed across its own first-to-last year, not the
        # dataset's: the row writes those two years underneath itself, so the
        # scale is legible per row, and every variable gets the full width of
        # the track at the finest step its span allows. A shared axis instead
        # spent most of a QoG row drawing the century before QoG starts.
        var_min, var_max = min(years), max(years)
        span = var_max - var_min + 1
        # A span narrower than the target would otherwise get sub-year buckets,
        # which just resamples the same year into neighbouring bars.
        buckets = min(bucket_target, span)
        # Bucket i covers years [edges[i], edges[i + 1]), which spreads the
        # remainder instead of piling it onto the last bar.
        edges = [var_min + (i * span) // buckets for i in range(buckets + 1)]

        levels = []
        for i in range(buckets):
            lo, hi = edges[i], edges[i + 1]
            observed = sum(years.get(year, 0) for year in range(lo, hi))
            # Missing years count as zero, so a variable sampled every other year
            # reads as half as dense as an annual one over the same span — the
            # "how often" and "how many countries" parts of coverage collapse
            # into the one number the bar height shows.
            ratio = observed / ((hi - lo) * dataset_max)
            # Level 0 means "no data at all"; anything present floors at 1 so a
            # thinly covered variable still shows where its span begins and ends.
            levels.append(0 if ratio <= 0 else max(1, min(9, 1 + round(8 * ratio))))

        variable_payload[variable] = {
            "yearMin": var_min,
            "yearMax": var_max,
            "maxCountries": max(years.values()),
            # One digit per bucket keeps the whole file well under the size at
            # which we would have to think about lazy-loading it per dataset.
            "levels": "".join(str(level) for level in levels),
        }

    # The dataset span is no longer what the strips are drawn against; it is
    # kept because the coverage text and the build log both quote it.
    datasets[dataset] = {
        "yearMin": year_min,
        "yearMax": year_max,
        "maxCountries": dataset_max,
        "variables": variable_payload,
    }

payload = {
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "bucketTarget": bucket_target,
    "datasets": datasets,
}

with open(out_file, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
    handle.write("\n")

for dataset, entry in sorted(datasets.items()):
    print(
        f"  {dataset}: {len(entry['variables'])} variables, "
        f"{entry['yearMin']}-{entry['yearMax']}, "
        f"max {entry['maxCountries']} countries"
    )
PY

echo "Wrote ${OUT_FILE} ($(wc -c < "$OUT_FILE") bytes)"
