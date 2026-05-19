# Web Backend

`web-backend` is a lightweight Node.js + Express API used by the web client.

## Purpose

- Serve webapp configuration from PostgreSQL where possible.
- Provide a stable API surface so frontend config sources are centralized.
- Keep map rendering direct from webapp to MapServer (no proxying of WMS tile requests).

## Endpoints

- `GET /healthz`: backend + DB liveness
- `GET /api/runtime`: runtime wiring (`cacheEnabled`, `mapServerBase`) derived from `DEMSCORE_ENABLE_MAPCACHE`
- `GET /api/config`: compact bundle (`variables`, `legendSemantics`, `variablePolarity`)
- `GET /api/config/variables`: variables/defaults/year ranges
- `GET /api/config/variable-metadata?dataset=<dataset_key>`: lightweight metadata summary for one dataset
- `GET /api/config/variable-metadata/:dataset`: lightweight metadata summary for one dataset
- `GET /api/config/variable-metadata/:dataset/:variable`: full metadata for one variable (for Variable Information dialog)
- `GET /api/config/legend-semantics`: legend semantic labels
- `GET /api/config/variable-polarity`: polarity mapping (`positive`/`negative`)

## Source of Data

- `variables` and `variable-metadata` are fetched from PostgreSQL (`demscore.variables`, `demscore.dataset_values`, `demscore.variable_metadata`).
- `legend-semantics` and `variable-polarity` are read from mounted JSON config files under `webapp/config`.

If DB tables are missing (for example before loaders run), `variables` and `variable-metadata` fall back to the corresponding JSON files if present.
