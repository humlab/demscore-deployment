# Demscore MapServer

This directory contains a file-configured MapServer WMS setup for rendering hexagon layers from the Demscore PostgreSQL/PostGIS database.

## Projection

Everything is *generated* in **EPSG:8857, Equal Earth**, which is what makes one hexagon one real area anywhere on the map, and that is what the web app asks for by default. `EPSG:4326` and `EPSG:3857` are advertised as well and MapServer reprojects into them on the way out; the mesh itself is never anything but equal-area.

Each plane has a mesh and two layers of its own. `hex_variable` / `hex_outline` draw the Equal Earth mesh and serve `EPSG:8857`; the `_mercator` pair draw `demscore.hex_mesh_mercator` and serve `EPSG:3857`. Neither pair is ever reprojected into the other plane, and each advertises only its own SRS so it cannot be: a hexagon is a hexagon only in the plane it was cut in, and the Equal Earth mesh asked for in `EPSG:3857` comes back as a field of slivers.

The two fill layers share their colours through `INCLUDE "hex_classes.inc"`, since the projection a cell was cut in has nothing to do with the class it falls in.

The world box is `-17243960 -8392928 17243960 8392928`. Do not derive that by transforming the `(-180,-90)` and `(180,90)` corners: Equal Earth is at its widest on the equator, where x reaches `+/-17243959`, and narrows to `+/-10216474` at the poles, so a corner-derived extent is 41% too narrow.

## Layers

- `hex_variable`: dynamic hexagons coloured by quantile class for a selected dataset variable and year.
- `hex_outline`: the black stroke around each rendered colour area. Only colour decides:
  neighbouring hexagons in the same class are interior to one area whichever country each
  belongs to, and all the no-data grey is one area. Request it by naming both layers
  (`LAYERS=hex_variable,hex_outline`); omit it to get the fills alone. It reads
  `demscore.hex_border_edges` and `demscore.hex_border_sides`, the precomputed table of every
  hexagon edge that could ever separate two colours together with the countries whose hexagons
  touch each one and on which side, and ignores `polarity` -- that only changes the colour
  ramp, and cannot change which sides match. Deciding an edge from the sides table rather than from the hexagons the
  request box returned is deliberate: `!BOX!` is half a pixel smaller than the tile, so a
  per-request recomputation strokes the rim of its own box and dashes a line along every tile
  seam.

## Runtime Parameters

Pass these as WMS request parameters:

- `dataset`: `qog` | `repdem` | `v_dem`
- `variable`: column name in the selected dataset
- `year`: 4-digit year
- Which country a cell belongs to: the one its centre falls in. A country that wins no cell that
  way is then given the cells that hold the most of it, spilling over the border, at most as many
  as its own area could fill and never a neighbour's last cell; then whatever is still empty takes
  a cell anyway, displacing a neighbour that holds less of it. See the two passes in
  `sql/mapserver_hex_setup.sql`. A country the cells still cannot seat gets nothing at that size
  and waits for a finer stop: every hexagon is one size, always. At `200000` that is 34
  data-carrying coding units undrawn (23 distinct names — Slovenia, Luxembourg, Montenegro,
  North Macedonia, Kosovo, San Marino, Liechtenstein, three Caribbean states, the four
  Palestine units and eight pre-unification German and Italian states); at `100000`, 5 (the
  Palestine units and Saint Kitts and Nevis); at `50000`, none. They stay in `/api/map-data`
  and in the spoken summary at every zoom, because those read `demscore.country_scores()`
  rather than the mesh.
- `hex_size`: hexagon edge size in the layer's own projected metres; local setup precomputes `20000` to `300000` in `5000` metre steps for the Equal Earth mesh and `40000` to `600000` in `10000` metre steps for the Mercator one. The web app uses `200000`, `100000`, and `50000` as zoom-responsive stops in *both* projections: both count in Web Mercator's resolution ladder, so an equal size is an equal grain on screen, and the Mercator mesh's larger cell count at a given size is the polar surplus the toggle exists to show. Three stops rather than a finer ladder because `hex_size` is a WMS dimension: crossing a stop invalidates every tile on screen, so each one is a full reload. The coarsest stop is also the mapfile default below and what `scripts/preload_mapcache_tiles.sh` warms; the three move together.
- `polarity`: `positive` | `negative` | `neutral`. Which end of the scale is the unfavourable
  one. Read by the fill layers only, and only by the two diverging schemes: it picks
  which end of their band the hexagons start from (`positive` reverses it, in SQL, as
  `base + (8 - class_idx)`). `neutral`, for a variable with no favourable end, is drawn the
  same way round as `positive` -- low values at the scheme's first-named colour -- so a
  scheme looks the same on every variable
- `palette`: `default` | `indigo_amber` | `viridis` | `cividis`. Which colour scheme paints the
  hexagons. Read by the fill layers only.

  Colour is the map's whole encoding and about one man in twelve cannot use the red-green
  channel the default leans on, so this is a reader's choice rather than a deployment setting.
  It reaches MapServer as a parameter because the hexagons are rendered here, not in the
  browser: a scheme cannot be a stylesheet.

  Mechanically it is an offset on `class_idx`, which the `DATA` query applies per scheme and
  polarity before MapServer classes on it -- see the `CASE` in the mapfile, the bands in
  `mapserver/hex_classes.inc`, and `webapp/src/core/palettes.js`, which is the source both are
  generated and checked from. `default` and `indigo_amber` are diverging and honour polarity;
  `viridis` and `cividis` are sequential, always read low-to-high, and ignore it.

  The web client omits the parameter entirely on `default` rather than spelling it out. The
  two requests render identically, but they are different URLs, and both the mapcache and the
  service worker key on the URL -- sending it would have thrown away every tile already cached
  for everyone who never touches the control.

Defaults:

- `dataset=v_dem`
- `variable=v2x_polyarchy`
- `year=2020`
- `hex_size=200000` (the same on the Mercator layers)
- `polarity=negative`
- `palette=default` (an unrecognised value falls back to this, as MapServer's `VALIDATION` does for every parameter here)

## Capabilities URL

`http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&REQUEST=GetCapabilities`

The app always uses the same `/mapserver` route. With `DEMSCORE_ENABLE_MAPCACHE=1`, that route stores `GetMap` tile responses in the server-side nginx cache and returns cacheable HTTP headers; with it disabled, the same route is a no-store pass-through for development.

For direct container-to-container debugging, MapServer itself is still addressed internally as `http://mapserver/?map=/etc/mapserver/mapserver.map`.

## Example GetMap URL

The whole world, requested the way the web app requests it (WMS 1.1.1 and `SRS`, which sidesteps 1.3.0's axis-order rules):

`http://127.0.0.1:8090/mapserver?map=/etc/mapserver/mapserver.map&SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=hex_variable,hex_outline&STYLES=&SRS=EPSG:8857&BBOX=-17243960,-8392928,17243960,8392928&WIDTH=1200&HEIGHT=584&FORMAT=image/png&dataset=v_dem&variable=v2x_polyarchy&year=2020&hex_size=100000&polarity=positive`
