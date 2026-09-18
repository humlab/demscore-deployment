-- A second hex mesh, cut in Web Mercator, for the projection toggle.
--
-- The map is an Equal Earth map and sql/mapserver_hex_setup.sql builds the mesh
-- that makes it one. This file adds the mesh the *comparison* view needs, and it
-- has to be a separate mesh rather than the same one reprojected.
--
-- Reprojecting looked like the cheap answer and is not usable. A hexagon is a
-- hexagon in the plane it was cut in and nowhere else: pushed through PROJ into
-- Mercator, an Equal Earth cell at 60N is drawn twice as tall as it is wide, and
-- by 80N it is a sliver. Reading a hex map means reading cells as
-- interchangeable units, and cells that are not the same shape are not read that
-- way -- the map stops looking like a hex map and starts looking broken. So each
-- projection gets a mesh cut in its own plane, and every cell is a regular
-- hexagon on screen in whichever one is showing.
--
-- What differs between the two meshes is what the cells *mean*, and that is the
-- point of being able to switch. An Equal Earth cell is a fixed amount of
-- ground anywhere on the map. A Mercator cell is a fixed amount of *screen*, so
-- it stands for less and less ground the further it is from the equator, which
-- is why Mercator gave Russia 795 hexagons across 17.0M km2 and Brazil 85
-- across 8.5M. Switching the projection switches which of those a hexagon
-- counts, and seeing the cell count move is the clearest statement of what the
-- projection was doing to the data all along.
--
-- Safe to run on its own against an existing database; the setup script runs it
-- after sql/mapserver_hex_setup.sql.

BEGIN;

DO $$
BEGIN
  IF to_regclass('demscore.countries') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.countries. Run sql/mapserver_hex_setup.sql first.';
  END IF;
END;
$$;

-- Country geometry in Web Mercator.
--
-- Clipped to +/-85.05112878 on the way, which the Equal Earth geometry
-- deliberately is not: that cut is Web Mercator's own limit, the latitude where
-- its y runs off to infinity, and it exists here for exactly the reason it was
-- removed there. Greenland and Antarctica therefore end in a straight
-- horizontal line in this mesh and in a real coastline in the other one.
ALTER TABLE demscore.countries
  ADD COLUMN IF NOT EXISTS geom_3857 geometry(MultiPolygon, 3857);

UPDATE demscore.countries c
SET geom_3857 = ST_Multi(
  ST_Transform(
    ST_MakeValid(
      ST_Intersection(
        c.geom_4326,
        ST_MakeEnvelope(-180, -85.05112878, 180, 85.05112878, 4326)
      )
    ),
    3857
  )
)::geometry(MultiPolygon, 3857);

CREATE INDEX IF NOT EXISTS countries_geom_3857_gix
  ON demscore.countries USING GIST (geom_3857);

DROP TABLE IF EXISTS demscore.hex_borders_mercator;
DROP TABLE IF EXISTS demscore.hex_mesh_mercator;

CREATE TABLE demscore.hex_mesh_mercator (
  country_id BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  hex_size_m INTEGER NOT NULL,
  hex_n INTEGER NOT NULL,
  id_key TEXT NOT NULL,
  geom geometry(Polygon, 3857) NOT NULL,
  PRIMARY KEY (country_id, hex_size_m, hex_n)
);

CREATE INDEX hex_mesh_mercator_size_idx ON demscore.hex_mesh_mercator (hex_size_m);
CREATE INDEX hex_mesh_mercator_country_idx ON demscore.hex_mesh_mercator (country_id);
CREATE INDEX hex_mesh_mercator_geom_gix ON demscore.hex_mesh_mercator USING GIST (geom);

-- Hexagon edge length in Web Mercator metres, which are not ground metres: a
-- cell of a given size here covers ground area proportional to cos^2(latitude).
--
-- The ladder is 40k-600k step 10k, exactly twice the Equal Earth one, and that
-- factor is what makes the two meshes comparable to look at. A Mercator mesh
-- carries a surplus of cells towards the poles, so reaching the same total takes
-- a nominally larger cell: measured, 200k here yields 5 917 hexagons against
-- 100k in Equal Earth's 5 690. The app's resolution stops are doubled to match,
-- so a zoom level draws about the same number of cells in either projection and
-- the toggle changes the shape of the world rather than the grain of the map.
WITH sizes AS (
  SELECT generate_series(40000, 600000, 10000)::INT AS hex_size_m
), raw_hexes AS (
  SELECT
    c.id AS country_id,
    c.id_key,
    s.hex_size_m,
    c.geom_3857 AS country_geom_3857,
    (ST_HexagonGrid(s.hex_size_m::FLOAT8, c.geom_3857)).geom AS hex_geom_3857
  FROM demscore.countries c
  CROSS JOIN sizes s
  WHERE NOT ST_IsEmpty(c.geom_3857)
), selected_hexes AS (
  SELECT
    rh.country_id,
    rh.id_key,
    rh.hex_size_m,
    rh.hex_geom_3857
  FROM raw_hexes rh
  WHERE ST_Within(ST_PointOnSurface(rh.hex_geom_3857), rh.country_geom_3857)
), ranked_hexes AS (
  SELECT
    sh.country_id,
    sh.id_key,
    sh.hex_size_m,
    row_number() OVER (
      PARTITION BY sh.country_id, sh.hex_size_m
      ORDER BY ST_YMin(sh.hex_geom_3857), ST_XMin(sh.hex_geom_3857)
    ) AS hex_n,
    sh.hex_geom_3857::geometry(Polygon, 3857) AS geom
  FROM selected_hexes sh
)
INSERT INTO demscore.hex_mesh_mercator (country_id, hex_size_m, hex_n, id_key, geom)
SELECT
  country_id,
  hex_size_m,
  hex_n,
  id_key,
  geom
FROM ranked_hexes;

-- The edges that can ever separate one colour from the next, exactly as
-- demscore.hex_borders is built for the Equal Earth mesh -- see the long note
-- there for why the perimeter is precomputed rather than dissolved per tile,
-- and why matching edges by exact geometry is safe.
CREATE TABLE demscore.hex_borders_mercator (
  id BIGSERIAL PRIMARY KEY,
  hex_size_m INTEGER NOT NULL,
  country_a BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  country_b BIGINT REFERENCES demscore.countries(id) ON DELETE CASCADE,
  geom geometry(MultiLineString, 3857) NOT NULL
);

INSERT INTO demscore.hex_borders_mercator (hex_size_m, country_a, country_b, geom)
WITH segments AS (
  SELECT
    hm.hex_size_m,
    hm.country_id,
    (ST_DumpSegments(hm.geom)).geom AS geom
  FROM demscore.hex_mesh_mercator hm
), directed AS (
  SELECT
    hex_size_m,
    country_id,
    CASE
      WHEN (ST_X(ST_StartPoint(geom)), ST_Y(ST_StartPoint(geom)))
           <= (ST_X(ST_EndPoint(geom)), ST_Y(ST_EndPoint(geom)))
      THEN geom
      ELSE ST_Reverse(geom)
    END AS geom
  FROM segments
), edges AS (
  SELECT
    hex_size_m,
    geom,
    min(country_id) AS country_a,
    CASE
      WHEN min(country_id) = max(country_id) THEN NULL
      ELSE max(country_id)
    END AS country_b,
    count(*) AS hex_count,
    count(DISTINCT country_id) AS country_count
  FROM directed
  GROUP BY hex_size_m, geom
)
SELECT
  hex_size_m,
  country_a,
  country_b,
  ST_Multi(ST_LineMerge(ST_Collect(geom)))::geometry(MultiLineString, 3857) AS geom
FROM edges
WHERE country_count = 2
   OR hex_count = 1
GROUP BY hex_size_m, country_a, country_b;

CREATE INDEX hex_borders_mercator_size_idx ON demscore.hex_borders_mercator (hex_size_m);
CREATE INDEX hex_borders_mercator_geom_gix ON demscore.hex_borders_mercator USING GIST (geom);

ANALYZE demscore.countries;
ANALYZE demscore.hex_mesh_mercator;
ANALYZE demscore.hex_borders_mercator;

COMMIT;
