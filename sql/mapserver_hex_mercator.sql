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

--
-- Validity is restored on both sides of the transform, not just before it.
-- Reprojecting moves every vertex, so a ring that was clean in lon/lat can come
-- back from PROJ crossing itself -- one country does -- and ST_Intersection,
-- which the fallback below leans on, refuses an invalid input outright.
UPDATE demscore.countries c
SET geom_3857 = ST_Multi(
  ST_CollectionExtract(
    ST_MakeValid(
      ST_Transform(
        ST_MakeValid(
          ST_Intersection(
            c.geom_4326,
            ST_MakeEnvelope(-180, -85.05112878, 180, 85.05112878, 4326)
          )
        ),
        3857
      )
    ),
    3
  )
)::geometry(MultiPolygon, 3857);

CREATE INDEX IF NOT EXISTS countries_geom_3857_gix
  ON demscore.countries USING GIST (geom_3857);

DROP TABLE IF EXISTS demscore.hex_border_sides_mercator;
DROP TABLE IF EXISTS demscore.hex_border_edges_mercator;
DROP TABLE IF EXISTS demscore.hex_borders_mercator;
DROP TABLE IF EXISTS demscore.hex_mesh_mercator;

CREATE TABLE demscore.hex_mesh_mercator (
  country_id BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  hex_size_m INTEGER NOT NULL,
  hex_n INTEGER NOT NULL,
  id_key TEXT NOT NULL,
  -- True for the half-size hexagons the inset pass hands to countries no grid
  -- can seat. They overlap the cell they sit on, so they are the one thing in
  -- here that is not part of the partition, and mapserver.map draws them as a
  -- layer of their own on top of the cells rather than among them.
  inset BOOLEAN NOT NULL DEFAULT false,
  geom geometry(Polygon, 3857) NOT NULL,
  PRIMARY KEY (country_id, hex_size_m, hex_n)
);

CREATE INDEX hex_mesh_mercator_size_idx ON demscore.hex_mesh_mercator (hex_size_m);
CREATE INDEX hex_mesh_mercator_country_idx ON demscore.hex_mesh_mercator (country_id);
CREATE INDEX hex_mesh_mercator_geom_gix ON demscore.hex_mesh_mercator USING GIST (geom);

-- Hexagon edge length in Web Mercator metres, which are not ground metres: a
-- cell of a given size here covers ground area proportional to cos^2(latitude).
--
-- The ladder is 40k-600k step 10k, twice the Equal Earth one, so that the sizes
-- the app asks for -- 200k, 100k, 50k, the same three in both projections -- are
-- all precomputed here. The app asks for the same sizes on purpose: both
-- projections count in Web Mercator's resolution ladder, so a cell is drawn
-- hex_size_m / resolution pixels across in either plane, and an equal size is an
-- equal grain on screen.
--
-- The counts then differ, and are meant to. At 200k this mesh holds 5 917 cells
-- against 1 396 in Equal Earth, because the Mercator surplus towards the poles
-- is real -- it is the distortion the toggle exists to show. The app's stops
-- used to be doubled here to cancel that surplus and land on the same total,
-- which bought a matching number by making every Mercator cell twice as wide on
-- screen: coarse blobs over Brazil to pay for the confetti over Russia.
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
-- always been. See the same note in sql/mapserver_hex_setup.sql.
CREATE TEMP TABLE hex_fallback_mercator ON COMMIT DROP AS
WITH sizes AS (
  SELECT generate_series(40000, 600000, 10000)::INT AS hex_size_m
), unplaced AS (
  SELECT c.id AS country_id, c.id_key, s.hex_size_m, c.geom_3857 AS country_geom
  FROM demscore.countries c
  CROSS JOIN sizes s
  WHERE NOT ST_IsEmpty(c.geom_3857)
    AND NOT EXISTS (
      SELECT 1 FROM demscore.hex_mesh_mercator hm
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
      WHERE ST_Within(ST_PointOnSurface(g.geom), c2.geom_3857)
      -- A historical polygon can contain this centre too, and the owner has to
      -- be the country that holds the cell in the partition, not whichever row
      -- the planner reached first.
      ORDER BY (c2.source = 'natural_earth') DESC, c2.id
      LIMIT 1
    ) AS owner_id,
    -- The most any other country holds of this cell, owner or not.
    COALESCE((
      SELECT max(ST_Area(ST_Intersection(g.geom, c2.geom_3857)))
      FROM demscore.countries c2
      WHERE c2.id <> u.country_id AND ST_Intersects(c2.geom_3857, g.geom)
    ), 0) AS rival_m2
  FROM unplaced u
  CROSS JOIN LATERAL ST_HexagonGrid(u.hex_size_m::FLOAT8, u.country_geom) g
  WHERE ST_Intersects(g.geom, u.country_geom)
), eligible AS (
  SELECT
    c.*,
    (
      SELECT count(*) FROM demscore.hex_mesh_mercator hm
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
DELETE FROM demscore.hex_mesh_mercator hm
USING hex_fallback_mercator f
WHERE hm.country_id = f.owner_id
  AND hm.hex_size_m = f.hex_size_m
  AND hm.geom = f.hex_geom
  AND EXISTS (
    SELECT 1 FROM demscore.countries owner, demscore.countries claimant
    WHERE owner.id = f.owner_id AND claimant.id = f.country_id
      AND owner.source = 'natural_earth'
      AND claimant.source = 'natural_earth'
  );

INSERT INTO demscore.hex_mesh_mercator (country_id, hex_size_m, hex_n, id_key, geom)
SELECT
  f.country_id,
  f.hex_size_m,
  -- The country was empty at this size, so the numbering starts over at 1.
  row_number() OVER (
    PARTITION BY f.country_id, f.hex_size_m
    ORDER BY ST_YMin(f.hex_geom), ST_XMin(f.hex_geom)
  ) AS hex_n,
  f.id_key,
  f.hex_geom::geometry(Polygon, 3857)
FROM hex_fallback_mercator f;

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
    CREATE TEMP TABLE hex_guarantee_mercator AS
    WITH sizes AS (
      SELECT generate_series(40000, 600000, 10000) AS hex_size_m
    ), unplaced AS (
      SELECT c.id AS country_id, c.id_key, s.hex_size_m, c.geom_3857 AS country_geom
      FROM demscore.countries c
      CROSS JOIN sizes s
      WHERE NOT ST_IsEmpty(c.geom_3857)
        AND NOT EXISTS (
          SELECT 1 FROM demscore.hex_mesh_mercator hm
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
        COALESCE(ST_Area(ST_Intersection(g.geom, oc.geom_3857)), 0) AS owner_overlap_m2
      FROM unplaced u
      CROSS JOIN LATERAL ST_HexagonGrid(u.hex_size_m::FLOAT8, u.country_geom) g
      -- Who holds this cell *now*, read from the mesh rather than from the centre
      -- rule, because by this point the mesh also holds cells the pass above
      -- handed out, whose centres are somewhere else entirely.
      LEFT JOIN LATERAL (
        SELECT
          hm.country_id,
          (
            SELECT count(*) FROM demscore.hex_mesh_mercator h2
            WHERE h2.country_id = hm.country_id AND h2.hex_size_m = u.hex_size_m
          ) AS cells
        FROM demscore.hex_mesh_mercator hm
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

    DELETE FROM demscore.hex_mesh_mercator hm
    USING hex_guarantee_mercator f
    WHERE hm.country_id = f.owner_id
      AND hm.hex_size_m = f.hex_size_m
      AND hm.geom = f.hex_geom
      AND EXISTS (
        SELECT 1 FROM demscore.countries owner, demscore.countries claimant
        WHERE owner.id = f.owner_id AND claimant.id = f.country_id
          AND owner.source = 'natural_earth'
          AND claimant.source = 'natural_earth'
      );

    INSERT INTO demscore.hex_mesh_mercator (country_id, hex_size_m, hex_n, id_key, geom)
    SELECT f.country_id, f.hex_size_m, 1, f.id_key, f.hex_geom::geometry(Polygon, 3857)
    FROM hex_guarantee_mercator f;

    GET DIAGNOSTICS placed = ROW_COUNT;
    DROP TABLE hex_guarantee_mercator;
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
  FOR sz IN SELECT generate_series(40000, 600000, 10000) ORDER BY 1 LOOP
    src := GREATEST(40000, 10000 * floor(sz / 2.0 / 10000)::INT);
    CONTINUE WHEN src >= sz;

    CREATE TEMP TABLE hex_inset_mercator AS
    SELECT DISTINCT ON (c.id)
      c.id AS country_id,
      c.id_key,
      hm.geom
    FROM demscore.countries c
    JOIN demscore.hex_mesh_mercator hm
      ON hm.country_id = c.id AND hm.hex_size_m = src
    WHERE NOT ST_IsEmpty(c.geom_3857)
      AND NOT EXISTS (
        SELECT 1 FROM demscore.hex_mesh_mercator h
        WHERE h.country_id = c.id AND h.hex_size_m = sz
      )
    -- Of the country's finer cells, the one holding most of it.
    ORDER BY c.id, ST_Area(ST_Intersection(hm.geom, c.geom_3857)) DESC;

    INSERT INTO demscore.hex_mesh_mercator (country_id, hex_size_m, hex_n, id_key, inset, geom)
    SELECT f.country_id, sz, 1, f.id_key, true, f.geom::geometry(Polygon, 3857)
    FROM hex_inset_mercator f;

    DROP TABLE hex_inset_mercator;
  END LOOP;
END;
$$;

-- The edges that can ever separate one colour from the next, exactly as
-- demscore.hex_border_edges and demscore.hex_border_sides are built for the
-- Equal Earth mesh -- see the long note there for why the perimeter is
-- precomputed rather than dissolved per tile, why an edge needs a row per
-- country rather than a country_a and a country_b, and why matching edges by
-- exact geometry is safe.
CREATE TEMP TABLE hex_border_build_mercator ON COMMIT DROP AS
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

CREATE TABLE demscore.hex_border_edges_mercator (
  id BIGINT PRIMARY KEY,
  hex_size_m INTEGER NOT NULL,
  geom geometry(LineString, 3857) NOT NULL
);

INSERT INTO demscore.hex_border_edges_mercator (id, hex_size_m, geom)
SELECT edge_id, hex_size_m, geom::geometry(LineString, 3857)
FROM hex_border_build_mercator;

CREATE TABLE demscore.hex_border_sides_mercator (
  edge_id BIGINT NOT NULL REFERENCES demscore.hex_border_edges_mercator(id) ON DELETE CASCADE,
  country_id BIGINT NOT NULL REFERENCES demscore.countries(id) ON DELETE CASCADE,
  hex_count INTEGER NOT NULL,
  PRIMARY KEY (edge_id, country_id)
);

INSERT INTO demscore.hex_border_sides_mercator (edge_id, country_id, hex_count)
SELECT b.edge_id, c, count(*)
FROM hex_border_build_mercator b, unnest(b.countries) AS c
GROUP BY b.edge_id, c;

CREATE INDEX hex_border_edges_mercator_size_idx
  ON demscore.hex_border_edges_mercator (hex_size_m);
CREATE INDEX hex_border_edges_mercator_geom_gix
  ON demscore.hex_border_edges_mercator USING GIST (geom);
CREATE INDEX hex_border_sides_mercator_country_idx
  ON demscore.hex_border_sides_mercator (country_id);

ANALYZE demscore.countries;
ANALYZE demscore.hex_mesh_mercator;
ANALYZE demscore.hex_border_edges_mercator;
ANALYZE demscore.hex_border_sides_mercator;

COMMIT;
