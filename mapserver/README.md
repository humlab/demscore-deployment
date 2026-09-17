# Demscore MapServer

This directory contains a file-configured MapServer WMS setup for rendering hexagon layers from the Demscore PostgreSQL/PostGIS database.

## Layers

- `hex_variable`: dynamic hexagons colored by quantile class for a selected dataset variable and year.
- `hex_outline`: the black perimeter around each *area* of equally colored hexagons. An area
  is a run of touching hexagons in the same quantile class, so two neighbouring countries the
  legend paints the same shade form one area with one outline, and the hexagons inside it keep
  only their white hairlines. Request it by naming both layers
  (`LAYERS=hex_variable,hex_outline`); omit it to get the fills alone. It reads
  `demscore.hex_borders`, the precomputed table of every hexagon edge that could ever separate
  two colors, and ignores `polarity` — that only relabels classes, and cannot change which
  sides match.

## Runtime Parameters

Pass these as WMS request parameters:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: column name in the selected dataset
- `year`: 4-digit year
- `hex_size`: hexagon edge size in meters; local setup precomputes `40000` to `600000` in `10000` meter steps, and the web app uses `200000`, `120000`, `80000`, and `50000` as zoom-responsive stops
- `polarity`: `positive` | `negative` (`positive` flips class colors so higher values are bluer); read by `hex_variable` only

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

`http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&CRS=EPSG:4326&BBOX=-60,-180,85,180&WIDTH=1200&HEIGHT=700&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=200000&polarity=positive`
