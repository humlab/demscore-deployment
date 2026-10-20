# Demscore

Demscore turns tabular democracy-indicator data (V-Dem, QoG, REPDEM) into a
thematic global hex map: a PostGIS database feeds a MapServer WMS layer,
rendered in a static OpenLayers web app, with an optional tile cache in front.

See [AGENTS.md](AGENTS.md) for full architecture, data flow, and developer
guidelines.

## Deploying

Requirements:

- `bash`, `curl` and `podman` with compose support — nothing else. Python,
  pdftotext, Node and GDAL all run in containers; the first run builds a small
  tools image for them (`tools/Containerfile`)
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

## Updating the data

To replace the data with a newer Demscore export, put the new files where the
old ones are — one folder per module, each holding `data.csv` and
`codebook.pdf`:

```
data/Demscore_Module_Vars/QoG/data.csv      data/Demscore_Module_Vars/QoG/codebook.pdf
data/Demscore_Module_Vars/REPDEM/data.csv   data/Demscore_Module_Vars/REPDEM/codebook.pdf
data/Demscore_Module_Vars/V-Dem/data.csv    data/Demscore_Module_Vars/V-Dem/codebook.pdf
```

and run

```bash
./deploy.sh import-data
```

It checks the files before touching anything, asks before replacing the data,
loads the CSVs and the codebooks, rebuilds the map, and prints a summary: what
the files held, what was imported and what was left out and why, which
variables are new or gone since the previous import, which have no codebook
entry, and any curated settings in `webapp/config` worth a look for the new
variables. It then offers to warm the tile cache for the new data.

The variables in an export may change freely from one import to the next: new
numeric columns become variables and missing ones disappear from the app. A
column is imported only if every value in it is a number; text columns
(names, dates, party lists) are listed in the summary as left out. What the
files must keep is their layout and each module's identifier columns
(`u_..._country`, `u_..._year`, and the ISO code for QoG and V-Dem).

If the files fail the check, nothing is changed. If the map cannot be built
from the new data — most often because the export introduces a country the
map has no geometry or policy for — the previous data is restored (after
asking, when run from a terminal). Every run keeps its logs and summary under
`state/imports/`. Options: `--yes` to skip the question, `--preload N` or
`--no-preload` to decide about the tile warm-up in advance, `--verbose` to see
every step's output.

The import renames the browser's tile cache as well as emptying the server's,
so readers get the new map on their next visit without a hard reload.
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
changes. `./deploy.sh install` and `./deploy.sh import-data` take care of both
caches themselves, since they rebuild the mesh; for a code change that
repaints tiles (a colour, a class boundary, the outline rule), bump
`WMS_TILE_CACHE` in `webapp/sw.js` — a reload alone will not do it.

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
- No automated test suite exists yet; `./deploy.sh install` and
  `./deploy.sh import-data` end with operational smoke tests (DB readiness,
  WMS `GetCapabilities`, and a `GetMap` for one variable of each dataset)
  and checks that every source observation is either drawn on the map or
  explicitly refused. It fails on a source country nothing covers, which is
  what a newer dataset export is most likely to introduce.
- **This deployment is non-commercial, and has to be.** Two of the four boundary
  sources are CC BY-NC-SA 4.0, which permits no commercial use, and the hex
  meshes and rendered tiles are derivatives of them — so no advertising, no paid
  access and no bundling into a commercial service, and anything offered onward
  carries the same licence. See [LICENSE](LICENSE). A deployment that needs an
  unencumbered map cannot simply drop a file: `sql/historical_geometry.sql`
  would have to be reduced to the Natural Earth rows, losing every pre-1886
  country. `data/reference/README.md` is the full licence and citation register;
  read it before redistributing the database, the tiles or the rendered map.
- The credits the app shows are generated, not written: `./deploy.sh install`
  (and `import-data`) reads which geometry is actually drawn out of `demscore.countries`, joins it
  to the hand-maintained register in `webapp/config/attribution_sources.json`,
  and **fails** on a boundary source the register cannot name, so a new source
  reaches the credits or it does not ship.
- `country_polygon_considerations.md` records what the country geometry is and
  where it is approximate — worth reading before quoting the map on a country
  that no longer exists.
- `POSTGRES_PASSWORD` is only applied the first time the `pg_data` volume is
  created. Changing it in `.env` later takes effect on the next
  `./deploy.sh start`, which brings the database role's password into line.
