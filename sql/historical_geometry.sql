-- Curated historical country geometry, and the policy that says what every
-- source observation is allowed to become.
--
-- Run after the ogr2ogr imports in scripts/setup_mapserver_hex_service.sh and
-- before sql/mapserver_hex_setup.sql, which reads the three tables this file
-- builds: the geometry registry, the resolution policy, and the table from
-- Gleditsch-Ward code to present-day Natural Earth country.
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
DROP TABLE IF EXISTS demscore.gwcode_natural_earth CASCADE;
DROP TABLE IF EXISTS demscore.gw_year_changes CASCADE;
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

-- 1g. Israel with Gaza and the West Bank, for UCDP after CShapes 2.0 ends.
--
-- UCDP codes organised violence by the territory it happened on, and has no
-- Palestine unit, so its Israel figures are taken to include Gaza and the West
-- Bank (an assumption, not yet confirmed by Demscore).
-- CShapes 2.0's Israel from 1979 already draws Israel together with both, and
-- the policy sends UCDP's 1989-2019 there. CShapes stops at 2019; this carries
-- its last Israel polygon forward, for the years 2023-2025 above all.
INSERT INTO demscore.historical_country_geometries_src
  (registry_key, source_dataset, source_license, source_url, source_citation,
   source_snapshot_year, source_name, normalized_name,
   valid_from_year, valid_to_year, confidence, notes, geom)
SELECT
  'ucdp_israel_with_territories',
  'cshapes_2.0_derived',
  'CC BY-NC-SA 4.0',
  'https://icr.ethz.ch/data/cshapes/CShapes-2.0.geojson',
  'Schvitz, Girardin, Rüegger, Weidmann, Cederman and Gleditsch (2022), Mapping the International System, 1886-2019: The CShapes 2.0 Dataset, Journal of Conflict Resolution 66(1): 144-161.',
  NULL,
  s.cntry_name,
  'Israel (with Gaza and the West Bank)',
  2020,
  demscore.historical_geometry_open_end(),
  'medium',
  'CShapes 2.0''s 1979-2019 Israel polygon, which includes Gaza and the West Bank, carried past the end of CShapes. Drawn for UCDP, whose Israel unit is assumed to cover both territories; Demscore has been asked to confirm.',
  ST_Multi(ST_CollectionExtract(ST_MakeValid(s.geom), 3))::geometry(MultiPolygon, 4326)
FROM demscore.cshapes_src s
WHERE s.gwcode = 666
ORDER BY s.gwsyear DESC
LIMIT 1;

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

--
-- A row names its source entity by whichever identifiers the dataset carries
-- (ISO3, name, Gleditsch-Ward code); every one it sets has to match. It names its
-- target by status: a Natural Earth country by `target_adm0_a3` -- Natural Earth's
-- own country code, which is the ISO code for most countries and Natural Earth's
-- own where there is none (KOS for Kosovo, SOL for Somaliland) -- or by name, a
-- CShapes 2.0 country by Gleditsch-Ward code (the year picks the period), or a
-- registry key.
CREATE TABLE demscore.country_resolution_policy (
  id BIGSERIAL PRIMARY KEY,
  dataset TEXT NOT NULL,
  source_iso3 TEXT,
  source_name TEXT,
  source_gwcode INTEGER,
  -- The window of *source* years this row governs. NULL is open at that end.
  from_year INTEGER,
  to_year INTEGER,
  status TEXT NOT NULL CHECK (status IN (
    'natural_earth',
    'cshapes',
    'historical_registry',
    'intentionally_unsupported'
  )),
  target_adm0_a3 TEXT,
  target_name TEXT,
  target_gwcode INTEGER,
  target_registry_key TEXT,
  reason TEXT,
  note TEXT,
  CHECK (source_iso3 IS NOT NULL OR source_name IS NOT NULL OR source_gwcode IS NOT NULL),
  CHECK (
    (status = 'natural_earth'
      AND (target_adm0_a3 IS NOT NULL OR target_name IS NOT NULL)
      AND target_gwcode IS NULL AND target_registry_key IS NULL)
    OR
    (status = 'cshapes'
      AND target_gwcode IS NOT NULL
      AND target_adm0_a3 IS NULL AND target_registry_key IS NULL)
    OR
    (status = 'historical_registry'
      AND target_registry_key IS NOT NULL
      AND target_adm0_a3 IS NULL AND target_gwcode IS NULL)
    OR
    (status = 'intentionally_unsupported'
      AND reason IS NOT NULL
      AND target_adm0_a3 IS NULL AND target_gwcode IS NULL AND target_registry_key IS NULL)
  )
);

-- Whether a policy row governs one source observation. The one place this is
-- written: every matching pass, the refusal pass, the audit and
-- demscore.source_coverage() call it, so a fourth kind of source identifier is
-- one edit here rather than eight that have to agree. A NULL year asks whether
-- the row names this entity at all, in any year.
CREATE OR REPLACE FUNCTION demscore.policy_covers(
  p demscore.country_resolution_policy,
  p_dataset TEXT,
  p_iso3 TEXT,
  p_name TEXT,
  p_gwcode INTEGER,
  p_year INTEGER
)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT p.dataset = p_dataset
     AND (p.source_iso3 IS NULL OR COALESCE(upper(p.source_iso3) = upper(p_iso3), FALSE))
     AND (p.source_name IS NULL OR COALESCE(lower(p.source_name) = lower(p_name), FALSE))
     AND (p.source_gwcode IS NULL OR COALESCE(p.source_gwcode = p_gwcode, FALSE))
     AND (p_year IS NULL OR (
       (p.from_year IS NULL OR p_year >= p.from_year)
       AND (p.to_year IS NULL OR p_year <= p.to_year)
     ))
$$;

INSERT INTO demscore.country_resolution_policy
  (dataset, source_iso3, source_name, from_year, to_year,
   status, target_adm0_a3, target_name, target_gwcode, target_registry_key, reason, note)
VALUES
  -- Current-country naming mismatch: REPDEM has no ISO column and Natural
  -- Earth's stored long name is "Czech Republic" even though NAME is "Czechia".
  ('repdem', NULL, 'Czechia', NULL, NULL, 'natural_earth', 'CZE', NULL, NULL, NULL, NULL,
   'REPDEM source name; Natural Earth NAME_LONG is Czech Republic'),

  -- V-Dem codes these two with codes of its own, and Natural Earth has no ISO
  -- code for either: Kosovo has none officially (XKX is a convention), and
  -- Somaliland is not a recognised state. Natural Earth draws both, under its
  -- own codes. They used to reach the map through the name pass, which V-Dem no
  -- longer falls back to: a dataset is matched on the one identifier it is
  -- declared to carry (demscore.datasets).
  ('v_dem', 'XKX', 'Kosovo',     NULL, NULL, 'natural_earth', 'KOS', NULL, NULL, NULL, NULL,
   'V-Dem code; Natural Earth ADM0_A3 is KOS and it has no ISO code'),
  ('v_dem', 'SML', 'Somaliland', NULL, NULL, 'natural_earth', 'SOL', NULL, NULL, NULL, NULL,
   'V-Dem code; Natural Earth ADM0_A3 is SOL and it has no ISO code'),

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

-- UCDP, named by Gleditsch-Ward code. UCDP counts organised violence by the
-- territory it happened on, and keeps one code for a state across a change of
-- territory, so each row below sends the years before the change to the outline
-- that was in force. The years after it fall through to demscore.gwcode_natural_earth.
-- A year in which CShapes 2.0 has two periods (1990 for Germany and Yemen) gets the
-- later one, which is the post-change state; those years are left to Natural Earth.
INSERT INTO demscore.country_resolution_policy
  (dataset, source_gwcode, from_year, to_year,
   status, target_gwcode, target_registry_key, note)
VALUES
  -- States that no longer exist.
  ('ucdp', 265, NULL, NULL, 'cshapes', 265, NULL, 'German Democratic Republic, 1989-1990'),
  ('ucdp', 315, NULL, NULL, 'cshapes', 315, NULL, 'Czechoslovakia, 1989-1992'),
  ('ucdp', 680, NULL, NULL, 'cshapes', 680, NULL, 'South Yemen, 1989-1990'),

  -- One code across a merger or a break-up.
  ('ucdp', 260, NULL, 1989, 'cshapes', 260, NULL,
   'West Germany before unification; unified Germany from 1990'),
  ('ucdp', 678, NULL, 1989, 'cshapes', 678, NULL,
   'North Yemen before unification; unified Yemen from 1990'),
  ('ucdp', 365, NULL, 1991, 'cshapes', 365, NULL,
   'The Soviet Union; Russia from 1992, when UCDP has every other successor state'),
  ('ucdp', 345, NULL, 2005, 'cshapes', 345, NULL,
   'Yugoslavia: the federation to 1991 (with Croatia, whose war UCDP counts here until Croatia begins in 1992), then Serbia and Montenegro'),
  ('ucdp', 345, 2006, 2007, 'cshapes', 340, NULL,
   'Serbia with Kosovo, between Montenegro leaving in 2006 and Kosovo beginning in 2008'),

  -- A present-day country that held more territory in these years.
  ('ucdp', 530, NULL, 1992, 'cshapes', 530, NULL, 'Ethiopia with Eritrea, until Eritrea begins in 1993'),
  ('ucdp', 625, NULL, 2010, 'cshapes', 625, NULL, 'Sudan with South Sudan, until South Sudan begins in 2011'),
  ('ucdp', 850, NULL, 2001, 'cshapes', 850, NULL, 'Indonesia with East Timor, until East Timor begins in 2002'),

  -- Israel with Gaza and the West Bank, which UCDP has no unit for. Assumed,
  -- not yet confirmed by Demscore.
  ('ucdp', 666, NULL, 2019, 'cshapes', 666, NULL,
   'Israel with Gaza and the West Bank (CShapes 2.0 from 1979)'),
  ('ucdp', 666, 2020, NULL, 'historical_registry', NULL, 'ucdp_israel_with_territories',
   'Israel with Gaza and the West Bank, CShapes 2.0''s 2019 polygon carried forward');

CREATE INDEX country_resolution_policy_dataset_idx
  ON demscore.country_resolution_policy (dataset);
CREATE INDEX country_resolution_policy_source_iso3_idx
  ON demscore.country_resolution_policy (upper(source_iso3));
CREATE INDEX country_resolution_policy_source_name_idx
  ON demscore.country_resolution_policy (lower(source_name));
CREATE INDEX country_resolution_policy_source_gwcode_idx
  ON demscore.country_resolution_policy (source_gwcode);
CREATE INDEX country_resolution_policy_registry_key_idx
  ON demscore.country_resolution_policy (target_registry_key);

ANALYZE demscore.country_resolution_policy;

-- ---------------------------------------------------------------------------
-- 2b. Gleditsch-Ward code to present-day Natural Earth country
-- ---------------------------------------------------------------------------
--
-- For a dataset matched on Gleditsch-Ward codes (demscore.datasets), the
-- present-day country each code stands for. Natural Earth carries no
-- Gleditsch-Ward codes, so this is written down here. It is a fact about two
-- code lists, not a decision: the decisions -- which years of a code belong to
-- an outline that has since changed -- are policy rows above, and run first.
-- A code that is in the data and neither here nor in a policy row is an
-- unresolved observation, and setup fails on it.
--
-- `label` is UCDP's name for the unit, for whoever reads this table; matching
-- uses the code alone. Rows marked "by hand" are those whose name does not match
-- Natural Earth's; every other row was taken from a name match and checked
-- against it. The three former states (265, 315, 680) are absent on purpose:
-- they have no present-day country.
CREATE TABLE demscore.gwcode_natural_earth (
  gwcode INTEGER PRIMARY KEY,
  adm0_a3 TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL
);

INSERT INTO demscore.gwcode_natural_earth (gwcode, adm0_a3, label) VALUES
  (  2, 'USA', 'United States of America'        ),  -- by hand
  ( 20, 'CAN', 'Canada'                          ),
  ( 31, 'BHS', 'Bahamas'                         ),
  ( 40, 'CUB', 'Cuba'                            ),
  ( 41, 'HTI', 'Haiti'                           ),
  ( 42, 'DOM', 'Dominican Republic'              ),
  ( 51, 'JAM', 'Jamaica'                         ),
  ( 52, 'TTO', 'Trinidad and Tobago'             ),
  ( 53, 'BRB', 'Barbados'                        ),
  ( 54, 'DMA', 'Dominica'                        ),
  ( 55, 'GRD', 'Grenada'                         ),
  ( 56, 'LCA', 'Saint Lucia'                     ),
  ( 57, 'VCT', 'Saint Vincent and the Grenadines'),
  ( 58, 'ATG', 'Antigua & Barbuda'               ),  -- by hand
  ( 60, 'KNA', 'Saint Kitts and Nevis'           ),
  ( 70, 'MEX', 'Mexico'                          ),
  ( 80, 'BLZ', 'Belize'                          ),
  ( 90, 'GTM', 'Guatemala'                       ),
  ( 91, 'HND', 'Honduras'                        ),
  ( 92, 'SLV', 'El Salvador'                     ),
  ( 93, 'NIC', 'Nicaragua'                       ),
  ( 94, 'CRI', 'Costa Rica'                      ),
  ( 95, 'PAN', 'Panama'                          ),
  (100, 'COL', 'Colombia'                        ),
  (101, 'VEN', 'Venezuela'                       ),
  (110, 'GUY', 'Guyana'                          ),
  (115, 'SUR', 'Suriname'                        ),
  (130, 'ECU', 'Ecuador'                         ),
  (135, 'PER', 'Peru'                            ),
  (140, 'BRA', 'Brazil'                          ),
  (145, 'BOL', 'Bolivia'                         ),
  (150, 'PRY', 'Paraguay'                        ),
  (155, 'CHL', 'Chile'                           ),
  (160, 'ARG', 'Argentina'                       ),
  (165, 'URY', 'Uruguay'                         ),
  (200, 'GBR', 'United Kingdom'                  ),
  (205, 'IRL', 'Ireland'                         ),
  (210, 'NLD', 'Netherlands'                     ),
  (211, 'BEL', 'Belgium'                         ),
  (212, 'LUX', 'Luxembourg'                      ),
  (220, 'FRA', 'France'                          ),
  (221, 'MCO', 'Monaco'                          ),
  (223, 'LIE', 'Liechtenstein'                   ),
  (225, 'CHE', 'Switzerland'                     ),
  (230, 'ESP', 'Spain'                           ),
  (232, 'AND', 'Andorra'                         ),
  (235, 'PRT', 'Portugal'                        ),
  (260, 'DEU', 'Germany'                         ),
  (290, 'POL', 'Poland'                          ),
  (305, 'AUT', 'Austria'                         ),
  (310, 'HUN', 'Hungary'                         ),
  (316, 'CZE', 'Czech Republic'                  ),
  (317, 'SVK', 'Slovakia'                        ),
  (325, 'ITA', 'Italy'                           ),
  (327, 'VAT', 'Vatican City State'              ),  -- by hand
  (331, 'SMR', 'San Marino'                      ),
  (338, 'MLT', 'Malta'                           ),
  (339, 'ALB', 'Albania'                         ),
  (341, 'MNE', 'Montenegro'                      ),
  (343, 'MKD', 'North Macedonia'                 ),
  (344, 'HRV', 'Croatia'                         ),
  (345, 'SRB', 'Serbia (Yugoslavia)'             ),  -- by hand
  (346, 'BIH', 'Bosnia-Herzegovina'              ),  -- by hand
  (347, 'KOS', 'Kosovo'                          ),
  (349, 'SVN', 'Slovenia'                        ),
  (350, 'GRC', 'Greece'                          ),
  (352, 'CYP', 'Cyprus'                          ),
  (355, 'BGR', 'Bulgaria'                        ),
  (359, 'MDA', 'Moldova'                         ),
  (360, 'ROU', 'Romania'                         ),
  (365, 'RUS', 'Russia (Soviet Union)'           ),  -- by hand
  (366, 'EST', 'Estonia'                         ),
  (367, 'LVA', 'Latvia'                          ),
  (368, 'LTU', 'Lithuania'                       ),
  (369, 'UKR', 'Ukraine'                         ),
  (370, 'BLR', 'Belarus'                         ),
  (371, 'ARM', 'Armenia'                         ),
  (372, 'GEO', 'Georgia'                         ),
  (373, 'AZE', 'Azerbaijan'                      ),
  (375, 'FIN', 'Finland'                         ),
  (380, 'SWE', 'Sweden'                          ),
  (385, 'NOR', 'Norway'                          ),
  (390, 'DNK', 'Denmark'                         ),
  (395, 'ISL', 'Iceland'                         ),
  (402, 'CPV', 'Cape Verde'                      ),  -- by hand
  (403, 'STP', 'Sao Tome and Principe'           ),  -- by hand
  (404, 'GNB', 'Guinea-Bissau'                   ),
  (411, 'GNQ', 'Equatorial Guinea'               ),
  (420, 'GMB', 'Gambia'                          ),  -- by hand
  (432, 'MLI', 'Mali'                            ),
  (433, 'SEN', 'Senegal'                         ),
  (434, 'BEN', 'Benin'                           ),
  (435, 'MRT', 'Mauritania'                      ),
  (436, 'NER', 'Niger'                           ),
  (437, 'CIV', 'Ivory Coast'                     ),  -- by hand
  (438, 'GIN', 'Guinea'                          ),
  (439, 'BFA', 'Burkina Faso'                    ),
  (450, 'LBR', 'Liberia'                         ),
  (451, 'SLE', 'Sierra Leone'                    ),
  (452, 'GHA', 'Ghana'                           ),
  (461, 'TGO', 'Togo'                            ),
  (471, 'CMR', 'Cameroon'                        ),
  (475, 'NGA', 'Nigeria'                         ),
  (481, 'GAB', 'Gabon'                           ),
  (482, 'CAF', 'Central African Republic'        ),
  (483, 'TCD', 'Chad'                            ),
  (484, 'COG', 'Congo'                           ),  -- by hand
  (490, 'COD', 'DR Congo (Zaire)'                ),  -- by hand
  (500, 'UGA', 'Uganda'                          ),
  (501, 'KEN', 'Kenya'                           ),
  (510, 'TZA', 'Tanzania'                        ),
  (516, 'BDI', 'Burundi'                         ),
  (517, 'RWA', 'Rwanda'                          ),
  (520, 'SOM', 'Somalia'                         ),
  (522, 'DJI', 'Djibouti'                        ),
  (530, 'ETH', 'Ethiopia'                        ),
  (531, 'ERI', 'Eritrea'                         ),
  (540, 'AGO', 'Angola'                          ),
  (541, 'MOZ', 'Mozambique'                      ),
  (551, 'ZMB', 'Zambia'                          ),
  (552, 'ZWE', 'Zimbabwe (Rhodesia)'             ),  -- by hand
  (553, 'MWI', 'Malawi'                          ),
  (560, 'ZAF', 'South Africa'                    ),
  (565, 'NAM', 'Namibia'                         ),
  (570, 'LSO', 'Lesotho'                         ),
  (571, 'BWA', 'Botswana'                        ),
  (572, 'SWZ', 'Kingdom of eSwatini (Swaziland)' ),  -- by hand
  (580, 'MDG', 'Madagascar (Malagasy)'           ),  -- by hand
  (581, 'COM', 'Comoros'                         ),
  (590, 'MUS', 'Mauritius'                       ),
  (591, 'SYC', 'Seychelles'                      ),
  (600, 'MAR', 'Morocco'                         ),
  (615, 'DZA', 'Algeria'                         ),
  (616, 'TUN', 'Tunisia'                         ),
  (620, 'LBY', 'Libya'                           ),
  (625, 'SDN', 'Sudan'                           ),
  (626, 'SDS', 'South Sudan'                     ),
  (630, 'IRN', 'Iran'                            ),
  (640, 'TUR', 'Turkey'                          ),
  (645, 'IRQ', 'Iraq'                            ),
  (651, 'EGY', 'Egypt'                           ),
  (652, 'SYR', 'Syria'                           ),
  (660, 'LBN', 'Lebanon'                         ),
  (663, 'JOR', 'Jordan'                          ),
  (666, 'ISR', 'Israel'                          ),
  (670, 'SAU', 'Saudi Arabia'                    ),
  (678, 'YEM', 'Yemen (North Yemen)'             ),  -- by hand
  (690, 'KWT', 'Kuwait'                          ),
  (692, 'BHR', 'Bahrain'                         ),
  (694, 'QAT', 'Qatar'                           ),
  (696, 'ARE', 'United Arab Emirates'            ),
  (698, 'OMN', 'Oman'                            ),
  (700, 'AFG', 'Afghanistan'                     ),
  (701, 'TKM', 'Turkmenistan'                    ),
  (702, 'TJK', 'Tajikistan'                      ),
  (703, 'KGZ', 'Kyrgyzstan'                      ),
  (704, 'UZB', 'Uzbekistan'                      ),
  (705, 'KAZ', 'Kazakhstan'                      ),
  (710, 'CHN', 'China'                           ),
  (712, 'MNG', 'Mongolia'                        ),
  (713, 'TWN', 'Taiwan'                          ),
  (731, 'PRK', 'North Korea'                     ),  -- by hand
  (732, 'KOR', 'South Korea'                     ),  -- by hand
  (740, 'JPN', 'Japan'                           ),
  (750, 'IND', 'India'                           ),
  (760, 'BTN', 'Bhutan'                          ),
  (770, 'PAK', 'Pakistan'                        ),
  (771, 'BGD', 'Bangladesh'                      ),
  (775, 'MMR', 'Myanmar (Burma)'                 ),  -- by hand
  (780, 'LKA', 'Sri Lanka'                       ),
  (781, 'MDV', 'Maldives'                        ),
  (790, 'NPL', 'Nepal'                           ),
  (800, 'THA', 'Thailand'                        ),
  (811, 'KHM', 'Cambodia (Kampuchea)'            ),  -- by hand
  (812, 'LAO', 'Laos'                            ),  -- by hand
  (816, 'VNM', 'Vietnam (North Vietnam)'         ),  -- by hand
  (820, 'MYS', 'Malaysia'                        ),
  (830, 'SGP', 'Singapore'                       ),
  (835, 'BRN', 'Brunei'                          ),  -- by hand
  (840, 'PHL', 'Philippines'                     ),
  (850, 'IDN', 'Indonesia'                       ),
  (860, 'TLS', 'East Timor'                      ),  -- by hand
  (900, 'AUS', 'Australia'                       ),
  (910, 'PNG', 'Papua New Guinea'                ),
  (920, 'NZL', 'New Zealand'                     ),
  (935, 'VUT', 'Vanuatu'                         ),
  (940, 'SLB', 'Solomon Islands'                 ),
  (950, 'FJI', 'Fiji'                            ),
  (970, 'KIR', 'Kiribati'                        ),
  (971, 'NRU', 'Nauru'                           ),
  (972, 'TON', 'Tonga'                           ),
  (973, 'TUV', 'Tuvalu'                          ),
  (983, 'MHL', 'Marshall Islands'                ),
  (986, 'PLW', 'Palau'                           ),
  (987, 'FSM', 'Federated States of Micronesia'  ),
  (990, 'WSM', 'Samoa (Western Samoa)'           );  -- by hand

ANALYZE demscore.gwcode_natural_earth;

-- The changes of state that fall inside a year, for the datasets whose units are
-- Gleditsch-Ward states (demscore.datasets.country_key = 'gwcode': UCDP). The
-- map draws one picture per year, so in a year a state begins, ends or breaks
-- up, two rows may cover the same ground for different parts of it -- the
-- Soviet Union until each republic begins, the republic after. The map draws
-- the smaller on top; /api/map-data gives each row these changes, and the table
-- view notes that the row may cover only part of the year. It states no date:
-- the dates here are CShapes', and whether UCDP splits a year at them is
-- unconfirmed.
--
--   from   this state begins on change_date; before it, its ground is in
--          other_gwcode's row
--   until  this state ends on change_date; after it, its ground is in
--          other_gwcode's row
--   loses  other_gwcode begins on change_date on part of this state's ground
--   gains  other_gwcode's ground joins this state on change_date
--
-- Dates are CShapes 2.0's (gwsdate/gwedate), which follow the Gleditsch-Ward
-- list, and every UCDP successor's first year is the year given here. Whether
-- UCDP splits a year's events at exactly these dates is not confirmed. Kept by
-- hand rather than derived from CShapes' periods: CShapes shrinks the Soviet
-- outline on 1 and 21 December 1991 but starts Ukraine, Armenia, Azerbaijan and
-- Kazakhstan on the 26th, and renumbers Serbia 340 in 2006 where UCDP keeps 345,
-- so matching periods end to start drops half the cases. Only changes inside a
-- year are listed: Czechoslovakia's split on 1 January 1993 is not one.
CREATE TABLE demscore.gw_year_changes (
  gwcode INTEGER NOT NULL,
  change_date DATE NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('from', 'until', 'loses', 'gains')),
  other_gwcode INTEGER NOT NULL,
  -- The other state's name as the note will read it ("the Soviet Union").
  other_label TEXT NOT NULL,
  PRIMARY KEY (gwcode, change_date, kind, other_gwcode)
);

INSERT INTO demscore.gw_year_changes (gwcode, change_date, kind, other_gwcode, other_label) VALUES
  -- Yemen and Germany: one state ends and its ground joins another's
  (680, DATE '1990-05-21', 'until', 678, 'Yemen'),
  (678, DATE '1990-05-22', 'gains', 680, 'South Yemen'),
  (265, DATE '1990-10-02', 'until', 260, 'Germany'),
  (260, DATE '1990-10-03', 'gains', 265, 'the German Democratic Republic'),
  -- the Soviet Union's successors
  (359, DATE '1991-08-25', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-08-25', 'loses', 359, 'Moldova'),
  (370, DATE '1991-08-25', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-08-25', 'loses', 370, 'Belarus'),
  (703, DATE '1991-09-01', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-01', 'loses', 703, 'Kyrgyzstan'),
  (704, DATE '1991-09-01', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-01', 'loses', 704, 'Uzbekistan'),
  (366, DATE '1991-09-06', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-06', 'loses', 366, 'Estonia'),
  (367, DATE '1991-09-06', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-06', 'loses', 367, 'Latvia'),
  (368, DATE '1991-09-06', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-06', 'loses', 368, 'Lithuania'),
  (372, DATE '1991-09-06', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-06', 'loses', 372, 'Georgia'),
  (702, DATE '1991-09-06', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-09-06', 'loses', 702, 'Tajikistan'),
  (701, DATE '1991-10-27', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-10-27', 'loses', 701, 'Turkmenistan'),
  (369, DATE '1991-12-26', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-12-26', 'loses', 369, 'Ukraine'),
  (371, DATE '1991-12-26', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-12-26', 'loses', 371, 'Armenia'),
  (373, DATE '1991-12-26', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-12-26', 'loses', 373, 'Azerbaijan'),
  (705, DATE '1991-12-26', 'from',  365, 'the Soviet Union'),
  (365, DATE '1991-12-26', 'loses', 705, 'Kazakhstan'),
  -- Yugoslavia's; UCDP keeps 345 for Serbia throughout, where CShapes renumbers it 340 in 2006
  (343, DATE '1991-11-20', 'from',  345, 'Yugoslavia'),
  (345, DATE '1991-11-20', 'loses', 343, 'North Macedonia'),
  (344, DATE '1992-04-27', 'from',  345, 'Yugoslavia'),
  (345, DATE '1992-04-27', 'loses', 344, 'Croatia'),
  (346, DATE '1992-04-27', 'from',  345, 'Yugoslavia'),
  (345, DATE '1992-04-27', 'loses', 346, 'Bosnia-Herzegovina'),
  (349, DATE '1992-04-27', 'from',  345, 'Yugoslavia'),
  (345, DATE '1992-04-27', 'loses', 349, 'Slovenia'),
  (341, DATE '2006-06-12', 'from',  345, 'Serbia'),
  (345, DATE '2006-06-12', 'loses', 341, 'Montenegro'),
  (347, DATE '2008-02-20', 'from',  345, 'Serbia'),
  (345, DATE '2008-02-20', 'loses', 347, 'Kosovo'),
  -- and the rest
  (531, DATE '1993-05-24', 'from',  530, 'Ethiopia'),
  (530, DATE '1993-05-24', 'loses', 531, 'Eritrea'),
  (860, DATE '2002-05-20', 'from',  850, 'Indonesia'),
  (850, DATE '2002-05-20', 'loses', 860, 'East Timor'),
  (626, DATE '2011-07-09', 'from',  625, 'Sudan'),
  (625, DATE '2011-07-09', 'loses', 626, 'South Sudan');

ANALYZE demscore.gw_year_changes;

-- ---------------------------------------------------------------------------
-- 3. Integrity of the tables against each other and their sources
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

  -- The Gleditsch-Ward table and the natural_earth policy rows name Natural
  -- Earth countries by code; a code Natural Earth does not carry would leave
  -- every observation of that country unmatched.
  SELECT string_agg(DISTINCT x.code, ', ')
    INTO dangling
  FROM (
    SELECT g.adm0_a3 AS code FROM demscore.gwcode_natural_earth g
    UNION ALL
    SELECT p.target_adm0_a3 FROM demscore.country_resolution_policy p
    WHERE p.status = 'natural_earth' AND p.target_adm0_a3 IS NOT NULL
  ) x
  WHERE NOT EXISTS (
    SELECT 1 FROM demscore.countries_src s
    WHERE upper(NULLIF(NULLIF(s.adm0_a3, ''), '-99')) = upper(x.code)
  );
  IF dangling IS NOT NULL THEN
    RAISE EXCEPTION 'Natural Earth has no country with ADM0_A3: %', dangling;
  END IF;

  SELECT string_agg(DISTINCT p.target_gwcode::TEXT, ', ')
    INTO dangling
  FROM demscore.country_resolution_policy p
  WHERE p.status = 'cshapes'
    AND NOT EXISTS (SELECT 1 FROM demscore.cshapes_src s WHERE s.gwcode = p.target_gwcode);
  IF dangling IS NOT NULL THEN
    RAISE EXCEPTION 'Resolution policy points at Gleditsch-Ward codes CShapes 2.0 does not carry: %', dangling;
  END IF;
END;
$$;

COMMIT;
