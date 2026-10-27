# Demscore

Demscore shows democracy indicators from V-Dem, QoG and REPDEM as an
interactive hexagon map of the world.

## Requirements

- `bash`, `curl`, `git` and `podman`
- A compose provider for podman: `docker-compose`, with podman's API socket
  running (`systemctl --user enable --now podman.socket`), or `podman-compose`
- About 10 GB of disk, plus room for the tile cache (up to 100 GB by default)

## Install

```bash
git clone https://github.com/humlab/demscore-deployment.git
cd demscore-deployment
./deploy.sh install
```

Installing takes 20 minutes or more, most of it spent building the map. The
map is then at <http://127.0.0.1:8090>.

## Keeping it running

Under rootless podman, the services stop when the user who started them logs
out, and nothing starts them again after a reboot. Run this once, as that
user:

```bash
sudo loginctl enable-linger "$USER"
systemctl --user enable podman-restart.service
```

Lingering keeps the user's services running without anyone logged in, and
`podman-restart.service` starts the containers at boot. When podman runs as
root, only `systemctl enable podman-restart.service` is needed.

## Serving it publicly

The stack serves plain HTTP on `DEMSCORE_ROUTER_PORT` and expects a reverse
proxy in front of it to terminate TLS and forward every path to that port.
[deploy/nginx-vhost.conf.example](deploy/nginx-vhost.conf.example) is one for
nginx. Firewall the port so only the reverse proxy can reach it: requests are
rate-limited per client using the address the proxy passes in
`X-Forwarded-For`, and a request made to the port directly goes round TLS.

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
| `DEMSCORE_TRUSTED_PROXY_CIDRS` | private ranges | Where the reverse proxy connects from (comma-separated); set it if the proxy is on another host with a public address |
| `DEMSCORE_ENABLE_MAPCACHE` | `1` | `0` turns off map tile caching |
| `DEMSCORE_MAPCACHE_MAX_SIZE` | `100g` | Largest the tile cache may grow; make sure the disk has room |

## Licence

The map may only be used non-commercially, because some of its boundary data
is licensed CC BY-NC-SA 4.0. See [LICENSE](LICENSE).

## More

- [docs/operations.md](docs/operations.md): what each command does, in detail
- [docs/tech-stack.md](docs/tech-stack.md): the components and how they fit together
- [AGENTS.md](AGENTS.md): architecture and developer guidelines
