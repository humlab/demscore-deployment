# Operating Demscore

What each `./deploy.sh` command does, and what to know when running the stack.
The [README](../README.md) is the short version.

## Install

`./deploy.sh install`:

1. checks out the web app (`webapp/`, the `humlab/demscore-web` repository) at
   the commit this repository pins, if it is not checked out yet. One that is
   already checked out is left as it is, with a warning if it is at another
   commit
2. creates `.env` from `.env.example` and fills in random `POSTGRES_PASSWORD`
   and `DEMSCORE_READER_PASSWORD`
3. builds the web app and the web backend image and starts every service
4. runs the same import as `./deploy.sh import-data` (below), without asking
   first, since there is no earlier data to replace

Only `bash`, `curl`, `git` and `podman` with a compose provider are needed on
the host. `podman compose` hands its work to `docker-compose` or
`podman-compose`, neither of which comes with podman; `docker-compose` also
needs podman's API socket (`systemctl --user enable --now podman.socket`).
Every command that starts or talks to the services checks this first. Python,
pdftotext, Node and GDAL run in containers; the first run builds a small tools
image for them (`tools/Containerfile`).

Most of the time goes on building the map: about 20 minutes on a 24-core
machine, longer on a smaller one. A first install also pulls six images and
builds two before that.

## Starting and stopping

`./deploy.sh start` rebuilds the web app and the web backend image and starts
the services. Run it after changing `.env`, anything under `webapp/`, or
`web-backend/`. `./deploy.sh stop` stops the services, and `./deploy.sh status`
lists them.

The database has two roles. `demscore` owns the data and is what the import
uses; `demscore_reader` is what MapServer and the web backend query as, and it
can only read. On every start, `./deploy.sh start` gives each the password
`.env` names (`POSTGRES_PASSWORD`, `DEMSCORE_READER_PASSWORD`), generating any
that is missing, and updates the PostGIS extensions in the database volume to
the version the database image carries. The database has no published port.

## Serving it publicly

The router serves plain HTTP. Put a reverse proxy that terminates TLS in front
of it and forwards every path to `DEMSCORE_ROUTER_PORT`;
`deploy/nginx-vhost.conf.example` is one for nginx, including HSTS. Firewall
the port so only the proxy can reach it.

The router limits each client to 50 tile requests and 20 API requests a
second, queueing short bursts and answering 429 beyond them. It identifies the
client by the last address in `X-Forwarded-For`, believed only from the
addresses in `DEMSCORE_TRUSTED_PROXY_CIDRS` (default: loopback and the private
ranges). If the proxy is on another host with a public address, add it there,
or every reader is counted as the proxy. Requests that arrive from a private
address without a forwarded client, such as `./deploy.sh preload` on the host,
are not limited.

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

Rendered map tiles are cached on the server and in readers' browsers. This is
the default (`DEMSCORE_ENABLE_MAPCACHE=1`); with `0`, every tile is rendered on
request.

| Setting | Default | |
| --- | --- | --- |
| `DEMSCORE_ENABLE_MAPCACHE` | `1` | `0` turns the cache off |
| `DEMSCORE_MAPCACHE_MAX_SIZE` | `100g` | Largest the server cache may grow (nginx `k`/`m`/`g` suffixes) |
| `DEMSCORE_MAPCACHE_MIN_FREE` | `10g` | Free space the cache always leaves on its disk |
| `DEMSCORE_MAPCACHE_TTL_SECONDS` | `86400` (24 h) | How long a tile is served before it is rendered again, on the server and in the browser |

When the server cache reaches its size limit, or the disk has less than
`DEMSCORE_MAPCACHE_MIN_FREE` left, nginx removes the least-recently-used tiles.
It also removes any tile not requested for 24 hours.

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
