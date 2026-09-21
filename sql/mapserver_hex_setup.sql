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

-- The Mercator mesh goes too, though this file does not build it: its tables
-- carry foreign keys into demscore.countries, so dropping that table without
-- them fails outright and a second run of this script on a built database is
-- refused. sql/mapserver_hex_mercator.sql rebuilds them immediately after --
-- scripts/setup_mapserver_hex_service.sh runs the two in that order -- so run
-- that file too if you run this one on its own.
DROP TABLE IF EXISTS demscore.hex_borders_mercator;
DROP TABLE IF EXISTS demscore.hex_mesh_mercator;
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
  -- True for the half-size hexagons the inset pass hands to countries no grid
  -- can seat. They overlap the cell they sit on, so they are the one thing in
  -- here that is not part of the partition, and mapserver.map draws them as a
  -- layer of their own on top of the cells rather than among them.
  inset BOOLEAN NOT NULL DEFAULT false,
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

-- A cell has one owner, so the country that had it gives it up. Matching by
-- geometry is exact because both sides are cells of the same global
-- ST_HexagonGrid -- the same reason the border table below groups segments
-- by geometry.
DELETE FROM demscore.hex_mesh hm
USING hex_fallback f
WHERE hm.country_id = f.owner_id
  AND hm.hex_size_m = f.hex_size_m
  AND hm.geom = f.hex_geom;

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
      AND hm.geom = f.hex_geom;

    INSERT INTO demscore.hex_mesh (country_id, hex_size_m, hex_n, id_key, geom)
    SELECT f.country_id, f.hex_size_m, 1, f.id_key, f.hex_geom::geometry(Polygon, 8857)
    FROM hex_guarantee f;

    GET DIAGNOSTICS placed = ROW_COUNT;
    DROP TABLE hex_guarantee;
    EXIT WHEN placed = 0;
  END LOOP;
END;
$$;

-- And the countries no grid can seat.
--
-- What is left is not a scheduling failure, it is arithmetic. At 200k the cells
-- covering the western Balkans number fewer than the countries standing on
-- them, so however the cells are dealt out, somebody gets none: Kosovo,
-- Montenegro, North Macedonia, Palestine and Slovenia in Equal Earth, four of
-- the same in Mercator. No rule about who deserves which cell can fix a
-- shortage of cells.
--
-- They get a hexagon from the grid one notch finer instead -- half the edge, a
-- quarter of the area -- sitting where the country is, and drawn on top of the
-- cell it lands on. This is the one place the mesh stops being a partition, and
-- the layer draws big cells before small ones (SORTBY in mapserver.map) so the
-- inset is never the one underneath.
--
-- It is drawn on top rather than cut out of the cell below because the cell
-- below is drawn for the country that owns it and the inset only for a country
-- that has a value: Palestine is in the mesh and in none of the datasets, so a
-- cut would leave a hexagon-shaped hole in Jordan for every variable and every
-- year. Overlaying costs nothing when the inset is missing.
--
-- The outline table needs no special case either. An inset shares no edge with
-- anything, so all six of its edges read as mesh coastline and it is drawn with
-- a perimeter of its own, which is what makes it legible as a country rather
-- than a blemish on the cell under it.
--
-- `inset` marks these rows, because the fill layer has to exclude them and draw
-- them again afterwards: MapServer draws a layer's features in whatever order
-- the query hands them over, and there is no mapfile directive to sort them, so
-- the only way to be sure an inset lands on top of the cell it overlaps is for
-- it to be a separate layer, drawn after. See hex_inset in mapserver.map.
--
-- Sizes are filled from the finest up, so the grid an inset is taken from is
-- always complete by the time it is read; the insets at one size are distinct
-- cells of one finer grid, so they never overlap each other either.
DO $$
DECLARE
  sz INT;
  src INT;
BEGIN
  FOR sz IN SELECT generate_series(20000, 300000, 5000) ORDER BY 1 LOOP
    src := GREATEST(20000, 5000 * floor(sz / 2.0 / 5000)::INT);
    CONTINUE WHEN src >= sz;

    CREATE TEMP TABLE hex_inset AS
    SELECT DISTINCT ON (c.id)
      c.id AS country_id,
      c.id_key,
      hm.geom
    FROM demscore.countries c
    JOIN demscore.hex_mesh hm
      ON hm.country_id = c.id AND hm.hex_size_m = src
    WHERE NOT ST_IsEmpty(c.geom_8857)
      AND NOT EXISTS (
        SELECT 1 FROM demscore.hex_mesh h
        WHERE h.country_id = c.id AND h.hex_size_m = sz
      )
    -- Of the country's finer cells, the one holding most of it.
    ORDER BY c.id, ST_Area(ST_Intersection(hm.geom, c.geom_8857)) DESC;

    INSERT INTO demscore.hex_mesh (country_id, hex_size_m, hex_n, id_key, inset, geom)
    SELECT f.country_id, sz, 1, f.id_key, true, f.geom::geometry(Polygon, 8857)
    FROM hex_inset f;

    DROP TABLE hex_inset;
  END LOOP;
END;
$$;

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
