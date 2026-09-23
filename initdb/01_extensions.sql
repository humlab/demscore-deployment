CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
-- Exclusion constraints over (text, int4range) pairs, which is how
-- demscore.historical_country_geometries_src refuses two overlapping validity
-- periods for the same historical country. sql/historical_geometry.sql creates
-- it too, for databases whose volume predates this line.
CREATE EXTENSION IF NOT EXISTS btree_gist;
