#!/usr/bin/env python3
"""
The checks and the report around ./deploy.sh import-data (scripts/import_data.sh).

  preflight  Read the exports in data/Demscore_Module_Vars before anything is
             touched, and fail on whatever would break the load. Also predicts
             which columns will import, so a dataset that would end up empty is
             caught here rather than by a rolled-back load.
  summary    Say what was found, what was imported, and what needs attention.

Runs in the tools container (tools/Containerfile), with the repository as its
working directory, and never talks to the database: scripts/import_data.sh
collects what the database holds into JSON files (collect_db_facts) before and
after the import, and this reads those. Standard library only.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data" / "Demscore_Module_Vars"
CONFIG_DIR = ROOT / "webapp" / "config"


@dataclass(frozen=True)
class Dataset:
    directory: str
    key: str
    year_col: str
    country_col: str
    iso_col: Optional[str]


# Must agree with the case block in scripts/load_demscore_module_vars.sh, which
# is what actually reads these columns.
DATASETS = [
    Dataset("QoG", "qog", "u_qog_country_year_year", "u_qog_country_year_country", "u_qog_country_year_ccodealp"),
    Dataset("REPDEM", "repdem", "u_repdem_country_year_year", "u_repdem_country_year_country", None),
    Dataset("V-Dem", "v_dem", "u_vdem_country_year_year", "u_vdem_country_year_country", "u_vdem_country_year_country_text_id"),
]

# The same rules the loader applies (MISSING_CODES, NA_TOKENS and the numeric
# pattern in scripts/load_demscore_module_vars.sh). The loader is the authority;
# these only let the preflight predict it.
MISSING_CODES = {-11111.0, -22222.0}
NA_TOKENS = {"na", "nan", "n/a", "."}
NUMERIC_RE = re.compile(r"^[+-]?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?$")
YEAR_RE = re.compile(r"^[0-9]{1,4}(\.0+)?$")
# The WMS `variable` parameter is validated against this, so a column named
# otherwise could be loaded but never drawn. Postgres also truncates
# identifiers past 63 bytes, which would rename the column on the way in.
COLUMN_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
MAX_IDENTIFIER_BYTES = 63
# The years the map can be asked for (the SQL clamps to this).
MAP_YEAR_MIN, MAP_YEAR_MAX = 1500, 2100
# V-Dem's variant suffixes, which the web client folds under their main
# variable (VARIANT_SUFFIXES in webapp/src/controllers/MetadataController.js).
VARIANT_SUFFIXES = {"codelow", "codehigh", "sd", "mean", "nr", "ord", "osp"}

LIST_LIMIT = 12


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def fmt_int(n: Any) -> str:
    try:
        return f"{int(n):,}"
    except (TypeError, ValueError):
        return "?"


def fmt_seconds(seconds: float) -> str:
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    return f"{minutes}m{seconds:02d}s"


def fmt_list(items: List[str], limit: int = LIST_LIMIT) -> str:
    items = list(items)
    if len(items) <= limit:
        return ", ".join(items)
    return ", ".join(items[:limit]) + f" … and {len(items) - limit} more"


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def main_variable(variable: str, variable_set: set) -> str:
    """The variable the web client lists `variable` under (see buildVariableHierarchy)."""
    base = variable
    while True:
        idx = base.rfind("_")
        if idx <= 0 or base[idx + 1:] not in VARIANT_SUFFIXES:
            break
        base = base[:idx]
    return base if base != variable and base in variable_set else variable


class Printer:
    """Prints to the terminal and keeps a copy for summary.txt."""

    def __init__(self) -> None:
        self.lines: List[str] = []

    def __call__(self, line: str = "") -> None:
        print(line)
        self.lines.append(line)

    def text(self) -> str:
        return "\n".join(self.lines) + "\n"


# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------


def inspect_csv(ds: Dataset, csv_path: Path, problems: List[Dict[str, str]]) -> Dict[str, Any]:
    def problem(level: str, text: str) -> None:
        problems.append({"level": level, "dataset": ds.directory, "text": text})

    facts: Dict[str, Any] = {"path": rel(csv_path)}
    if not csv_path.is_file():
        problem("error", f"{rel(csv_path)} is missing")
        return facts
    if csv_path.stat().st_size == 0:
        problem("error", f"{rel(csv_path)} is empty")
        return facts
    facts["bytes"] = csv_path.stat().st_size

    try:
        with csv_path.open(newline="", encoding="utf-8-sig") as handle:
            reader = csv.reader(handle)
            header = next(reader, None)
            if not header:
                problem("error", f"{rel(csv_path)} has no header line")
                return facts
            header = [name.strip() for name in header]
            facts["columns"] = len(header)

            if len(header) == 1 and any(sep in header[0] for sep in (";", "\t", "|")):
                problem("error", f"{rel(csv_path)} does not look comma-separated "
                                 f"(the header is one column: {header[0][:60]!r}…)")
                return facts

            seen: Dict[str, int] = {}
            for name in header:
                seen[name] = seen.get(name, 0) + 1
            duplicates = sorted(n for n, c in seen.items() if c > 1)
            if duplicates:
                problem("error", f"duplicate column name(s): {fmt_list(duplicates)}")
            if any(not n for n in header):
                problem("error", "the header has an empty column name")
            bad_names = [n for n in header if n and not COLUMN_NAME_RE.match(n)]
            if bad_names:
                problem("error", "column name(s) with characters other than letters, digits "
                                 f"and _: {fmt_list(bad_names)}")
            long_names = [n for n in header if len(n.encode()) > MAX_IDENTIFIER_BYTES]
            if long_names:
                problem("error", f"column name(s) longer than {MAX_IDENTIFIER_BYTES} bytes, which "
                                 f"Postgres would truncate: {fmt_list(long_names)}")

            required = [c for c in (ds.year_col, ds.country_col, ds.iso_col) if c]
            missing = [c for c in required if c not in seen]
            if missing:
                problem("error", f"required identifier column(s) missing: {', '.join(missing)}")
                return facts

            index = {name: i for i, name in enumerate(header)}
            year_i = index[ds.year_col]
            country_i = index[ds.country_col]
            iso_i = index[ds.iso_col] if ds.iso_col else None
            identifiers = [n for n in header if n.startswith("u_")]
            candidates = [n for n in header if not n.startswith("u_")]
            facts["identifier_columns"] = len(identifiers)
            facts["candidate_columns"] = candidates

            # Per candidate column: does it hold text, and does it hold a usable value?
            has_text: Dict[str, str] = {}
            has_value = set()
            na_cells = 0
            rows = 0
            ragged: List[int] = []
            no_year = 0
            out_of_range = 0
            no_country = 0
            years: List[int] = []
            countries = set()

            for row in reader:
                rows += 1
                if len(row) != len(header):
                    ragged.append(reader.line_num)
                    continue
                year_raw = row[year_i].strip()
                year: Optional[int] = None
                if YEAR_RE.match(year_raw):
                    year = int(float(year_raw))
                    years.append(year)
                    if not MAP_YEAR_MIN <= year <= MAP_YEAR_MAX:
                        out_of_range += 1
                else:
                    no_year += 1
                country = row[country_i].strip()
                iso = row[iso_i].strip() if iso_i is not None else ""
                if country:
                    countries.add(country)
                elif not iso:
                    no_country += 1
                for name in candidates:
                    cell = row[index[name]].strip()
                    if not cell:
                        continue
                    if cell.lower() in NA_TOKENS:
                        na_cells += 1
                        continue
                    if not NUMERIC_RE.match(cell):
                        has_text.setdefault(name, cell)
                        continue
                    if year is not None and float(cell) not in MISSING_CODES:
                        has_value.add(name)
    except UnicodeDecodeError as exc:
        problem("error", f"{rel(csv_path)} is not valid UTF-8 ({exc.reason} at byte {exc.start})")
        return facts
    except csv.Error as exc:
        problem("error", f"{rel(csv_path)} could not be parsed as CSV: {exc}")
        return facts

    facts.update(
        rows=rows,
        year_min=min(years) if years else None,
        year_max=max(years) if years else None,
        countries=len(countries),
        na_token_cells=na_cells,
    )
    predicted = [n for n in candidates if n in has_value and n not in has_text]
    facts["predicted_imports"] = predicted
    facts["predicted_text_columns"] = {n: v[:40] for n, v in has_text.items()}

    if rows == 0:
        problem("error", f"{rel(csv_path)} has a header but no data rows")
    if ragged:
        problem("error", f"{len(ragged)} row(s) have a different number of fields from the header "
                         f"(first at line {ragged[0]}); the load would fail on them")
    if rows and no_year == rows:
        problem("error", f"no row has a usable year in {ds.year_col}")
    elif no_year:
        problem("warning", f"{fmt_int(no_year)} row(s) have no usable year in {ds.year_col} and will be skipped")
    if out_of_range:
        problem("warning", f"{fmt_int(out_of_range)} row(s) fall outside {MAP_YEAR_MIN}–{MAP_YEAR_MAX}, "
                           "the years the map can be asked for")
    if no_country:
        problem("warning", f"{fmt_int(no_country)} row(s) name no country and cannot be placed on the map")
    if rows and not ragged and not predicted:
        problem("error", "no column would import as an indicator (every candidate is text, empty "
                         "or only missing codes); the load would refuse this dataset")
    return facts


def inspect_codebook(ds: Dataset, pdf_path: Path, problems: List[Dict[str, str]]) -> Dict[str, Any]:
    facts: Dict[str, Any] = {"path": rel(pdf_path)}
    if not pdf_path.is_file() or pdf_path.stat().st_size == 0:
        problems.append({"level": "error", "dataset": ds.directory,
                         "text": f"{rel(pdf_path)} is missing or empty"})
        return facts
    try:
        result = subprocess.run(
            ["pdftotext", "-layout", str(pdf_path), "-"],
            capture_output=True, text=True, timeout=300,
        )
    except FileNotFoundError:
        problems.append({"level": "error", "dataset": ds.directory,
                         "text": "pdftotext is not installed (poppler-utils), so the codebook cannot be read"})
        return facts
    except subprocess.TimeoutExpired:
        problems.append({"level": "error", "dataset": ds.directory,
                         "text": f"pdftotext timed out reading {rel(pdf_path)}"})
        return facts
    if result.returncode != 0:
        problems.append({"level": "error", "dataset": ds.directory,
                         "text": f"pdftotext could not read {rel(pdf_path)}: "
                                 f"{result.stderr.strip().splitlines()[-1] if result.stderr.strip() else 'unknown error'}"})
        return facts
    # The parser anchors every entry on this label (scripts/extract_variable_metadata.py).
    tags = re.findall(r"^\s*Long tag\s*:\s*(\S+)", result.stdout, flags=re.MULTILINE)
    facts["entries"] = len(tags)
    if not tags:
        problems.append({"level": "warning", "dataset": ds.directory,
                         "text": f"{rel(pdf_path)} has no 'Long tag:' entries, so no variable will get a "
                                 "title or description from it"})
    return facts


def cmd_preflight(args: argparse.Namespace) -> int:
    problems: List[Dict[str, str]] = []
    report: Dict[str, Any] = {"datasets": {}, "problems": problems}
    previous = read_json(Path(args.previous)) if args.previous else None

    for ds in DATASETS:
        directory = DATA_DIR / ds.directory
        if not directory.is_dir():
            problems.append({"level": "error", "dataset": ds.directory,
                             "text": f"{rel(directory)}/ is missing"})
            report["datasets"][ds.key] = {"directory": ds.directory}
            continue
        report["datasets"][ds.key] = {
            "directory": ds.directory,
            "csv": inspect_csv(ds, directory / "data.csv", problems),
            "codebook": inspect_codebook(ds, directory / "codebook.pdf", problems),
        }

    expected = {d.directory for d in DATASETS}
    if DATA_DIR.is_dir():
        extra = sorted(p.name for p in DATA_DIR.iterdir() if p.is_dir() and p.name not in expected)
        if extra:
            problems.append({"level": "warning", "dataset": "-",
                             "text": f"ignoring unknown folder(s) in {rel(DATA_DIR)}: {', '.join(extra)}"})

    # Which columns are new, or gone, against the last import's column record.
    previous_columns: Dict[str, List[str]] = {}
    for row in (previous or {}).get("columns") or []:
        previous_columns.setdefault(row["dataset"], []).append(row["column_name"])
    for ds in DATASETS:
        facts = report["datasets"][ds.key].get("csv") or {}
        if "candidate_columns" not in facts or ds.key not in previous_columns:
            continue
        now = set(facts["candidate_columns"])
        before = set(c for c in previous_columns[ds.key] if not c.startswith("u_"))
        facts["new_columns"] = sorted(now - before)
        facts["gone_columns"] = sorted(before - now)

    Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")

    p = Printer()
    for ds in DATASETS:
        entry = report["datasets"][ds.key]
        c = entry.get("csv") or {}
        b = entry.get("codebook") or {}
        if "rows" in c:
            years = f"{c['year_min']}–{c['year_max']}" if c.get("year_min") is not None else "no years"
            p(f"  {ds.directory:<8} data.csv  {fmt_int(c['rows'])} rows, {c['columns']} columns, {years}, "
              f"{fmt_int(c['countries'])} countries; {len(c['predicted_imports'])} of "
              f"{len(c['candidate_columns'])} candidate columns look numeric")
        else:
            p(f"  {ds.directory:<8} data.csv  not readable")
        if "entries" in b:
            p(f"  {'':<8} codebook  {fmt_int(b['entries'])} variable entries")
        if c.get("new_columns") or c.get("gone_columns"):
            if c.get("new_columns"):
                p(f"  {'':<8} new       {fmt_list(c['new_columns'])}")
            if c.get("gone_columns"):
                p(f"  {'':<8} gone      {fmt_list(c['gone_columns'])}")
    for level in ("error", "warning"):
        for item in (x for x in problems if x["level"] == level):
            p(f"  {level.upper()}: {item['dataset']}: {item['text']}")

    return 1 if any(x["level"] == "error" for x in problems) else 0


# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------


def read_stages(run_dir: Path) -> List[Dict[str, Any]]:
    stages = []
    path = run_dir / "stages.tsv"
    if not path.is_file():
        return stages
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) >= 5:
            stages.append({"key": parts[0], "label": parts[1], "status": parts[2],
                           "seconds": float(parts[3] or 0), "log": str(ROOT / parts[4])})
    return stages


def resolve_polarity(config: Dict[str, Any], dataset: str, variable: str) -> str:
    valid = {"positive", "negative", "neutral"}
    override = ((config.get("variable_overrides") or {}).get(dataset) or {}).get(variable)
    if override in valid:
        return override
    for rule in config.get("rules") or []:
        if rule.get("dataset") and rule["dataset"] != dataset:
            continue
        try:
            if rule.get("match") and re.search(rule["match"], variable) and rule.get("polarity") in valid:
                return rule["polarity"]
        except re.error:
            continue
    default = (config.get("dataset_defaults") or {}).get(dataset)
    if default in valid:
        return default
    return (config.get("defaults") or {}).get("polarity") or "negative"


def cmd_summary(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir)
    started = float(args.started)
    stages = read_stages(run_dir)
    status = {s["key"]: s["status"] for s in stages}
    preflight = read_json(run_dir / "preflight.json") or {"datasets": {}, "problems": []}
    previous = read_json(run_dir / "previous.json") or {}
    # What the database holds now. A key is null when its table does not exist.
    facts = read_json(run_dir / "facts.json") or {}
    warnings: List[str] = []
    review: List[str] = []
    out: Dict[str, Any] = {"stages": stages}

    loaded = status.get("load") == "ok"
    p = Printer()
    p()
    p("=" * 72)
    p("Import summary")
    p("=" * 72)

    # --- What the files hold ------------------------------------------------
    p()
    p(f"Found in {rel(DATA_DIR)}")
    for ds in DATASETS:
        entry = preflight["datasets"].get(ds.key) or {}
        c = entry.get("csv") or {}
        b = entry.get("codebook") or {}
        if "rows" in c:
            years = f"years {c['year_min']}–{c['year_max']}" if c.get("year_min") is not None else "no years"
            p(f"  {ds.directory:<8} data.csv   {fmt_int(c['rows'])} rows, {c['columns']} columns "
              f"({c['identifier_columns']} identifiers), {years}, {fmt_int(c['countries'])} countries")
        else:
            p(f"  {ds.directory:<8} data.csv   not readable")
        p(f"  {'':<8} codebook   " + (f"{fmt_int(b['entries'])} variable entries" if "entries" in b else "not readable"))
    for item in preflight.get("problems", []):
        if item["level"] == "warning":
            warnings.append(f"{item['dataset']}: {item['text']}")

    # --- What the load made of them -----------------------------------------
    now_vars: Dict[str, Dict[str, bool]] = {}
    counts: Dict[str, Dict[str, Any]] = {}
    if loaded:
        for r in facts.get("variables") or []:
            now_vars.setdefault(r["dataset"], {})[r["variable"]] = bool(r["hidden"])

    if loaded:
        p()
        p("Imported")
        counts = {r["dataset"]: r for r in facts.get("counts") or []}
        columns = facts.get("columns")
        by_outcome: Dict[str, Dict[str, List[Dict[str, Any]]]] = {}
        for r in columns or []:
            by_outcome.setdefault(r["dataset"], {}).setdefault(r["outcome"], []).append(r)
        out["columns"] = columns
        for ds in DATASETS:
            variables = now_vars.get(ds.key, {})
            visible = sum(1 for h in variables.values() if not h)
            hidden = len(variables) - visible
            c = counts.get(ds.key) or {}
            outcomes = by_outcome.get(ds.key, {})
            notes = []
            for outcome, label in (
                ("dropped_not_numeric", "non-numeric dropped"),
                ("dropped_no_values", "empty dropped"),
                ("dropped_redundant", "redundant twin(s) dropped"),
            ):
                if outcomes.get(outcome):
                    notes.append(f"{len(outcomes[outcome])} {label}")
            hidden_text = f" (+{hidden} hidden)" if hidden else ""
            years = f", {c.get('year_min')}–{c.get('year_max')}" if c.get("year_min") is not None else ""
            p(f"  {ds.key:<8} {visible} variables{hidden_text}, {fmt_int(c.get('values'))} values{years}"
              + (f" · {', '.join(notes)}" if notes else ""))
            na = sum(int(r.get("na_token_cells") or 0) for rows in outcomes.values() for r in rows)
            if na:
                p(f"  {'':<8} {fmt_int(na)} cell(s) spelled NA/NaN/'.' were read as empty")
        dropped = [r for r in columns or [] if r["outcome"] in ("dropped_not_numeric", "dropped_no_values")]
        if dropped:
            p("  Columns left out (not indicators):")
            for r in dropped:
                p(f"    {r['dataset']:<7} {r['column_name']:<34} {r['detail'] or r['outcome']}")
        for r in columns or []:
            if r["outcome"] == "imported" and (r.get("detail") or "").startswith("kept beside"):
                warnings.append(f"{r['dataset']}: {r['column_name']} {r['detail']}")

    # --- What changed --------------------------------------------------------
    added: Dict[str, List[str]] = {}
    removed: Dict[str, List[str]] = {}
    if loaded:
        p()
        p("Compared with the data before this import")
        before_rows = previous.get("variables")
        if before_rows is None:
            p("  no earlier data in the database to compare with")
        else:
            before: Dict[str, set] = {}
            for r in before_rows:
                if not r.get("hidden"):
                    before.setdefault(r["dataset"], set()).add(r["variable"])
            for ds in DATASETS:
                now = {v for v, h in now_vars.get(ds.key, {}).items() if not h}
                was = before.get(ds.key, set())
                added[ds.key] = sorted(now - was)
                removed[ds.key] = sorted(was - now)
                if not added[ds.key] and not removed[ds.key]:
                    p(f"  {ds.key:<8} same variables")
                    continue
                if added[ds.key]:
                    p(f"  {ds.key:<8} + {len(added[ds.key])} new: {fmt_list(added[ds.key])}")
                if removed[ds.key]:
                    label = ds.key if not added[ds.key] else ""
                    p(f"  {label:<8} - {len(removed[ds.key])} gone: {fmt_list(removed[ds.key])}")
        out["added"], out["removed"] = added, removed

    # --- Codebook metadata ---------------------------------------------------
    if loaded:
        p()
        p("Codebook metadata (titles, descriptions and citations)")
        if status.get("metadata") != "ok" or facts.get("metadata_matched") is None:
            p("  NOT LOADED: the variable list shows raw column names and no hover cards")
            warnings.append("codebook metadata was not loaded")
        else:
            parsed = {r["dataset"]: r["entries"] for r in facts.get("metadata_parsed") or []}
            matched = facts.get("metadata_matched") or []
            out["metadata"] = matched
            for ds in DATASETS:
                row = next((r for r in matched if r["dataset"] == ds.key), None)
                if not row:
                    continue
                line = (f"  {ds.key:<8} {row['matched']} of {row['visible']} variables matched "
                        f"({fmt_int(parsed.get(ds.key, 0))} codebook entries parsed)")
                p(line)
                if row["unmatched"]:
                    p(f"  {'':<8} no entry for: {fmt_list(row['unmatched'])}")
                    warnings.append(f"{ds.key}: {len(row['unmatched'])} variable(s) have no codebook entry "
                                    "and show as their raw column name")

    # --- Countries -----------------------------------------------------------
    if loaded:
        p()
        p("Countries")
        if counts and all(int(c.get("countries") or 0) == 0 for c in counts.values()):
            p("  not matched yet: the map step did not get as far as matching countries")
        else:
            audit = facts.get("audit")
            audit_by = {(r["dataset"], r["status"]): r for r in audit or []}
            for ds in DATASETS:
                c = counts.get(ds.key) or {}
                line = f"  {ds.key:<8} {fmt_int(c.get('countries'))} countries on the map"
                unsupported = audit_by.get((ds.key, "intentionally_unsupported"))
                if unsupported:
                    line += (f"; {fmt_int(unsupported['values'])} values from {unsupported['entities']} "
                             "entit(ies) intentionally not drawn")
                p(line)
            unresolved = facts.get("unresolved")
            out["unresolved"] = unresolved
            if unresolved:
                p(f"  UNRESOLVED: {len(unresolved)} source entit(ies) have no geometry and no policy saying why:")
                for r in unresolved[:LIST_LIMIT]:
                    p(f"    {r['dataset']:<7} {r['country_name']} ({r['iso3']}), {r['from_year']}–{r['to_year']}, "
                      f"{fmt_int(r['values'])} values")
                if len(unresolved) > LIST_LIMIT:
                    p(f"    … and {len(unresolved) - LIST_LIMIT} more")
                p("  Each needs geometry or an 'intentionally_unsupported' row in sql/historical_geometry.sql.")
        map_log = next((Path(s["log"]) for s in stages if s["key"] == "map"), None)
        if map_log and map_log.is_file():
            skipped = [line.split(":", 1)[1].strip() for line in map_log.read_text(errors="replace").splitlines()
                       if line.startswith("Skipped regression case:")]
            if skipped:
                p(f"  {len(skipped)} country regression case(s) skipped, their entity-year is not in the source:")
                for line in skipped[:LIST_LIMIT]:
                    p(f"    {line}")

    # --- Generated files -----------------------------------------------------
    if status.get("map") == "ok":
        p()
        p("Generated for the web app")
        for name, label in (("variable_coverage.json", "coverage strips"), ("attribution.json", "credits")):
            path = CONFIG_DIR / name
            fresh = path.is_file() and path.stat().st_mtime >= started
            p(f"  {label:<16} {'rebuilt' if fresh else 'NOT rebuilt'} ({rel(path)})")
            if not fresh:
                warnings.append(f"{rel(path)} was not rebuilt")

    # --- Hand-curated config -------------------------------------------------
    if loaded and now_vars:
        variables_cfg = read_json(CONFIG_DIR / "variables.json") or {}
        topics_cfg = read_json(CONFIG_DIR / "variable_topics.json") or {}
        polarity_cfg = read_json(CONFIG_DIR / "variable_polarity.json") or {}
        for ds in DATASETS:
            visible = sorted(v for v, h in now_vars.get(ds.key, {}).items() if not h)
            visible_set = set(visible)
            mains = sorted({main_variable(v, visible_set) for v in visible})

            default = ((variables_cfg.get("datasets") or {}).get(ds.key) or {}).get("defaultVariable")
            if default and default not in visible_set:
                review.append(f"variables.json: {ds.key} defaultVariable {default!r} is no longer imported; "
                              "the app opens that dataset on another variable")

            assigned = (topics_cfg.get("assignments") or {}).get(ds.key) or {}
            if topics_cfg:
                untopiced = [v for v in mains if v not in assigned]
                stale = sorted(v for v in assigned if v not in visible_set)
                if untopiced:
                    review.append(f"variable_topics.json: {ds.key} has {len(untopiced)} variable(s) with no topic, "
                                  f"listed under \"Other variables\": {fmt_list(untopiced)}")
                if stale:
                    review.append(f"variable_topics.json: {ds.key} assigns topics to {len(stale)} variable(s) "
                                  f"no longer imported (harmless): {fmt_list(stale)}")

            if polarity_cfg and added.get(ds.key):
                new_mains = sorted({main_variable(v, visible_set) for v in added[ds.key]})
                described = [f"{v} ({resolve_polarity(polarity_cfg, ds.key, v)})" for v in new_mains]
                review.append(f"variable_polarity.json: check the colour direction of {ds.key}'s new "
                              f"variable(s): {fmt_list(described)}")
            overrides = (polarity_cfg.get("variable_overrides") or {}).get(ds.key) or {}
            stale_overrides = sorted(v for v in overrides if v not in visible_set)
            if stale_overrides:
                review.append(f"variable_polarity.json: {ds.key} overrides polarity for {len(stale_overrides)} "
                              f"variable(s) no longer imported (harmless): {fmt_list(stale_overrides)}")
        if any(added.values()) or any(removed.values()):
            review.append("variables.json: the download links replay Demscore's saved selection for each "
                          "module; if this export is a different selection, update them")
        if review:
            p()
            p("To review in webapp/config (the import works without these)")
            for item in review:
                p(f"  - {item}")

    # --- Steps and result ----------------------------------------------------
    p()
    p("Steps")
    for s in stages:
        log = f"   log: {rel(Path(s['log']))}" if s["status"] == "failed" else ""
        p(f"  {s['status']:<7} {s['label']:<22} {fmt_seconds(s['seconds'])}{log}")

    if warnings:
        p()
        p("Warnings")
        for w in warnings:
            p(f"  - {w}")

    failed = [s for s in stages if s["status"] == "failed"]
    p()
    if not failed:
        verdict = "OK" if not warnings else f"OK, with {len(warnings)} warning(s)"
    elif all(s["key"] == "metadata" for s in failed):
        verdict = "COMPLETED WITH ERRORS: the new data is on the map, but its codebook metadata did not load"
    else:
        verdict = f"FAILED at: {', '.join(s['label'] for s in failed)}"
    p(f"Result: {verdict}")
    p(f"Run directory: {rel(run_dir)}")

    out.update(verdict=verdict, warnings=warnings, review=review)
    (run_dir / "summary.txt").write_text(p.text(), encoding="utf-8")
    (run_dir / "summary.json").write_text(json.dumps(out, indent=2, default=str), encoding="utf-8")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    pre = sub.add_parser("preflight")
    pre.add_argument("--out", required=True)
    pre.add_argument("--previous")
    summ = sub.add_parser("summary")
    summ.add_argument("--run-dir", required=True)
    summ.add_argument("--started", required=True)
    args = parser.parse_args()
    return {"preflight": cmd_preflight, "summary": cmd_summary}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
