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
  cache disk behaviour

```bash
./deploy.sh install
```

This generates a `.env` (from `.env.example`) with a random `POSTGRES_PASSWORD`,
starts all services, loads the datasets, and sets up the map-ready DB objects.
The web app is then available at `http://127.0.0.1:8090` (the router's host
port; change it with `DEMSCORE_ROUTER_PORT` in `.env`).

Other commands: `./deploy.sh start`, `./deploy.sh stop`, `./deploy.sh status`.
With map caching enabled and services running, `./deploy.sh --preload 2`
preloads zoom levels 1 and 2 for every dataset/variable/year combination
across all colour schemes.

A preload only *asks* for tiles, so a tile the cache already holds is answered
from the cache and never re-rendered. After anything that repaints a tile
without changing its URL — a rebuilt hex mesh, a colour, a class boundary, the
outline rule — the cache has to be emptied first, or the warm-up preserves the
old map instead of replacing it:

```bash
./deploy.sh clear-map-tile-cache     # empty the server cache and reload nginx
./deploy.sh --preload 2 --clear      # empty it, then warm it again
```

Both reach the server cache only. A reader's browser keeps its own copy behind
the service worker, which is keyed by URL and shed only when the cache's *name*
changes, so bump `WMS_TILE_CACHE` in `webapp/sw.js` for that — a reload alone
will not do it. (`scripts/setup_mapserver_hex_service.sh` already clears the
server cache itself when caching is enabled, since it rebuilds the mesh.)

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
  `GetMap`), and `scripts/check_country_resolution.sh` checks that every source
  observation is either drawn on the map or explicitly refused. Setup fails on
  a source country nothing covers, which is what a newer dataset export is most
  likely to introduce.
- **This deployment is non-commercial, and has to be.** Two of the four boundary
  sources are CC BY-NC-SA 4.0, which permits no commercial use, and the hex
  meshes and rendered tiles are derivatives of them — so no advertising, no paid
  access and no bundling into a commercial service, and anything offered onward
  carries the same licence. See [LICENSE](LICENSE). A deployment that needs an
  unencumbered map cannot simply drop a file: `sql/historical_geometry.sql`
  would have to be reduced to the Natural Earth rows, losing every pre-1886
  country. `data/reference/README.md` is the full licence and citation register;
  read it before redistributing the database, the tiles or the rendered map.
- The credits the app shows are generated, not written:
  `scripts/build_attribution.sh` reads which geometry is actually drawn out of
  `demscore.countries`, joins it to the hand-maintained register in
  `webapp/config/attribution_sources.json`, and **fails** on a boundary source
  the register cannot name. Setup runs it, so a new source reaches the credits
  or it does not ship.
- `country_polygon_considerations.md` records what the country geometry is and
  where it is approximate — worth reading before quoting the map on a country
  that no longer exists.
- `POSTGRES_PASSWORD` is only applied the first time the `pg_data` volume is
  created. Changing it in `.env` later requires `scripts/sync_db_password.sh`
  (run automatically by `./scripts/start_services.sh`) to reconcile it.
