#!/usr/bin/env bash
set -euo pipefail

# Builds webapp/config/attribution.json, the credits the app shows: the always-on
# line under the map and the "Sources & licences" dialog behind it.
#
# The indicator credits are read out of the codebooks (the tables
# scripts/load_variable_metadata.sh fills), and it fails on a dataset on the map
# that its codebook gave no citation for.
#
# The point of generating it rather than writing it is that a boundary source can
# reach the map without anyone remembering the credits. `demscore.countries` is
# the one table that says what geometry every drawn country rests on, so this
# reads that, joins it to the hand-maintained licence and citation register in
# webapp/config/attribution_sources.json, and **fails** on a source_dataset the
# register has never heard of. Same shape as check_country_resolution.sh failing
# on an unmapped country: an omission here is a licence breach, not a cosmetic
# gap, so it is a build error.
#
# Rerun after anything that changes which geometry is on the map -- a new
# boundary source, a changed historical registry, a fresh setup run. The setup
# script calls it next to the coverage build.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PG_DB="${PG_DB:-demscore}"
PG_USER="${PG_USER:-demscore}"
SOURCES_FILE="${SOURCES_FILE:-${ROOT_DIR}/webapp/config/attribution_sources.json}"
OUT_FILE="${OUT_FILE:-${ROOT_DIR}/webapp/config/attribution.json}"
# Read for each dataset's display name only; the credits themselves come from
# the codebooks.
VARIABLES_FILE="${VARIABLES_FILE:-${ROOT_DIR}/webapp/config/variables.json}"
# Which mesh the reported hexagon counts are measured at. One of the three sizes
# the app actually asks for, so the weights are a weight somebody can see.
WEIGHT_HEX_SIZE="${WEIGHT_HEX_SIZE:-100000}"

# shellcheck source=scripts/lib/tools.sh
source "${ROOT_DIR}/scripts/lib/tools.sh"
# Inside the repository, where the tools container that runs the Python below
# can read it.
TMP_DIR="$(tool_tmpdir)"
TMP_TSV="${TMP_DIR}/sources.tsv"
TMP_INDICATORS="${TMP_DIR}/indicators.json"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Reading the geometry sources that are actually on the map..."
# demscore.countries first, because that is what gets drawn; the historical
# registry unioned in as well, so a source added there but not yet reaching a
# country still has to be credited before it can.
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
  --no-align --tuples-only --field-separator=$'\t' -c "
WITH drawn AS (
  SELECT
    c.geometry_source_dataset AS source_dataset,
    c.geometry_source_license AS source_license,
    count(DISTINCT c.id) AS countries,
    count(m.country_id) FILTER (WHERE m.hex_size_m = ${WEIGHT_HEX_SIZE}) AS hexes,
    count(DISTINCT c.id) FILTER (WHERE c.valid_from_year IS NULL) AS present_day,
    min(c.valid_from_year) AS year_from,
    max(c.valid_to_year) AS year_to
  FROM demscore.countries c
  LEFT JOIN demscore.hex_mesh m ON m.country_id = c.id
  GROUP BY 1, 2
),
registered AS (
  SELECT DISTINCT source_dataset, source_license
  FROM demscore.historical_country_geometries_src
)
SELECT
  COALESCE(d.source_dataset, r.source_dataset),
  COALESCE(d.source_license, r.source_license),
  COALESCE(d.countries, 0),
  COALESCE(d.hexes, 0),
  COALESCE(d.present_day, 0),
  d.year_from,
  d.year_to
FROM drawn d
FULL OUTER JOIN registered r
  ON r.source_dataset = d.source_dataset
ORDER BY 1;" > "$TMP_TSV"

if [[ ! -s "$TMP_TSV" ]]; then
  echo "No geometry sources returned. Run scripts/setup_mapserver_hex_service.sh first." >&2
  exit 1
fi

echo "Reading the indicator credits out of the codebooks..."
# Which works the indicator data asks to be cited for, from the codebook tables
# scripts/load_variable_metadata.sh fills. A bibliography entry is credited when
# a variable the map shows cites it, or when no variable entry cites it at all
# (the dataset description is then what does); one cited only by hidden or
# dropped variables -- REPDEM's WECEE edition, QoG's OECD twin -- is left out.
# It counts as the dataset's own citation when something on the map cites it as
# its "Dataset citation", or nothing cites it; otherwise it is the original
# source of particular indicators.
podman compose exec -T db psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
  --quiet --no-align --tuples-only -c "
DO \$\$
BEGIN
  IF to_regclass('demscore.codebook_bibliography') IS NULL THEN
    RAISE EXCEPTION 'No codebook credits in the database. Run ./deploy.sh import-data.';
  END IF;
END;
\$\$;
WITH visible AS (
  SELECT vm.dataset, vm.source_long_tag AS long_tag, vm.dataset_tag
  FROM demscore.variable_metadata vm
  JOIN demscore.variables v ON v.id = vm.variable_id
  WHERE NOT v.hidden
),
works AS (
  SELECT
    b.dataset,
    b.entry_no,
    b.citation,
    b.url,
    count(c.long_tag) = 0
      OR COALESCE(bool_or(c.role = 'dataset' AND vis.long_tag IS NOT NULL), FALSE) AS own,
    count(DISTINCT vis.long_tag) AS cited_by
  FROM demscore.codebook_bibliography b
  LEFT JOIN demscore.codebook_citations c
    ON c.dataset = b.dataset AND c.entry_no = b.entry_no
  LEFT JOIN visible vis
    ON vis.dataset = c.dataset AND vis.long_tag = c.long_tag
  GROUP BY b.dataset, b.entry_no, b.citation, b.url
  HAVING count(c.long_tag) = 0 OR count(vis.long_tag) > 0
),
datasets AS (
  SELECT DISTINCT dataset FROM demscore.variables WHERE NOT hidden
),
projects AS (
  SELECT DISTINCT ON (dataset) dataset, project_name, project_url
  FROM demscore.codebook_source_datasets
  ORDER BY dataset, dataset_tag
)
SELECT COALESCE(json_object_agg(d.dataset, json_build_object(
  'projectName', p.project_name,
  'url', p.project_url,
  'citations', (
    SELECT COALESCE(json_agg(json_build_object('text', w.citation, 'url', w.url)
                             ORDER BY w.cited_by DESC, w.entry_no), '[]'::json)
    FROM works w WHERE w.dataset = d.dataset AND w.own),
  'sourceCitations', (
    SELECT COALESCE(json_agg(json_build_object('text', w.citation, 'url', w.url)
                             ORDER BY w.entry_no), '[]'::json)
    FROM works w WHERE w.dataset = d.dataset AND NOT w.own),
  -- The terms of each source dataset the map shows a variable from.
  'licenses', (
    SELECT COALESCE(json_agg(json_build_object('source', s.title, 'text', s.license)
                             ORDER BY s.dataset_tag), '[]'::json)
    FROM demscore.codebook_source_datasets s
    WHERE s.dataset = d.dataset AND s.license IS NOT NULL
      AND EXISTS (SELECT 1 FROM visible vis
                  WHERE vis.dataset = s.dataset AND vis.dataset_tag = s.dataset_tag))
)), '{}'::json)
FROM datasets d
LEFT JOIN projects p ON p.dataset = d.dataset;" > "$TMP_INDICATORS"

run_tool env SOURCES_FILE="$(tool_path "$SOURCES_FILE")" OUT_FILE="$(tool_path "$OUT_FILE")" \
  VARIABLES_FILE="$(tool_path "$VARIABLES_FILE")" WEIGHT_HEX_SIZE="$WEIGHT_HEX_SIZE" \
  python3 - "$(tool_path "$TMP_TSV")" "$(tool_path "$TMP_INDICATORS")" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

sources_file = os.environ["SOURCES_FILE"]
out_file = os.environ["OUT_FILE"]
variables_file = os.environ["VARIABLES_FILE"]
weight_hex_size = int(os.environ["WEIGHT_HEX_SIZE"])

with open(sources_file, encoding="utf-8") as handle:
    register = json.load(handle)

licenses = register["licenses"]
source_credits = register["sourceCredits"]
credits = register["credits"]


def parse_int(text):
    text = text.strip()
    return int(text) if text else None


rows = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        (source_dataset, source_license, countries, hexes, present_day,
         year_from, year_to) = line.split("\t")
        rows.append({
            "sourceDataset": source_dataset,
            "license": source_license,
            "countries": int(countries),
            "hexes": int(hexes),
            # Countries with no year span: the present-day ones, which is why a
            # block can be both "present-day" and dated. Natural Earth is both --
            # 242 current countries, plus one registry period that borrows its
            # geometry -- and reporting only the span would have read as though
            # Natural Earth covered 1802-1953 and nothing else.
            "presentDay": int(present_day),
            "yearFrom": parse_int(year_from),
            "yearTo": parse_int(year_to),
        })

# The two failure modes worth stopping the build for. Everything else about the
# credits is a matter of wording; these two are the difference between crediting
# a source and not.
problems = []
for row in rows:
    entry = source_credits.get(row["sourceDataset"])
    if entry is None:
        problems.append(
            f"geometry source {row['sourceDataset']!r} ({row['countries']} countries, "
            f"{row['hexes']} hexagons at {weight_hex_size // 1000} km) has no entry in "
            f"sourceCredits"
        )
        continue
    if entry["credit"] not in credits:
        problems.append(
            f"geometry source {row['sourceDataset']!r} names credit {entry['credit']!r}, "
            f"which is not in credits"
        )
    if row["license"] not in licenses:
        problems.append(
            f"geometry source {row['sourceDataset']!r} carries licence {row['license']!r}, "
            f"which is not in licenses"
        )

# The indicator credits, one block per dataset with a variable on the map, in the
# order the variable list shows the datasets. The citations, the project URL and
# the licence text are the codebook's own; only the display name is ours.
with open(sys.argv[2], encoding="utf-8") as handle:
    from_codebooks = json.load(handle)
with open(variables_file, encoding="utf-8") as handle:
    presentation = json.load(handle).get("datasets", {})

indicator_problems = []
indicator_datasets = {}
order = [key for key in presentation if key in from_codebooks]
order += sorted(key for key in from_codebooks if key not in presentation)
for key in order:
    found = from_codebooks[key]
    shown = presentation.get(key, {})
    title, label = shown.get("title"), shown.get("label")
    name = f"{title} ({label})" if title and label and title != label else (title or label or found["projectName"] or key)
    if not found["citations"]:
        indicator_problems.append(
            f"indicator dataset {key!r} has variables on the map, but its codebook yielded no "
            f"citation for them"
        )
    # Source datasets of one project usually share their terms word for word.
    terms = []
    for entry in found["licenses"]:
        same = next((t for t in terms if t["text"] == entry["text"]), None)
        if same:
            same["sources"].append(entry["source"])
        else:
            terms.append({"sources": [entry["source"]], "text": entry["text"]})
    indicator_datasets[key] = {
        "title": name,
        "url": found["url"],
        "citations": found["citations"],
        "sourceCitations": found["sourceCitations"],
        "licenses": terms,
    }

if problems or indicator_problems:
    print("Attribution is incomplete:", file=sys.stderr)
    for problem in problems + indicator_problems:
        print(f"  - {problem}", file=sys.stderr)
    if problems:
        print(
            "\nA boundary source that reaches the map without reaching the credits is a licence\n"
            f"breach. Add the missing entries to {sources_file} and run this again.",
            file=sys.stderr,
        )
    if indicator_problems:
        print(
            "\nEvery dataset asks to be cited as a condition of use. The citations are read from\n"
            "the bibliography at the end of each codebook.pdf (scripts/extract_variable_metadata.py);\n"
            "check that the codebook has one and that the import's metadata step succeeded.",
            file=sys.stderr,
        )
    sys.exit(1)

# Group the per-table rows into one block per credited work. CShapes 2.0 is one
# citation whether a polygon came from the vendored table or from a period this
# deployment extended, so the dialog says it once and lists the variants.
grouped = {}
for row in rows:
    key = source_credits[row["sourceDataset"]]["credit"]
    block = grouped.setdefault(key, {
        "key": key,
        **{field: credits[key][field] for field in
           ("title", "shortLabel", "url", "citation", "role", "modifications")},
        "license": None,
        "licenses": [],
        "variants": [],
        "countries": 0,
        "hexes": 0,
        "presentDay": 0,
        "yearFrom": None,
        "yearTo": None,
        "inShortLine": bool(credits[key].get("inShortLine", True)),
    })
    block["variants"].append({
        "sourceDataset": row["sourceDataset"],
        "label": source_credits[row["sourceDataset"]]["label"],
        "countries": row["countries"],
        "hexes": row["hexes"],
    })
    if row["license"] not in block["licenses"]:
        block["licenses"].append(row["license"])
    block["countries"] += row["countries"]
    block["hexes"] += row["hexes"]
    block["presentDay"] += row["presentDay"]
    for field, pick in (("yearFrom", min), ("yearTo", max)):
        value = row[field]
        if value is not None:
            current = block[field]
            block[field] = value if current is None else pick(current, value)

for block in grouped.values():
    # A work with two licences in one block would mean the register has split
    # something it should not have; the check above cannot see it, so say it
    # here rather than picking one silently.
    if len(block["licenses"]) > 1:
        print(
            f"Credit {block['key']!r} covers more than one licence "
            f"({', '.join(block['licenses'])}); split it into separate credits.",
            file=sys.stderr,
        )
        sys.exit(1)
    label = block["licenses"][0]
    block["license"] = {"label": label, **{k: v for k, v in licenses[label].items() if k != "label"}}
    del block["licenses"]
    block["variants"].sort(key=lambda variant: -variant["hexes"])

# Heaviest first, so the line reads in the order a viewer would weight it.
boundary = sorted(grouped.values(), key=lambda block: (-block["hexes"], block["title"]))

# The always-visible line. Generated from the same blocks as the dialog, which is
# the point: the two cannot disagree about which sources are on the map. Works
# under one licence are named together, and public-domain ones carry no licence
# because none is being claimed.
line_groups = []
for block in boundary:
    if not block["inShortLine"]:
        continue
    label = block["license"]["label"]
    shown = "" if label == "Public domain" else label
    for group in line_groups:
        if group["license"] == shown:
            group["names"].append(block["shortLabel"])
            break
    else:
        line_groups.append({"license": shown, "names": [block["shortLabel"]]})

short_line = "Boundaries: " + " · ".join(
    " & ".join(group["names"]) + (f" ({group['license']})" if group["license"] else "")
    for group in line_groups
) + ". Modified."

payload = {
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "weightHexSizeM": weight_hex_size,
    "shortLine": short_line,
    "boundary": boundary,
    # Per-table labels, which is the granularity /api/map-data reports a row's
    # geometry at. The data table's Boundary column reads this.
    "sourceLabels": {key: entry["label"] for key, entry in source_credits.items()},
    "mapOutput": {
        "statement": register["mapOutput"]["statement"],
        "note": register["mapOutput"].get("note"),
        "license": {
            "label": register["mapOutput"]["license"],
            **{k: v for k, v in licenses[register["mapOutput"]["license"]].items() if k != "label"},
        },
    },
    "indicatorDatasets": indicator_datasets,
    "indicatorNote": register.get("indicatorNote"),
    "software": register["software"],
    "media": register["media"],
}

with open(out_file, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=1, sort_keys=False)
    handle.write("\n")

print(f"  line: {short_line}")
for block in boundary:
    parts = []
    if block["presentDay"]:
        parts.append(f"{block['presentDay']} present-day")
    dated = block["countries"] - block["presentDay"]
    if dated:
        parts.append(f"{dated} dated {block['yearFrom']}-{block['yearTo']}")
    print(
        f"  {block['title']}: {block['license']['label']}, "
        f"{' + '.join(parts)} countries, "
        f"{block['hexes']} hexagons at {weight_hex_size // 1000} km"
    )
for key, block in indicator_datasets.items():
    print(
        f"  {block['title']}: {len(block['citations'])} citation(s), "
        f"{len(block['sourceCitations'])} original source(s)"
    )
PY

echo "Wrote ${OUT_FILE} ($(wc -c < "$OUT_FILE") bytes)"
