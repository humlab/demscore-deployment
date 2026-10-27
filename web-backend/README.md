# Web Backend

`web-backend` is a lightweight Node.js + Express API used by the web client.

## Purpose

- Serve webapp configuration from PostgreSQL where possible.
- Provide a stable API surface so frontend config sources are centralized.
- Provide runtime cache settings so the webapp and WMS proxy use the same `.env` toggle.

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

## Running

`./deploy.sh start` builds the image from `Containerfile` (dependencies installed with
`npm ci --omit=dev` from `package-lock.json`, run as the unprivileged `node` user) and starts it.
It connects as `demscore_reader`, a role that can only read and whose statements time out
after 30 s; an error reaches the client as `{"error": "internal_error"}` and its detail goes to
the container log only.
