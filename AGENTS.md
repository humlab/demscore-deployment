# AGENTS.md

This document explains how the Demscore system is built, how its parts fit together, and how to work safely in this repository.

## 1) System Overview

Demscore is a mapping stack with an optional cache layer:

1. PostGIS database (`db`) stores source datasets and geographic boundaries.
2. MapServer (`mapserver`) exposes a WMS layer that renders data-driven hexagons.
3. Static web app (`web`) uses OpenLayers to request and display the WMS layer.
4. Optional WMS cache proxy (`mapcache`) can sit in front of MapServer.

The system turns tabular democracy indicator data into a thematic global hex map.

## 2) Architecture and Data Flow

1. CSV datasets are mounted into the DB container from `data/Demscore_Module_Vars`.
2. `scripts/load_demscore_module_vars.sh` loads CSVs into a typed long-format model:
   - `demscore.variables` (`dataset`, `variable`)
   - `demscore.dataset_values` (`variable_id`, `year`, `iso3`, `country_name`, `value`, `country_id`)
   - every `u_`-prefixed CSV column is an identifier (country, year, and the various country
     code systems), not an indicator, and is excluded from the melt; excluding only the three
     read by name once let `u_vdem_country_year_country_id` and friends become variables
   - `-11111` is Demscore's marker for an observation lost in the translation to the requested
     unit of analysis, not a measurement, and is filtered out (`MISSING_CODE`). Loading it put
     8402 rows of it into REPDEM, where `ntile()` classed them lowest and `AVG()` folded them
     into the hex average, dragging the legend floor to -11111. The variables insert reads the
     same filtered rows, so a column left with nothing — the ones whose real values are text,
     like `cab_name`, `elecdate`, `date_in` — is never registered; the load names each one it
     dropped
   - a variable that is an exact subset of another in the same dataset is dropped, so QoG's
     twelve `qog_oecd_ts_*` columns give way to their global `qog_std_ts_*` twins instead of
     doubling the variable list under the codebook's identical titles. Redundancy is proved
     per variable, not assumed: if a later export revises one product and not the other, the
     load warns and keeps both
   - REPDEM's ten `repdem_wecee_*` twins are *superseded* rather than redundant — the codebook
     has `repdem_basic` (PAGED Basic) updated in-house for more countries, more years and more
     variables through late-2025, while `wecee` stops at 2019/2021 — so they are marked
     `demscore.variables.hidden` instead of deleted. The rows stay queryable and a direct WMS
     request still renders them; they only leave the list the web client offers. Deleting would
     be wrong: `basic` revises `wecee`'s figures (disagreeing on up to 16% of shared
     country-years for `num_parties`) and, pooled over all years `wecee` adds no country, but
     the map draws one year at a time and nine country-year cells sit only in `wecee` —
     Ireland 2020 in `cab_composition2`, where `basic` carries 2025 in its place. The load
     prints that count rather than claiming the twin adds nothing
3. `scripts/load_variable_metadata.sh` enriches variables with codebook metadata:
   - converts each dataset `codebook.pdf` to text (`pdftotext -layout`)
   - parses entries using `scripts/extract_variable_metadata.py`
   - loads parsed rows into `demscore.variable_metadata_raw`
   - resolves matches to `demscore.variables` and stores final metadata in `demscore.variable_metadata`,
     in four passes recorded in `matched_by`, each declining to overwrite an earlier one:
     `direct` (data column = codebook long tag), `vdem_prefix` (long tag minus `vdem_cy_`),
     `vdem_additional_versions[_combo]` (V-Dem `_codelow`/`_codehigh`/`_sd` variants expanded
     from `ADDITIONAL VERSIONS`), and `original_tag` (data column = the codebook's *original*
     short tag, e.g. `bti_su` for `qog_std_ts_bti_su`) — the last is restricted to short tags
     naming exactly one block per dataset, since QoG documents most indicators once per unit
     and shares short tags like `fh_rol` between `qog_std_ts_*` and `qog_oecd_ts_*`
   - a final pass disambiguates titles: where one dataset documents the same title under more
     than one `dataset_tag`, the differing part of the tag is appended, so REPDEM's genuinely
     distinct twins read "Cabinet seat share (basic)" and "... (wecee)" rather than twice the
     same words. It is driven by the collision *among visible variables*, so a unique title is
     left alone, V-Dem (one tag) is untouched, and hiding REPDEM's `wecee` twins takes the
     `(basic)` suffixes away again without editing this rule
   - a clean run ends with `unmatched_rows = 0`; anything else is a variable the web client can
     only show as its raw key, with no hover card
4. Two Natural Earth layers are imported by `ogr2ogr` in `scripts/setup_mapserver_hex_service.sh`:
   - `demscore.countries_src` from `ne_110m_admin_0_countries.geojson` — country identity
     (name, ISO codes) and the untrimmed outline
   - `demscore.country_units_src` from `ne_110m_admin_0_map_units.geojson` — the same
     sovereigns split into geographic units, which is what makes overseas territories
     separable from the mainland
5. `sql/mapserver_hex_setup.sql`:
   - normalizes country geometry into `demscore.countries` (4326 + 8857), taking identity
     from `countries_src` and geometry from the map units dissolved per `adm0_a3`, minus
     overseas units — one that carries its own ISO code while its sovereign is drawn as
     several units (French Guiana, Svalbard). Without this a country's hexagons land on
     territories an ocean away; with it, France is metropolitan France plus Corsica.
     Sovereigns drawn as a single unit are always kept, so Western Sahara (`SAH`/`ESH`)
     and South Sudan (`SDS`/`SSD`) survive despite `adm0_a3` differing from their ISO code.
   - remaps `demscore.dataset_values.country_id` to the current country table (ISO3 first, then name fallback)
   - precomputes hex meshes into `demscore.hex_mesh` for supported hex sizes
   - precomputes `demscore.hex_borders`, one row per mesh per pair of neighbouring countries
     (and one per country for the edges facing nothing), holding the hexagon edges between
     them. Every other edge sits between two hexagons of the same country, can never separate
     two colours, and is dropped. Dataset, variable and year do not enter into it, so the
     render-time cost of an outline is a filter rather than a dissolve
   - defines `demscore.hex_variable(...)` to join precomputed hex geometry with selected dataset values and compute quantile classes
6. MapServer layer `hex_variable` calls `demscore.hex_variable(...)` dynamically using WMS params and applies bbox filtering inside the SQL subquery.
   Layer `hex_outline` draws the black perimeter around each *area* of one colour — a run of
   touching hexagons in the same class, so two neighbouring countries the legend paints the
   same shade are one area — by keeping the `hex_borders` rows whose two sides fall in
   different classes. A country absent from `country_scores` reads as a NULL class, so an area
   that is not drawn is not outlined either. The client asks for it by naming both layers.
7. `scripts/build_variable_coverage.sh` precomputes `webapp/config/variable_coverage.json`:
   - reads per-variable, per-year country counts once
   - buckets them onto one shared year axis per dataset (~40 bars), so two rows in
     the same list are read against the same scale
   - each bar is one digit `0`-`9`: `0` is no data, and `1`-`9` scale how much data
     sits in that window — missing years and thin country coverage both pull it down
   - the variable list draws a strip under every row at once, so it cannot afford the
     live per-year aggregate the map's own timeline runs for the one selected variable
   - the same data backs the COVERAGE block at the foot of the variable hover card,
     which adds the axis years and an explanation the row itself has no room for
8. The map UI sends WMS requests with `dataset`, `variable`, `year` and `hex_size`, naming
   the layer pair that belongs to the projection it is drawing in.

## 3) Tech Stack

- Container orchestration: `podman compose` workflow (Compose file is Docker Compose format)
- Database: PostgreSQL 16 + PostGIS 3.4 (`postgis/postgis:16-3.4`)
- Spatial server: MapServer 8.4 (`camptocamp/mapserver:8.4`)
- Web server: Nginx 1.27 Alpine (`nginx:1.27-alpine`)
- Frontend: Vanilla JS + OpenLayers 10.10.0 + proj4 2.22.0 + static HTML/CSS
- GIS import tooling: `ogr2ogr` (required by setup script)

## 4) Repository Map

- `compose.yml`: service definitions, ports, mounts, cache toggle wiring
- `initdb/01_extensions.sql`: bootstrap PostGIS extensions
- `scripts/load_demscore_module_vars.sh`: CSV-to-table loader
- `scripts/dev_up.sh`: starts core services and conditionally includes `mapcache` based on `.env`
- `scripts/extract_variable_metadata.py`: robust parser for codebook text blocks and variable metadata fields
- `scripts/load_variable_metadata.sh`: PDF-to-DB metadata load pipeline for variable titles/citations/descriptions
- `scripts/setup_mapserver_hex_service.sh`: full environment + geometry + SQL setup + smoke tests
- `scripts/build_variable_coverage.sh`: precomputes the variable list's coverage strips
  into `webapp/config/variable_coverage.json` (run by the setup script; rerun it after
  any load that changes which years or countries a variable covers)
- `sql/mapserver_hex_setup.sql`: core DB objects and hex function
- `mapserver/mapserver.map`: WMS config and style classes
- `mapserver/README.md`: WMS parameter contract
- `webapp/index.html`, `webapp/app.js`, `webapp/styles.css`: UI
- `webapp/config/variables.json`: dataset presentation metadata — `label`, `title`, `color`,
  `palette` (five shades, darkest first), `codebook`, `image`, `defaultVariable`. The variable
  lists and year spans in it are only a fallback: `getVariablesConfig()` builds those from
  `demscore.variables`, then `overlayDatasetPresentation()` lays this file's presentation keys
  over the result. Before that overlay existed the database path never read the file at all, so
  anything added here was silently ignored and `DATASET_META` in `web-backend/server.js` was the
  real source
- `webapp/config/variable_coverage.json`: generated coverage strips, served as
  `/api/config/variable-coverage`
- `webapp/config/variable_topics.json`: the curated cross-dataset topics the variable list's
  filter chips are built from, served as `/api/config/variable-topics`. Hand-maintained, not
  generated: the codebook section a variable sits under is dataset-scoped and, for this
  selection, mostly one variable per section, so it seeds the grouping but cannot be it.
  Demscore's own 13 published Thematic Datasets were tested against this selection and fit it
  badly — five themes match nothing here, seven variables land in no theme at all (including
  four of the five V-Dem democracy indices, since there is no Democracy theme), and all eleven
  REPDEM variables collapse into one. `topic_classification.wip.md` has the counts and method
- `mapcache/cache-enabled.conf`, `mapcache/cache-disabled.conf`: reverse-proxy WMS gateway
  configs; the same `/mapserver` route passes through or caches tiles based on
  `DEMSCORE_ENABLE_MAPCACHE`
- `data/`: input datasets + reference boundaries
- `data/reference/`: Natural Earth boundaries — `ne_110m_admin_0_countries.geojson`
  (identity + web-backend land basemap) and `ne_110m_admin_0_map_units.geojson` (hex geometry)

## 5) Runtime Interfaces

### Service endpoints

- Web app: `http://127.0.0.1:8090`
- MapServer WMS via router/cache gateway: `http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map`
- Server-side tile caching: set `DEMSCORE_ENABLE_MAPCACHE=1` in `.env`; with `0`,
  the same route is a no-store pass-through for development
- PostgreSQL: `127.0.0.1:5532` (db/user/password default: `demscore`)

### Web backend endpoints

Config payloads (`/api/config/*`, listed in `webapp/AGENTS.md`) are files on disk. The two
database-backed reads are `/api/config/variables` and `/api/class-breaks`; the latter answers
the legend's hover card with the quantile class spans for one dataset/variable/year, validated
the same way the mapfile validates its own parameters.

### WMS parameter contract

Accepted parameters for `hex_variable` and `hex_outline`:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: alphanumeric/underscore (`^[A-Za-z0-9_]+$`)
- `year`: four digits
- `hex_size`: 5-7 digit integer
- `polarity`: `positive` | `negative` | `neutral`, read by `hex_variable` only

MapServer applies validation defaults; SQL additionally clamps:

- year: `1500..2100`
- hex size: `20000..300000` meters (Equal Earth metres, so the same real area anywhere)

Advertised CRS: `EPSG:4326`, `EPSG:8857` and `EPSG:3857`, with WMS 1.1.1 (`SRS`, not `CRS`),
which sidesteps 1.3.0's axis-order rules. Each layer narrows that to the one plane its mesh
was cut in: `hex_variable` / `hex_outline` serve `EPSG:8857` and
`hex_variable_mercator` / `hex_outline_mercator` serve `EPSG:3857`. A layer is never
reprojected into the other plane, because a hexagon is a hexagon only in the plane it was
cut in — see the note above `hex_variable_mercator` in the mapfile.

## 6) Local Setup and Operations

### Prerequisites

- `podman` + compose support
- `ogr2ogr` on host PATH
- `curl`

### Typical startup

Set cache toggle in `.env`:
- `DEMSCORE_ENABLE_MAPCACHE=0` (no server/browser tile cache)
- `DEMSCORE_ENABLE_MAPCACHE=1` (enable server/browser tile cache)

1. Start services:
   - `./scripts/dev_up.sh`
2. Load datasets:
   - `./scripts/load_demscore_module_vars.sh`
3. Setup map-ready DB objects and smoke tests:
   - `./scripts/setup_mapserver_hex_service.sh`

`setup_mapserver_hex_service.sh` also checks:

- DB readiness
- function result sanity
- WMS `GetCapabilities`
- WMS `GetMap` response

## 7) Developer Guidelines

### Data and schema changes

- Loader is the canonical ingest path: it recreates `demscore.variables` and `demscore.dataset_values` from CSV headers.
- `demscore.dataset_values` is the normalized value layer. If dataset column names change, update loader extraction logic first.
- `demscore.variable_metadata` is the UI-facing dictionary layer (human titles, citations, descriptions, provenance).
- `demscore.variable_metadata_raw` is a refreshable staging table for parsed codebook output.
- `demscore.hex_mesh` stores precomputed geometry for `hex_size` values 20000..300000 (step 5000).
- `demscore.hex_borders` is derived from `demscore.hex_mesh` and is rebuilt with it. It matches
  the two sides of an edge by exact geometry, which holds because `ST_HexagonGrid` makes every
  country's mesh part of one global grid; a change that gave countries their own grids would
  silently leave every hexagon outlined on its own.
- Everything spatial is EPSG:8857, Equal Earth. One hexagon is one real area anywhere on
  the map, which is the only reading under which a hexagon count means anything; Web
  Mercator scaled area by sec^2(latitude) and the mesh inherited it, so Russia carried
  795 hexagons across 17.0M km2 while Brazil carried 85 across 8.5M.
  - there is a second mesh, `demscore.hex_mesh_mercator`, cut in EPSG:3857 by
    `sql/mapserver_hex_mercator.sql`, and the web app's projection toggle switches to it.
    It is a second mesh and not the first one reprojected: a hexagon is a hexagon only in
    the plane it was cut in, and an Equal Earth cell pushed into Mercator is drawn twice as
    tall as it is wide by 60N and as a sliver by 80N. What the toggle compares is what a
    cell *means* — a fixed amount of ground against a fixed amount of screen — so the
    Mercator mesh is the old distortion on purpose, kept alongside rather than in place of
    the real one. Its size ladder is 40k-600k step 10k, exactly twice the Equal Earth one,
    which is what makes the two the same grain: Mercator 200k gives 5 917 cells against
    Equal Earth 100k's 5 690.
  - `demscore.countries.geom_3857` *is* clipped at `+/-85.05112878`, for the same reason
    `geom_8857` is not: that latitude is where Web Mercator's y runs off to infinity.
  - the size ladder is deliberately half the old Mercator one. A Mercator hexagon covered
    ground area proportional to cos^2(latitude), so the old sizes were counting on a
    surplus of hexagons near the poles; halved, the meshes land within 4% of the old
    counts at every stop the app uses while carrying real areas.
  - `demscore.countries.geom_8857` has no latitude clip. The old `+/-85.05112878` cut was
    Web Mercator's limit, not the world's.
- Deriving a world extent by transforming the `(-180,-90)` and `(180,90)` corners gives a
  box 41% too narrow. Equal Earth is widest on the equator (x = `+/-17243959`) and
  narrowest at the poles (`+/-10216474`); y runs to `+/-8392927`. Every extent in the
  stack -- mapfile, preloader, `webapp/src/core/projection.js` -- comes from those numbers.
- Preserve join quality in `hex_variable`: ISO3 matching is primary; name matching is fallback.
- `webapp/config/variable_coverage.json` is derived from `demscore.dataset_values`. It is a
  build artifact, not a source of truth, and goes stale silently: rerun
  `scripts/build_variable_coverage.sh` after any reload.
- If changing numeric parsing logic, test null/invalid values explicitly.

### Map rendering changes

- Update `mapserver/mapserver.map` for style/class behavior.
- Keep WMS validation regex aligned with backend expectations.
- If adding request params, update both:
  - MapServer `VALIDATION`
  - SQL function signature/logic
  - Frontend request builder

### Frontend changes

- `webapp/config/variables.json` is the source of dataset/variable/year UI metadata.
- `webapp/app.js` is intentionally framework-free; keep it dependency-light.
- Preserve mobile layout behavior in `styles.css` (`@media (max-width: 900px)`).

## 8) Quality and Safety Checklist

Before merging changes:

1. Run setup smoke flow (`./scripts/setup_mapserver_hex_service.sh`).
2. Confirm `GetCapabilities` and one `GetMap` request succeed.
3. Verify the web UI can switch dataset, variable, year, and hex size.
4. Validate SQL changes with at least one query for each dataset (`qog`, `repdem`, `v_dem`).

## 9) Known Constraints and Risks

- Source CSV fields are imported as text in transient staging tables; numeric conversion is done during ingest into `demscore.dataset_values`.
- Codebook PDFs are semi-structured; metadata extraction is heuristic by design. Keep parser stop markers and label handling conservative.
- Country matching can miss rows if ISO/name values drift from Natural Earth naming.
- The two Natural Earth layers are joined on `adm0_a3` and currently agree exactly (177 each).
  A country present in `countries_src` but absent from the map units keeps its untrimmed
  outline rather than disappearing.
- The land basemap deliberately keeps overseas territories: they are real land, they just
  must not inherit the sovereign's indicator value.
- Precomputing `hex_mesh` across all supported sizes increases setup time and storage footprint.
- Coverage strips are normalized against the busiest year in their own dataset, so bar
  heights compare rows within a dataset and mean nothing across datasets — RepDem's
  fullest year reaches 32 countries where V-Dem's reaches 165.
- Dynamic SQL surface is partially constrained by MapServer regex validation; keep validation strict.
- No automated test suite currently exists; scripts provide operational smoke tests only.

## 10) Recommended Next Improvements

1. Add repeatable automated checks (SQL assertions + WMS HTTP smoke tests) in CI.
2. Add a small integration test script that validates map output for all three datasets.
3. Consider materializing heavy intermediate results if response time degrades on larger datasets.
4. Add data dictionary docs per dataset for easier variable onboarding.
