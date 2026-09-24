-- Curated historical country geometry, and the policy that says what every
-- source observation is allowed to become.
--
-- Run after the ogr2ogr imports in scripts/setup_mapserver_hex_service.sh and
-- before sql/mapserver_hex_setup.sql, which reads both tables this file builds.
--
-- Why a second historical layer at all: demscore.cshapes_src is CShapes 2.0,
-- which starts in 1886. V-Dem reaches back to 1789, and roughly 145 000 of its
-- loaded values belong to states that had stopped existing before CShapes
-- begins -- the German and Italian states of the Confederation era -- or to
-- coding units whose territory CShapes carries for only part of the span V-Dem
-- codes. Those rows were kept and audited but could not be drawn. This file is
-- where they get geometry, or an explicit refusal.
--
-- The registry deliberately holds its own copy of every polygon rather than
-- pointing at the upstream tables. A row here is one (entity, year span,
-- polygon) with the source, the licence, the citation and a confidence grade
-- attached to it, which is the only form in which a snapshot reconstruction and
-- a period-aware boundary can sit in the same table without one being mistaken
-- for the other.

BEGIN;

CREATE SCHEMA IF NOT EXISTS demscore;

-- Lets the registry declare "one entity's periods may not overlap" as a
-- constraint rather than as a check somebody remembers to run.
CREATE EXTENSION IF NOT EXISTS btree_gist;

DO $$
BEGIN
  IF to_regclass('demscore.cshapes_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.cshapes_src. Run scripts/setup_mapserver_hex_service.sh to import CShapes 2.0.';
  END IF;
  IF to_regclass('demscore.cshapes_europe_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.cshapes_europe_src. Run scripts/setup_mapserver_hex_service.sh to import CShapes-Europe.';
  END IF;
  IF to_regclass('demscore.historical_basemaps_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.historical_basemaps_src. Run scripts/setup_mapserver_hex_service.sh to import the historical-basemaps snapshots.';
  END IF;
  IF to_regclass('demscore.custom_historical_geometries_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.custom_historical_geometries_src. Run scripts/setup_mapserver_hex_service.sh to import custom historical approximations.';
  END IF;
  IF to_regclass('demscore.countries_src') IS NULL THEN
    RAISE EXCEPTION 'Missing table demscore.countries_src. Run scripts/setup_mapserver_hex_service.sh to import Natural Earth countries.';
  END IF;
END;
$$;

-- demscore.countries is rebuilt from this table by sql/mapserver_hex_setup.sql,
-- so it has to go first when this file is re-run on a built database.
DROP TABLE IF EXISTS demscore.historical_country_geometries_src CASCADE;
DROP TABLE IF EXISTS demscore.country_resolution_policy CASCADE;
-- The table the policy table replaces. Dropped so a redeploy over a database
-- built before this file leaves nothing behind that still looks authoritative.
DROP TABLE IF EXISTS demscore.country_aliases CASCADE;

-- ---------------------------------------------------------------------------
-- 1. The curated geometry registry
-- ---------------------------------------------------------------------------

CREATE TABLE demscore.historical_country_geometries_src (
  id BIGSERIAL PRIMARY KEY,
  -- One key per source coding unit. A unit's polygon can change hands between
  -- upstream sources partway through its life -- Bavaria is a
  -- historical-basemaps snapshot until 1805 and CShapes-Europe from 1806 -- and
  -- the key is what holds those periods together as one entity.
  registry_key TEXT NOT NULL,
  source_dataset TEXT NOT NULL,
  source_license TEXT NOT NULL,
  source_url TEXT NOT NULL,
  source_citation TEXT NOT NULL,
  -- Set only for snapshot sources, which is the whole point of recording it:
  -- a NULL here means the polygon came from a dataset that knows its own
  -- validity period, and a year here means it did not.
  source_snapshot_year INTEGER,
  source_name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  valid_from_year INTEGER NOT NULL,
  valid_to_year INTEGER NOT NULL,
  -- high:   a period-aware source, and the year falls inside its own period.
  -- medium: a period-aware polygon carried across years the V-Dem coding-unit
  --         history documents as territorially unchanged.
  -- low:    a snapshot reconstruction, or a polygon knowingly drawn for a
  --         different extent than the coding unit had in these years. Always
  --         say which in notes.
  confidence TEXT NOT NULL CHECK (confidence IN ('high', 'medium', 'low')),
  notes TEXT,
  geom geometry(MultiPolygon, 4326) NOT NULL,
  CHECK (valid_to_year >= valid_from_year),
  CHECK (source_snapshot_year IS NULL OR confidence = 'low'),
  CHECK (confidence <> 'low' OR notes IS NOT NULL),
  -- A year that matched two polygons for the same entity would put the same
  -- country on the map twice, so overlap is refused rather than resolved by
  -- an ORDER BY somewhere downstream.
  EXCLUDE USING gist (
    registry_key WITH =,
    int4range(valid_from_year, valid_to_year, '[]') WITH &&
  )
);

-- Open-ended periods use this rather than NULL, so the exclusion constraint
-- above has a range to compare. It is the upper clamp demscore.country_scores()
-- already applies to a requested year.
CREATE OR REPLACE FUNCTION demscore.historical_geometry_open_end()
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS $$ SELECT 2100 $$;

-- 1a. CShapes-Europe, the period-aware source for European states from 1816.
--
-- Seventeen of the nineteen pre-unification states V-Dem codes are in here with
-- their own border-change periods. The two that are not -- Tuscany and Hamburg
-- -- have no entry in CShapes-Europe at all, and Hanover is folded into the
-- United Kingdom until the personal union ends in 1838. Those three are picked
-- up from the snapshot source in 1c.
CREATE TEMPORARY TABLE ce_entities (
  registry_key TEXT PRIMARY KEY,
  gwcode INTEGER NOT NULL,
  normalized_name TEXT NOT NULL
) ON COMMIT DROP;

INSERT INTO ce_entities (registry_key, gwcode, normalized_name) VALUES
  ('v_dem_baden',                 267, 'Baden'),
  ('v_dem_bavaria',               245, 'Bavaria'),
  ('v_dem_brunswick',           10037, 'Brunswick'),
  ('v_dem_hanover',               240, 'Hanover'),
  ('v_dem_hesse_darmstadt',       275, 'Hesse-Darmstadt'),
  ('v_dem_hesse_kassel',          273, 'Hesse-Kassel'),
  ('v_dem_mecklenburg_schwerin',  280, 'Mecklenburg-Schwerin'),
  ('v_dem_modena',                332, 'Modena'),
  ('v_dem_nassau',              10021, 'Nassau'),
  ('v_dem_oldenburg',           10022, 'Oldenburg'),
  ('v_dem_papal_states',          327, 'Papal States'),
  ('v_dem_parma',                 335, 'Parma'),
  ('v_dem_piedmont_sardinia',   10023, 'Piedmont-Sardinia'),
  ('v_dem_saxe_weimar_eisenach',10033, 'Saxe-Weimar-Eisenach'),
  ('v_dem_saxony',                269, 'Saxony'),
  ('v_dem_two_sicilies',        10016, 'Two Sicilies'),
  ('v_dem_wurttemberg',           271, 'Württemberg');

INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  e.registry_key,
  'cshapes_europe',
  'CC BY-NC-SA 4.0',
  'https://icr.ethz.ch/data/cshapes/CShapes-Europe.geojson',
  'Cederman, Girardin, Rüegger, Schvitz and Weidmann (2025), Nationalism and the Transformation of the State, Cambridge University Press.',
  NULL,
  src.cntry_name,
  e.normalized_name,
  src.gwsyear,
  src.gweyear,
  'high',
  NULL,
  ST_Multi(
    ST_CollectionExtract(ST_MakeValid(src.geom), 3)
  )::geometry(MultiPolygon, 4326)
FROM demscore.cshapes_europe_src src
JOIN ce_entities e ON e.gwcode = src.gwcode
WHERE src.geom IS NOT NULL
  AND NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(src.geom), 3));

-- 1b. The same polygons carried outside their own periods.
--
-- V-Dem starts these units in 1789 and CShapes-Europe starts in 1816, and four
-- of them are coded through the year of German unification while
-- CShapes-Europe stops in 1870. Carrying a border-change period across a gap is
-- a claim about the gap, so every row below states in `notes` what it is
-- asserting, and grades itself `low` where the claim is known to be wrong in a
-- way the map will show.

-- Backwards, from each entity's earliest CShapes-Europe period.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  x.registry_key,
  'cshapes_europe_extended',
  'CC BY-NC-SA 4.0',
  'https://icr.ethz.ch/data/cshapes/CShapes-Europe.geojson',
  'Cederman, Girardin, Rüegger, Schvitz and Weidmann (2025), Nationalism and the Transformation of the State, Cambridge University Press.',
  NULL,
  g.source_name,
  g.normalized_name,
  x.from_year,
  g.first_year - 1,
  x.confidence,
  x.notes,
  g.geom
FROM (VALUES
  ('v_dem_baden',                1789, 'low',
   'Carries the 1816 Grand Duchy back over the Margraviate of Baden, which until the 1803 mediatization held roughly a fifth of this area.'),
  ('v_dem_bavaria',              1806, 'medium',
   'Kingdom of Bavaria from 1806, at the borders the Congress of Vienna settled in 1815. Earlier years come from the 1783 snapshot instead.'),
  ('v_dem_brunswick',            1789, 'medium',
   'The duchy was restored in 1813 at approximately its pre-1807 extent, which is what this polygon draws.'),
  ('v_dem_hesse_darmstadt',      1789, 'low',
   'Carries the 1816 Grand Duchy back over the Landgraviate of Hesse-Darmstadt, which was smaller before 1806.'),
  ('v_dem_hesse_kassel',         1789, 'medium',
   'The electorate was restored in 1813 at approximately its pre-1807 extent, which is what this polygon draws.'),
  ('v_dem_mecklenburg_schwerin', 1789, 'medium',
   'Mecklenburg-Schwerin held the same territory across the whole period; only its title changed, from duchy to grand duchy in 1815.'),
  ('v_dem_modena',               1789, 'medium',
   'The duchy was restored in 1814 at approximately its pre-1796 extent, which is what this polygon draws.'),
  ('v_dem_nassau',               1806, 'medium',
   'The duchy was formed in 1806 from Nassau-Weilburg and Nassau-Usingen; this is its extent as settled in 1815.'),
  ('v_dem_oldenburg',            1789, 'medium',
   'The duchy was restored in 1813 at approximately its pre-1810 extent and was raised to a grand duchy in 1829 without territorial change.'),
  ('v_dem_papal_states',         1789, 'medium',
   'The Papal States were restored in 1814 at approximately their pre-1809 extent, which is what this polygon draws.'),
  ('v_dem_parma',                1789, 'medium',
   'The duchy was restored in 1814 at approximately its pre-1802 extent, which is what this polygon draws.'),
  ('v_dem_piedmont_sardinia',    1789, 'low',
   'Includes Savoy and Nice, which were annexed by France between 1793 and 1814, and Piedmont itself was French territory from 1802 to 1814.'),
  ('v_dem_saxe_weimar_eisenach', 1809, 'medium',
   'Saxe-Weimar and Saxe-Eisenach entered personal union in 1809; this is their combined extent as settled in 1815.'),
  ('v_dem_saxony',               1815, 'medium',
   'The kingdom as the Congress of Vienna left it, after Prussia took some three fifths of the electorate. Earlier years come from the 1783 snapshot instead.'),
  ('v_dem_two_sicilies',         1789, 'low',
   'V-Dem codes the mainland Kingdom of Naples alone until it united with Sicily in 1816; this polygon includes Sicily throughout.'),
  ('v_dem_wurttemberg',          1789, 'low',
   'Carries the 1816 kingdom back over the Duchy of Württemberg, which until the 1803 mediatization held roughly two thirds of this area.')
) AS x(registry_key, from_year, confidence, notes)
JOIN LATERAL (
  SELECT DISTINCT ON (r.registry_key)
    r.registry_key, r.source_name, r.normalized_name, r.geom,
    r.valid_from_year AS first_year
  FROM demscore.historical_country_geometries_src r
  WHERE r.registry_key = x.registry_key
    AND r.source_dataset = 'cshapes_europe'
  ORDER BY r.registry_key, r.valid_from_year ASC
) g ON TRUE
WHERE g.first_year - 1 >= x.from_year;

-- Forwards, from each entity's latest CShapes-Europe period. Only the four
-- states V-Dem carries into 1871 need it; CShapes-Europe ends them in 1870
-- because the German Empire is proclaimed in January 1871.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  x.registry_key,
  'cshapes_europe_extended',
  'CC BY-NC-SA 4.0',
  'https://icr.ethz.ch/data/cshapes/CShapes-Europe.geojson',
  'Cederman, Girardin, Rüegger, Schvitz and Weidmann (2025), Nationalism and the Transformation of the State, Cambridge University Press.',
  NULL,
  g.source_name,
  g.normalized_name,
  g.last_year + 1,
  x.to_year,
  'medium',
  'V-Dem codes this state through the proclamation of the German Empire in January 1871; CShapes-Europe ends it in 1870. Borders were unchanged between the two.',
  g.geom
FROM (VALUES
  ('v_dem_baden',           1871),
  ('v_dem_bavaria',         1871),
  ('v_dem_hesse_darmstadt', 1871),
  ('v_dem_wurttemberg',     1871)
) AS x(registry_key, to_year)
JOIN LATERAL (
  SELECT DISTINCT ON (r.registry_key)
    r.registry_key, r.source_name, r.normalized_name, r.geom,
    r.valid_to_year AS last_year
  FROM demscore.historical_country_geometries_src r
  WHERE r.registry_key = x.registry_key
    AND r.source_dataset = 'cshapes_europe'
  ORDER BY r.registry_key, r.valid_to_year DESC
) g ON TRUE
WHERE x.to_year >= g.last_year + 1;

-- 1c. historical-basemaps snapshots, for the years and entities no
-- period-aware source reaches.
--
-- Five rows, each one justified on its own line below. The source is
-- snapshot-based and map-scale, so every row here is `low` by construction --
-- see the confidence CHECK on the table. It is used where it is demonstrably
-- closer than carrying a CShapes-Europe polygon would be: the two entities
-- CShapes-Europe does not carry at all, the one it hides inside the United
-- Kingdom, and the two whose territory before 1815 was a different size from
-- what they became.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  x.registry_key,
  'historical_basemaps',
  'GPL-3.0',
  'https://github.com/aourednik/historical-basemaps',
  'Ourednik, A. (2021). Historical Basemaps. https://doi.org/10.5281/zenodo.11212643',
  x.snapshot_year,
  x.source_name,
  x.normalized_name,
  x.from_year,
  x.to_year,
  'low',
  x.notes,
  h.geom
FROM (VALUES
  ('v_dem_bavaria', 1783, 'Bavaria', 'Bavaria', 1789, 1805,
   'Electorate of Bavaria including the Palatinate, from the 1783 snapshot. CShapes-Europe starts Bavaria in 1816, by which time the kingdom had been reshaped twice.'),
  ('v_dem_saxony', 1783, 'Saxony', 'Saxony', 1789, 1814,
   'Electorate of Saxony before the 1815 partition, from the 1783 snapshot. The kingdom CShapes-Europe draws from 1816 is some two fifths of it.'),
  ('v_dem_hanover', 1815, 'Hanover', 'Hanover', 1789, 1837,
   'CShapes-Europe carries no separate Hanover until the personal union with Britain ends in 1838; before that it is inside the United Kingdom. This is the 1815 snapshot, whose area is within 3% of the 1838 CShapes-Europe polygon.'),
  ('v_dem_hamburg', 1815, 'Hamburg', 'Hamburg', 1789, 1867,
   'CShapes-Europe carries no Hamburg at all. This is the 1815 snapshot of the free city, held across the whole span V-Dem codes.'),
  ('v_dem_tuscany', 1815, 'Tuscany', 'Tuscany', 1789, 1861,
   'CShapes-Europe carries no Tuscany at all. This is the 1815 snapshot of the grand duchy, held across the whole span V-Dem codes, during which it also absorbed Lucca in 1847.')
) AS x(registry_key, snapshot_year, source_name, normalized_name, from_year, to_year, notes)
JOIN LATERAL (
  SELECT ST_Multi(
           ST_CollectionExtract(
             ST_MakeValid(ST_Union(ST_MakeValid(s.geom))),
             3
           )
         )::geometry(MultiPolygon, 4326) AS geom
  FROM demscore.historical_basemaps_src s
  WHERE s.snapshot_year = x.snapshot_year
    AND s.name = x.source_name
) h ON TRUE
WHERE h.geom IS NOT NULL AND NOT ST_IsEmpty(h.geom);

-- 1d. CShapes 2.0 polygons re-periodised, and one built by union.
--
-- These are coding units CShapes 2.0 already carries, for years it does not.
-- Nothing here invents a border: each row is an existing CShapes polygon given
-- a different validity window, except the West Bank row for 1968-2006, which is
-- the union of two of them because that is what V-Dem's coding unit covers in
-- those years.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  x.registry_key,
  'cshapes_2.0_extended',
  'CC BY-NC-SA 4.0',
  'https://icr.ethz.ch/data/cshapes/CShapes-2.0.geojson',
  'Schvitz, Girardin, Rüegger, Weidmann, Cederman and Gleditsch (2022), Mapping the International System, 1886-2019: The CShapes 2.0 Dataset, Journal of Conflict Resolution 66(1): 144-161.',
  NULL,
  g.cntry_name,
  x.normalized_name,
  x.from_year,
  x.to_year,
  x.confidence,
  x.notes,
  g.geom
FROM (VALUES
  ('v_dem_zanzibar', 511, 'earliest', 'Zanzibar', 1856, 1889, 'low',
   'CShapes 2.0 begins Zanzibar in 1890 and draws Unguja and Pemba alone; V-Dem''s coding unit also covers the East African coastal strip until 1895. Holding the islands across the whole series keeps one Zanzibar on the map rather than two, at the cost of understating the sultanate before 1890.'),
  ('v_dem_zanzibar', 511, 'latest', 'Zanzibar', 1965, 2100, 'high',
   'V-Dem codes Zanzibar separately from mainland Tanzania after the 1964 union. The territory is Unguja and Pemba, which is exactly the polygon CShapes 2.0 ends with in 1964.'),
  ('v_dem_palestine_west_bank', 6631, 'latest', 'Palestine/West Bank', 2007, 2100, 'high',
   'V-Dem''s West Bank unit refers to the West Bank alone from 2007, Gaza being coded separately again from that year.'),
  ('v_dem_palestine_gaza', 6511, 'latest', 'Palestine/Gaza', 2007, 2100, 'high',
   'V-Dem resumes coding Gaza separately in 2007. The territory is the present-day Gaza Strip, which is the polygon CShapes 2.0 carries.'),
  ('v_dem_palestine_mandate', 665, 'earliest', 'Palestine/British Mandate', 1918, 1919, 'high',
   'V-Dem codes the British Mandate from 1918; CShapes 2.0 begins it in 1920. The two intervening years are the Occupied Enemy Territory Administration over the same area.')
) AS x(registry_key, gwcode, which_period, normalized_name, from_year, to_year, confidence, notes)
JOIN LATERAL (
  SELECT
    s.cntry_name,
    ST_Multi(ST_CollectionExtract(ST_MakeValid(s.geom), 3))::geometry(MultiPolygon, 4326) AS geom
  FROM demscore.cshapes_src s
  WHERE s.gwcode = x.gwcode
    AND s.geom IS NOT NULL
  ORDER BY
    CASE WHEN x.which_period = 'earliest' THEN s.gwsyear END ASC NULLS LAST,
    s.gwsyear DESC
  LIMIT 1
) g ON TRUE;

-- The one polygon in the registry that no single upstream feature supplies.
-- V-Dem's Palestine/West Bank unit covers the West Bank *and* Gaza between the
-- 1967 occupation and Hamas taking Gaza in 2007, and only the West Bank on
-- either side of that window. A table that could not express this would have to
-- draw one of the two wrong for 39 years.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  'v_dem_palestine_west_bank',
  'cshapes_2.0_derived',
  'CC BY-NC-SA 4.0',
  'https://icr.ethz.ch/data/cshapes/CShapes-2.0.geojson',
  'Schvitz, Girardin, Rüegger, Weidmann, Cederman and Gleditsch (2022), Mapping the International System, 1886-2019: The CShapes 2.0 Dataset, Journal of Conflict Resolution 66(1): 144-161.',
  NULL,
  'West Bank + Gaza',
  'Palestine/West Bank and Gaza',
  1968,
  2006,
  'high',
  'Union of the CShapes 2.0 West Bank and Gaza polygons. V-Dem''s coding unit covers both territories between 1967 and 2007; Gaza is coded separately outside that window.',
  ST_Multi(
    ST_CollectionExtract(
      ST_MakeValid(
        ST_Union(
          (SELECT ST_MakeValid(s.geom) FROM demscore.cshapes_src s WHERE s.gwcode = 6631 ORDER BY s.gwsyear DESC LIMIT 1),
          (SELECT ST_MakeValid(s.geom) FROM demscore.cshapes_src s WHERE s.gwcode = 6511 ORDER BY s.gwsyear DESC LIMIT 1)
        )
      ),
      3
    )
  )::geometry(MultiPolygon, 4326);

-- 1e. Vietnam before the partition.
--
-- V-Dem's "Republic of Vietnam" unit is South Vietnam only from 1955. From 1802
-- it is the Nguyen empire, and from 1887 it is Tonkin, Annam and Cochinchina
-- inside French Indochina -- in both cases the whole of present-day Vietnam.
-- Drawing those years on the South Vietnam polygon CShapes 2.0 supplies from
-- 1954 would put a value for the whole country on half of it, so this row
-- carries Natural Earth's Vietnam outline instead, as a country of its own
-- rather than as an alias onto modern Vietnam: V-Dem codes a separate northern
-- unit from 1945, and two coding units resolved onto one country row would be
-- averaged together by demscore.country_scores().
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  'v_dem_vietnam_pre_partition',
  'natural_earth_50m',
  'Public domain',
  'https://github.com/nvkelso/natural-earth-vector',
  'Natural Earth, 1:50m Admin 0 Countries. Public domain.',
  NULL,
  src.name,
  'Vietnam (pre-partition)',
  1802,
  1953,
  'medium',
  'V-Dem''s Republic of Vietnam unit covers the whole of Vietnam until the 1954 partition: the Nguyen empire to 1862, then Tonkin, Annam and Cochinchina within French Indochina. Present-day Vietnam''s outline is the closest available; it overstates the years from 1862 to 1887, when France held Cochinchina separately.',
  ST_Multi(ST_CollectionExtract(ST_MakeValid(src.geom), 3))::geometry(MultiPolygon, 4326)
FROM demscore.countries_src src
WHERE upper(NULLIF(NULLIF(src.iso_a3_eh, ''), '-99')) = 'VNM'
LIMIT 1;

-- 1f. Project-local approximate marker for V-Dem's South Yemen coding unit
-- before statehood.
--
-- V-Dem carries South Yemen/YMD from 1900, but through 1963 that coding unit is
-- Aden and its immediate surroundings, and from 1963 to 1966 the Federation of
-- South Arabia rather than the later People's Democratic Republic. The
-- deployment does not vendor a real historical boundary for either. This row is
-- intentionally only a low-confidence map marker: a small square centred near
-- modern Aden so values draw in the right locality instead of being dropped or
-- painted across the much larger 1967-1990 state polygon.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  src.registry_key,
  src.source_dataset,
  src.source_license,
  src.source_url,
  src.source_citation,
  NULL::INTEGER,
  src.source_name,
  src.normalized_name,
  src.valid_from_year::INTEGER,
  src.valid_to_year::INTEGER,
  src.confidence,
  src.notes,
  ST_Multi(ST_CollectionExtract(ST_MakeValid(src.geom), 3))::geometry(MultiPolygon, 4326)
FROM demscore.custom_historical_geometries_src src
WHERE src.registry_key = 'v_dem_south_yemen_aden_approx'
  AND src.geom IS NOT NULL
  AND NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(src.geom), 3));

CREATE INDEX historical_country_geometries_key_idx
  ON demscore.historical_country_geometries_src (registry_key, valid_from_year, valid_to_year);
CREATE INDEX historical_country_geometries_geom_gix
  ON demscore.historical_country_geometries_src USING GIST (geom);

ANALYZE demscore.historical_country_geometries_src;

-- ---------------------------------------------------------------------------
-- 2. The resolution policy
-- ---------------------------------------------------------------------------
--
-- One row per (dataset, source entity, year window) saying what that window of
-- that entity is allowed to become. This replaces demscore.country_aliases,
-- which could say "map this to that" but had no way to say "this one is not
-- representable, and here is why" -- and so left the difference between a
-- decision and an oversight invisible.
--
-- sql/mapserver_hex_setup.sql drives its matching passes from this table and
-- then requires that every observation it could not map is covered by an
-- `intentionally_unsupported` row here. scripts/check_country_resolution.sh
-- fails the setup if any is not.

CREATE TABLE demscore.country_resolution_policy (
  id BIGSERIAL PRIMARY KEY,
  dataset TEXT NOT NULL,
  source_iso3 TEXT,
  source_name TEXT,
  -- The window of *source* years this row governs. NULL is open at that end.
  from_year INTEGER,
  to_year INTEGER,
  status TEXT NOT NULL CHECK (status IN (
    'natural_earth',
    'cshapes',
    'historical_registry',
    'intentionally_unsupported'
  )),
  target_iso3 TEXT,
  target_name TEXT,
  target_gwcode INTEGER,
  target_registry_key TEXT,
  reason TEXT,
  note TEXT,
  CHECK (source_iso3 IS NOT NULL OR source_name IS NOT NULL),
  CHECK (
    (status = 'natural_earth'
      AND (target_iso3 IS NOT NULL OR target_name IS NOT NULL)
      AND target_gwcode IS NULL AND target_registry_key IS NULL)
    OR
    (status = 'cshapes'
      AND target_gwcode IS NOT NULL
      AND target_iso3 IS NULL AND target_registry_key IS NULL)
    OR
    (status = 'historical_registry'
      AND target_registry_key IS NOT NULL
      AND target_iso3 IS NULL AND target_gwcode IS NULL)
    OR
    (status = 'intentionally_unsupported'
      AND reason IS NOT NULL
      AND target_iso3 IS NULL AND target_gwcode IS NULL AND target_registry_key IS NULL)
  )
);

INSERT INTO demscore.country_resolution_policy
  (dataset, source_iso3, source_name, from_year, to_year,
   status, target_iso3, target_name, target_gwcode, target_registry_key, reason, note)
VALUES
  -- Current-country naming mismatch: REPDEM has no ISO column and Natural
  -- Earth's stored long name is "Czech Republic" even though NAME is "Czechia".
  ('repdem', NULL, 'Czechia', NULL, NULL, 'natural_earth', 'CZE', NULL, NULL, NULL, NULL,
   'REPDEM source name; Natural Earth NAME_LONG is Czech Republic'),

  -- Historical countries present in QoG and covered by CShapes 2.0.
  ('qog', 'YUG', 'Yugoslavia',                 NULL, NULL, 'cshapes', NULL, NULL,  345, NULL, NULL, 'Yugoslavia, Gleditsch-Ward 345'),
  ('qog', 'CSK', 'Czechoslovakia',             NULL, NULL, 'cshapes', NULL, NULL,  315, NULL, NULL, 'Czechoslovakia, Gleditsch-Ward 315'),
  ('qog', 'SUN', 'USSR',                       NULL, 1991, 'cshapes', NULL, NULL,  365, NULL, NULL, 'Russia/Soviet Union, Gleditsch-Ward 365'),
  ('qog', 'DDR', 'German Democratic Republic', NULL, NULL, 'cshapes', NULL, NULL,  265, NULL, NULL, 'German Democratic Republic, Gleditsch-Ward 265'),

  -- V-Dem units CShapes 2.0 covers, for the years it covers them.
  ('v_dem', 'DDR', 'German Democratic Republic', NULL, NULL, 'cshapes', NULL, NULL,  265, NULL, NULL, 'German Democratic Republic, Gleditsch-Ward 265'),
  ('v_dem', 'ZZB', 'Zanzibar',                   1890, 1964, 'cshapes', NULL, NULL,  511, NULL, NULL, 'Zanzibar, Gleditsch-Ward 511'),
  ('v_dem', 'VDR', 'Republic of Vietnam',        1954, 1975, 'cshapes', NULL, NULL,  817, NULL, NULL, 'Republic of Vietnam, Gleditsch-Ward 817'),
  ('v_dem', 'YMD', 'South Yemen',                1967, 1990, 'cshapes', NULL, NULL,  680, NULL, NULL, 'Yemen, People''s Republic of, Gleditsch-Ward 680'),
  ('v_dem', 'YEM', 'Yemen',                       1918, 1989, 'cshapes', NULL, NULL,  678, NULL, NULL, 'Yemen Arab Republic / North Yemen, Gleditsch-Ward 678'),
  ('v_dem', 'PSE', 'Palestine/West Bank',        1948, 1967, 'cshapes', NULL, NULL, 6631, NULL, NULL, 'West Bank, Gleditsch-Ward 6631'),
  ('v_dem', 'PSG', 'Palestine/Gaza',             1948, 1967, 'cshapes', NULL, NULL, 6511, NULL, NULL, 'Gaza, Gleditsch-Ward 6511'),
  ('v_dem', 'PSB', 'Palestine/British Mandate',  1920, 1948, 'cshapes', NULL, NULL,  665, NULL, NULL, 'Palestine, Gleditsch-Ward 665'),

  -- V-Dem units the curated registry covers. The registry's own validity
  -- periods pick the polygon within each window.
  ('v_dem', 'ZZB', 'Zanzibar',                  1856, 1889, 'historical_registry', NULL, NULL, NULL, 'v_dem_zanzibar', NULL,
   'Before CShapes 2.0 begins'),
  ('v_dem', 'ZZB', 'Zanzibar',                  1965, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_zanzibar', NULL,
   'Semi-autonomous within Tanzania, still coded separately by V-Dem'),
  ('v_dem', 'PSE', 'Palestine/West Bank',       1968, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_palestine_west_bank', NULL,
   'West Bank and Gaza to 2006, West Bank alone from 2007'),
  ('v_dem', 'PSG', 'Palestine/Gaza',            2007, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_palestine_gaza', NULL,
   'V-Dem resumes a separate Gaza unit in 2007'),
  ('v_dem', 'PSB', 'Palestine/British Mandate', 1918, 1919, 'historical_registry', NULL, NULL, NULL, 'v_dem_palestine_mandate', NULL,
   'Occupied Enemy Territory Administration, before CShapes 2.0 begins the mandate'),
  ('v_dem', 'VDR', 'Republic of Vietnam',       1802, 1953, 'historical_registry', NULL, NULL, NULL, 'v_dem_vietnam_pre_partition', NULL,
   'The whole of Vietnam before the 1954 partition, not the southern state CShapes 2.0 carries from 1954'),
  ('v_dem', 'YMD', 'South Yemen',                NULL, 1966, 'historical_registry', NULL, NULL, NULL, 'v_dem_south_yemen_aden_approx', NULL,
   'Low-confidence local marker near Aden for V-Dem South Yemen/YMD before the 1967 state polygon is valid'),

  -- The pre-unification German and Italian states. One policy row each: the
  -- registry holds the period changes.
  ('v_dem', 'BDN', 'Baden',                 NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_baden',                 NULL, NULL),
  ('v_dem', 'BVR', 'Bavaria',               NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_bavaria',               NULL, NULL),
  ('v_dem', 'BRW', 'Brunswick',             NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_brunswick',             NULL, NULL),
  ('v_dem', 'HRG', 'Hamburg',               NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_hamburg',               NULL, NULL),
  ('v_dem', 'HVR', 'Hanover',               NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_hanover',               NULL, NULL),
  ('v_dem', 'HDM', 'Hesse-Darmstadt',       NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_hesse_darmstadt',       NULL, NULL),
  ('v_dem', 'HKS', 'Hesse-Kassel',          NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_hesse_kassel',          NULL, NULL),
  ('v_dem', 'MCL', 'Mecklenburg Schwerin',  NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_mecklenburg_schwerin',  NULL, NULL),
  ('v_dem', 'MDN', 'Modena',                NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_modena',                NULL, NULL),
  ('v_dem', 'NSS', 'Nassau',                NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_nassau',                NULL, NULL),
  ('v_dem', 'OLD', 'Oldenburg',             NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_oldenburg',             NULL, NULL),
  ('v_dem', 'PPS', 'Papal States',          NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_papal_states',          NULL, NULL),
  ('v_dem', 'PRM', 'Parma',                 NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_parma',                 NULL, NULL),
  ('v_dem', 'SPD', 'Piedmont-Sardinia',     NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_piedmont_sardinia',     NULL, NULL),
  ('v_dem', 'SAX', 'Saxe-Weimar-Eisenach',  NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_saxe_weimar_eisenach',  NULL, NULL),
  ('v_dem', 'SXN', 'Saxony',                NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_saxony',                NULL, NULL),
  ('v_dem', 'TSC', 'Tuscany',               NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_tuscany',               NULL, NULL),
  ('v_dem', 'TWS', 'Two Sicilies',          NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_two_sicilies',          NULL, NULL),
  ('v_dem', 'WRG', 'Würtemberg',            NULL, NULL, 'historical_registry', NULL, NULL, NULL, 'v_dem_wurttemberg',           NULL, NULL);

CREATE INDEX country_resolution_policy_dataset_idx
  ON demscore.country_resolution_policy (dataset);
CREATE INDEX country_resolution_policy_source_iso3_idx
  ON demscore.country_resolution_policy (upper(source_iso3));
CREATE INDEX country_resolution_policy_source_name_idx
  ON demscore.country_resolution_policy (lower(source_name));
CREATE INDEX country_resolution_policy_registry_key_idx
  ON demscore.country_resolution_policy (target_registry_key);

ANALYZE demscore.country_resolution_policy;

-- ---------------------------------------------------------------------------
-- 3. Integrity of the two tables against each other
-- ---------------------------------------------------------------------------
--
-- Both tables are hand-written, and a typo in a registry key would otherwise
-- surface as a silently unmapped country a year later.
DO $$
DECLARE
  dangling TEXT;
  uncovered TEXT;
BEGIN
  SELECT string_agg(DISTINCT p.target_registry_key, ', ')
    INTO dangling
  FROM demscore.country_resolution_policy p
  WHERE p.status = 'historical_registry'
    AND NOT EXISTS (
      SELECT 1 FROM demscore.historical_country_geometries_src r
      WHERE r.registry_key = p.target_registry_key
    );
  IF dangling IS NOT NULL THEN
    RAISE EXCEPTION 'Resolution policy points at registry keys that carry no geometry: %', dangling;
  END IF;

  SELECT string_agg(DISTINCT r.registry_key, ', ')
    INTO uncovered
  FROM demscore.historical_country_geometries_src r
  WHERE NOT EXISTS (
    SELECT 1 FROM demscore.country_resolution_policy p
    WHERE p.target_registry_key = r.registry_key
  );
  IF uncovered IS NOT NULL THEN
    RAISE EXCEPTION 'Registry holds geometry no resolution policy points at: %', uncovered;
  END IF;
END;
$$;

COMMIT;
