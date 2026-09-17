# Classifying variables into topics — findings & open questions

Status: **investigated, not started.** Paused before implementation on 2026-09-16.
Re-investigated 2026-09-17 against Demscore's live site — see [§7 Second pass](#7-second-pass-2026-09-17).
The §3 plan is sound but §7.3 argues its *output* is thinner than expected; read §7 before building.

Covers the todo item:

> classify variables into topics — use "cb section"(?) (prob. codebook section) values to categorize

Decisions already taken (see [Decisions taken](#decisions-taken)): group **within** each dataset,
with a curated override layer on top of the codebook sections.

---

## 1. What "cb section" turned out to be

Confirmed: it is the **codebook section**. The Demscore v7 codebooks are numbered four levels
deep, and each level means something different:

| Depth | Example | Meaning |
|---|---|---|
| `2` | `2 V-DEM` | dataset |
| `2.1` | `2.1 QoG OECD Dataset Time-Series` | module / sample |
| `2.1.3` | `2.1.3 Judicial` | **section — this is the topic** |
| `2.1.3.1` | `2.1.3.1 Rule of Law (fh_rol)` | the variable entry |

### The section is currently thrown away

`scripts/extract_variable_metadata.py` already walks these headings, but loses the part we need:

- `SECTION_START_RE` (line 53) matches `\d+(?:\.\d+){2,}`, i.e. **3 or more** numeric parts — so it
  matches section headings (`2.1.3`) and variable headings (`2.1.3.1`) alike, with no way to tell
  them apart.
- `HEADING_RE` (line 51) captures only the text *after* the number; the number is discarded.
- `extract_heading()` scans backwards from `Long tag:` and stops at the **first** match, which is
  always the variable's own depth-4 heading.

So `demscore.variable_metadata.heading_raw` holds the *variable's* heading (e.g.
`Rule of Law (fh_rol)`), never the section's. Nothing in the DB currently carries the section.

### Coverage is exact — verified, not assumed

Counting depth-4 headings against `Long tag:` blocks per codebook:

| Codebook | depth-4 headings | `Long tag:` blocks |
|---|---|---|
| QoG | 25 | 25 |
| REPDEM | 29 | 29 |
| V-Dem | 17 | 17 |

Every documented variable sits under exactly one section. No fuzzy matching, no unclassified
leftovers. V-Dem's 141 rows in `demscore.variables` expand from those 17 codebook entries via the
existing variant expansion, so variants inherit their parent's section for free through
`source_long_tag`.

### The sections that exist

**QoG (6)** — Conflict and Military Service · Public Economy · Judicial · Gender Equality ·
Quality of Government · Education

**V-Dem (9)** — V-Dem Democracy Indices - V-Dem High-Level Democracy Indices ·
V-Dem Indicators - The Executive · - The Legislature · - Deliberation · - The Judiciary ·
- Civil Society · - The Media · Other Indices Created Using V-Dem Data - Academic Freedom ·
Digital Society Survey - Coordinated Information Operations

**REPDEM (1 topic, 2 names)** — `Cabinet Information` (Basic) and `Information on the Cabinets`
(PAGED). Same topic, worded differently per module. All 29 RepDem variables fall in it.

---

## 2. Parsing notes (validated against the real `pdftotext -layout` output)

A prototype run over all three codebooks confirmed these three rules are sufficient:

1. **Body headings start at column 0.** The repeated running page header
   (`  2.1 V-Dem Country-Year: V-Dem Full+Others v16`) is indented by two spaces, so column
   position alone separates real headings from page furniture.
2. **Skip the TOC** by dropping lines with dot leaders (` . . . `) or a trailing page number
   (`\s{2,}\d{1,3}$`). Both TOCs (Summary and full) are removed cleanly by this.
3. **Reject prose starting with a number.** One real false positive exists: V-Dem line 176 is
   `23 Regional Managers, 134 Country Coordinators and more than 4000 Country Experts, the V-Dem`,
   which parses as a depth-1 heading numbered 23. Requiring each heading number to be a valid
   successor of the current stack rejects it.

With those rules the prototype produced a correct section for all 71 variable entries.

---

## 3. Proposed implementation

### 3.1 Capture the section during parse — `scripts/extract_variable_metadata.py`

Add a pre-pass that walks the lines once, maintains a heading stack keyed by numeric depth, and
annotates each `Long tag:` line index with the enclosing `section_number`, `section_title`,
`module_number`, `module_title`. Four new `ParsedEntry` fields and CSV columns.

Add an assertion that depth-4 headings == `Long tag:` blocks per codebook, so a future codebook
revision that changes the numbering fails loudly instead of silently mislabelling everything.

### 3.2 Schema and load — `scripts/load_variable_metadata.sh`

Four new columns on `demscore.variable_metadata_raw` and `demscore.variable_metadata`, with
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for existing DBs (matching how the other late columns
were added, lines 142-152), carried through all four match passes. The script is `DROP`/`TRUNCATE`
based, so re-running it is idempotent.

### 3.3 Topic resolution — new `webapp/config/variable_topics.json`

Mirrors the shape of `webapp/config/variable_polarity.json`, which the frontend already knows how
to consume (exact `variable_overrides` plus a `rules` regex list):

- `section_labels` — display names, shortening V-Dem's compound sections
  (`V-Dem Indicators - The Executive` → `The Executive`) while the DB keeps the raw value.
- `variable_overrides` / `rules` — the curated layer, seeded for RepDem from the groupings already
  written down in `data/Demscore_Module_Vars/List.docx`: Cabinet Characteristics,
  Formation & Duration, Parliament Structure, Temporal Markers.

The codebook section stays the default; the config only overrides.

### 3.4 Expose it — `web-backend/server.js`

`fetchVariableMetadataSummaryFromDb` (line 213) currently returns `{variable: title}`. Add a
sibling `sections` map and an ordered `section_order` array rather than changing the shape of the
`variables` map, so nothing downstream breaks. Same shape added to the `variable_metadata.json`
file-fallback, plus a `/api/config/variable-topics` route alongside the existing config routes.

### 3.5 Render the groups — `webapp/src/controllers/MetadataController.js`

`refreshVariables` (line 968) groups `mainVariables` by resolved topic and emits a heading before
each run. Sections in codebook order; variables alphabetical within a section, preserving current
behaviour. Headings take `role="presentation"` so the `radiogroup` semantics, roving tabindex,
variant carets and hover tooltips keep working. `scrollSelectedVariableIntoView` is `offsetTop`
based and needs no change. Sticky headings in the scrolling list, styled in `webapp/styles.css`.

### 3.6 Verify

Re-run `scripts/load_variable_metadata.sh`; assert zero NULL sections and distinct-section counts
of 6 / 2 / 9; then load the app and check the three dataset tabs.

---

## 4. Open questions

1. **`bti_su` (Sustainability) is filed under "Education"** in the QoG Standard module (§2.2.2.1).
   That looks like a codebook error rather than a real classification — it is a Bertelsmann
   Transformation Index sustainability score. The override layer can correct it. Report the
   codebook faithfully, or reassign it? *(Not decided.)*

2. **QoG and RepDem each split into two modules** (OECD/Standard, Basic/PAGED), so the same section
   title appears twice per dataset. Proposal: group by section *title* and order by the lowest
   section number, merging the twins under one heading — consistent with how the variable list
   already pairs `qog_std_ts_*` / `qog_oecd_ts_*` rows via `collectSharedTitles`. *(Proposed, not
   confirmed.)*

3. **How far to shorten the V-Dem section names.** `Other Indices Created Using V-Dem Data -
   Academic Freedom` → `Academic Freedom` drops the provenance, which may matter to some readers.
   `Digital Society Survey - Coordinated Information Operations` has the same issue. *(Not
   decided.)*

---

## 5. Decisions taken

- **Group within each dataset**, not a cross-dataset topic taxonomy. The dataset tabs stay as they
  are; section headings are inserted into the existing variable list. Smallest change, faithful to
  the codebook, no harmonisation of dataset-scoped names needed (QoG `Judicial` vs V-Dem
  `V-Dem Indicators - The Judiciary` never have to be reconciled).
- **Curated override layer for RepDem**, rather than leaving it as a single bucket or hiding
  single-section headings. Codebook section is the default; the JSON config overrides.

---

## 6. Related todo items

These touch the same code and may be worth doing in the same pass:

- *"remove the variants from the Varieties of Democracy variables"* — would cut V-Dem from 141 rows
  to 17, one per codebook entry, which is exactly one per depth-4 heading. Makes the grouped list
  far shorter.
- *"add demscore download links to the variables in the interface"* — also needs per-variable
  metadata plumbed through `fetchVariableMetadataSummaryFromDb`, the same function §3.4 touches.


---

## 7. Second pass (2026-09-17)

Triggered by the observation that demscore.se exposes a **"Codebook Section Name"** column at
`/data_analysis/menu_all_codebook`.

### 7.1 "cb section" is now confirmed, not inferred

That page is a DataTable fed by `GET https://www.demscore.se/data_analysis/ajax_all_codebook`
(no auth, ~487 KB JSON). Its rows are literally:

```json
{"cb_section_id": 1155, "dataset_name": "COMPLAB GRACE - Governing the Anthropocene",
 "cb_section_name": "Identifiers", "cb_section_intro": "Variables in this section identify...",
 "num_vars": 5}
```

The field is named **`cb_section_name`**. The meeting note's "cb section" is this, verbatim —
no longer an educated guess. Registry-wide: 838 sections over 193 datasets, 314 distinct names.

### 7.2 We already have it locally — the site is confirmation, not a dependency

The site registry lists **every** section of each full module; our `codebook.pdf` files are
*custom codebooks* covering only our downloaded variable selection, so they carry a subset.
That subset matches the registry exactly:

> all **23** section headings parsed from our three PDFs appear verbatim in `ajax_all_codebook`
> under the same `dataset_name` — 23/23, no near-misses.

The PDFs are also the *better* source: `cb_section_intro` comes back as raw LaTeX for V-Dem
(`\textbf{\underline{Instructions to the coders...}}`), while `pdftotext` yields it already
rendered. So no scraping is needed; §3.1 stands as written. `cb_section_id` is the one thing
only the API has, if stable section identity is ever wanted.

The §2 parse rules were re-run independently and reproduced **71/71 entries classified, 0
unclassified** (QoG 25, REPDEM 29, V-Dem 17), confirming §1 and §2.

### 7.3 The catch: for *our* selection the sections are mostly singletons

§3 was planned without counting what the headings would actually caption. Counting only
variables the loader leaves **visible** (OECD twins dropped, `wecee` twins hidden, text-valued
columns never registered):

| Dataset | Visible vars | Sections | Distribution |
|---|---|---|---|
| QoG | 13 | 6 | 4, 3, 3, **1, 1, 1** |
| REPDEM | 11 | 1 | 11 |
| V-Dem | 15 (base, post-variant-removal) | 9 | 5, 2, 2, **1, 1, 1, 1, 1, 1** |

**9 of the 16 headings would caption exactly one variable**, and REPDEM's single heading
captions its entire list — zero information in both cases. The "remove V-Dem variants" todo
makes this *worse*, not better: it takes V-Dem from 141 rows to 15, i.e. 9 headings over 15 items.

This does not invalidate §3 — the classification is correct and exact. It means the classification
is finer-grained than a 39-variable list can use.

### 7.4 A second candidate the meeting did not mention: Thematic Datasets

Demscore publishes 13 **cross-dataset** topics at `/data/thematic-datasets/`, which "assemble a
wide range of variables from datasets across all partnering Modules related to a selected topic":

> Gender · Environment · Political Parties and Elections · Migration · Unemployment · Media ·
> Education · Corruption · Security and Violence · Economic Development · Health · Peace ·
> Laws and Liberties

These are variable-level and curated by Demscore, and they cut *across* modules — which suits an
explorative interface better than a per-dataset hierarchy (a user exploring "gender" does not care
which module the variable came from).

Cost: membership lists are not in our data and not on the theme pages; each theme has its own
codebook PDF that would need downloading and parsing, and our 39 variables may not all appear in one.

Note the convergence: the **full** QoG module vocabulary in the registry (Health, Environment,
Media, Migration, Labour Market, Political Parties and Elections, Gender Equality, Education,
Judicial, Public Economy, …) is already close to the thematic list. The two taxonomies are
related, which makes a curated cross-dataset topic set cheap to seed from the sections we parse.

### 7.5 Revised recommendation

Keep §3.1–3.2 (parse and store `cb_section_*`) — it is exact, cheap, locally sourced, and useful
metadata regardless of how it is displayed. **Reconsider §3.5**: rather than rendering sections as
headings inside each dataset tab, use the parsed section as the *seed* for a small curated
cross-dataset topic set (~6–8 topics over 39 variables), which is what §5's "explorative interface"
goal actually calls for. That reopens the §5 decision "group within each dataset".

This supersedes open question 2 (§4) and makes question 3 moot if V-Dem's compound section names
are folded into curated topics instead of displayed raw.

Open question 1 (`bti_su` under Education) is **confirmed real**: QoG codebook §2.2.2.1 is
`Sustainability (bti_su)` sitting under §2.2.2 `Education`. A curated topic layer resolves it
without having to contradict the codebook in the DB.


---

## 8. Cross-dataset topics — tested against the real data (2026-09-17)

Decision from §7.5 accepted: go with cross-dataset topics. This section tests whether Demscore's
13 published themes can be used **as-is**. They cannot. Evidence, then a proposal.

### 8.1 Method

All 13 thematic codebooks were downloaded (linked from each `/data/thematic-datasets/…` page,
e.g. `/documents/746/gender_codebook.pdf`) and their `Long tag:` sets extracted. They use the
**same long-tag namespace** as our module codebooks, so membership is an exact set test, not a
fuzzy match. Our 39 visible variables were looked up in each.

### 8.2 Result: the published themes fit our selection badly

| Theme | Our vars | Theme size |
|---|---|---|
| Political Parties and Elections | 11 | 1576 |
| Corruption | 7 | 140 |
| Media | 5 | 159 |
| Education | 5 | 363 |
| Economic Development | 5 | 1250 |
| Laws and Liberties | 4 | 268 |
| Gender | 2 | 312 |
| Security and Violence | 2 | 258 |
| Environment · Migration · Unemployment · Health · Peace | **0** | 496 / 1300 / 642 / 256 / 4 |

Four problems:

1. **5 of 13 themes are empty** for our selection.
2. **7 of 39 variables have no theme at all** — including *four of the five V-Dem high-level
   democracy indices* (Liberal, Participatory, Deliberative, Egalitarian). There is no "Democracy"
   theme, presumably because all of Demscore is about democracy. For this map, where those indices
   are the headline layers, that is disqualifying on its own.
3. **Membership is noisy for our purpose.** `v2x_polyarchy` (Electoral Democracy Index) matches
   *only* Corruption; `v2xca_academ` (Academic Freedom) matches Media + Education + Corruption.
   The thematic datasets assemble broad variable sets including controls, so presence in a theme
   is not a claim about what the variable measures.
4. **Political Parties and Elections swallows all 11 REPDEM variables**, reproducing exactly the
   single-bucket problem §7.3 identified.

Conclusion: use the 13 themes as **vocabulary inspiration**, not as the assignment. Curate.

### 8.3 Proposed curated set — 11 topics, 39 variables, no orphans

Primary assignment is one topic per variable; `+x` counts variables cross-listed into the topic
from elsewhere. Draft data: `scripts/…/topics_proposal.json` (currently in scratchpad).

| Topic | Vars | +x | Datasets |
|---|---|---|---|
| Democracy Indices | 5 | – | V-Dem |
| Rule of Law & Justice | 4 | – | QoG + V-Dem |
| Corruption | 3 | – | QoG + V-Dem |
| Media & Expression | 4 | – | V-Dem |
| Civil Society | 2 | – | V-Dem |
| Cabinets & Government | 6 | – | REPDEM |
| Parliament & Party System | 5 | 1 | REPDEM (+V-Dem) |
| Economy & Development | 3 | 1 | QoG |
| Education | 3 | – | QoG |
| Gender | 1 | 1 | QoG |
| State Capacity & Security | 3 | 1 | QoG |

Four topics now span more than one dataset, which is the whole point of the exercise. Only
**Gender** is a singleton on primary assignment, and cross-listing `wdi_gersf` lifts it to 2.

### 8.4 Open design questions

1. **Multi-membership or a strict tree?** Cross-listing solves the singleton problem and suits
   faceted exploration, but rules out a plain tab/tree UI. Recommended: allow it, and render
   topics as filters rather than as an exclusive hierarchy.
2. **11 topics or ~8?** Merging (Corruption + State Capacity → "Governance & Corruption",
   Civil Society + Media, Education + Gender) gives ~8 topics of ~5. Denser, but loses Gender as a
   browsable facet. `bicc_gmi` (militarization) is the awkward one in every merge variant.
3. **What happens to the dataset tabs?** If topic becomes the primary axis, dataset demotes to a
   badge on each row plus an optional secondary filter. That is a bigger UI change than §3.5.
4. **Where does the mapping live?** A curated JSON like `variable_polarity.json`, seeded from
   `cb_section` (§3.1) — the parsed section stays useful as the seed and as fallback for variables
   added later.
