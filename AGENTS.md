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
4. Reference boundaries are imported by `ogr2ogr` in `scripts/setup_mapserver_hex_service.sh`:
   - `demscore.countries_src` from `ne_50m_admin_0_countries.geojson` — country identity
     (name, ISO codes) and the untrimmed outline
   - `demscore.country_units_src` from `ne_50m_admin_0_map_units.geojson` — the same
     sovereigns split into geographic units, which is what makes overseas territories
     separable from the mainland
   - `demscore.cshapes_src` from `CShapes-2.0.geojson` — time-bounded historical country
     geometry for source observations whose country-year unit no longer exists in Natural
     Earth's current-country layer
   - `demscore.cshapes_europe_src` from `CShapes-Europe.geojson` — the same project's
     European series from 1816, which is where the pre-unification German and Italian
     states come from. The import renames its columns to `cshapes_src`'s names, and gives
     the FID a column of its own: CShapes-Europe reuses one Gleditsch-Ward code across
     every period of a country, so `ogr2ogr`'s default promotion of a field called `Id`
     to the primary key collides on the second period of the first country
   - `demscore.historical_basemaps_src` from `historical_basemaps/world_{1783,1800,1815}.geojson`
     — world snapshots, all three in one table with the snapshot year as a column
4b. `sql/historical_geometry.sql` builds the two tables that decide what a source
    observation is allowed to become:
   - `demscore.historical_country_geometries_src`, the curated geometry registry. One row
     per (entity, year span, polygon), carrying `source_dataset`, `source_license`,
     `source_url`, `source_citation`, `source_snapshot_year`, `valid_from_year`,
     `valid_to_year` and a `confidence` grade. It holds its own copy of every polygon
     rather than pointing at the upstream tables, because a snapshot reconstruction and a
     period-aware boundary can only share a table if each carries its own provenance. One
     entity's periods may not overlap, which is an exclusion constraint rather than a check
     somebody remembers to run — an overlap would draw the same country twice
   - `demscore.country_resolution_policy`, which replaces `demscore.country_aliases`. One
     row per (dataset, source entity, year window) with a `status` of `natural_earth`,
     `cshapes`, `historical_registry` or `intentionally_unsupported`. The last is the
     reason the table exists: an alias could say "map this to that" but had no way to say
     "this one is not representable, and here is why", so the difference between a decision
     and an oversight was invisible
5. `sql/mapserver_hex_setup.sql`:
   - normalises country geometry into `demscore.countries` (4326 + 8857), taking identity
     from `countries_src` and geometry from the map units dissolved per `adm0_a3`, minus
     overseas units — one that carries its own ISO code while its sovereign is drawn as
     several units (French Guiana, Svalbard). Without this a country's hexagons land on
     territories an ocean away; with it, France is metropolitan France plus Corsica.
     Sovereigns drawn as a single unit are always kept, so Western Sahara (`SAH`/`ESH`)
     and South Sudan (`SDS`/`SSD`) survive despite `adm0_a3` differing from their ISO code.
  - remaps `demscore.dataset_values.country_id` to the country table, running
    `demscore.country_resolution_policy` first (`natural_earth`, then `cshapes`, then
    `historical_registry`) and only then the source's own ISO3 and country name against
    present-day countries. Policy goes first because it is a decision somebody wrote down
    and an ISO3 that happens to equal a Natural Earth code is two code lists agreeing by
    accident; when they disagree the decision has to win, or a policy row narrowing an
    entity to part of its span would be quietly overtaken on the rest. An
    `intentionally_unsupported` row then clears any `country_id` a later pass set, so a
    refusal is enforced rather than merely hoped for. Rows still unmatched are kept and
    summarised in `demscore.dataset_value_unmapped_audit`, never silently deleted, and
    that table's `resolution_status` says whether the row is `intentionally_unsupported`
    (a policy names it and gives a reason) or `unresolved` (nothing does).
    `scripts/check_country_resolution.sh` fails setup on the second kind
   - precomputes hex meshes into `demscore.hex_mesh` for supported hex sizes
   - precomputes the outline candidates as two tables: `demscore.hex_border_edges`, one row
     per hexagon edge that could ever separate two colours, and `demscore.hex_border_sides`,
     one row per country with hexagons on that edge, carrying how many. Every other edge has
     hexagons of one country on it only, can never separate two colours, and is dropped —
     two thirds of them. It takes two tables rather than a `country_a`/`country_b` pair
     because an edge can have more than two sides: displaced cells overlap, and
     the CShapes historical countries lay a second mesh over the current one (6 740 Soviet
     Union cells over Russia and its neighbours at 50 km). Dataset, variable and year do not
     enter into it, so the render-time cost of an outline is a filter rather than a dissolve
   - defines `demscore.hex_variable(...)` to join precomputed hex geometry with selected dataset values and compute quantile classes
6. MapServer layer `hex_variable` calls `demscore.hex_variable(...)` dynamically using WMS params and applies bbox filtering inside the SQL subquery.
   Layer `hex_outline` draws the black stroke around each rendered colour area and around each
   rendered country/coding-unit boundary. It restricts `hex_border_sides` to the countries this
   request renders and keeps edges that then carry a single hexagon (a perimeter, with the
   background on the other side), more than one country/coding unit, or more than one class. A
   country absent from `country_scores` drops out of the sides, so an area that is not drawn is
   not outlined either. The client asks for it by naming both layers.
7. `scripts/build_variable_coverage.sh` precomputes `webapp/config/variable_coverage.json`:
   - reads per-variable, per-year country counts once
   - buckets each variable across its own first-to-last year (~40 bars, one per year where
     the span is shorter than that), so every strip fills its row. The row writes those two
     years underneath the strip, which is what makes a scale nobody shares readable; bar
     height is still normalised per dataset, so heights compare within a dataset and
     positions compare nowhere
   - each bar is one digit `0`-`9`: `0` is no data, and `1`-`9` scale how much data
     sits in that window — missing years and thin country coverage both pull it down
   - the variable list draws a strip under every row at once, so it cannot afford to
     ask the database per row; the same file also sets the height of the main
     timeline's read-ahead marks, so one variable reads as one shape in both places.
     On the timeline a mark's height is that coverage and its fill is how much of
     those years is in the tile cache -- one row, two readings
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
- `scripts/dev_up.sh`: starts core services and conditionally includes `mapcache` based on `.env`,
  then calls `sync_db_password.sh`
- `scripts/sync_db_password.sh`: `ALTER ROLE` over the trusted unix socket so the `demscore`
  role's password matches `POSTGRES_PASSWORD` in `.env`
- `scripts/extract_variable_metadata.py`: robust parser for codebook text blocks and variable metadata fields
- `scripts/load_variable_metadata.sh`: PDF-to-DB metadata load pipeline for variable titles/citations/descriptions
- `scripts/setup_mapserver_hex_service.sh`: full environment + geometry + SQL setup + smoke tests
- `scripts/clear_map_tile_cache.sh`: empties the server-side WMS tile cache and reloads
  nginx. The one place that command is written; `setup_mapserver_hex_service.sh` calls it
  after rebuilding the mesh, `preload_mapcache_tiles.sh --clear` calls it before warming,
  and `./deploy.sh clear-map-tile-cache` is the hand-run form. A preload on its own never
  clears: it only requests tiles, and a URL the cache holds is served from the cache
- `scripts/build_variable_coverage.sh`: precomputes the variable list's coverage strips
  into `webapp/config/variable_coverage.json` (run by the setup script; rerun it after
  any load that changes which years or countries a variable covers)
- `scripts/build_hex_classes.mjs`: generates `mapserver/hex_classes.inc` from
  `webapp/src/core/palettes.js`, which is where every quantile colour is written. The colours
  have to exist in two languages -- MapServer paints the map, the browser paints the legend
  that is the key to it -- so one is generated from the other rather than kept in step by
  hand. `--check` fails instead of writing, for CI
- `scripts/check_palette_contrast.mjs`: reads the colours out of `mapserver/hex_classes.inc`
  *and* out of `webapp/src/core/palettes.js`, fails if the two disagree, and measures every
  adjacent class pair in greyscale and under simulated protanopia, deuteranopia and
  tritanopia. Plain `node`, no dependencies. Run it after any change to a colour, or to the
  interface colour tokens it also checks
- `country_polygon_considerations.md`: what the country geometry is, where it is
  approximate and which of those approximations matter — the per-entity register of
  known inaccuracies, the V-Dem coding units that change territory mid-series, the
  overlapping-entity cases that look like rendering faults, and the licence consequences.
  Read it before quoting the map on a pre-1886 country
- `ACCESSIBILITY.md`: what the accessibility work covers, the manual keyboard and
  screen-reader checklist to run before a release, and what is still missing
- `scripts/check_country_resolution.sh`: reports source-versus-map coverage, lists the
  entities this deployment intentionally does not draw, and **fails** if any source
  observation is unmapped without a policy row saying why. Also runs regression assertions
  over the cases that are easy to get wrong — Palestine, Zanzibar, Vietnam and the pre-1850
  European states, each of which changes geometry source partway through its own series.
  Run by the setup script, and safe to run on its own at any time
- `sql/historical_geometry.sql`: the curated historical geometry registry and the
  resolution policy. Runs before `mapserver_hex_setup.sql`, which reads both
- `sql/mapserver_hex_setup.sql`: core DB objects and hex function
- `mapserver/mapserver.map`: WMS config and style classes
- `mapserver/README.md`: WMS parameter contract
- `webapp/index.html`, `webapp/app.js`, `webapp/styles.css`: UI
- `webapp/config/variables.json`: dataset presentation metadata — `label`, `title`, `color`,
  `palette` (five shades, darkest first), `codebook`, `download`, `image`, `defaultVariable`.
  `download` is Demscore's own downloader replaying a saved *download ID*, one per module, and
  the ID is the selection this deployment loads: its `data.csv` carries the same columns as
  `data/Demscore_Module_Vars/<module>`. It is per-dataset because nothing finer exists — the
  portal's variable browser (`menu_all_variables`) is a DataTables grid that reads no query
  string, so no URL can name a variable. The variable
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
- `data/reference/`: Natural Earth 50m boundaries — `ne_50m_admin_0_countries.geojson`
  (identity + web-backend land basemap), `ne_50m_admin_0_map_units.geojson` (hex geometry),
  and `ne_50m_admin_0_tiny_countries.geojson` (point support for countries too small to
  read well as polygons). `CShapes-2.0.geojson` adds historical country geometry for
  country-year observations that cannot honestly be drawn on current borders;
  `CShapes-Europe.geojson` extends that back to 1816 for Europe; and
  `historical_basemaps/world_{1783,1800,1815}.geojson` covers what neither reaches.
  `data/reference/README.md` is the licence and citation register — two of the four
  sources carry conditions that reach the tiles rendered from them, so read it before
  adding or removing one

## 5) Runtime Interfaces

### Service endpoints

- Web app: `http://127.0.0.1:8090` (port set by `DEMSCORE_ROUTER_PORT` in `.env`,
  default `8090`)
- MapServer WMS via router/cache gateway: `http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map`
- Server-side tile caching: set `DEMSCORE_ENABLE_MAPCACHE=1` in `.env`; with `0`,
  the same route is a no-store pass-through for development
- PostgreSQL: `127.0.0.1:5532` (db/user/password default: `demscore`)

### Web backend endpoints

Config payloads (`/api/config/*`, listed in `webapp/AGENTS.md`) are files on disk. The
database-backed reads are `/api/config/variables`, `/api/class-breaks` and `/api/map-data`.
The last two take the same `dataset`/`variable`/`year` triple the map's WMS request carries
and validate it the same way the mapfile validates its own parameters (`readMapStateQuery`),
so an unknown dataset is a 400 rather than a silent fall back to `v_dem`:

- `/api/class-breaks` — the seven quantile class spans behind the legend bar, plus
  `countriesWithData` and `countriesTotal`. The totals ride along because the map's spoken
  summary needs them and this request is already made for every variable-year the map draws
- `/api/map-data` — one row per country on the map (name, ISO3, value, class, no-data), for
  the accessible data table. It is a `LEFT JOIN` from the whole country table on purpose: a
  country with no value for this year is a reading of the data, and a table that quietly
  omitted it would look complete while being wrong. Each row also carries
  `historical`, `validFromYear`/`validToYear`, `geometrySource` and
  `geometryConfidence`: a hexagon drawn on an 1815 snapshot and one drawn on a present-day
  border are the same picture, and this is the only place a reader can be told which
- `/api/source-coverage` — what the source measured for this variable-year against what the
  map can draw of it. `sourceCountries`, `mappedCountries`, `unrepresentedCountries`,
  `mappedByGeometryConfidence`, and `unrepresented[]` naming each entity with the reason
  this deployment cannot represent it. It exists because the two routes above can only see
  countries that have geometry, which makes "the source never measured this" and "this
  deployment cannot draw it" indistinguishable — and those are opposite facts. Backed by
  `demscore.source_coverage()`

### WMS parameter contract

Accepted parameters for `hex_variable` and `hex_outline`:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: alphanumeric/underscore (`^[A-Za-z0-9_]+$`)
- `year`: four digits
- `hex_size`: 5-7 digit integer
- `polarity`: `positive` | `negative` | `neutral`, read by the fill layers only
- `palette`: `default` | `indigo_amber` | `viridis` | `cividis`, read by the fill layers
  only. Which colour scheme paints the hexagons -- a reader's choice, not a deployment
  setting, since colour is the map's whole encoding and about one man in twelve cannot use
  the red-green channel the default leans on. Mechanically an offset on `class_idx` applied
  per scheme and polarity in the `DATA` query; see `mapserver/README.md` and
  `webapp/src/core/palettes.js`

MapServer applies validation defaults; SQL additionally clamps:

- year: `1500..2100`
- hex size: `20000..300000` metres (Equal Earth metres, so the same real area anywhere)

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
- `demscore.dataset_values` is the normalised value layer. If dataset column names change, update loader extraction logic first.
- `demscore.country_resolution_policy` is the curated crosswalk, and it replaced
  `demscore.country_aliases`. Use it for explicit source-name or source-code fixes such as
  REPDEM `Czechia -> CZE`, for historical mappings into CShapes `gwcode`s, for entities the
  curated registry covers, and — the case an alias table could not express — for entities
  this deployment refuses to draw, which need a `reason` saying why. Do not map historical
  countries onto successor states unless the product requirement explicitly chooses that
  aggregation, and do not resolve two source coding units onto one country row:
  `demscore.country_scores()` would average them together. V-Dem codes both a
  pre-partition Vietnam and a northern one for 1945-1953, which is why the former is a
  registry country of its own rather than an alias onto modern Vietnam.
- `demscore.historical_country_geometries_src` is where historical polygons live. A row is
  one entity for one year span, with its source, licence, citation, snapshot year (if it
  came from one) and confidence grade. Grade honestly: `high` only for a period-aware
  source used inside its own period, `medium` for such a polygon carried across years the
  coding-unit history documents as unchanged, `low` for a snapshot or for a polygon known
  to draw the wrong extent — and a `low` row must say in `notes` what it is getting wrong.
  The table enforces both: a snapshot row cannot be graded above `low`, and a `low` row
  cannot have empty notes.
- `demscore.dataset_value_unmapped_audit` is rebuilt by map setup and is the required report
  for source observations that still cannot be represented. Its `resolution_status` is
  `intentionally_unsupported` or `unresolved`, and `scripts/check_country_resolution.sh`
  fails setup on any `unresolved` row. A non-empty audit table is allowed only for entities
  that have a policy row explaining the refusal.
- **Adding a dataset, or taking a newer export of one, can introduce a source country
  nothing covers.** Setup will fail rather than ship a map whose universe silently differs
  from the source's; the check prints each entity with its years and value count, and the
  fix is a registry entry plus a `historical_registry` policy row, or an
  `intentionally_unsupported` row. Rerunning `scripts/build_variable_coverage.sh` after
  that is still required, since the coverage strips are derived from the same values.
- `demscore.variable_metadata` is the UI-facing dictionary layer (human titles, citations, descriptions, provenance).
- `demscore.variable_metadata_raw` is a refreshable staging table for parsed codebook output.
- `demscore.hex_mesh` stores precomputed geometry for `hex_size` values 20000..300000 (step 5000).
- `demscore.hex_border_edges` and `demscore.hex_border_sides` are derived from
  `demscore.hex_mesh` and are rebuilt with it. They match the sides of an edge by exact
  geometry, which holds because `ST_HexagonGrid` makes every country's mesh part of one global
  grid; a change that gave countries their own grids would silently leave every hexagon
  outlined on its own.
- **The outline layers must read `hex_count` from `hex_border_sides`, never from the hexagons a
  request returns.** MapServer substitutes `!BOX!` with the extent of pixel *centres*, half a
  pixel smaller than the tile on every side, so a query that decides "nothing on the other
  side" from what its own box returned mistakes the rim of the box for the rim of the map and
  strokes a dashed line along every tile seam. `ST_Expand(!BOX!, %hex_size%)` in those layers
  is only so a border just outside the tile still lays its half of the stroke in the edge
  pixels; nothing about which edges are drawn depends on it.
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
    the real one. Its size ladder is 40k-600k step 10k, twice the Equal Earth one, but
    the app asks both projections for the *same* three sizes (200k/100k/50k): both count
    in Web Mercator's resolution ladder, so a cell is drawn `hex_size_m / resolution`
    pixels across in either plane and an equal size is an equal grain on screen. The
    counts then differ on purpose — 5 917 Mercator cells at 200k against 1 396 in Equal
    Earth — because that surplus is the distortion being shown. The stops used to be
    doubled for Mercator to make the totals match, which only bought the matching number
    by drawing every Mercator cell twice as wide.
  - **a historical country borrows a cell, it never takes one.** The dealing passes below
    move cells between countries, which is right while the mesh is a partition among the
    countries on the map at once. The historical rows are not part of that partition: they
    are an overlay, drawn for the years they were in force and invisible otherwise, so a
    cell one of them took would be gone from a present-day country in *every* year.
    Germany fell from 11 cells to 6 at 100 km when the pre-unification states arrived, and
    Ukraine had already lost four to the Soviet Union before that. The claim logic is
    unchanged; only the eviction is conditional, on both sides of the transfer being
    `natural_earth`. Two countries then hold the same geometry, which is what the Soviet
    mesh lying over Russia has always been and which the border tables already allow for.
  - **every hexagon is one size, at every stop, always** — that is the rule the whole
    mesh exists to keep, since a hexagon count only means something when one cell is one
    fixed real area. Two passes in `sql/mapserver_hex_setup.sql` get as many countries
    onto the map as that allows. A cell is kept when its centre
    falls inside the country; left at that, whether a small country is on the map is a
    lottery on the global grid's phase, and Denmark had one cell at 200k and none at
    100k. So a country that wins none is given the cells that hold the most of it (over
    the border on purpose, at most what its own area could fill, never a neighbour's last
    cell); then whatever is still empty takes a cell anyway, displacing a neighbour that
    holds less of it — which cannot ping-pong, because a cell only ever moves to a country
    holding more of it.
  - **a country the cells cannot seat is not drawn at that size.** At the coarsest sizes
    some regions hold more countries than cells covering them — the western Balkans at
    200k — so no dealing of cells can seat them all, and the leftovers wait for a finer
    stop. Measured: 34 data-carrying coding units undrawn at 200k (23 distinct
    names — Slovenia, Luxembourg, Montenegro, North Macedonia, Kosovo, San Marino,
    Liechtenstein, three Caribbean states, the four Palestine units and eight
    pre-unification German and Italian states), 5 at 100k (the Palestine units and
    Saint Kitts and Nevis), none at 50k.
    There used to be an `inset` pass instead, giving them a hexagon from the grid one
    notch finer drawn on top of the cell below, by a layer of its own (`hex_inset`).
    It was removed: it broke the one-size rule, and at 200k a quarter-area cell with a
    perimeter of its own read as a rendering fault sitting inside a neighbour's hexagon
    rather than as a country. The picture is the only place they are missing —
    `demscore.country_scores()` is unchanged, so `/api/map-data`, `/api/class-breaks`,
    the spoken summary and the accessible data table carry them at every zoom.
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
  - the web client draws *less* than that box. `viewExtent` in `projection.js` cuts
    everything south of 60S, and it is what the world fit and the pan limit are
    measured against; nothing below carries an indicator value, since the southernmost
    land outside Antarctica is Chile at 55.6S and Antarctica is on the basemap but in
    no dataset. The full box stays as the tile grid's, because a tile coordinate is a
    slice of it and narrowing it would rename every tile and void both caches. The
    crop is worth 29% of Web Mercator's square world and, in Equal Earth, only a pan
    limit at ordinary window shapes -- see the projection notes in `webapp/AGENTS.md`.
- Preserve join quality in `hex_variable`: ISO3 matching is primary; name matching is fallback.
- `webapp/config/variable_coverage.json` is derived from `demscore.dataset_values`. It is a
  build artefact, not a source of truth, and goes stale silently: rerun
  `scripts/build_variable_coverage.sh` after any reload.
- If changing numeric parsing logic, test null/invalid values explicitly.

### Map rendering changes

- Update `mapserver/mapserver.map` for style/class behaviour.
- Keep WMS validation regex aligned with backend expectations.
- If adding request params, update both:
  - MapServer `VALIDATION`
  - SQL function signature/logic
  - Frontend request builder

### Frontend changes

- `webapp/config/variables.json` is the source of dataset/variable/year UI metadata.
- `webapp/app.js` is intentionally framework-free; keep it dependency-light.
- Preserve mobile layout behaviour in `styles.css` (`@media (max-width: 900px)`).

### Colour changes

- **`webapp/src/core/palettes.js` is where colours are written, and the only place.** It
  defines the four schemes the reader can pick between, the seven-class bands they are built
  from, and which `class_idx` base each band occupies. `mapserver/hex_classes.inc` is
  *generated* from it — edit the JavaScript, run `node scripts/build_hex_classes.mjs`, never
  edit the `.inc`. `scripts/check_palette_contrast.mjs` reads both and fails if they have
  drifted, so a hand-edited `.inc` is caught even by someone who never runs the generator.
- A band's `base` is permanent. It is part of every cached tile — the scheme rides in the
  request URL and both caches key on the URL — so renumbering a band changes no URL and both
  caches go on serving the old colours under the new legend. Add a band at a fresh base;
  never reuse one.
- **Changing a colour inside an existing band invalidates every cached tile for it.** The
  tiles carry the colours, not just the geometry, and nothing in the URL changes when a colour
  does. Clear the server cache
  (`./deploy.sh clear-map-tile-cache`, or `./deploy.sh --preload N --clear` to empty and warm
  it in one run) **and bump `WMS_TILE_CACHE` in `webapp/sw.js`**. A reload does not reach the service worker's copy:
  Cache Storage is keyed by URL and is only shed when the cache's *name* changes, so a tile
  whose contents changed under an unchanged URL stays a cache hit forever. The same applies to
  any change that repaints a tile without changing its URL -- a colour, a class boundary, the
  outline rule.
- Adding a scheme means: a band in `palettes.js`, the generator, a `WHEN` arm in the four
  `DATA` strings in the mapfile, and the `palette` regex in the four `VALIDATION` blocks. The
  client needs nothing — the picker, the legend, the cookie and the spoken summary are all
  driven from `MAP_PALETTES`.

## 8) Quality and Safety Checklist

Before merging changes:

1. Run setup smoke flow (`./scripts/setup_mapserver_hex_service.sh`).
2. Confirm `GetCapabilities` and one `GetMap` request succeed.
3. Verify the web UI can switch dataset, variable, year, and hex size.
4. Validate SQL changes with at least one query for each dataset (`qog`, `repdem`, `v_dem`).
4b. Run `./scripts/check_country_resolution.sh` if anything touched country matching,
   the resolution policy, the historical registry or the reference geometry. It fails on
   any source observation that lost its geometry, and its regression cases cover the
   entities whose territory moves under them.
5. Run `node scripts/build_hex_classes.mjs --check` and
   `node scripts/check_palette_contrast.mjs` if any colour moved.
6. Run the keyboard pass in `ACCESSIBILITY.md` if any control, dialog or focus behaviour
   moved. There is no automated accessibility check yet, so that list is the check.

## 9) Known Constraints and Risks

- Source CSV fields are imported as text in transient staging tables; numeric conversion is done during ingest into `demscore.dataset_values`.
- Codebook PDFs are semi-structured; metadata extraction is heuristic by design. Keep parser stop markers and label handling conservative.
- Country matching can miss rows if ISO/name values drift from Natural Earth naming.
  Setup now fails rather than absorbing that silently — see
  `scripts/check_country_resolution.sh`.
- Eleven of the 67 historical country-periods rest on `low`-confidence outlines: world
  snapshots asked to stand for a span of years, or a polygon drawn at the wrong extent
  because no vendored source carries the right one. Mostly this is a difference the map
  cannot express anyway -- six of the eleven are one hexagon at every size the app offers,
  and Baden before 1816 is drawn five times too large and is one hexagon either way. Two
  of them are not about precision but about territory: Two Sicilies before 1816 includes
  Sicily, which V-Dem's unit did not, and that is 6 of its 17 hexagons at 50 km.
  `country_polygon_considerations.md` has the measurements and the per-entity register.
- Two of the four boundary sources are non-commercial or copyleft — see
  `data/reference/README.md`. The hex meshes and the rendered tiles are derivatives of
  them.
- V-Dem's Republic of Vietnam (1802-1953, the whole country) and Vietnam (North Vietnam
  from 1945) overlap for nine years, so both are drawn on the same ground for 1945-1953.
  That is the same overlap CShapes already produces for the Soviet Union over Russia, and
  it is in the source rather than in the mapping.
- One source entity is intentionally undrawn: V-Dem's South Yemen before 1967, which codes
  the city of Aden (192 km2) and later the western Federation of South Arabia. The only
  available polygon is the whole People's Democratic Republic, some 287 000 km2.
  OpenHistoricalMap carries dated Aden Colony relations under CC0 if this is picked up.
- The two Natural Earth layers are joined on `adm0_a3` and currently agree exactly (177 each).
  A country present in `countries_src` but absent from the map units keeps its untrimmed
  outline rather than disappearing.
- The land basemap deliberately keeps overseas territories: they are real land, they just
  must not inherit the sovereign's indicator value.
- Precomputing `hex_mesh` across all supported sizes increases setup time and storage footprint.
- Coverage strips are normalised against the busiest year in their own dataset, so bar
  heights compare rows within a dataset and mean nothing across datasets — RepDem's
  fullest year reaches 33 countries where V-Dem's reaches 179 and QoG's 193. V-Dem's
  figure moved from 165 when the historical registry made its pre-1886 states drawable,
  which is the coverage strips going stale in exactly the way the note above them warns
  about: they are derived from `country_id`, so anything that changes what maps changes
  them.
- Dynamic SQL surface is partially constrained by MapServer regex validation; keep validation strict.
- `POSTGRES_PASSWORD` initialises the `demscore` role once, when the `pg_data` volume is
  created, and lives in the volume from then on; changing `.env` afterwards does not reach
  it. Nothing in `scripts/` notices, because they all reach the database as
  `podman compose exec db psql`, over the unix socket the postgres image's `pg_hba.conf`
  trusts. The mismatch surfaces only where a container connects over TCP, which
  scram-sha-256 guards -- `ogr2ogr` in the setup script first, then `mapserver` and
  `web-backend` -- as `password authentication failed for user "demscore"`.
  `scripts/sync_db_password.sh`, run on every `dev_up.sh`, reconciles the two.
- No automated test suite currently exists; scripts provide operational smoke tests only.
- The map is a WMS image, so nothing in it can be reached by assistive technology. The
  non-visual equivalent -- `#mapSummary`, `#mapAnnouncer` and the data table, all in
  `webapp/src/controllers/MapDataController.js` -- is a parallel implementation of what the
  picture shows, and nothing enforces that the two stay in step. They are held together by
  both being read from `demscore.country_scores()`; a change that colours the map from
  anything else has to bring the summary with it.
- **A rebuilt hex mesh invalidates every cached tile, and nothing in the URL says so.**
  Same trap as a colour change: the tiles carry the geometry, not a reference to it, so a
  setup run that moves a hexagon leaves the cache serving the old map. `setup_mapserver_hex_service.sh`
  now clears the server cache when `DEMSCORE_ENABLE_MAPCACHE=1`; the browser's service
  worker holds its own copy and needs a hard reload.
- Each colour scheme has its own tile cache, because the scheme is in the request URL. That
  is what keeps them from serving each other's colours, but it also means the mapcache
  warm-up (`scripts/preload_mapcache_tiles.sh`) and the in-browser read-ahead cover one
  scheme at a time: switching schemes is a cold cache until it refills. The default scheme
  sends no `palette` parameter at all, so the tiles everyone who never touches the control
  gets are the ones that were already cached before the control existed.
- Both diverging schemes are non-monotonic in lightness: `default` and `indigo_amber` each
  have two classes that print as the same grey. A reader who cannot use hue at all wants a
  sequential scheme, which is what `viridis` and `cividis` are there for.
- The diverging ramp is not monotonic in lightness: classes 2 and 7 print as the same grey.
  That is inherent to a diverging scheme and is the price of keeping polarity direction in
  the colour. What answers it is the equal-colour area outlines (on by default, and the
  toggle for them is on screen rather than behind Shift+D for this reason) and the data
  table. `scripts/check_palette_contrast.mjs` reports the collision as a note on every run
  so it stays a known trade rather than a surprise.

## 10) Recommended Next Improvements

1. Add repeatable automated checks (SQL assertions + WMS HTTP smoke tests) in CI.
2. Add a small integration test script that validates map output for all three datasets.
3. Consider materializing heavy intermediate results if response time degrades on larger datasets.
4. Add data dictionary docs per dataset for easier variable onboarding.
4b. Consume `/api/source-coverage` in the web client, so a country the source measured but
   this deployment cannot draw is distinguishable from one the source never measured. That
   is the part of the geometry metadata the picture genuinely cannot carry; the confidence
   grade itself does not need surfacing -- see `country_polygon_considerations.md` section 2.
5. Add an automated accessibility audit (Playwright driving the desktop and phone states,
   axe-core over each). It is the one item of the accessibility plan not done, purely
   because it needs a dependency install this repository has never had; the states worth
   auditing are listed at the end of `ACCESSIBILITY.md`.
