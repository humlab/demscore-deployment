# Demscore

Demscore shows democracy indicators from V-Dem, QoG and REPDEM as an
interactive hexagon map of the world.

## Requirements

- `bash`, `curl` and `podman` with compose support
- About 10 GB of disk, plus room for the tile cache if you enable it

## Install

```bash
./deploy.sh install
```

The map is then at <http://127.0.0.1:8090>.

## Commands

| Command | What it does |
| --- | --- |
| `./deploy.sh start` | Start the services |
| `./deploy.sh stop` | Stop the services |
| `./deploy.sh status` | Show which services are running |
| `./deploy.sh import-data` | Replace the data with a new export (see below) |
| `./deploy.sh preload N` | Fill the tile cache for zoom levels 1 to N |
| `./deploy.sh clear-map-tile-cache` | Empty the tile cache |

## Updating the data

Put the new Demscore export in `data/Demscore_Module_Vars/`, one folder per
module:

```
data/Demscore_Module_Vars/QoG/data.csv      data/Demscore_Module_Vars/QoG/codebook.pdf
data/Demscore_Module_Vars/REPDEM/data.csv   data/Demscore_Module_Vars/REPDEM/codebook.pdf
data/Demscore_Module_Vars/V-Dem/data.csv    data/Demscore_Module_Vars/V-Dem/codebook.pdf
```

Then run `./deploy.sh import-data`. It checks the files, imports them, rebuilds
the map and prints a summary. If anything fails, the previous data is kept.

## Settings

Settings are in `.env`, which `install` creates. Run `./deploy.sh start` after
changing it.

| Setting | Default | |
| --- | --- | --- |
| `DEMSCORE_ROUTER_PORT` | `8090` | Port the site is served on |
| `DEMSCORE_ENABLE_MAPCACHE` | `0` | `1` caches map tiles |
| `DEMSCORE_MAPCACHE_MAX_SIZE` | `100g` | Largest the tile cache may grow; make sure the disk has room |

## Licence

The map may only be used non-commercially, because some of its boundary data
is licensed CC BY-NC-SA 4.0. See [LICENSE](LICENSE).

## More

- [docs/operations.md](docs/operations.md): what each command does, in detail
- [docs/tech-stack.md](docs/tech-stack.md): the components and how they fit together
- [AGENTS.md](AGENTS.md): architecture and developer guidelines
