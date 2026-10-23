# Operating Demscore

What each `./deploy.sh` command does, and what to know when running the stack.
The [README](../README.md) is the short version.

## Install

`./deploy.sh install`:

1. creates `.env` from `.env.example` and fills in a random `POSTGRES_PASSWORD`
2. builds the web app and starts every service
3. runs the same import as `./deploy.sh import-data` (below), without asking
   first, since there is no earlier data to replace

Only `bash`, `curl` and `podman` are needed on the host. Python, pdftotext,
Node and GDAL run in containers; the first run builds a small tools image for
them (`tools/Containerfile`).

## Starting and stopping

`./deploy.sh start` rebuilds the web app and starts the services. Run it after
changing `.env` or anything under `webapp/`. `./deploy.sh stop` stops the
services, and `./deploy.sh status` lists them.

`POSTGRES_PASSWORD` is stored in the database volume when the volume is first
created. If you change it in `.env` later, `./deploy.sh start` updates the
database to match.

## Importing data

`./deploy.sh import-data` replaces the indicator data with the files in
`data/Demscore_Module_Vars/` (`QoG`, `REPDEM` and `V-Dem`, each holding
`data.csv` and `codebook.pdf`). It:

1. checks the files, and stops without changing anything if they cannot be
   loaded
2. asks before replacing the data
3. backs up the current data
4. loads the CSVs and the codebooks
5. rebuilds the map, and checks the result
6. prints a summary
7. offers to fill the tile cache for the new data

The summary shows what the files held, what was imported, what was left out
and why, which variables are new or gone since the previous import, which have
no codebook entry, and which curated settings in `webapp/config` are worth
checking for the new variables.

Each `codebook.pdf` is also the codebook the app offers readers, and the citations
in the app's credits are read from its bibliography. A new export's codebook
replaces both, and the import fails if a dataset's codebook yields no citation.

Options:

| Option | |
| --- | --- |
| `--yes` | Don't ask before replacing the data. Required when not run from a terminal |
| `--preload N` | Fill the tile cache for zoom levels 1 to N afterwards, without asking |
| `--no-preload` | Don't offer to fill the tile cache |
| `--verbose` | Show every step's output |

Each run's logs and summary are kept in `state/imports/`, for the last ten
runs.

### What the files must look like

Variables may come and go between exports: new numeric columns become
variables, and columns that are gone disappear from the app. A column is
imported only if every value in it is a number, so text columns (names, dates,
party lists) are left out and listed in the summary.

What must stay the same is the layout and each module's identifier columns:
`u_..._country`, `u_..._year`, and the ISO code column for QoG and V-Dem.

### When an import fails

If the map cannot be built from the new data, the previous data is restored
(after asking, when run from a terminal). The most common cause is an export
that adds a country the map has no geometry for. The summary names each such
country; it has to be given geometry, or marked as deliberately not drawn,
before the import can succeed.

### Checks

`install` and `import-data` end by checking that:

- the database is ready
- WMS `GetCapabilities` and a `GetMap` for one variable of each dataset
  succeed
- every source observation is either drawn on the map or deliberately not
  drawn
- every boundary source on the map is named in the app's credits

## Tile cache

With `DEMSCORE_ENABLE_MAPCACHE=1`, rendered map tiles are cached on the server
and in readers' browsers. With `0`, every tile is rendered on request.

| Setting | Default | |
| --- | --- | --- |
| `DEMSCORE_MAPCACHE_MAX_SIZE` | `100g` | Largest the server cache may grow (nginx `k`/`m`/`g` suffixes) |
| `DEMSCORE_MAPCACHE_TTL_SECONDS` | `86400` (24 h) | How long a tile is served before it is rendered again, on the server and in the browser |

When the server cache reaches its size limit, nginx removes the
least-recently-used tiles, and any tile not requested for 24 hours. The disk
must have room for the full limit.

### Preloading

`./deploy.sh preload N` requests every tile for zoom levels 1 to N, for every
dataset, variable and year, in the two colour schemes the app offers. Each
zoom level is about four times the work of the one before. `N=2` is a
reasonable start.

A preload only requests tiles. A tile the cache already holds is not rendered
again, so a preload alone does not replace stale tiles.

### Clearing the cache

`import-data` and `install` empty the server cache and make readers' browsers
drop their copies, so nothing extra is needed after an import.

After a code change that alters how tiles look (a colour, a class boundary,
the outline rule), clear the cache yourself:

```bash
./deploy.sh clear-map-tile-cache     # empty the server cache
./deploy.sh preload 2 --clear        # empty it, then fill it again
```

These reach the server cache only. To make browsers drop their copies too,
bump `WMS_TILE_CACHE` in `webapp/sw.js` before running `./deploy.sh start`.

## Licence

The hexagon meshes and rendered tiles are built from CShapes 2.0 and
CShapes-Europe, which are licensed CC BY-NC-SA 4.0. That means:

- no commercial use: no advertising, no paid access, no bundling into a
  commercial service
- anything offered onward carries the same licence
- the sources must be credited

The app credits the sources on the map itself and in its "Sources & licences"
dialog. Those credits are generated from the geometry that is actually drawn,
and the import fails if a boundary source has no entry in
`webapp/config/attribution_sources.json`.

Removing the CShapes data would also remove every country drawn on historical
borders (the Soviet Union, Yugoslavia, the pre-1886 states and others), and the
Palestine and Zanzibar units, which use CShapes in present-day years too.

[LICENSE](../LICENSE) has the full terms, and
[data/reference/README.md](../data/reference/README.md) lists every boundary
source with its licence and citation.
