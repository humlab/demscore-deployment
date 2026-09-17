BEGIN;

CREATE SCHEMA IF NOT EXISTS demscore;

DO $$
BEGIN
  IF to_regclass('demscore.variables') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.variables. Run scripts/load_demscore_module_vars.sh first.';
  END IF;
  IF to_regclass('demscore.dataset_values') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.dataset_values. Run scripts/load_demscore_module_vars.sh first.';
  END IF;
  IF to_regclass('demscore.country_units_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.country_units_src. Run scripts/setup_mapserver_hex_service.sh to import Natural Earth map units.';
  END IF;
END;
$$;

DROP TABLE IF EXISTS demscore.hex_borders;
DROP TABLE IF EXISTS demscore.hex_mesh;
DROP TABLE IF EXISTS demscore.countries;

CREATE TABLE demscore.countries (
  id BIGSERIAL PRIMARY KEY,
  name TEXT,
  iso_a3 TEXT,
  iso_a2 TEXT,
  id_key TEXT NOT NULL,
  geom_4326 geometry(MultiPolygon, 4326) NOT NULL,
  geom_8857 geometry(MultiPolygon, 8857) NOT NULL
);

-- Country identity (name, codes) comes from demscore.countries_src, the Natural
-- Earth admin-0 *countries* layer. Geometry comes from demscore.country_units_src,
-- the *map units* layer, which draws the same sovereigns split into their
-- geographic units: France vs French Guiana, Norway vs Svalbard, the four UK
-- nations, Papua New Guinea vs Bougainville. Splitting the sources this way lets
-- us drop the overseas units -- so a sovereign's hexagons never land on a
-- territory an ocean away -- while every country keeps the name and codes the
-- indicator data is matched against.
INSERT INTO demscore.countries (name, iso_a3, iso_a2, id_key, geom_4326, geom_8857)
WITH units AS (
  SELECT
    NULLIF(NULLIF(adm0_a3, ''), '-99') AS adm0_a3,
    -- iso_a3_eh rather than iso_a3: the latter is -99 for sub-national units
    -- (England, Wales, ...), which would read as "has its own country code".
    NULLIF(NULLIF(iso_a3_eh, ''), '-99') AS unit_iso_a3,
    ST_MakeValid(geom) AS geom
  FROM demscore.country_units_src
  WHERE geom IS NOT NULL
), mainland_units AS (
  -- A unit is overseas when its sovereign is drawn as several units and this one
  -- carries a country code of its own (French Guiana as GUF, Svalbard as SJM).
  -- Sovereigns drawn as a single unit are kept whatever their codes say: Western
  -- Sahara (SAH/ESH) and South Sudan (SDS/SSD) are whole countries whose adm0_a3
  -- differs from their ISO code.
  SELECT *
  FROM (
    SELECT u.*, count(*) OVER (PARTITION BY u.adm0_a3) AS unit_count
    FROM units u
    WHERE u.adm0_a3 IS NOT NULL
  ) counted
  WHERE unit_count = 1
     OR unit_iso_a3 IS NULL
     OR unit_iso_a3 = adm0_a3
), trimmed_geom AS (
  SELECT
    adm0_a3,
    ST_Multi(ST_UnaryUnion(ST_Collect(geom)))::geometry(MultiPolygon, 4326) AS geom_4326
  FROM mainland_units
  GROUP BY adm0_a3
), c AS (
  SELECT
    COALESCE(NULLIF(src.name_long, ''), src.name) AS name,
    NULLIF(NULLIF(src.adm0_a3, ''), '-99') AS iso_a3,
    NULLIF(NULLIF(src.iso_a2, ''), '-99') AS iso_a2,
    -- Fall back to the untrimmed outline if the map-units layer has no geometry
    -- for this country, so a mismatch between the two layers drops no country.
    COALESCE(
      t.geom_4326,
      ST_Multi(ST_MakeValid(src.geom))::geometry(MultiPolygon, 4326)
    ) AS geom_4326
  FROM demscore.countries_src src
  LEFT JOIN trimmed_geom t
    ON t.adm0_a3 = NULLIF(NULLIF(src.adm0_a3, ''), '-99')
  WHERE src.geom IS NOT NULL
)
SELECT
  c.name,
  c.iso_a3,
  c.iso_a2,
  COALESCE(c.iso_a3, lower(c.name)) AS id_key,
  c.geom_4326,
  -- No latitude clip. The old one cut every outline at +/-85.05112878 because
  -- that is where Web Mercator stops being able to represent the world at all;
  -- Equal Earth is defined to the poles, so northern Greenland, Svalbard and
  -- Antarctica keep their real shape instead of ending in a straight line.
  ST_Multi(
    ST_CollectionExtract(
      ST_MakeValid(ST_Transform(c.geom_4326, 8857)),
      3
    )
  )::geometry(MultiPolygon, 8857) AS geom_8857
FROM c
WHERE c.name IS NOT NULL
  AND NOT ST_IsEmpty(
    ST_CollectionExtract(
      ST_MakeValid(ST_Transform(c.geom_4326, 8857)),
      3
    )
  );

CREATE INDEX countries_iso_a3_idx ON demscore.countries (iso_a3);
CREATE INDEX countries_name_lc_idx ON demscore.countries (lower(name));
CREATE INDEX countries_geom_4326_gix ON demscore.countries USING GIST (geom_4326);
CREATE INDEX countries_geom_8857_gix ON demscore.countries USING GIST (geom_8857);

UPDATE demscore.dataset_values
SET country_id = NULL;

UPDATE demscore.dataset_values dv
SET country_id = c.id
FROM demscore.countries c
WHERE dv.iso3 IS NOT NULL
  AND upper(c.iso_a3) = upper(dv.iso3);

UPDATE demscore.dataset_values dv
SET country_id = c.id
FROM demscore.countries c
WHERE dv.country_id IS NULL
  AND dv.country_name IS NOT NULL
  AND lower(c.name) = lower(dv.country_name);

DELETE FROM demscore.dataset_values
WHERE country_id IS NULL;

ANALYZE demscore.dataset_values;

CREATE TABLE demscore.hex_mesh (
  country_id BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  hex_size_m INTEGER NOT NULL,
  hex_n INTEGER NOT NULL,
  id_key TEXT NOT NULL,
  geom geometry(Polygon, 8857) NOT NULL,
  PRIMARY KEY (country_id, hex_size_m, hex_n)
);

CREATE INDEX hex_mesh_size_idx ON demscore.hex_mesh (hex_size_m);
CREATE INDEX hex_mesh_country_idx ON demscore.hex_mesh (country_id);
CREATE INDEX hex_mesh_geom_gix ON demscore.hex_mesh USING GIST (geom);

-- Hexagon edge length in Equal Earth metres, which -- the projection being
-- equal-area -- is the same real area everywhere on the map. The ladder is the
-- old Web Mercator one halved (40k-600k step 10k becomes 20k-300k step 5k).
-- Halving is what keeps the map's density: a Mercator hexagon of a given size
-- covered ground area proportional to cos^2(latitude), so the mesh carried a
-- surplus of hexagons at high latitudes, and matching today's counts needs a
-- hexagon of about half the nominal size. Measured, 100k here yields 5 690
-- hexagons against the old 200k's 5 917.
WITH sizes AS (
  SELECT generate_series(20000, 300000, 5000)::INT AS hex_size_m
), raw_hexes AS (
  SELECT
    c.id AS country_id,
    c.id_key,
    s.hex_size_m,
    c.geom_8857 AS country_geom_8857,
    (ST_HexagonGrid(s.hex_size_m::FLOAT8, c.geom_8857)).geom AS hex_geom_8857
  FROM demscore.countries c
  CROSS JOIN sizes s
), selected_hexes AS (
  SELECT
    rh.country_id,
    rh.id_key,
    rh.hex_size_m,
    rh.hex_geom_8857
  FROM raw_hexes rh
  WHERE ST_Within(ST_PointOnSurface(rh.hex_geom_8857), rh.country_geom_8857)
), ranked_hexes AS (
  SELECT
    sh.country_id,
    sh.id_key,
    sh.hex_size_m,
    row_number() OVER (
      PARTITION BY sh.country_id, sh.hex_size_m
      ORDER BY ST_YMin(sh.hex_geom_8857), ST_XMin(sh.hex_geom_8857)
    ) AS hex_n,
    sh.hex_geom_8857::geometry(Polygon, 8857) AS geom
  FROM selected_hexes sh
)
INSERT INTO demscore.hex_mesh (country_id, hex_size_m, hex_n, id_key, geom)
SELECT
  country_id,
  hex_size_m,
  hex_n,
  id_key,
  geom
FROM ranked_hexes;

-- Where to draw the black outline that separates one colour from the next.
--
-- The map's unit of colour is not the hexagon but the *area*: a run of
-- neighbouring hexagons that landed in the same quantile class, which is what a
-- reader sees as one shade. France and Spain sharing a shade of blue are one
-- area, and only its outer perimeter should be stroked -- not every hexagon
-- inside it.
--
-- Dissolving that perimeter at render time (ST_Union per class, per tile) would
-- be both slow and wrong at tile seams, where the union cannot see the
-- neighbours just outside the request box. It is also unnecessary: a hexagon's
-- class is its country's class, so the only edges that can ever be stroked are
-- the ones between two different countries, or between a country and nothing at
-- all. Those edges do not depend on the dataset, variable or year, so they are
-- precomputed once here and merely *filtered* per request.
--
-- Every hexagon edge falls into one of three cases:
--   * shared by two hexagons of the same country -- can never separate two
--     colours, so it is dropped here and never drawn;
--   * shared by two hexagons of different countries -- drawn only when the two
--     countries fall in different classes (country_b holds the other side);
--   * held by one hexagon alone, the coastline of the mesh -- country_b is NULL,
--     and the edge is drawn whenever its own country has a value at all.
-- The render-time test is the same for all of them once an absent country reads
-- as a NULL class: `a.class_idx IS DISTINCT FROM b.class_idx`.
--
-- Matching edges by exact geometry is safe because the meshes come from
-- ST_HexagonGrid, so hexagons of adjacent countries are cells of one global
-- grid and a shared edge is bit-identical on both sides.
CREATE TABLE demscore.hex_borders (
  id BIGSERIAL PRIMARY KEY,
  hex_size_m INTEGER NOT NULL,
  country_a BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  -- NULL when no hexagon lies on the other side of the edge.
  country_b BIGINT REFERENCES demscore.countries(id) ON DELETE CASCADE,
  geom geometry(MultiLineString, 8857) NOT NULL
);

INSERT INTO demscore.hex_borders (hex_size_m, country_a, country_b, geom)
WITH segments AS (
  SELECT
    hm.hex_size_m,
    hm.country_id,
    (ST_DumpSegments(hm.geom)).geom AS geom
  FROM demscore.hex_mesh hm
), directed AS (
  -- Two hexagons walk their shared edge in opposite directions, so each segment
  -- is turned to point the same way before the two sides can be grouped as one.
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
  -- One row per country pair per mesh, merged into continuous lines so the
  -- stroke joins cleanly instead of being drawn as thousands of loose segments.
  ST_Multi(ST_LineMerge(ST_Collect(geom)))::geometry(MultiLineString, 8857) AS geom
FROM edges
WHERE country_count = 2
   OR hex_count = 1
GROUP BY hex_size_m, country_a, country_b;

CREATE INDEX hex_borders_size_idx ON demscore.hex_borders (hex_size_m);
CREATE INDEX hex_borders_geom_gix ON demscore.hex_borders USING GIST (geom);

ANALYZE demscore.countries;
ANALYZE demscore.hex_mesh;
ANALYZE demscore.hex_borders;

CREATE OR REPLACE FUNCTION demscore.country_scores(
  p_dataset TEXT DEFAULT 'v_dem',
  p_variable TEXT DEFAULT 'v2x_polyarchy',
  p_year INTEGER DEFAULT 2020
)
RETURNS TABLE (
  country_id BIGINT,
  dataset TEXT,
  variable TEXT,
  year INTEGER,
  value DOUBLE PRECISION,
  class_idx INTEGER,
  min_value DOUBLE PRECISION,
  max_value DOUBLE PRECISION
)
LANGUAGE SQL
STABLE
AS $$
WITH normalized AS (
  SELECT
    CASE lower(p_dataset)
      WHEN 'qog' THEN 'qog'
      WHEN 'repdem' THEN 'repdem'
      WHEN 'v_dem' THEN 'v_dem'
      ELSE 'v_dem'
    END AS dataset,
    p_variable AS variable,
    GREATEST(1500, LEAST(2100, p_year)) AS year
), country_values AS (
  SELECT
    dv.country_id,
    AVG(dv.value)::DOUBLE PRECISION AS value
  FROM demscore.dataset_values dv
  JOIN demscore.variables v
    ON v.id = dv.variable_id
  JOIN normalized n
    ON v.dataset = n.dataset
   AND v.variable = n.variable
   AND dv.year = n.year
  WHERE dv.country_id IS NOT NULL
  GROUP BY dv.country_id
), ranked_countries AS (
  SELECT
    cv.country_id,
    cv.value,
    ntile(7) OVER (ORDER BY cv.value) AS class_idx,
    min(cv.value) OVER () AS min_value,
    max(cv.value) OVER () AS max_value
  FROM country_values cv
)
SELECT
  rc.country_id,
  n.dataset,
  n.variable,
  n.year,
  rc.value,
  rc.class_idx,
  rc.min_value,
  rc.max_value
FROM ranked_countries rc
JOIN normalized n ON TRUE;
$$;

CREATE OR REPLACE FUNCTION demscore.hex_variable(
  p_dataset TEXT DEFAULT 'v_dem',
  p_variable TEXT DEFAULT 'v2x_polyarchy',
  p_year INTEGER DEFAULT 2020,
  p_hex_size_m INTEGER DEFAULT 200000
)
RETURNS TABLE (
  id TEXT,
  dataset TEXT,
  variable TEXT,
  year INTEGER,
  value DOUBLE PRECISION,
  class_idx INTEGER,
  min_value DOUBLE PRECISION,
  max_value DOUBLE PRECISION,
  geom geometry(Polygon, 8857)
)
LANGUAGE SQL
STABLE
AS $$
WITH normalized AS (
  SELECT
    lower(p_dataset) AS dataset,
    p_variable AS variable,
    GREATEST(1500, LEAST(2100, p_year)) AS year,
    GREATEST(20000, LEAST(300000, p_hex_size_m))::INT AS hex_size_m
)
SELECT
  hm.id_key || '_' || hm.hex_n AS id,
  cs.dataset,
  cs.variable,
  cs.year,
  cs.value,
  cs.class_idx,
  cs.min_value,
  cs.max_value,
  hm.geom
FROM normalized n
JOIN demscore.country_scores(n.dataset, n.variable, n.year) cs ON TRUE
JOIN demscore.hex_mesh hm
  ON hm.country_id = cs.country_id
 AND hm.hex_size_m = n.hex_size_m;
$$;

COMMIT;
