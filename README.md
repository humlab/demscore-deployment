# Demscore

Demscore turns tabular democracy-indicator data (V-Dem, QoG, REPDEM) into a
thematic global hex map: a PostGIS database feeds a MapServer WMS layer,
rendered in a static OpenLayers web app, with an optional tile cache in front.

See [AGENTS.md](AGENTS.md) for full architecture, data flow, and developer
guidelines.

## Deploying

Requirements:

- `podman` with compose support
- `ogr2ogr` on the host `PATH`
- `curl`
- ~10 GB disk for the database and reference boundaries; see below for tile
  cache disk behavior

```bash
./deploy.sh install
```

This generates a `.env` (from `.env.example`) with a random `POSTGRES_PASSWORD`,
starts all services, loads the datasets, and sets up the map-ready DB objects.
The web app is then available at `http://127.0.0.1:8090`.

Other commands: `./deploy.sh start`, `./deploy.sh stop`, `./deploy.sh status`.
With map caching enabled and services running, `./deploy.sh --preload 2`
preloads zoom levels 1 and 2 for every dataset/variable/year combination
across all colour schemes.

To enable server/browser WMS tile caching, set `DEMSCORE_ENABLE_MAPCACHE=1`
in `.env` before starting. `DEMSCORE_MAPCACHE_MAX_SIZE` (default `100g`)
controls how large that cache is allowed to grow — see disk space below.
`DEMSCORE_MAPCACHE_TTL_SECONDS` (default `43200` = 12h) controls how long a
tile is served as fresh, both from the server cache and the browser, before
it's re-rendered from the database.

## Deployment requirements and notes

- Disk space: with tile caching on, the server-side nginx cache size is set
  by `DEMSCORE_MAPCACHE_MAX_SIZE` in `.env` (default **100 GB**; accepts
  nginx's k/m/g suffixes). Once the cache hits that size, nginx evicts
  least-recently-used tiles (plus anything untouched for 24h), so normal
  browsing plateaus at the configured limit rather than growing without
  bound — **make sure that much disk is actually available**, or lower the
  setting. For reference, an exhaustive warm-up of every variable, every
  year, all four colour schemes, both projections and all hex sizes would
  need **roughly 1.2 TB** (measured at ~44 KB/tile average, ~28M tiles);
  ordinary usage stays far below that, but the 100 GB default is sized to
  comfortably hold most of what real traffic would ever request. Use
  `./deploy.sh --preload N` for a bounded warm-up of the first `N` zoom levels.
- No automated test suite exists yet; `scripts/setup_mapserver_hex_service.sh`
  provides operational smoke tests (DB readiness, WMS `GetCapabilities` and
  `GetMap`).
- `POSTGRES_PASSWORD` is only applied the first time the `pg_data` volume is
  created. Changing it in `.env` later requires `scripts/sync_db_password.sh`
  (run automatically by `./scripts/dev_up.sh`) to reconcile it.
