# Map Projection Upgrade: Equal Earth

**Status: done.** The map is drawn in Equal Earth (EPSG:8857) and so is the hex mesh.
Web Mercator is gone from the stack; there is no projection toggle.

This file began as an investigation into adding Equal Earth *alongside* Web Mercator.
That framing is what made it look expensive. What follows is what was decided, what was
measured, and what turned out to be wrong in the original plan.

## The decision

Replace rather than add. Nearly every cost in the original plan came from the word
"alongside": a second mesh, a toggle, recreating the Leaflet map on switch, dual cache
warming, projection in the preload signature, a doubled test matrix. For a country-level
thematic map Web Mercator is the indefensible one -- it inflates exactly the countries
these indicators are most often read about -- so keeping it bought nothing.

## Why the mesh had to be rebuilt, not reprojected

The original plan's Option A was to keep the Web Mercator mesh and let MapServer
reproject it, shipping that if it "looked acceptable". It does not. The defect is not
shape but size: every hexagon was identical in *Mercator* metres, so in an equal-area
projection each draws at its true ground area, which falls off as cos^2(latitude).

| latitude band | avg true area | vs equator |
|---|---|---|
| 0-20 | 98 515 km2 | 1x |
| 41-60 | 41 142 km2 | 2.4x smaller |
| 60-80 | 14 310 km2 | 6.9x smaller |
| 80-83 | 2 338 km2 | 42x smaller |

Per country: Russia carried 795 hexagons across 17.0M km2, Brazil 85 across 8.5M --
twice the area, a ninth of the hexagons. Reprojected, that renders as fine confetti over
Russia and Canada against coarse blobs over Africa and Brazil.

The original plan also had the cost backwards. It listed "larger setup time and storage
footprint" as the con of a native mesh. A native Equal Earth mesh at the same nominal
size is about **4x smaller** (1 396 hexagons against 5 917 at the world view), because
the Mercator surplus at high latitudes is what it was generating. The full rebuild takes
about 90 seconds and the table came out slightly smaller than before, 171MB against 177MB.

## What the sizes had to become

The ladder is the old one halved: `20000..300000` step `5000` for `40000..600000` step
`10000`, and the app's stops are `100000 / 60000 / 40000 / 25000`. Halving is what keeps
the map's density, because the old sizes were implicitly counting on the Mercator
surplus. Measured against the old mesh at each stop the app uses:

| app stop | Equal Earth hexes | old Mercator hexes | countries with hexes (EE / Merc) |
|---|---|---|---|
| world view | 5 690 | 5 917 | 159 / 133 |
| second | 15 827 | 16 446 | 174 / 157 |
| third | 35 341 | 36 973 | 177 / 169 |
| finest | 90 757 | 94 698 | 177 / 176 |

Within 4% on density at every stop, and more countries drawn at every stop. Small
countries dropping out at coarse meshes is pre-existing behaviour, not a regression --
Mercator dropped 44 at its world stop, Equal Earth drops 18 at its own.

## The two traps in the client

Both come from one fact the original plan never reached: **Equal Earth fills a lens, not
the rectangle that bounds it.**

1. **No LatLngBounds can describe the world.** The projection is widest on the equator
   (x = +/-17243959) and narrowest at the poles (+/-10216474), and Leaflet projects only
   the two corners of a bounds. The obvious `maxBounds: [[-90,-180],[90,180]]` therefore
   describes the world at its pole width, 41% too narrow, and would have put Indonesia,
   Australia, Japan and New Zealand permanently out of reach; the same box in
   `getBoundsZoom` and in the tile layer's `bounds` option would have marked their tiles
   invalid so the map never asked for them. Widening the box past +/-180 does not work
   either -- proj4 wraps. Panning, world fit and the tile range all read the CRS's
   projected bounds instead.

2. **The projection has to be total, or the first paint is fatal.** Whenever the world
   does not exactly fill the window -- a fixed 2.055:1 box in a window of whatever shape,
   so nearly always -- Leaflet unprojects the corners of the letterboxed viewport, which
   are off the globe. proj4 answers with a NaN latitude and `GridLayer._updateLevels`
   throws `Invalid LatLng object` before a single tile is drawn. The projection is
   extended past the globe so this cannot happen, and `unproject` never takes proj4's
   longitude, which wraps past +/-180 and would otherwise return a point half a world away.

The CRS reuses Web Mercator's resolution ladder on purpose, so a zoom level still means
the metres per pixel it always did and the zoom thresholds did not have to move.

## What was investigated and deliberately not built

**Densifying the land basemap.** Equal Earth curves the meridians, so a long straight
lat/lon edge in the GeoJSON is drawn as a chord of the curve it should follow. Measured
across Natural Earth 110m: the worst segment in the world (the 141W Alaska/Yukon border)
is off by 6.3km, which is 0.2px at the world view and 2.6px at `MAX_ZOOM`. Eight segments
out of 10 360 exceed 1px even at the deepest zoom. Not worth a densify step at this data
resolution -- re-measure before adding one if the basemap ever gets finer.

## Known, unrelated

`scripts/preload_mapcache_tiles.sh` warms `LAYERS=hex_variable` while the app requests
`hex_variable,hex_outline`. The nginx cache keys on the full request URI, so the warmed
entries are not the ones the app asks for. This predates the projection work and was left
alone; it is a one-word fix but it changes how much the preloader writes.
