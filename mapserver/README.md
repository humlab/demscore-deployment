# Demscore MapServer

This directory contains a file-configured MapServer WMS setup for rendering hexagon layers from the Demscore PostgreSQL/PostGIS database.

## Projection

Everything is *generated* in **EPSG:8857, Equal Earth**, which is what makes one hexagon one real area anywhere on the map, and that is what the web app asks for by default. `EPSG:4326` and `EPSG:3857` are advertised as well and MapServer reprojects into them on the way out; the mesh itself is never anything but equal-area.

A Mercator request should carry `clip=mercator`, which drops the cells that projection cannot draw — those reaching past 85.05N/S, and the handful straddling the antimeridian. Without it they are rendered as columns standing over the map and bands across it. The default is `clip=none` and it costs the Equal Earth path nothing: the tests are constant-folded away.

The world box is `-17243960 -8392928 17243960 8392928`. Do not derive that by transforming the `(-180,-90)` and `(180,90)` corners: Equal Earth is at its widest on the equator, where x reaches `+/-17243959`, and narrows to `+/-10216474` at the poles, so a corner-derived extent is 41% too narrow.

## Layers

- `hex_variable`: dynamic hexagons colored by quantile class for a selected dataset variable and year.
- `hex_outline`: the black perimeter around each *area* of equally colored hexagons. An area
  is a run of touching hexagons in the same quantile class, so two neighbouring countries the
  legend paints the same shade form one area with one outline, and the hexagons inside it keep
  only their white hairlines. Request it by naming both layers
  (`LAYERS=hex_variable,hex_outline`); omit it to get the fills alone. It reads
  `demscore.hex_borders`, the precomputed table of every hexagon edge that could ever separate
  two colors, and ignores `polarity` -- that only changes the color ramp, and cannot change
  which sides match.

## Runtime Parameters

Pass these as WMS request parameters:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: column name in the selected dataset
- `year`: 4-digit year
- `hex_size`: hexagon edge size in Equal Earth meters; local setup precomputes `20000` to `300000` in `5000` meter steps, and the web app uses `100000`, `60000`, `40000`, and `25000` as zoom-responsive stops
- `polarity`: `positive` | `negative` | `neutral` (`positive` flips class colors so higher values are bluer; `neutral` uses a single-hue green ramp); read by `hex_variable` only

Defaults:

- `dataset=v_dem`
- `variable=v2x_polyarchy`
- `year=2020`
- `hex_size=100000`
- `polarity=negative`

## Capabilities URL

`http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities`

Optional cached endpoint (when `mapcache` profile is running):

`http://127.0.0.1:8089/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities`

## Example GetMap URL

The whole world, requested the way the web app requests it (WMS 1.1.1 and `SRS`, which sidesteps 1.3.0's axis-order rules):

`http://127.0.0.1:8088/?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000&polarity=positive`
