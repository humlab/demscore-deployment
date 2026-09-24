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
  IF to_regclass('demscore.cshapes_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.cshapes_src. Run scripts/setup_mapserver_hex_service.sh to import CShapes historical boundaries.';
  END IF;
  IF to_regclass('demscore.historical_country_geometries_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.historical_country_geometries_src. Run sql/historical_geometry.sql first (scripts/setup_mapserver_hex_service.sh does).';
  END IF;
  IF to_regclass('demscore.country_resolution_policy') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.country_resolution_policy. Run sql/historical_geometry.sql first (scripts/setup_mapserver_hex_service.sh does).';
  END IF;
END;
$$;

-- The Mercator mesh goes too, though this file does not build it: its tables
-- carry foreign keys into demscore.countries, so dropping that table without
-- them fails outright and a second run of this script on a built database is
-- refused. sql/mapserver_hex_mercator.sql rebuilds them immediately after --
-- scripts/setup_mapserver_hex_service.sh runs the two in that order -- so run
-- that file too if you run this one on its own.
DROP TABLE IF EXISTS demscore.hex_border_sides_mercator;
DROP TABLE IF EXISTS demscore.hex_border_edges_mercator;
DROP TABLE IF EXISTS demscore.hex_borders_mercator;
DROP TABLE IF EXISTS demscore.hex_mesh_mercator;
DROP TABLE IF EXISTS demscore.hex_border_sides;
DROP TABLE IF EXISTS demscore.hex_border_edges;
-- The single-row-per-country-pair table these two replace. Still dropped so a
-- redeploy over a database built before the split leaves nothing behind.
DROP TABLE IF EXISTS demscore.hex_borders;
DROP TABLE IF EXISTS demscore.hex_mesh;
DROP TABLE IF EXISTS demscore.countries;
DROP TABLE IF EXISTS demscore.dataset_value_unmapped_audit;

-- demscore.country_aliases and its replacement, demscore.country_resolution_policy,
-- are built by sql/historical_geometry.sql, which runs before this file. The
-- policy table is read here rather than written: which historical geometry a
-- source entity is allowed to become is a curation decision, and keeping it in
-- one file next to the geometry it points at is what lets
-- scripts/check_country_resolution.sh check the two against each other.

CREATE TABLE demscore.countries (
  id BIGSERIAL PRIMARY KEY,
  name TEXT,
  iso_a3 TEXT,
  iso_a2 TEXT,
  id_key TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'natural_earth',
  source_key TEXT,
  gwcode INTEGER,
  registry_key TEXT,
  valid_from_year INTEGER,
  valid_to_year INTEGER,
  -- Where this country's outline came from, and how far it is to be trusted.
  -- A Natural Earth country and a grand duchy traced off an 1815 snapshot both
  -- end up as a row here with hexagons on it, and nothing else downstream can
  -- tell them apart -- the WMS image least of all. These three columns are what
  -- /api/map-data and /api/source-coverage read so the table beside the map can
  -- say which is which. demscore.historical_country_geometries_src holds the
  -- full provenance; this is the part every consumer needs.
  geometry_source_dataset TEXT NOT NULL DEFAULT 'natural_earth_50m',
  geometry_source_license TEXT NOT NULL DEFAULT 'Public domain',
  geometry_confidence TEXT NOT NULL DEFAULT 'high'
    CHECK (geometry_confidence IN ('high', 'medium', 'low')),
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
INSERT INTO demscore.countries
  (name, iso_a3, iso_a2, id_key, source, source_key, geom_4326, geom_8857)
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
  'natural_earth' AS source,
  'natural_earth:' || COALESCE(c.iso_a3, lower(c.name)) AS source_key,
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

-- Historical countries the resolution policy sends to CShapes 2.0. CShapes
-- carries one row per validity period, so the source year can land on the
-- matching period instead of forcing dissolved modern borders onto historical
-- data.
INSERT INTO demscore.countries
  (name, iso_a3, iso_a2, id_key, source, source_key, gwcode, valid_from_year, valid_to_year,
   geometry_source_dataset, geometry_source_license, geometry_confidence, geom_4326, geom_8857)
SELECT
  src.cntry_name AS name,
  NULL::TEXT AS iso_a3,
  NULL::TEXT AS iso_a2,
  'cshapes_' || src.gwcode::TEXT || '_' || src.id::TEXT AS id_key,
  'cshapes' AS source,
  'cshapes:' || src.gwcode::TEXT || ':' || src.id::TEXT AS source_key,
  src.gwcode::INTEGER AS gwcode,
  src.gwsyear::INTEGER AS valid_from_year,
  src.gweyear::INTEGER AS valid_to_year,
  'cshapes_2.0' AS geometry_source_dataset,
  'CC BY-NC-SA 4.0' AS geometry_source_license,
  -- CShapes is period-aware, and the matching pass below only ever lands a year
  -- inside a period's own span, so every row it supplies is a boundary that
  -- source says was in force that year.
  'high' AS geometry_confidence,
  ST_Multi(ST_MakeValid(src.geom))::geometry(MultiPolygon, 4326) AS geom_4326,
  ST_Multi(
    ST_CollectionExtract(
      ST_MakeValid(ST_Transform(ST_MakeValid(src.geom), 8857)),
      3
    )
  )::geometry(MultiPolygon, 8857) AS geom_8857
FROM demscore.cshapes_src src
JOIN (
  SELECT DISTINCT target_gwcode
  FROM demscore.country_resolution_policy
  WHERE status = 'cshapes'
) a ON a.target_gwcode = src.gwcode
WHERE src.geom IS NOT NULL
  AND src.gwcode IS NOT NULL
  AND src.cntry_name IS NOT NULL
  AND NOT ST_IsEmpty(
    ST_CollectionExtract(
      ST_MakeValid(ST_Transform(ST_MakeValid(src.geom), 8857)),
      3
    )
  );

-- The curated historical registry: every polygon sql/historical_geometry.sql
-- assembled, whatever upstream source it came from. These arrive as countries
-- of their own rather than as aliases onto a present-day row, because a source
-- coding unit folded onto a modern country would be averaged together with it
-- by demscore.country_scores() -- V-Dem codes both a pre-partition Vietnam and
-- a northern one for the years 1945 to 1953, and one row could not hold both.
INSERT INTO demscore.countries
  (name, iso_a3, iso_a2, id_key, source, source_key, registry_key, valid_from_year, valid_to_year,
   geometry_source_dataset, geometry_source_license, geometry_confidence, geom_4326, geom_8857)
SELECT
  r.normalized_name AS name,
  NULL::TEXT AS iso_a3,
  NULL::TEXT AS iso_a2,
  'histgeom_' || r.registry_key || '_' || r.valid_from_year::TEXT AS id_key,
  'historical_registry' AS source,
  'historical_registry:' || r.registry_key || ':' || r.valid_from_year::TEXT AS source_key,
  r.registry_key,
  r.valid_from_year,
  r.valid_to_year,
  r.source_dataset,
  r.source_license,
  r.confidence,
  ST_Multi(ST_MakeValid(r.geom))::geometry(MultiPolygon, 4326) AS geom_4326,
  ST_Multi(
    ST_CollectionExtract(
      ST_MakeValid(ST_Transform(ST_MakeValid(r.geom), 8857)),
      3
    )
  )::geometry(MultiPolygon, 8857) AS geom_8857
FROM demscore.historical_country_geometries_src r
WHERE NOT ST_IsEmpty(
  ST_CollectionExtract(
    ST_MakeValid(ST_Transform(ST_MakeValid(r.geom), 8857)),
    3
  )
);

CREATE INDEX countries_iso_a3_idx ON demscore.countries (iso_a3);
CREATE INDEX countries_name_lc_idx ON demscore.countries (lower(name));
CREATE INDEX countries_source_idx ON demscore.countries (source);
CREATE INDEX countries_source_key_idx ON demscore.countries (source_key);
CREATE INDEX countries_gwcode_year_idx ON demscore.countries (gwcode, valid_from_year, valid_to_year);
CREATE INDEX countries_registry_key_year_idx ON demscore.countries (registry_key, valid_from_year, valid_to_year);
CREATE INDEX countries_geom_4326_gix ON demscore.countries USING GIST (geom_4326);
CREATE INDEX countries_geom_8857_gix ON demscore.countries USING GIST (geom_8857);

UPDATE demscore.dataset_values
SET country_id = NULL;

-- Matching runs policy first, then the two direct matches.
--
-- The order is the point. demscore.country_resolution_policy is a decision
-- somebody wrote down; an ISO3 that happens to equal a Natural Earth code is an
-- accident of two code lists agreeing. When they disagree the written decision
-- has to win, or a policy row narrowing an entity to part of its span would be
-- quietly overtaken by a direct match on the rest.

-- Pass 1: policy rows pointing at a present-day Natural Earth country.
WITH matches AS (
  SELECT DISTINCT ON (dv.id)
    dv.id AS dataset_value_id,
    c.id AS country_id
  FROM demscore.dataset_values dv
  JOIN demscore.variables v ON v.id = dv.variable_id
  JOIN demscore.country_resolution_policy p
    ON p.dataset = v.dataset
   AND p.status = 'natural_earth'
   AND (p.source_iso3 IS NULL OR (dv.iso3 IS NOT NULL AND upper(p.source_iso3) = upper(dv.iso3)))
   AND (p.source_name IS NULL OR (dv.country_name IS NOT NULL AND lower(p.source_name) = lower(dv.country_name)))
   AND (p.from_year IS NULL OR dv.year >= p.from_year)
   AND (p.to_year IS NULL OR dv.year <= p.to_year)
  JOIN demscore.countries c
    ON c.source = 'natural_earth'
   AND (
     (p.target_iso3 IS NOT NULL AND c.iso_a3 IS NOT NULL AND upper(c.iso_a3) = upper(p.target_iso3))
     OR
     (p.target_name IS NOT NULL AND lower(c.name) = lower(p.target_name))
   )
  WHERE dv.country_id IS NULL
  ORDER BY dv.id, c.id
)
UPDATE demscore.dataset_values dv
SET country_id = m.country_id
FROM matches m
WHERE dv.id = m.dataset_value_id;

-- Pass 2: policy rows pointing at a CShapes 2.0 historical period.
WITH matches AS (
  SELECT DISTINCT ON (dv.id)
    dv.id AS dataset_value_id,
    c.id AS country_id
  FROM demscore.dataset_values dv
  JOIN demscore.variables v ON v.id = dv.variable_id
  JOIN demscore.country_resolution_policy p
    ON p.dataset = v.dataset
   AND p.status = 'cshapes'
   AND (p.source_iso3 IS NULL OR (dv.iso3 IS NOT NULL AND upper(p.source_iso3) = upper(dv.iso3)))
   AND (p.source_name IS NULL OR (dv.country_name IS NOT NULL AND lower(p.source_name) = lower(dv.country_name)))
   AND (p.from_year IS NULL OR dv.year >= p.from_year)
   AND (p.to_year IS NULL OR dv.year <= p.to_year)
  JOIN demscore.countries c
    ON c.source = 'cshapes'
   AND c.gwcode = p.target_gwcode
   AND (c.valid_from_year IS NULL OR dv.year >= c.valid_from_year)
   AND (c.valid_to_year IS NULL OR dv.year <= c.valid_to_year)
  WHERE dv.country_id IS NULL
  -- Some CShapes transitions have more than one feature touching the same year.
  -- Country-year data gets the latest-starting period for that year.
  ORDER BY dv.id, c.valid_from_year DESC NULLS LAST, c.valid_to_year ASC NULLS LAST, c.id
)
UPDATE demscore.dataset_values dv
SET country_id = m.country_id
FROM matches m
WHERE dv.id = m.dataset_value_id;

-- Pass 3: policy rows pointing at the curated historical registry.
--
-- The registry's own validity periods choose the polygon inside the window the
-- policy row opens, which is what lets one policy row cover Bavaria from 1789
-- to 1871 across a snapshot, a backward extension, five border-change periods
-- and a forward extension. An exclusion constraint on the registry makes those
-- periods non-overlapping, so at most one can match and no tie-break is needed.
WITH matches AS (
  SELECT
    dv.id AS dataset_value_id,
    c.id AS country_id
  FROM demscore.dataset_values dv
  JOIN demscore.variables v ON v.id = dv.variable_id
  JOIN demscore.country_resolution_policy p
    ON p.dataset = v.dataset
   AND p.status = 'historical_registry'
   AND (p.source_iso3 IS NULL OR (dv.iso3 IS NOT NULL AND upper(p.source_iso3) = upper(dv.iso3)))
   AND (p.source_name IS NULL OR (dv.country_name IS NOT NULL AND lower(p.source_name) = lower(dv.country_name)))
   AND (p.from_year IS NULL OR dv.year >= p.from_year)
   AND (p.to_year IS NULL OR dv.year <= p.to_year)
  JOIN demscore.countries c
    ON c.source = 'historical_registry'
   AND c.registry_key = p.target_registry_key
   AND dv.year BETWEEN c.valid_from_year AND c.valid_to_year
  WHERE dv.country_id IS NULL
)
UPDATE demscore.dataset_values dv
SET country_id = m.country_id
FROM matches m
WHERE dv.id = m.dataset_value_id;

-- Pass 4: the source's own ISO3 against a present-day country code.
UPDATE demscore.dataset_values dv
SET country_id = c.id
FROM demscore.countries c
WHERE dv.country_id IS NULL
  AND dv.iso3 IS NOT NULL
  AND c.source = 'natural_earth'
  AND upper(c.iso_a3) = upper(dv.iso3);

-- Pass 5: the source's own country name against a present-day country name.
UPDATE demscore.dataset_values dv
SET country_id = c.id
FROM demscore.countries c
WHERE dv.country_id IS NULL
  AND dv.country_name IS NOT NULL
  AND c.source = 'natural_earth'
  AND lower(c.name) = lower(dv.country_name);

-- An `intentionally_unsupported` policy row is a refusal, so it has to be able
-- to overrule a later match as well as the absence of one. Nothing in the
-- current policy set reaches this -- South Yemen before 1967 has no ISO3 or
-- name Natural Earth answers to -- but a refusal that only worked while no
-- other pass happened to match would be a decision the next source revision
-- could undo without anybody noticing.
UPDATE demscore.dataset_values dv
SET country_id = NULL
FROM demscore.variables v, demscore.country_resolution_policy p
WHERE v.id = dv.variable_id
  AND dv.country_id IS NOT NULL
  AND p.dataset = v.dataset
  AND p.status = 'intentionally_unsupported'
  AND (p.source_iso3 IS NULL OR (dv.iso3 IS NOT NULL AND upper(p.source_iso3) = upper(dv.iso3)))
  AND (p.source_name IS NULL OR (dv.country_name IS NOT NULL AND lower(p.source_name) = lower(dv.country_name)))
  AND (p.from_year IS NULL OR dv.year >= p.from_year)
  AND (p.to_year IS NULL OR dv.year <= p.to_year);

-- Every matching pass has now run against every dataset_values row, so a
-- historical period nothing points to can never be reached: country_scores()
-- and hex_variable() only ever look up a country's hexagons by a country_id
-- that came out of dataset_values, and getMapData's LEFT JOIN keeps a
-- historical row only when scores found one (web-backend/server.js). CShapes
-- carries one row per border-change period rather than one per policy row, so a
-- long-lived state arrives as several near-duplicate, full-sized periods --
-- the Soviet Union (gwcode 365) as 24 of them, of which only one is ever
-- matched. Building a full hex mesh and border set at every hex_size for the
-- other 23 would be real work spent on rows no request can ever select, so
-- they are dropped here, before that work runs, rather than kept unused. The
-- registry is curated period by period and should lose nothing here; if it
-- does, scripts/check_country_resolution.sh says which key and why.
DELETE FROM demscore.countries c
WHERE c.source IN ('cshapes', 'historical_registry')
  AND NOT EXISTS (
    SELECT 1 FROM demscore.dataset_values dv WHERE dv.country_id = c.id
  );

ANALYZE demscore.countries;

-- What the map could not represent, and whether that was a decision.
--
-- Every row here is a source observation that exists and carries a value but
-- has no geometry to be drawn on. `resolution_status` is the part that matters:
-- `intentionally_unsupported` means demscore.country_resolution_policy names
-- this entity and this year window and gives a reason, and `unresolved` means
-- nothing does. scripts/check_country_resolution.sh fails the setup on the
-- second kind, so an entity can leave the map only by somebody deciding it
-- should.
CREATE TABLE demscore.dataset_value_unmapped_audit (
  dataset TEXT NOT NULL,
  variable TEXT NOT NULL,
  year INTEGER NOT NULL,
  iso3 TEXT,
  country_name TEXT,
  value_count BIGINT NOT NULL,
  min_value DOUBLE PRECISION,
  max_value DOUBLE PRECISION,
  resolution_status TEXT NOT NULL
    CHECK (resolution_status IN ('intentionally_unsupported', 'unresolved')),
  -- For an intentionally unsupported row, the policy's own reason. For an
  -- unresolved one, how far the match got, which is the first thing anybody
  -- adding a policy row needs to know.
  reason TEXT NOT NULL
);

INSERT INTO demscore.dataset_value_unmapped_audit
  (dataset, variable, year, iso3, country_name, value_count, min_value, max_value,
   resolution_status, reason)
SELECT
  v.dataset,
  v.variable,
  dv.year,
  dv.iso3,
  dv.country_name,
  count(*) AS value_count,
  min(dv.value) AS min_value,
  max(dv.value) AS max_value,
  CASE WHEN unsupported.reason IS NOT NULL
    THEN 'intentionally_unsupported'
    ELSE 'unresolved'
  END AS resolution_status,
  COALESCE(
    unsupported.reason,
    CASE
      WHEN matched_policy.exists_any
        THEN 'policy_covers_entity_but_not_this_year'
      ELSE 'no_policy_for_this_entity'
    END
  ) AS reason
FROM demscore.dataset_values dv
JOIN demscore.variables v ON v.id = dv.variable_id
LEFT JOIN LATERAL (
  SELECT p.reason
  FROM demscore.country_resolution_policy p
  WHERE p.dataset = v.dataset
    AND p.status = 'intentionally_unsupported'
    AND (p.source_iso3 IS NULL OR (dv.iso3 IS NOT NULL AND upper(p.source_iso3) = upper(dv.iso3)))
    AND (p.source_name IS NULL OR (dv.country_name IS NOT NULL AND lower(p.source_name) = lower(dv.country_name)))
    AND (p.from_year IS NULL OR dv.year >= p.from_year)
    AND (p.to_year IS NULL OR dv.year <= p.to_year)
  ORDER BY p.id
  LIMIT 1
) unsupported ON TRUE
LEFT JOIN LATERAL (
  SELECT TRUE AS exists_any
  FROM demscore.country_resolution_policy p
  WHERE p.dataset = v.dataset
    AND (p.source_iso3 IS NULL OR (dv.iso3 IS NOT NULL AND upper(p.source_iso3) = upper(dv.iso3)))
    AND (p.source_name IS NULL OR (dv.country_name IS NOT NULL AND lower(p.source_name) = lower(dv.country_name)))
  LIMIT 1
) matched_policy ON TRUE
WHERE dv.country_id IS NULL
GROUP BY v.dataset, v.variable, dv.year, dv.iso3, dv.country_name,
         unsupported.reason, matched_policy.exists_any;

CREATE INDEX dataset_value_unmapped_audit_dataset_idx
  ON demscore.dataset_value_unmapped_audit (dataset);
CREATE INDEX dataset_value_unmapped_audit_country_idx
  ON demscore.dataset_value_unmapped_audit (dataset, iso3, country_name);
CREATE INDEX dataset_value_unmapped_audit_status_idx
  ON demscore.dataset_value_unmapped_audit (resolution_status);

ANALYZE demscore.dataset_values;
ANALYZE demscore.dataset_value_unmapped_audit;

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

-- Countries the grid missed, given a hexagon anyway.
--
-- The rule above keeps a cell when its centre lands inside the country, and that
-- test is a lottery for anything smaller than a few cells: whether a country is
-- on the map depends on where the global grid's phase falls over it, not on how
-- big it is. Denmark had one cell at 200k and *none* at 100k -- the finer mesh
-- showed less -- and Nepal, half again the area of a 200k cell, had none at all,
-- because every cell along the Himalaya is centred in India or China. A country
-- with data and no hexagons reads as a country with no data, which is the one
-- thing the map must not say.
--
-- So every country the rule left empty at a given size is given the cells that
-- hold the most of it. The hexagons spill across the border, and that is
-- accepted: this is an approximate map -- a hexagon means "this country's score
-- around here", not a parcel boundary -- and showing the country matters more
-- than the fit.
--
-- A cell is available to a country that has none when
--   * nobody holds it: its centre is at sea, so no country loses anything;
--   * the country holds more of it than any other, which is the better claim
--     even though the centre fell elsewhere -- Nepal fills 62% of the cell that
--     went to India; or
--   * the country holds at least a fifth of it, so a weaker claim can still put
--     Estonia or Belgium on the map where a neighbour holds more but can spare
--     the cell.
-- Anything less gets nothing and waits for a finer stop. Luxembourg at 2% of a
-- 200k cell is not a hexagon's worth of country, and drawing one would be a lie
-- about the other 98% of the hexagon. Neither is a claim enough on its own: the
-- cell also has to be one its owner can spare, which is what keeps this from
-- filling one hole by opening another. Hungary fills 66% of a 200k cell and
-- still waits for the next stop, because that cell is all Slovakia has.
--
-- How many cells: at most what the country's own area could fill, so the
-- fallback never draws a country bigger than it is, and past the first only
-- cells that are a quarter country or better, so the extra hexagon is real land
-- and not a clipped corner. Denmark comes out with two cells at 100k, which is
-- what 42 777 km2 buys against a 25 980 km2 cell.
-- A historical country borrows a cell; it never takes one.
--
-- The dealing below moves cells between countries, which is right while the
-- mesh is a partition of the grid among the countries on the map at once. The
-- historical rows are not part of that partition: they are an overlay, drawn
-- for the years they were in force and invisible otherwise. Letting one of them
-- take a cell removes it from a present-day country in *every* year -- Germany
-- fell from 11 cells to 6 at 100 km once the pre-unification states arrived,
-- and Ukraine had already lost four to the Soviet Union. So the claim logic is
-- unchanged and only the eviction is conditional: when either side of a
-- transfer is historical, the claimant gets the cell and the owner keeps it
-- too. Two countries then hold the same geometry, which the border tables
-- already allow for and which is what the Soviet mesh lying over Russia has
-- always been.
CREATE TEMP TABLE hex_fallback ON COMMIT DROP AS
WITH sizes AS (
  SELECT generate_series(20000, 300000, 5000)::INT AS hex_size_m
), unplaced AS (
  SELECT c.id AS country_id, c.id_key, s.hex_size_m, c.geom_8857 AS country_geom
  FROM demscore.countries c
  CROSS JOIN sizes s
  WHERE NOT ST_IsEmpty(c.geom_8857)
    AND NOT EXISTS (
      SELECT 1 FROM demscore.hex_mesh hm
      WHERE hm.country_id = c.id AND hm.hex_size_m = s.hex_size_m
    )
), candidates AS (
  SELECT
    u.country_id,
    u.id_key,
    u.hex_size_m,
    g.geom AS hex_geom,
    ST_Area(ST_Intersection(g.geom, u.country_geom)) AS overlap_m2,
    ST_Area(g.geom) AS hex_m2,
    GREATEST(1, ceil(ST_Area(u.country_geom) / ST_Area(g.geom))::INT) AS fair_share,
    -- Whose cell this is. The centre test here and the rule above are the
    -- same test, so a non-NULL owner always holds this cell in the mesh.
    (
      SELECT c2.id FROM demscore.countries c2
      WHERE ST_Within(ST_PointOnSurface(g.geom), c2.geom_8857)
      -- A historical polygon can contain this centre too, and the owner has to
      -- be the country that holds the cell in the partition, not whichever row
      -- the planner reached first.
      ORDER BY (c2.source = 'natural_earth') DESC, c2.id
      LIMIT 1
    ) AS owner_id,
    -- The most any other country holds of this cell, owner or not.
    COALESCE((
      SELECT max(ST_Area(ST_Intersection(g.geom, c2.geom_8857)))
      FROM demscore.countries c2
      WHERE c2.id <> u.country_id AND ST_Intersects(c2.geom_8857, g.geom)
    ), 0) AS rival_m2
  FROM unplaced u
  CROSS JOIN LATERAL ST_HexagonGrid(u.hex_size_m::FLOAT8, u.country_geom) g
  WHERE ST_Intersects(g.geom, u.country_geom)
), eligible AS (
  SELECT
    c.*,
    (
      SELECT count(*) FROM demscore.hex_mesh hm
      WHERE hm.country_id = c.owner_id AND hm.hex_size_m = c.hex_size_m
    ) AS owner_cells
  FROM candidates c
  WHERE c.owner_id IS NULL
     OR c.overlap_m2 >= c.rival_m2
     OR c.overlap_m2 >= 0.2 * c.hex_m2
), uncontested AS (
  -- Two empty countries can want the same cell; it goes to the one holding
  -- more of it.
  SELECT * FROM (
    SELECT e.*, row_number() OVER (
      PARTITION BY e.hex_size_m, e.hex_geom
      ORDER BY e.overlap_m2 DESC, e.country_id
    ) AS cell_rank
    FROM eligible e
  ) ranked_cells
  WHERE cell_rank = 1
), within_share AS (
  SELECT * FROM (
    SELECT u.*, row_number() OVER (
      PARTITION BY u.country_id, u.hex_size_m
      ORDER BY u.overlap_m2 DESC
    ) AS pick
    FROM uncontested u
  ) ranked_picks
  WHERE pick <= fair_share
    AND (pick = 1 OR overlap_m2 >= 0.25 * hex_m2)
)
SELECT
  w.country_id,
  w.id_key,
  w.hex_size_m,
  w.hex_geom,
  w.owner_id
FROM (
  SELECT
    ws.*,
    row_number() OVER (
      PARTITION BY ws.owner_id, ws.hex_size_m ORDER BY ws.overlap_m2 DESC
    ) AS take_rank
  FROM within_share ws
) w
-- Whatever the claim, the country it is taken from keeps a cell. An owner
-- exists only because the centre rule gave it this one, so it always has
-- this one, and `owner_cells - 1` is what it can spare. Filling one hole by
-- opening another is not a trade worth making, so a country whose only
-- reachable cells are last cells gets nothing and waits for a finer stop.
WHERE w.owner_id IS NULL
   OR w.take_rank <= w.owner_cells - 1;

-- The country that had it gives it up -- unless either side is historical, in
-- which case the claimant only borrows it and the owner keeps it too (see the
-- note above this pass). Matching by geometry is exact because both sides are
-- cells of the same global ST_HexagonGrid -- the same reason the border table
-- below groups segments by geometry.
DELETE FROM demscore.hex_mesh hm
USING hex_fallback f
WHERE hm.country_id = f.owner_id
  AND hm.hex_size_m = f.hex_size_m
  AND hm.geom = f.hex_geom
  AND EXISTS (
    SELECT 1 FROM demscore.countries owner, demscore.countries claimant
    WHERE owner.id = f.owner_id AND claimant.id = f.country_id
      AND owner.source = 'natural_earth'
      AND claimant.source = 'natural_earth'
  );

INSERT INTO demscore.hex_mesh (country_id, hex_size_m, hex_n, id_key, geom)
SELECT
  f.country_id,
  f.hex_size_m,
  -- The country was empty at this size, so the numbering starts over at 1.
  row_number() OVER (
    PARTITION BY f.country_id, f.hex_size_m
    ORDER BY ST_YMin(f.hex_geom), ST_XMin(f.hex_geom)
  ) AS hex_n,
  f.id_key,
  f.hex_geom::geometry(Polygon, 8857)
FROM hex_fallback f;

-- Everyone else, guaranteed.
--
-- The pass above refuses to take a neighbour's last cell, which leaves the
-- countries whose only reachable cells are last cells -- Hungary filling 66% of
-- the one cell Slovakia has at 200k. This pass takes those, because a country
-- that vanishes is worse than a neighbour that moves over, and the country it
-- takes from is then unplaced itself and picks again on the next round.
--
-- It cannot ping-pong. A last cell is only ever taken by a country that holds
-- more of it than the country that had it, so it is never taken straight back,
-- and each move strictly increases how much of that cell its holder covers --
-- a quantity that cannot increase forever. Rounds stop when one places nobody;
-- measured, the third round is already empty.
--
-- Cells nobody would lose come first, so displacing is the last resort rather
-- than the first move: an unheld cell, then one from a country with cells to
-- spare, then a last cell. One cell each -- what is being guaranteed here is
-- that the country is on the map at all, not that it is drawn to size.
DO $$
DECLARE
  placed BIGINT;
BEGIN
  FOR attempt IN 1..8 LOOP
    CREATE TEMP TABLE hex_guarantee AS
    WITH sizes AS (
      SELECT generate_series(20000, 300000, 5000) AS hex_size_m
    ), unplaced AS (
      SELECT c.id AS country_id, c.id_key, s.hex_size_m, c.geom_8857 AS country_geom
      FROM demscore.countries c
      CROSS JOIN sizes s
      WHERE NOT ST_IsEmpty(c.geom_8857)
        AND NOT EXISTS (
          SELECT 1 FROM demscore.hex_mesh hm
          WHERE hm.country_id = c.id AND hm.hex_size_m = s.hex_size_m
        )
    ), candidates AS (
      SELECT
        u.country_id,
        u.id_key,
        u.hex_size_m,
        g.geom AS hex_geom,
        ST_Area(ST_Intersection(g.geom, u.country_geom)) AS overlap_m2,
        held.country_id AS owner_id,
        held.cells AS owner_cells,
        COALESCE(ST_Area(ST_Intersection(g.geom, oc.geom_8857)), 0) AS owner_overlap_m2
      FROM unplaced u
      CROSS JOIN LATERAL ST_HexagonGrid(u.hex_size_m::FLOAT8, u.country_geom) g
      -- Who holds this cell *now*, read from the mesh rather than from the centre
      -- rule, because by this point the mesh also holds cells the pass above
      -- handed out, whose centres are somewhere else entirely.
      LEFT JOIN LATERAL (
        SELECT
          hm.country_id,
          (
            SELECT count(*) FROM demscore.hex_mesh h2
            WHERE h2.country_id = hm.country_id AND h2.hex_size_m = u.hex_size_m
          ) AS cells
        FROM demscore.hex_mesh hm
        WHERE hm.hex_size_m = u.hex_size_m
          AND hm.geom ~= g.geom
          AND hm.geom = g.geom
        -- Several countries can hold one cell -- a historical overlay over a
        -- present-day country, or two islands sharing a cell whose centre is at
        -- sea -- so pick the present-day holder, and break the remaining tie by
        -- id rather than leaving it to the planner.
        ORDER BY (
          SELECT (c3.source = 'natural_earth')
          FROM demscore.countries c3 WHERE c3.id = hm.country_id
        ) DESC, hm.country_id
        LIMIT 1
      ) held ON TRUE
      LEFT JOIN demscore.countries oc ON oc.id = held.country_id
      WHERE ST_Intersects(g.geom, u.country_geom)
    ), costed AS (
      SELECT
        c.*,
        CASE
          WHEN c.owner_id IS NULL THEN 0            -- nobody loses anything
          WHEN c.owner_cells > 1 THEN 1             -- the owner can spare it
          WHEN c.overlap_m2 > c.owner_overlap_m2 THEN 2  -- a last cell, better held here
          ELSE NULL                                 -- a last cell, and not ours to take
        END AS cost
      FROM candidates c
    ), chosen AS (
      SELECT * FROM (
        SELECT c.*, row_number() OVER (
          PARTITION BY c.country_id, c.hex_size_m
          ORDER BY c.cost, c.overlap_m2 DESC
        ) AS pick
        FROM costed c
        WHERE c.cost IS NOT NULL
      ) ranked_picks
      WHERE pick = 1
    ), uncontested AS (
      SELECT * FROM (
        SELECT c.*, row_number() OVER (
          PARTITION BY c.hex_size_m, c.hex_geom
          ORDER BY c.overlap_m2 DESC, c.country_id
        ) AS cell_rank
        FROM chosen c
      ) ranked_cells
      WHERE cell_rank = 1
    )
    SELECT t.country_id, t.id_key, t.hex_size_m, t.hex_geom, t.owner_id
    FROM (
      SELECT u.*, row_number() OVER (
        PARTITION BY u.owner_id, u.hex_size_m ORDER BY u.overlap_m2 DESC
      ) AS take_rank
      FROM uncontested u
    ) t
    -- Spare cells stay spare: several countries taking from the same owner in
    -- one round must still leave it one. A deliberate last-cell take is exempt.
    WHERE t.owner_id IS NULL
       OR t.cost = 2
       OR t.take_rank <= t.owner_cells - 1;

    DELETE FROM demscore.hex_mesh hm
    USING hex_guarantee f
    WHERE hm.country_id = f.owner_id
      AND hm.hex_size_m = f.hex_size_m
      AND hm.geom = f.hex_geom
      AND EXISTS (
        SELECT 1 FROM demscore.countries owner, demscore.countries claimant
        WHERE owner.id = f.owner_id AND claimant.id = f.country_id
          AND owner.source = 'natural_earth'
          AND claimant.source = 'natural_earth'
      );

    INSERT INTO demscore.hex_mesh (country_id, hex_size_m, hex_n, id_key, geom)
    SELECT f.country_id, f.hex_size_m, 1, f.id_key, f.hex_geom::geometry(Polygon, 8857)
    FROM hex_guarantee f;

    GET DIAGNOSTICS placed = ROW_COUNT;
    DROP TABLE hex_guarantee;
    EXIT WHEN placed = 0;
  END LOOP;
END;
$$;

-- And the countries no grid can seat, which are left unseated.
--
-- What is left is not a scheduling failure, it is arithmetic. At 200k the cells
-- covering the western Balkans number fewer than the countries standing on
-- them, so however the cells are dealt out, somebody gets none: Kosovo,
-- Montenegro, North Macedonia, Palestine and Slovenia in Equal Earth, four of
-- the same in Mercator. No rule about who deserves which cell can fix a
-- shortage of cells.
--
-- They get nothing, and wait for a finer stop. There used to be an `inset` pass
-- here: a hexagon from the grid one notch finer -- half the edge, a quarter of
-- the area -- sitting where the country is and drawn on top of the cell it
-- landed on, by a layer of its own. It is gone. Every hexagon on this map is
-- one fixed real area, which is the only reading under which a hexagon count
-- means anything, and a cell drawn at another size breaks the one rule the mesh
-- exists to keep. It also does not read as a country: half the width of
-- everything around it and with a perimeter of its own, an inset looked like a
-- rendering fault sitting inside a neighbour's cell.
--
-- The cost is real and is accepted. 34 coding units that carry data draw nothing
-- at 200k -- 23 distinct names: Slovenia, Luxembourg, Montenegro, North
-- Macedonia, Kosovo, San Marino, Liechtenstein, three Caribbean states, the four
-- Palestine units and eight pre-unification German and Italian states. At 100k
-- five are still undrawn (the Palestine units and Saint Kitts and Nevis); at 50k
-- none are. They are missing from the picture only: demscore.country_scores() is
-- unchanged, so the spoken summary, the class breaks and the accessible data
-- table still carry them at every zoom. The map is the one view that cannot hold
-- them, and drawing them at another size was not holding them either.
--
-- The mesh is therefore a strict partition again at every size: one cell, one
-- country. The only overlaps left are the intended ones -- a historical
-- country's cells lying over a present-day country's for the years it was in
-- force -- and those are full-size cells of the same grid.

-- Where to draw the black outline.
--
-- Same-country neighbouring hexagons that landed in the same quantile class are
-- interior to one colour area and keep only their white hairlines. Different
-- rendered country/coding-unit ids are still stroked even when they share a
-- class, because historical overlays and split countries otherwise make real
-- boundaries, and sometimes apparent coastlines, disappear when adjacent units
-- happen to use the same shade.
--
-- Dissolving that perimeter at render time (ST_Union per class, per tile) would
-- be both slow and wrong at tile seams, where the union cannot see the
-- neighbours just outside the request box. It is also unnecessary: a hexagon's
-- class is its country's class, so the only edges that can ever be stroked are
-- the ones where the hexagons meeting on them do not all belong to one country.
-- Which edges those are does not depend on the dataset, variable or year, so
-- they are precomputed once here and merely *filtered* per request. Edges whose
-- hexagons all belong to one country are dropped and never drawn -- two thirds
-- of them, 47 000 of 71 000 at 50 km.
--
-- It takes two tables because an edge can have more than two sides. Seating
-- every country means cells that overlap -- one displaced onto a neighbour that
-- held less of it -- and the CShapes historical countries lay a second mesh over
-- the current one, 6 740 cells of Soviet Union over Russia and its neighbours at
-- 50 km alone. So
-- `hex_border_edges` holds the edge and its geometry, and `hex_border_sides`
-- holds one row per country with hexagons on it. One row naming a country_a and
-- a country_b cannot carry that: keeping only the lowest and highest country,
-- as this table first did, dropped the third and with it 1 899 edges per mesh.
--
-- What the split buys is that the render-time question -- is there anything on
-- the other side of this edge, is it a different country/coding unit, and is it
-- a different colour? -- is answered from the mesh as a whole rather than from
-- the hexagons that happened to fall inside the request box. Counting only the
-- countries a request actually renders, an edge is stroked when either
--   * exactly one hexagon sits on it, so it is a perimeter with the map's
--     background on the other side,
--   * more than one rendered country/coding unit sits on it, or
--   * the hexagons on it carry more than one class.
-- Both read their counts out of `hex_border_sides`, so a tile cannot mistake the
-- edge of its own request box for the edge of the map. Deriving them from what
-- the box returned did exactly that: MapServer substitutes !BOX! with the extent
-- of pixel *centres*, half a pixel smaller than the tile on every side, and the
-- rim of the hexagons that came back was stroked as a dashed line along every
-- tile seam.
--
-- `hex_count` is how many of that country's own hexagons touch the edge. It is
-- normally one, and more where the country's own cells overlap -- which is what
-- keeps an edge interior to that country even when a second country also has a
-- cell on it, the Russia/Soviet Union case.
--
-- Matching edges by exact geometry is safe because the meshes come from
-- ST_HexagonGrid, so hexagons of adjacent countries are cells of one global
-- grid and a shared edge is bit-identical on both sides.
CREATE TEMP TABLE hex_border_build ON COMMIT DROP AS
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
    array_agg(country_id) AS countries,
    count(*) AS hex_count,
    count(DISTINCT country_id) AS country_count
  FROM directed
  GROUP BY hex_size_m, geom
)
SELECT
  row_number() OVER () AS edge_id,
  hex_size_m,
  geom,
  countries
FROM edges
WHERE country_count > 1
   OR hex_count = 1;

CREATE TABLE demscore.hex_border_edges (
  id BIGINT PRIMARY KEY,
  hex_size_m INTEGER NOT NULL,
  geom geometry(LineString, 8857) NOT NULL
);

INSERT INTO demscore.hex_border_edges (id, hex_size_m, geom)
SELECT edge_id, hex_size_m, geom::geometry(LineString, 8857)
FROM hex_border_build;

CREATE TABLE demscore.hex_border_sides (
  edge_id BIGINT NOT NULL REFERENCES demscore.hex_border_edges(id) ON DELETE CASCADE,
  country_id BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  hex_count INTEGER NOT NULL,
  PRIMARY KEY (edge_id, country_id)
);

INSERT INTO demscore.hex_border_sides (edge_id, country_id, hex_count)
SELECT b.edge_id, c, count(*)
FROM hex_border_build b, unnest(b.countries) AS c
GROUP BY b.edge_id, c;

CREATE INDEX hex_border_edges_size_idx ON demscore.hex_border_edges (hex_size_m);
CREATE INDEX hex_border_edges_geom_gix ON demscore.hex_border_edges USING GIST (geom);
CREATE INDEX hex_border_sides_country_idx ON demscore.hex_border_sides (country_id);

ANALYZE demscore.countries;
ANALYZE demscore.hex_mesh;
ANALYZE demscore.hex_border_edges;
ANALYZE demscore.hex_border_sides;

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
), distinct_values AS (
  SELECT DISTINCT value
  FROM country_values
), class_plan AS (
  SELECT LEAST(7, count(*)::INTEGER) AS class_count
  FROM distinct_values
), ranked_values AS (
  SELECT
    value,
    dense_rank() OVER (ORDER BY value)::INTEGER AS value_rank
  FROM distinct_values
), ranked_countries AS (
  SELECT
    cv.country_id,
    cv.value,
    CASE
      WHEN cp.class_count = 0 THEN NULL
      ELSE FLOOR(
        (rv.value_rank - 1)::NUMERIC * cp.class_count
        / (SELECT count(*)::NUMERIC FROM distinct_values)
      )::INTEGER + 1
    END AS class_idx,
    min(cv.value) OVER () AS min_value,
    max(cv.value) OVER () AS max_value
  FROM country_values cv
  JOIN ranked_values rv ON rv.value = cv.value
  CROSS JOIN class_plan cp
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

-- What the source says, next to what the map can show.
--
-- demscore.country_scores() answers "what is on the map", and it can only ever
-- answer for entities that have geometry. That makes a source country this
-- deployment cannot draw indistinguishable, in every downstream reading, from
-- one the source never measured -- and those are opposite facts. This function
-- is the other half: one row per *source* coding unit that carries a value for
-- this variable-year, drawn or not, with `map_status` saying which.
--
--   mapped                    -- resolved to geometry and on the map
--   intentionally_unsupported -- a policy row names it and gives a reason
--   unresolved                -- nothing covers it; setup fails on these
--
-- `geometry_confidence` comes along for the mapped rows because a value drawn
-- on an 1815 snapshot and a value drawn on a present-day border are both just
-- coloured hexagons in the WMS image, and a reader deserves to be told which
-- they are looking at.
CREATE OR REPLACE FUNCTION demscore.source_coverage(
  p_dataset TEXT DEFAULT 'v_dem',
  p_variable TEXT DEFAULT 'v2x_polyarchy',
  p_year INTEGER DEFAULT 2020
)
RETURNS TABLE (
  source_name TEXT,
  source_iso3 TEXT,
  value DOUBLE PRECISION,
  map_status TEXT,
  map_country_name TEXT,
  geometry_source_dataset TEXT,
  geometry_confidence TEXT,
  reason TEXT
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
), source_rows AS (
  -- Grouped the same way demscore.country_scores() groups, so a source entity
  -- here is the same thing a country there is and the two counts can be
  -- subtracted from each other.
  SELECT
    COALESCE(dv.country_name, dv.iso3) AS source_name,
    dv.iso3 AS source_iso3,
    dv.country_id,
    AVG(dv.value)::DOUBLE PRECISION AS value
  FROM demscore.dataset_values dv
  JOIN demscore.variables v ON v.id = dv.variable_id
  JOIN normalized n
    ON v.dataset = n.dataset
   AND v.variable = n.variable
   AND dv.year = n.year
  GROUP BY 1, 2, 3
)
SELECT
  sr.source_name,
  sr.source_iso3,
  sr.value,
  CASE
    WHEN sr.country_id IS NOT NULL THEN 'mapped'
    WHEN unsupported.reason IS NOT NULL THEN 'intentionally_unsupported'
    ELSE 'unresolved'
  END AS map_status,
  c.name AS map_country_name,
  c.geometry_source_dataset,
  c.geometry_confidence,
  unsupported.reason
FROM source_rows sr
CROSS JOIN normalized n
LEFT JOIN demscore.countries c ON c.id = sr.country_id
LEFT JOIN LATERAL (
  SELECT p.reason
  FROM demscore.country_resolution_policy p
  WHERE sr.country_id IS NULL
    AND p.dataset = n.dataset
    AND p.status = 'intentionally_unsupported'
    AND (p.source_iso3 IS NULL OR (sr.source_iso3 IS NOT NULL AND upper(p.source_iso3) = upper(sr.source_iso3)))
    AND (p.source_name IS NULL OR (sr.source_name IS NOT NULL AND lower(p.source_name) = lower(sr.source_name)))
    AND (p.from_year IS NULL OR n.year >= p.from_year)
    AND (p.to_year IS NULL OR n.year <= p.to_year)
  ORDER BY p.id
  LIMIT 1
) unsupported ON TRUE;
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
