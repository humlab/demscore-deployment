# Reference geometry

Everything the map is drawn on. Upstream files are vendored verbatim and
imported by `scripts/setup_mapserver_hex_service.sh`, which downloads anything
missing. Files under `custom/` are project-local approximations and are marked
as such in the registry.

| File | Role | Licence |
| --- | --- | --- |
| `ne_50m_admin_0_countries.geojson` | Country identity (names, ISO codes) and the web-backend land basemap | Public domain |
| `ne_50m_admin_0_map_units.geojson` | Hex geometry, sovereigns split into geographic units | Public domain |
| `ne_50m_admin_0_tiny_countries.geojson` | Point support for countries too small to read as polygons | Public domain |
| `CShapes-2.0.geojson` | Period-aware world country boundaries, 1886-2019 | CC BY-NC-SA 4.0 |
| `CShapes-Europe.geojson` | Period-aware European boundaries from 1816 | CC BY-NC-SA 4.0 |
| `historical_basemaps/world_1783.geojson` | World snapshot, 1783 | GPL-3.0 |
| `historical_basemaps/world_1800.geojson` | World snapshot, 1800 | GPL-3.0 |
| `historical_basemaps/world_1815.geojson` | World snapshot, 1815 | GPL-3.0 |
| `custom/v_dem_south_yemen_aden_approx.geojson` | Project-local low-confidence Aden marker for V-Dem South Yemen/YMD before 1967 | Project-local approximation |

## Why three historical sources

V-Dem reaches back to 1789. CShapes 2.0 starts in 1886, so about 145 000 of
V-Dem's loaded values belonged to states that had ceased to exist before the
only historical boundary source here begins. `sql/historical_geometry.sql`
resolves them, preferring in this order:

1. **CShapes 2.0** where it covers the coding unit and the year. Period-aware,
   already vendored, already what the rest of the historical path uses.
2. **CShapes-Europe**, the same project's European series from 1816. Also
   period-aware, and it carries seventeen of the nineteen pre-unification German
   and Italian states V-Dem codes, with their border-change periods.
3. **historical-basemaps** snapshots, for the years and entities neither reaches:
   before 1816, and for Tuscany and Hamburg, which CShapes-Europe has no entry
   for at all, and Hanover, which it folds into the United Kingdom until 1838.

Everything taken from a snapshot is recorded as `low` confidence with the
snapshot year attached, because a snapshot is a picture of one year being asked
to stand for a span of them. `demscore.historical_country_geometries_src`
carries the source, licence, citation, year span and confidence of every polygon
individually, and `/api/source-coverage` and `/api/map-data` pass the confidence
through to the client.

The `custom/` directory is different from the upstream files above: it contains
project-local approximations rather than vendored source data. The South Yemen
file is a small square centred near modern Aden. It is marked `low` confidence
and is used only so V-Dem's pre-1967 South Yemen/YMD values draw near Aden
instead of being dropped or painted across the larger 1967-1990 state polygon.

## Attribution

**Natural Earth.** Made with Natural Earth. Free vector and raster map data at
<https://naturalearthdata.com>. Public domain.

**CShapes 2.0.** Schvitz, G., Girardin, L., Rüegger, S., Weidmann, N. B.,
Cederman, L.-E., and Gleditsch, K. S. (2022). Mapping the International System,
1886-2019: The CShapes 2.0 Dataset. *Journal of Conflict Resolution* 66(1):
144-161. Licensed CC BY-NC-SA 4.0. <https://icr.ethz.ch/data/cshapes/>

**CShapes-Europe.** Cederman, L.-E., Girardin, L., Rüegger, S., Schvitz, G., and
Weidmann, N. B. (2025). *Nationalism and the Transformation of the State*.
Cambridge University Press. Licensed CC BY-NC-SA 4.0.
<https://icr.ethz.ch/data/cshapes/>

**Historical Basemaps.** Ourednik, A. (2021). Historical Basemaps.
<https://doi.org/10.5281/zenodo.11212643>. Licensed GPL-3.0.
<https://github.com/aourednik/historical-basemaps>

## Licence consequences

Two of these carry conditions that reach the data this deployment derives from
them, so they are worth stating plainly rather than leaving in a table.

- **CC BY-NC-SA 4.0** (both CShapes datasets): non-commercial use only, and a
  derivative distributed onward must carry the same licence. The hex meshes and
  the tiles rendered from them are derivatives.
- **GPL-3.0** (historical-basemaps): copyleft. The five polygons taken from it
  are listed in the `historical_basemaps` rows of
  `demscore.historical_country_geometries_src`, and a query on
  `source_dataset = 'historical_basemaps'` is the complete list at any time.

Nothing here is public-domain-only, so a deployment that needs an unencumbered
map cannot simply drop a file: it would need `sql/historical_geometry.sql`
reduced to the Natural Earth rows, and would lose every pre-1886 country.
