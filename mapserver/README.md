# Demscore MapServer

This directory contains a file-configured MapServer WMS setup for rendering hexagon layers from the Demscore PostgreSQL/PostGIS database.

## Layer

- `hex_variable`: dynamic hexagons colored by quantile class for a selected dataset variable and year.

## Runtime Parameters

Pass these as WMS request parameters:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: column name in the selected dataset
- `year`: 4-digit year
- `hex_size`: hexagon edge size in meters (suggested `100000` to `300000`)
- `polarity`: `positive` | `negative` (`positive` flips class colors so higher values are bluer)

Defaults:

- `dataset=v_dem`
- `variable=v2x_polyarchy`
- `year=2020`
- `hex_size=200000`
- `polarity=negative`

## Capabilities URL

`http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities`

Optional cached endpoint (when `mapcache` profile is running):

`http://127.0.0.1:8089/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities`

## Example GetMap URL

`http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=hex_variable&STYLES=&CRS=EPSG:4326&BBOX=-60,-180,85,180&WIDTH=1200&HEIGHT=700&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=200000&polarity=positive`
