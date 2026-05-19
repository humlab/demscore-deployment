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
END;
$$;

DROP TABLE IF EXISTS demscore.hex_mesh;
DROP TABLE IF EXISTS demscore.countries;

CREATE TABLE demscore.countries (
  id BIGSERIAL PRIMARY KEY,
  name TEXT,
  iso_a3 TEXT,
  iso_a2 TEXT,
  id_key TEXT NOT NULL,
  geom_4326 geometry(MultiPolygon, 4326) NOT NULL,
  geom_3857 geometry(MultiPolygon, 3857) NOT NULL
);

INSERT INTO demscore.countries (name, iso_a3, iso_a2, id_key, geom_4326, geom_3857)
SELECT
  c.name,
  c.iso_a3,
  c.iso_a2,
  COALESCE(c.iso_a3, lower(c.name)) AS id_key,
  c.geom_4326,
  ST_Transform(
    ST_Multi(
      ST_CollectionExtract(
        ST_Intersection(
          c.geom_4326,
          ST_MakeEnvelope(-180, -85.05112878, 180, 85.05112878, 4326)
        ),
        3
      )
    ),
    3857
  )::geometry(MultiPolygon, 3857) AS geom_3857
FROM (
  SELECT
    COALESCE(NULLIF(name_long, ''), name) AS name,
    NULLIF(NULLIF(adm0_a3, ''), '-99') AS iso_a3,
    NULLIF(NULLIF(iso_a2, ''), '-99') AS iso_a2,
    ST_Multi(ST_MakeValid(geom))::geometry(MultiPolygon, 4326) AS geom_4326
  FROM demscore.countries_src
  WHERE geom IS NOT NULL
) c
WHERE c.name IS NOT NULL
  AND NOT ST_IsEmpty(
    ST_CollectionExtract(
      ST_Intersection(
        c.geom_4326,
        ST_MakeEnvelope(-180, -85.05112878, 180, 85.05112878, 4326)
      ),
      3
    )
  );

CREATE INDEX countries_iso_a3_idx ON demscore.countries (iso_a3);
CREATE INDEX countries_name_lc_idx ON demscore.countries (lower(name));
CREATE INDEX countries_geom_4326_gix ON demscore.countries USING GIST (geom_4326);
CREATE INDEX countries_geom_3857_gix ON demscore.countries USING GIST (geom_3857);

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
  geom geometry(Polygon, 3857) NOT NULL,
  PRIMARY KEY (country_id, hex_size_m, hex_n)
);

CREATE INDEX hex_mesh_size_idx ON demscore.hex_mesh (hex_size_m);
CREATE INDEX hex_mesh_country_idx ON demscore.hex_mesh (country_id);
CREATE INDEX hex_mesh_geom_gix ON demscore.hex_mesh USING GIST (geom);

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
INSERT INTO demscore.hex_mesh (country_id, hex_size_m, hex_n, id_key, geom)
SELECT
  country_id,
  hex_size_m,
  hex_n,
  id_key,
  geom
FROM ranked_hexes;

ANALYZE demscore.countries;
ANALYZE demscore.hex_mesh;

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
  geom geometry(Polygon, 3857)
)
LANGUAGE SQL
STABLE
AS $$
WITH normalized AS (
  SELECT
    lower(p_dataset) AS dataset,
    p_variable AS variable,
    GREATEST(1500, LEAST(2100, p_year)) AS year,
    GREATEST(40000, LEAST(600000, p_hex_size_m))::INT AS hex_size_m
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
