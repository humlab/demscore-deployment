# AGENTS.md

This document explains how the Demscore system is built, how its parts fit together, and how to work safely in this repository.

## 1) System Overview

Demscore is a mapping stack with an optional cache layer:

1. PostGIS database (`db`) stores source datasets and geographic boundaries.
2. MapServer (`mapserver`) exposes a WMS layer that renders data-driven hexagons.
3. Static web app (`web`) uses Leaflet to request and display the WMS layer.
4. Optional WMS cache proxy (`mapcache`) can sit in front of MapServer.

The system turns tabular democracy indicator data into a thematic global hex map.

## 2) Architecture and Data Flow

1. CSV datasets are mounted into the DB container from `data/Demscore_Module_Vars`.
2. `scripts/load_demscore_module_vars.sh` loads CSVs into a typed long-format model:
   - `demscore.variables` (`dataset`, `variable`)
   - `demscore.dataset_values` (`variable_id`, `year`, `iso3`, `country_name`, `value`, `country_id`)
3. `scripts/load_variable_metadata.sh` enriches variables with codebook metadata:
   - converts each dataset `codebook.pdf` to text (`pdftotext -layout`)
   - parses entries using `scripts/extract_variable_metadata.py`
   - loads parsed rows into `demscore.variable_metadata_raw`
   - resolves matches to `demscore.variables` and stores final metadata in `demscore.variable_metadata`
4. Country geometry is imported into `demscore.countries_src` (via `ogr2ogr` in `scripts/setup_mapserver_hex_service.sh`).
5. `sql/mapserver_hex_setup.sql`:
   - normalizes country geometry into `demscore.countries` (4326 + 3857)
   - remaps `demscore.dataset_values.country_id` to the current country table (ISO3 first, then name fallback)
   - precomputes hex meshes into `demscore.hex_mesh` for supported hex sizes
   - defines `demscore.hex_variable(...)` to join precomputed hex geometry with selected dataset values and compute quantile classes
6. MapServer layer `hex_variable` calls `demscore.hex_variable(...)` dynamically using WMS params and applies bbox filtering inside the SQL subquery.
7. Leaflet UI sends WMS requests with `dataset`, `variable`, `year`, and `hex_size`.

## 3) Tech Stack

- Container orchestration: `podman compose` workflow (Compose file is Docker Compose format)
- Database: PostgreSQL 16 + PostGIS 3.4 (`postgis/postgis:16-3.4`)
- Spatial server: MapServer 8.4 (`camptocamp/mapserver:8.4`)
- Web server: Nginx 1.27 Alpine (`nginx:1.27-alpine`)
- Frontend: Vanilla JS + Leaflet 1.9.4 + static HTML/CSS
- GIS import tooling: `ogr2ogr` (required by setup script)

## 4) Repository Map

- `compose.yml`: service definitions, ports, mounts, optional cache profile
- `initdb/01_extensions.sql`: bootstrap PostGIS extensions
- `scripts/load_demscore_module_vars.sh`: CSV-to-table loader
- `scripts/dev_up.sh`: starts core services and conditionally includes `mapcache` based on `.env`
- `scripts/extract_variable_metadata.py`: robust parser for codebook text blocks and variable metadata fields
- `scripts/load_variable_metadata.sh`: PDF-to-DB metadata load pipeline for variable titles/citations/descriptions
- `scripts/setup_mapserver_hex_service.sh`: full environment + geometry + SQL setup + smoke tests
- `sql/mapserver_hex_setup.sql`: core DB objects and hex function
- `mapserver/mapserver.map`: WMS config and style classes
- `mapserver/README.md`: WMS parameter contract
- `webapp/index.html`, `webapp/app.js`, `webapp/styles.css`: UI
- `webapp/config/variables.json`: dataset defaults and allowed variables
- `mapcache/nginx.conf`: optional reverse-proxy tile cache in front of MapServer
- `data/`: input datasets + reference boundaries

## 5) Runtime Interfaces

### Service endpoints

- Web app: `http://127.0.0.1:8090`
- MapServer WMS: `http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map`
- Optional cached WMS: `http://127.0.0.1:8089/?map=/etc/mapserver/mapserver.map` (set `DEMSCORE_ENABLE_MAPCACHE=1` in `.env`, then run `./scripts/setup_mapserver_hex_service.sh`)
- PostgreSQL: `127.0.0.1:5532` (db/user/password default: `demscore`)

### WMS parameter contract

Accepted parameters for `hex_variable`:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: alphanumeric/underscore (`^[A-Za-z0-9_]+$`)
- `year`: four digits
- `hex_size`: 5-7 digit integer

MapServer applies validation defaults; SQL additionally clamps:

- year: `1500..2100`
- hex size: `40000..600000` meters

## 6) Local Setup and Operations

### Prerequisites

- `podman` + compose support
- `ogr2ogr` on host PATH
- `curl`

### Typical startup

Set cache toggle in `.env`:
- `DEMSCORE_ENABLE_MAPCACHE=0` (no cache)
- `DEMSCORE_ENABLE_MAPCACHE=1` (enable cache proxy)

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
- `demscore.hex_mesh` stores precomputed geometry for `hex_size` values 40000..600000 (step 10000).
- Preserve join quality in `hex_variable`: ISO3 matching is primary; name matching is fallback.
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
- Precomputing `hex_mesh` across all supported sizes increases setup time and storage footprint.
- Dynamic SQL surface is partially constrained by MapServer regex validation; keep validation strict.
- No automated test suite currently exists; scripts provide operational smoke tests only.

## 10) Recommended Next Improvements

1. Add repeatable automated checks (SQL assertions + WMS HTTP smoke tests) in CI.
2. Add a small integration test script that validates map output for all three datasets.
3. Consider materializing heavy intermediate results if response time degrades on larger datasets.
4. Add data dictionary docs per dataset for easier variable onboarding.
