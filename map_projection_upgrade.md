# Map Projection Upgrade: Equal Earth Investigation

## Goal

Investigate whether Demscore can render the map in the 2018 Equal Earth projection in addition to the existing Web Mercator-oriented rendering.

## Summary

Adding Equal Earth support is feasible. The local runtime already has the projection support needed at the spatial stack level:

- PostGIS `spatial_ref_sys` includes `EPSG:8857`, "WGS 84 / Equal Earth Greenwich".
- The MapServer container reports MapServer 8.4.1 with PROJ 9.5, and `projinfo EPSG:8857` resolves to `+proj=eqearth`.

The current application is nevertheless built around Web Mercator assumptions:

- Countries are stored as both `geom_4326` and `geom_3857`.
- Hex meshes and hex borders are generated and stored only in `EPSG:3857`.
- MapServer advertises only `EPSG:4326 EPSG:3857`.
- Leaflet uses its default CRS, which is Web Mercator.
- The scripted mapcache preloader computes tile BBOXes using Web Mercator extents and requests `SRS=EPSG:3857`.

The main work is therefore not basic projection support. It is adding a second projection mode cleanly through MapServer, database geometry, and the Leaflet client.

## Current Projection Dependencies

### Database

`sql/mapserver_hex_setup.sql` creates `demscore.countries` with:

- `geom_4326 geometry(MultiPolygon, 4326)`
- `geom_3857 geometry(MultiPolygon, 3857)`

The setup then builds `demscore.hex_mesh` from `geom_3857` using `ST_HexagonGrid(...)`. The table stores:

- `geom geometry(Polygon, 3857)`

`demscore.hex_borders` also stores:

- `geom geometry(MultiLineString, 3857)`

`demscore.hex_variable(...)` returns `geometry(Polygon, 3857)`.

Implication: the current hexagons are native Web Mercator hexagons. If MapServer reprojects them into Equal Earth at render time, the result will display in Equal Earth, but the hexagons themselves were not generated in an equal-area coordinate space.

### MapServer

`mapserver/mapserver.map` currently has:

- map projection: `init=epsg:4326`
- advertised WMS SRS: `EPSG:4326 EPSG:3857`
- `hex_variable` source projection: `init=epsg:3857`
- `hex_outline` source projection: `init=epsg:3857`

A direct `GetMap` probe with `CRS=EPSG:8857` currently returns an `InvalidSRS` XML exception because `EPSG:8857` is not advertised as valid for the requested layers.

Implication: MapServer likely only needs mapfile changes for a first server-side Equal Earth render, but each requested layer must advertise the CRS.

### Frontend

`webapp/src/controllers/MapController.js` creates Leaflet with no custom CRS:

```js
this.map = L.map("mapCanvas", { ... });
```

Leaflet defaults to Web Mercator. The WMS layer is created with `L.tileLayer.wms(...)` and WMS `version: "1.1.1"`, so browser tile coordinates and BBOX generation are Web Mercator-oriented.

Implication: client support needs `proj4` plus a Leaflet CRS bridge such as `Proj4Leaflet`, or a different mapping approach for projected image requests. Leaflet cannot reliably switch CRS on an existing map instance; a projection toggle should probably recreate the map.

### Basemap

The land basemap is loaded as GeoJSON from `/api/basemap/land` and displayed with `L.geoJSON(...)`.

Implication: with a custom Leaflet CRS, this can still work if the CRS plugin correctly projects GeoJSON lat/lon coordinates. It should be tested carefully around the dateline and high latitudes.

### Cache

Runtime nginx mapcache should naturally cache Equal Earth requests because the request URL includes CRS/SRS and BBOX.

`scripts/preload_mapcache_tiles.sh` is hard-coded to Web Mercator:

- `WEB_MERCATOR_HALF=20037508.342789244`
- tile BBOX math assumes a square Web Mercator world
- request URL includes `SRS=EPSG:3857`

Implication: normal runtime caching does not block Equal Earth, but scripted cache warming needs a projection-aware branch if it should preload Equal Earth tiles.

## Implementation Options

## Option A: Reproject Existing Web Mercator Hexes at Render Time

This is the smallest implementation.

### Server work

1. Add `EPSG:8857` to `wms_srs` at the map and layer metadata levels.
2. Add suitable map/layer extents or bounding boxes for Equal Earth if MapServer needs them for clean capabilities output and request validation.
3. Keep layer source projections as `EPSG:3857`.
4. Let MapServer reproject the existing `hex_mesh.geom` and `hex_borders.geom` into `EPSG:8857` for WMS output.
5. Add a setup smoke test for a `GetMap` request with `CRS=EPSG:8857`.

### Frontend work

1. Add `proj4` and `Proj4Leaflet`, either vendored locally or loaded consistently with the current CDN pattern.
2. Define `EPSG:8857`:

   ```text
   +proj=eqearth +lon_0=0 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs
   ```

3. Define projected bounds. The observed country extent was approximately:

   ```text
   x: -16923980.33 to 16923980.33
   y:  -8392927.60 to  8316222.40
   ```

   The mathematical full-world corners from `(-180,-90)` and `(180,90)` are approximately:

   ```text
   x: -10216474.79 to 10216474.79 at the poles
   y:  -8392927.60 to  8392927.60
   ```

   Because Equal Earth has widest x extent away from the poles, use a full projected world extent from PROJ/MapServer testing rather than only corner transforms.

4. Create the map with the custom CRS when Equal Earth mode is selected.
5. Recreate the Leaflet map when switching between Web Mercator and Equal Earth.
6. Ensure WMS tile requests use the matching CRS/SRS and BBOX axis order. WMS 1.1.1 with `SRS=EPSG:8857` is likely simpler than WMS 1.3.0 axis-order handling.
7. Include the projection mode in tile/preload signatures and cache keys where the app tracks loading state.

### Pros

- Smallest database change: none.
- No additional hex precomputation.
- Fastest way to prove the UX and rendering path.

### Cons

- Hexagons are generated in Web Mercator, then warped into Equal Earth.
- Areas and shapes of the rendered hexagons will not be native Equal Earth hexagons.
- This may be visually acceptable for an initial mode, but it is not the cleanest thematic cartography.

## Option B: Add Native Equal Earth Hex Meshes

This is the stronger implementation.

### Server/database work

1. Add `geom_8857 geometry(MultiPolygon, 8857)` to `demscore.countries`, generated from `geom_4326`.
2. Add a native Equal Earth hex mesh table, for example:

   - `demscore.hex_mesh_8857`
   - `demscore.hex_borders_8857`

3. Generate the Equal Earth mesh with `ST_HexagonGrid(hex_size_m, geom_8857)`.
4. Select hexes using `ST_PointOnSurface(...)` within the Equal Earth country geometry.
5. Rebuild border detection for the Equal Earth mesh using the same exact-edge matching approach.
6. Expose either:

   - separate WMS layers such as `hex_variable_equalearth` and `hex_outline_equalearth`, or
   - parameterized SQL that chooses the mesh by a validated projection parameter.

Separate layers are safer in MapServer because they keep SRID declarations explicit.

### Frontend work

Same as Option A, except Equal Earth mode should request the Equal Earth layers rather than the existing layers.

### Pros

- Hexagons are native to the Equal Earth projected plane.
- Better matches the intent of an equal-area world map.
- Avoids visually odd warped Web Mercator hexes.

### Cons

- Larger setup time and storage footprint.
- More SQL and MapServer configuration to maintain.
- Need to decide whether `hex_size_m` stops should match Web Mercator values or be tuned separately for Equal Earth.

## Recommended Plan

Implement in two phases.

### Phase 1: Thin Equal Earth Prototype

Purpose: validate browser, WMS, and UX behavior with minimal data model churn.

1. Add `EPSG:8857` to MapServer WMS metadata for the map and both current layers.
2. Add a temporary/manual `GetMap` smoke request for `EPSG:8857`.
3. Add frontend CRS support with `proj4` and `Proj4Leaflet`.
4. Add a projection selector with two modes:

   - Web Mercator
   - Equal Earth

5. Recreate the Leaflet map when projection changes.
6. Verify:

   - world fit at desktop and mobile sizes
   - panning bounds
   - zoom behavior
   - WMS tile alignment
   - land GeoJSON alignment with WMS hex tiles
   - outlines alignment with fills
   - timeline preloading still behaves sensibly

If the reprojected Web Mercator hexes look acceptable, this phase could be enough for a first release.

### Phase 2: Native Equal Earth Mesh

Purpose: make the Equal Earth mode cartographically correct.

1. Extend SQL setup with `geom_8857`.
2. Add native Equal Earth mesh and border tables.
3. Add Equal Earth WMS layers sourced from those tables.
4. Tune Equal Earth-specific hex size stops.
5. Update setup smoke tests to validate both projections.
6. Update cache preloader to accept a projection option:

   - `webmercator`: current behavior
   - `equalearth`: Equal Earth bounds and `SRS=EPSG:8857`

7. Document the projection modes in `mapserver/README.md` and `webapp/README.md`.

## Testing Checklist

For either implementation:

1. `GetCapabilities` advertises `EPSG:8857` for all intended layers.
2. `GetMap` returns `image/png`, not XML, for an Equal Earth request.
3. The Equal Earth layer renders both fills and outlines.
4. The land basemap aligns with the hex layer.
5. Dataset, variable, year, polarity, outline toggle, and zoom-driven hex size changes still work.
6. Mobile layout still fits and controls remain usable.
7. Timeline tile preloading does not reuse statuses across projections.
8. Optional mapcache mode caches Equal Earth URLs separately from Web Mercator URLs.

## Open Questions

1. Should Equal Earth initially reuse the existing Web Mercator hex mesh, or should the first shipped version wait for a native Equal Earth mesh?
2. Should the UI expose projection as a persistent preference?
3. Should Equal Earth use the same hex sizes as Web Mercator, or projection-specific stops tuned by visual density?
4. Should the land basemap remain GeoJSON in the browser, or should it also come from MapServer as a projected layer for perfect alignment?

