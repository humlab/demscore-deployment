#!/usr/bin/env python3
"""
Extract variable metadata blocks from Demscore codebook PDFs (converted to text).

This parser is intentionally defensive:
- Anchors variable blocks on "Long tag:" (most stable marker).
- Accepts multiline/wrapped fields for citations and descriptions.
- Handles heading wraps around the variable title.
- Extracts "ADDITIONAL VERSIONS" from description for V-Dem variant expansion.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


LABELS = [
    "Long tag",
    "Original tag",
    "Dataset citation",
    "Variable citation",
    "Description",
]

DESCRIPTION_SECTION_LABELS = [
    "ADDITIONAL VERSIONS",
    "QUESTION",
    "CLARIFICATION",
    "SCALE",
    "SOURCE(S)",
    "DATA RELEASE",
    "AGGREGATION",
    "CROSS-CODER AGGREGATION",
    "COUNTRY-YEAR AGGREGATION",
]

STOP_PREFIXES = (
    "Merge scores:",
    "Non-missing observations",
    "Lost observations",
    "Output Unit:",
    "Dataset tag:",
    "TOC",
    "Bibliography",
)

HEADING_RE = re.compile(r"^\s*\d+(?:\.\d+){2,}\s+(.+?)\s*$")
SECTION_START_RE = re.compile(r"^\s*\d+(?:\.\d+){2,}\s+")
FIELD_RE_TEMPLATE = r"^\s*{label}\s*:\s*(.*)\s*$"


@dataclass
class ParsedEntry:
    dataset: str
    source_pdf: str
    dataset_tag: Optional[str]
    heading_raw: Optional[str]
    title: Optional[str]
    long_tag: str
    original_tag: Optional[str]
    dataset_citation: Optional[str]
    variable_citation: Optional[str]
    description: Optional[str]
    description_full: Optional[str]
    raw_block_text: Optional[str]
    additional_versions: Optional[str]
    question: Optional[str]
    clarification: Optional[str]
    scale: Optional[str]
    sources: Optional[str]
    data_release: Optional[str]
    aggregation: Optional[str]
    cross_coder_aggregation: Optional[str]
    country_year_aggregation: Optional[str]


def normalize_line(line: str) -> str:
    return line.replace("\u00a0", " ").rstrip("\n\r")


def collapse_spaces(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def parse_dataset_key(path: str) -> str:
    parent = os.path.basename(os.path.dirname(path)).lower()
    if parent == "qog":
        return "qog"
    if parent == "repdem":
        return "repdem"
    if parent in {"v-dem", "v_dem", "vdem"}:
        return "v_dem"
    raise ValueError(f"Cannot infer dataset key from parent directory: {path}")


def is_field_stop(line: str, current_label: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    for label in LABELS:
        if label != current_label and stripped.startswith(f"{label}:"):
            return True
    if stripped.startswith(STOP_PREFIXES):
        return True
    if SECTION_START_RE.match(stripped):
        return True
    return False


def get_field(lines: List[str], label: str) -> Optional[str]:
    field_re = re.compile(FIELD_RE_TEMPLATE.format(label=re.escape(label)))
    idx = None
    first_value = ""
    for i, line in enumerate(lines):
        m = field_re.match(line)
        if m:
            idx = i
            first_value = m.group(1).strip()
            break
    if idx is None:
        return None

    chunks: List[str] = []
    if first_value:
        chunks.append(first_value)

    for j in range(idx + 1, len(lines)):
        candidate = lines[j]
        if is_field_stop(candidate, label):
            break

        s = candidate.strip()
        # Skip obvious page artefacts.
        if s == "\x0c":
            continue
        if s.startswith("TOC"):
            continue

        if not s:
            # Preserve paragraph boundaries in descriptions.
            if label == "Description" and chunks and chunks[-1] != "":
                chunks.append("")
            continue
        chunks.append(s)

    if not chunks:
        return None

    # Rebuild with paragraph separators.
    paragraphs: List[str] = []
    current: List[str] = []
    for c in chunks:
        if c == "":
            if current:
                paragraphs.append(collapse_spaces(" ".join(current)))
                current = []
            continue
        current.append(c)
    if current:
        paragraphs.append(collapse_spaces(" ".join(current)))
    return "\n\n".join(p for p in paragraphs if p).strip() or None


def extract_heading(block_lines: List[str], long_tag_line_idx: int) -> Optional[str]:
    heading_idx = None
    heading_raw = None
    for i in range(long_tag_line_idx - 1, -1, -1):
        line = block_lines[i].strip()
        m = HEADING_RE.match(line)
        if m:
            heading_idx = i
            heading_raw = m.group(1).strip()
            break
    if heading_idx is None or heading_raw is None:
        return None

    # Some headings split "(original_tag)" onto a continuation line.
    continuation_bits: List[str] = []
    for j in range(heading_idx + 1, long_tag_line_idx):
        t = block_lines[j].strip()
        if not t:
            continue
        if any(t.startswith(f"{label}:") for label in LABELS):
            break
        if t.startswith("Merge scores:") or t.startswith("Non-missing observations"):
            break
        # Keep concise continuation fragments only.
        if len(t) <= 120:
            continuation_bits.append(t)
    if continuation_bits:
        heading_raw = collapse_spaces(" ".join([heading_raw] + continuation_bits))

    # Strip trailing "(tag)" to produce a cleaner human title.
    title = re.sub(r"\s*\([^()]+\)\s*$", "", heading_raw).strip()
    return title or heading_raw


def find_additional_versions(text: Optional[str]) -> Optional[str]:
    if not text:
        return None
    # Keep this bounded to the ADDITIONAL VERSIONS field only. In some codebooks
    # the next labels appear on the same wrapped paragraph after text extraction.
    m = re.search(
        r"ADDITIONAL VERSIONS:\s*(.+?)(?:\bQUESTION:|\bCLARIFICATION:|\bSCALE:|\bSOURCE\(S\):|\bDATA RELEASE:|\bAGGREGATION:|\bCROSS-CODER AGGREGATION:|\bCOUNTRY-YEAR AGGREGATION:|$)",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    if not m:
        return None
    raw = m.group(1).strip()
    suffixes: List[str] = []

    # Prefer explicit *_suffix patterns.
    explicit = re.findall(r"\*?\s*_[a-z0-9_]+", raw, flags=re.IGNORECASE)
    for token in explicit:
        p = token.lower().replace("*", "").strip()
        p = p[1:] if p.startswith("_") else p
        p = re.sub(r"[^a-z0-9_]+", "", p)
        if p:
            suffixes.append(p)

    # Fallback for occasional plain comma-separated tokens without leading "_".
    if not suffixes:
        for part in re.split(r"\s*,\s*", raw):
            p = re.sub(r"[^a-z0-9_]+", "", part.lower())
            if re.fullmatch(r"[a-z][a-z0-9_]{1,40}", p or ""):
                suffixes.append(p)
    if not suffixes:
        return None
    # Deduplicate while preserving order.
    seen = set()
    ordered = []
    for s in suffixes:
        if s not in seen:
            seen.add(s)
            ordered.append(s)
    return ",".join(ordered)


def extract_description_section(text: Optional[str], label: str) -> Optional[str]:
    if not text:
        return None
    alternation = "|".join(re.escape(x) for x in DESCRIPTION_SECTION_LABELS)
    pattern = re.compile(
        rf"(?ims)^\s*{re.escape(label)}\s*:\s*(.*?)(?=^\s*(?:{alternation})\s*:|\Z)",
    )
    m = pattern.search(text)
    if not m:
        return None
    raw = m.group(1).strip()
    if not raw:
        return None
    lines = [line.strip() for line in raw.splitlines()]
    text = "\n".join(lines).strip()
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text or None


def strip_description_sections(description: Optional[str]) -> Optional[str]:
    if not description:
        return None
    cleaned = description
    alternation = "|".join(re.escape(x) for x in DESCRIPTION_SECTION_LABELS)
    pattern = re.compile(
        rf"(?ims)^\s*(?:{alternation})\s*:\s*.*?(?=^\s*(?:{alternation})\s*:|\Z)",
    )
    cleaned = pattern.sub("", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return cleaned or None


def parse_text_file(txt_path: str, source_pdf: str, dataset: str) -> List[ParsedEntry]:
    with open(txt_path, "r", encoding="utf-8", errors="replace") as f:
        lines = [normalize_line(line) for line in f]

    dataset_tag_at_line: List[Optional[str]] = []
    current_dataset_tag: Optional[str] = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("Dataset tag:"):
            current_dataset_tag = stripped.split(":", 1)[1].strip() or None
        dataset_tag_at_line.append(current_dataset_tag)

    long_tag_re = re.compile(FIELD_RE_TEMPLATE.format(label="Long tag"))
    long_tag_indices: List[int] = []
    for idx, line in enumerate(lines):
        if long_tag_re.match(line):
            long_tag_indices.append(idx)

    entries: List[ParsedEntry] = []
    for pos, idx in enumerate(long_tag_indices):
        # Parse forward from the current long-tag row only, to avoid bleeding metadata
        # from the previous variable entry into the current one.
        start = idx
        end = long_tag_indices[pos + 1] if pos + 1 < len(long_tag_indices) else len(lines)
        block = lines[start:end]
        long_idx_in_block = idx - start
        raw_block_text = "\n".join(line.rstrip() for line in block).strip() or None

        long_tag = get_field(block, "Long tag")
        if not long_tag:
            continue

        original_tag = get_field(block, "Original tag")
        dataset_citation = get_field(block, "Dataset citation")
        variable_citation = get_field(block, "Variable citation")
        description_full = get_field(block, "Description")
        description = strip_description_sections(description_full)
        # Heading is often above "Long tag:" so we search in a context window that
        # includes lines immediately before this block start.
        context_start = max(0, idx - 50)
        context_block = lines[context_start:end]
        context_long_idx = idx - context_start
        title = extract_heading(context_block, context_long_idx)
        additional_versions = find_additional_versions(raw_block_text)
        question = extract_description_section(raw_block_text, "QUESTION")
        clarification = extract_description_section(raw_block_text, "CLARIFICATION")
        scale = extract_description_section(raw_block_text, "SCALE")
        sources = extract_description_section(raw_block_text, "SOURCE(S)")
        data_release = extract_description_section(raw_block_text, "DATA RELEASE")
        aggregation = extract_description_section(raw_block_text, "AGGREGATION")
        cross_coder_aggregation = extract_description_section(raw_block_text, "CROSS-CODER AGGREGATION")
        country_year_aggregation = extract_description_section(raw_block_text, "COUNTRY-YEAR AGGREGATION")

        # Keep raw heading context if available (for debugging/troubleshooting).
        heading_raw = None
        for i in range(context_long_idx - 1, -1, -1):
            m = HEADING_RE.match(context_block[i].strip())
            if m:
                heading_raw = m.group(1).strip()
                break

        entries.append(
            ParsedEntry(
                dataset=dataset,
                source_pdf=source_pdf,
                dataset_tag=dataset_tag_at_line[idx],
                heading_raw=heading_raw,
                title=title,
                long_tag=long_tag,
                original_tag=original_tag,
                dataset_citation=dataset_citation,
                variable_citation=variable_citation,
                description=description,
                description_full=description_full,
                raw_block_text=raw_block_text,
                additional_versions=additional_versions,
                question=question,
                clarification=clarification,
                scale=scale,
                sources=sources,
                data_release=data_release,
                aggregation=aggregation,
                cross_coder_aggregation=cross_coder_aggregation,
                country_year_aggregation=country_year_aggregation,
            )
        )

    return entries


# ---------------------------------------------------------------------------
# Credits: who to cite for the data, read from the same codebook
# ---------------------------------------------------------------------------
#
# Each source dataset section carries a prose "Dataset citation:", but it is
# typed by hand and goes stale: QoG's Standard section still cites version
# Jan25 under a Jan26 export. What a variable entry cites -- "Dataset citation:
# Teorell et al. (2026b)", "Variable citation: World Bank (2024)" -- is generated
# against the bibliography in the codebook's last chapter, so the bibliography
# is what the credits are read from, and those short references say which of its
# works the loaded variables actually rest on.

# "2     QOG", "3     Bibliography". The table of contents spells the same
# headings with a single space, which keeps it from matching.
CHAPTER_RE = re.compile(r"^(\d+)\s{2,}(\S.*?)\s*$")
SECTION_HEADING_RE = re.compile(r"^\d+\.\d+\s+(\S.*?)\s*$")
ANY_HEADING_RE = re.compile(r"^\d+(?:\.\d+)+\s+\S")
PAGE_HEADER_RE = re.compile(r"^\s*TOC\s+\d+\s*$")
# "(2026)", "(2026b)", "(n.d.)"
REFERENCE_RE = re.compile(r"(.+?)\((\d{4}[a-z]?|n\.d\.)\)")
URL_PREFIXES = ("http://", "https://")
# Every Demscore bibliography entry repeats the infrastructure's funding line;
# the credits say it once for all modules (indicatorNote), not once per work.
FUNDING_RE = re.compile(
    r"\s*\b[\w-]+(?: Data)? is part of\s+and funded by DEMSCORE\b[^.]*?Swedish Research Council\."
)


@dataclass
class SourceDataset:
    dataset: str
    source_pdf: str
    project_name: Optional[str]
    project_url: Optional[str]
    dataset_tag: str
    title: Optional[str]
    license: Optional[str]


@dataclass
class BibliographyEntry:
    dataset: str
    entry_no: int
    citation: str
    url: Optional[str]
    authors: str
    year: str


@dataclass
class CitationLink:
    dataset: str
    long_tag: str
    entry_no: int
    role: str


def without_page_headers(lines: List[str]) -> List[str]:
    """Drop each page's running head: the "TOC <page>" line and the lines under it."""
    out: List[str] = []
    in_header = False
    for line in lines:
        line = line.lstrip("\x0c")
        if PAGE_HEADER_RE.match(line):
            in_header = True
            continue
        if in_header:
            if line.strip():
                continue
            in_header = False
        out.append(line)
    return out


def join_wrapped(parts: List[str]) -> str:
    """Join lines pdftotext wrapped, without breaking a hyphenated name or a URL."""
    text = ""
    for part in parts:
        part = collapse_spaces(part)
        if not part:
            continue
        last_token = text.rsplit(" ", 1)[-1]
        if not text:
            text = part
        elif re.search(r"[^\W\d_]-$", text):
            text += part
        elif last_token.startswith(URL_PREFIXES) and (part[0].islower() or part[0].isdigit() or part[0] == "/"):
            text += part
        else:
            text += " " + part
    return text


def collect_paragraphs(lines: List[str]) -> Optional[str]:
    paragraphs: List[List[str]] = [[]]
    for line in lines:
        if line.strip():
            paragraphs[-1].append(line)
        elif paragraphs[-1]:
            paragraphs.append([])
    text = "\n\n".join(join_wrapped(p) for p in paragraphs if p).strip()
    return text or None


def parse_source_datasets(lines: List[str], source_pdf: str, dataset: str) -> List[SourceDataset]:
    lines = without_page_headers(lines)
    tag_indices = [i for i, line in enumerate(lines) if line.strip().startswith("Dataset tag:")]
    if not tag_indices:
        return []

    # The project is the chapter the first source dataset sits in; its opening
    # prose ends on the project's website.
    project_name = None
    project_url = None
    chapter_start = 0
    for i in range(tag_indices[0], -1, -1):
        m = CHAPTER_RE.match(lines[i])
        if m:
            project_name = m.group(2)
            chapter_start = i
            break
    intro = lines[chapter_start:tag_indices[0]]
    for i, line in enumerate(intro):
        m = re.search(r"website:\s*(\S*)", line)
        if not m:
            continue
        project_url = m.group(1) or next((l.split()[0] for l in intro[i + 1:] if l.strip()), None)
        break

    sources: List[SourceDataset] = []
    for pos, idx in enumerate(tag_indices):
        tag = lines[idx].split(":", 1)[1].strip()
        title = None
        for i in range(idx - 1, -1, -1):
            if lines[i].strip():
                m = SECTION_HEADING_RE.match(lines[i].strip())
                title = m.group(1) if m else None
                break

        end = tag_indices[pos + 1] if pos + 1 < len(tag_indices) else len(lines)
        license_lines: List[str] = []
        for i in range(idx + 1, end):
            stripped = lines[i].strip()
            if not license_lines:
                if stripped.startswith("License:"):
                    license_lines.append(stripped.split(":", 1)[1])
                continue
            if stripped.startswith("More detailed information") or ANY_HEADING_RE.match(stripped) \
                    or CHAPTER_RE.match(lines[i]):
                break
            license_lines.append(lines[i])

        sources.append(SourceDataset(
            dataset=dataset,
            source_pdf=source_pdf,
            project_name=project_name,
            project_url=project_url,
            dataset_tag=tag,
            title=title,
            license=collect_paragraphs(license_lines),
        ))
    return sources


def parse_bibliography(lines: List[str], dataset: str) -> List[BibliographyEntry]:
    lines = without_page_headers(lines)
    start = None
    for i, line in enumerate(lines):
        m = CHAPTER_RE.match(line)
        if m and m.group(2).lower() == "bibliography":
            start = i + 1
    if start is None:
        return []

    # An entry starts flush left and its wrapped lines are indented.
    raw_entries: List[List[str]] = []
    for line in lines[start:]:
        if CHAPTER_RE.match(line):
            break
        if not line.strip():
            continue
        if not line[0].isspace() or not raw_entries:
            raw_entries.append([line])
        else:
            raw_entries[-1].append(line)

    entries: List[BibliographyEntry] = []
    for raw in raw_entries:
        url = None
        parts: List[str] = []
        for line in raw:
            stripped = line.strip()
            if stripped.startswith("URL:"):
                url = stripped.split(":", 1)[1].strip() or None
            elif url is not None and " " not in stripped:
                url += stripped
            else:
                parts.append(stripped)
        text = join_wrapped(parts)
        m = REFERENCE_RE.match(text)
        if not m:
            continue
        citation = FUNDING_RE.sub("", text)
        citation = re.sub(r"\.\s+\.", ".", citation)
        citation = re.sub(r"\s+([.,])(?=\s|$)", r"\1", citation).strip()
        entries.append(BibliographyEntry(
            dataset=dataset,
            entry_no=len(entries) + 1,
            citation=citation,
            url=url,
            authors=m.group(1).strip(),
            year=m.group(2),
        ))
    return entries


def split_references(text: str) -> List[Tuple[List[str], str]]:
    """'Teorell et al. (2019), Coppedge, Gerring & Ziblatt (2026)' -> name lists and years."""
    refs: List[Tuple[List[str], str]] = []
    for m in REFERENCE_RE.finditer(text):
        authors = re.sub(r"^[\s,;]*(?:(?:and|&)\s+)?", "", m.group(1))
        authors = re.sub(r"\bet al\.?", "", authors)
        names = [n.strip() for n in re.split(r",|&|\band\b", authors) if n.strip()]
        if names:
            refs.append((names, m.group(2)))
    return refs


def resolve_reference(names: List[str], year: str, bibliography: List[BibliographyEntry]) -> List[BibliographyEntry]:
    candidates = [
        e for e in bibliography
        if e.year == year and e.authors.casefold().startswith(names[0].casefold())
    ]
    if len(candidates) <= 1:
        return candidates
    # V-Dem's dataset and codebook are both "Coppedge ... (2026)", told apart only
    # by who is on the author list.
    def score(entry: BibliographyEntry) -> int:
        authors = entry.authors.casefold()
        return sum(1 for n in names if n.casefold() in authors)
    best = max(score(e) for e in candidates)
    return [e for e in candidates if score(e) == best]


def link_citations(
    entries: List[ParsedEntry], bibliography: List[BibliographyEntry]
) -> Tuple[List[CitationLink], List[str]]:
    links: Dict[Tuple[str, str, int], CitationLink] = {}
    unresolved: List[str] = []
    for e in entries:
        for role, text in (("dataset", e.dataset_citation), ("variable", e.variable_citation)):
            if not text:
                continue
            for names, year in split_references(text):
                matches = resolve_reference(names, year, bibliography)
                if not matches:
                    unresolved.append(f"{e.dataset}: {names[0]} ({year}) in {e.long_tag}")
                for match in matches:
                    key = (e.long_tag, role, match.entry_no)
                    links.setdefault(key, CitationLink(e.dataset, e.long_tag, match.entry_no, role))
    return list(links.values()), sorted(set(unresolved))


def write_rows(path: str, rows: List[object]) -> None:
    fieldnames = list(rows[0].__dataclass_fields__) if rows else []
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({k: ("" if v is None else v) for k, v in vars(row).items()})


def write_csv(entries: List[ParsedEntry], output_csv: str) -> None:
    fieldnames = [
        "dataset",
        "source_pdf",
        "dataset_tag",
        "heading_raw",
        "title",
        "long_tag",
        "original_tag",
        "dataset_citation",
        "variable_citation",
        "description",
        "description_full",
        "raw_block_text",
        "additional_versions",
        "question",
        "clarification",
        "scale",
        "sources",
        "data_release",
        "aggregation",
        "cross_coder_aggregation",
        "country_year_aggregation",
    ]
    with open(output_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for e in entries:
            writer.writerow(
                {
                    "dataset": e.dataset,
                    "source_pdf": e.source_pdf,
                    "dataset_tag": e.dataset_tag or "",
                    "heading_raw": e.heading_raw or "",
                    "title": e.title or "",
                    "long_tag": e.long_tag,
                    "original_tag": e.original_tag or "",
                    "dataset_citation": e.dataset_citation or "",
                    "variable_citation": e.variable_citation or "",
                    "description": e.description or "",
                    "description_full": e.description_full or "",
                    "raw_block_text": e.raw_block_text or "",
                    "additional_versions": e.additional_versions or "",
                    "question": e.question or "",
                    "clarification": e.clarification or "",
                    "scale": e.scale or "",
                    "sources": e.sources or "",
                    "data_release": e.data_release or "",
                    "aggregation": e.aggregation or "",
                    "cross_coder_aggregation": e.cross_coder_aggregation or "",
                    "country_year_aggregation": e.country_year_aggregation or "",
                }
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract metadata from Demscore codebook text files.")
    parser.add_argument("--output-csv", required=True, help="Path to output CSV.")
    parser.add_argument(
        "--input",
        action="append",
        required=True,
        help="Input pair as <text_path>::<source_pdf_path> (repeatable).",
    )
    parser.add_argument("--sources-csv", help="Path to output CSV: one row per source dataset section.")
    parser.add_argument("--bibliography-csv", help="Path to output CSV: one row per bibliography entry.")
    parser.add_argument(
        "--citations-csv",
        help="Path to output CSV: which bibliography entries each variable entry cites.",
    )
    args = parser.parse_args()

    all_entries: List[ParsedEntry] = []
    all_sources: List[SourceDataset] = []
    all_bibliography: List[BibliographyEntry] = []
    all_links: List[CitationLink] = []
    all_unresolved: List[str] = []
    for item in args.input:
        if "::" not in item:
            raise ValueError(f"Invalid --input value: {item}. Expected <text_path>::<source_pdf_path>")
        txt_path, source_pdf = item.split("::", 1)
        dataset = parse_dataset_key(source_pdf)
        entries = parse_text_file(txt_path, source_pdf, dataset)
        all_entries.extend(entries)

        with open(txt_path, "r", encoding="utf-8", errors="replace") as f:
            lines = [normalize_line(line) for line in f]
        all_sources.extend(parse_source_datasets(lines, source_pdf, dataset))
        bibliography = parse_bibliography(lines, dataset)
        all_bibliography.extend(bibliography)
        links, unresolved = link_citations(entries, bibliography)
        all_links.extend(links)
        all_unresolved.extend(unresolved)

    write_csv(all_entries, args.output_csv)
    if args.sources_csv:
        write_rows(args.sources_csv, all_sources)
    if args.bibliography_csv:
        write_rows(args.bibliography_csv, all_bibliography)
    if args.citations_csv:
        write_rows(args.citations_csv, all_links)

    # Print a compact summary for operator visibility.
    per_dataset: Dict[str, int] = {}
    for e in all_entries:
        per_dataset[e.dataset] = per_dataset.get(e.dataset, 0) + 1
    summary = ", ".join(f"{k}={v}" for k, v in sorted(per_dataset.items()))
    print(f"Extracted variable metadata entries: {len(all_entries)} ({summary})")
    print(
        f"Extracted credits: {len(all_sources)} source datasets, "
        f"{len(all_bibliography)} bibliography entries, {len(all_links)} citation links"
    )
    # A reference no bibliography entry answers to is a work the credits cannot
    # name. scripts/build_attribution.sh fails if that leaves a dataset with no
    # citation at all; anything short of that is reported here.
    for line in all_unresolved:
        print(f"  unresolved citation: {line}")


if __name__ == "__main__":
    main()
