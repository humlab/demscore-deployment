# Demscore MapServer

This directory contains a file-configured MapServer WMS setup for rendering hexagon layers from the Demscore PostgreSQL/PostGIS database.

## Projection

Everything is *generated* in **EPSG:8857, Equal Earth**, which is what makes one hexagon one real area anywhere on the map, and that is what the web app asks for by default. `EPSG:4326` and `EPSG:3857` are advertised as well and MapServer reprojects into them on the way out; the mesh itself is never anything but equal-area.

Each plane has a mesh and three layers of its own. `hex_variable` / `hex_inset` / `hex_outline` draw the Equal Earth mesh and serve `EPSG:8857`; the `_mercator` three draw `demscore.hex_mesh_mercator` and serve `EPSG:3857`. Neither pair is ever reprojected into the other plane, and each advertises only its own SRS so it cannot be: a hexagon is a hexagon only in the plane it was cut in, and the Equal Earth mesh asked for in `EPSG:3857` comes back as a field of slivers.

The two fill layers share their colours through `INCLUDE "hex_classes.inc"`, since the projection a cell was cut in has nothing to do with the class it falls in.

The world box is `-17243960 -8392928 17243960 8392928`. Do not derive that by transforming the `(-180,-90)` and `(180,90)` corners: Equal Earth is at its widest on the equator, where x reaches `+/-17243959`, and narrows to `+/-10216474` at the poles, so a corner-derived extent is 41% too narrow.

## Layers

- `hex_variable`: dynamic hexagons colored by quantile class for a selected dataset variable and year.
- `hex_inset`: the half-size hexagons given to countries that no cell of the grid could be
  dealt to. Every country gets at least one hexagon at every size — a country with data and no
  hexagons reads as a country with no data — but at the coarsest sizes some regions hold more
  countries than there are cells covering them (the western Balkans at `200000`), so those
  countries are drawn with a hexagon from the grid one notch finer, sitting where the country
  is. It overlaps the cell beneath it, which is why it is a layer of its own: MapServer draws a
  layer's features in whatever order the query returns and has no mapfile directive to sort
  them, so being on top is only guaranteed by being a later *layer*. Name it after the fills
  (`LAYERS=hex_variable,hex_inset,hex_outline`). At `200000` it carries 5 hexagons in Equal
  Earth and 4 in Mercator; at `100000` and below, none.
- `hex_outline`: the black perimeter around each *area* of equally colored hexagons. An area
  is a run of touching hexagons in the same quantile class, so two neighbouring countries the
  legend paints the same shade form one area with one outline, and the hexagons inside it keep
  only their white hairlines. Request it by naming both layers
  (`LAYERS=hex_variable,hex_inset,hex_outline`); omit it to get the fills alone. An inset's
  edges match nothing, so it is outlined all the way round and reads as a country rather than a
  blemish on the cell under it. It reads
  `demscore.hex_borders`, the precomputed table of every hexagon edge that could ever separate
  two colors, and ignores `polarity` -- that only changes the color ramp, and cannot change
  which sides match.

## Runtime Parameters

Pass these as WMS request parameters:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: column name in the selected dataset
- `year`: 4-digit year
- Which country a cell belongs to: the one its centre falls in. A country that wins no cell that
  way is then given the cells that hold the most of it, spilling over the border, at most as many
  as its own area could fill and never a neighbour's last cell; then whatever is still empty takes
  a cell anyway, displacing a neighbour that holds less of it; then `hex_inset` covers the rest.
  See the three passes in `sql/mapserver_hex_setup.sql`.
- `hex_size`: hexagon edge size in the layer's own projected meters; local setup precomputes `20000` to `300000` in `5000` meter steps for the Equal Earth mesh and `40000` to `600000` in `10000` meter steps for the Mercator one. The web app uses `200000`, `100000`, and `50000` as zoom-responsive stops in *both* projections: both count in Web Mercator's resolution ladder, so an equal size is an equal grain on screen, and the Mercator mesh's larger cell count at a given size is the polar surplus the toggle exists to show. Three stops rather than a finer ladder because `hex_size` is a WMS dimension: crossing a stop invalidates every tile on screen, so each one is a full reload. The coarsest stop is also the mapfile default below and what `scripts/preload_mapcache_tiles.sh` warms; the three move together.
- `polarity`: `positive` | `negative` | `neutral` (`positive` flips class colors so higher values are bluer; `neutral` uses a single-hue green ramp); read by `hex_variable` only

Defaults:

- `dataset=v_dem`
- `variable=v2x_polyarchy`
- `year=2020`
- `hex_size=200000` (the same on the Mercator layers)
- `polarity=negative`

## Capabilities URL

`http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities`

The app always uses the same `/mapserver` route. With `DEMSCORE_ENABLE_MAPCACHE=1`, that route stores `GetMap` tile responses in the server-side nginx cache and returns cacheable HTTP headers; with it disabled, the same route is a no-store pass-through for development.

For direct container-to-container debugging, MapServer itself is still addressed internally as `http://mapserver/?map=/etc/mapserver/mapserver.map`.

## Example GetMap URL

The whole world, requested the way the web app requests it (WMS 1.1.1 and `SRS`, which sidesteps 1.3.0's axis-order rules):

`http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000&polarity=positive`
