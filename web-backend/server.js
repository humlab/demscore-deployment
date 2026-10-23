const express = require("express");
const cors = require("cors");
const fs = require("fs/promises");
const path = require("path");
const { Pool } = require("pg");

const PORT = Number.parseInt(process.env.PORT || "8091", 10);
const CONFIG_DIR = process.env.CONFIG_DIR || path.join(__dirname, "webapp-config");
const REFERENCE_DATA_DIR = process.env.REFERENCE_DATA_DIR || path.join(__dirname, "..", "data", "reference");
const LAND_BASEMAP_FILE = "ne_50m_admin_0_countries.geojson";
const WMS_BASE_PATH = "/mapserver?map=/etc/mapserver/mapserver.map";
const CACHE_ENABLED = isTruthy(process.env.DEMSCORE_ENABLE_MAPCACHE || "0");

// `download` points at Demscore's own downloader, not at a file of ours. The
// portal has no per-variable page to deep-link to — `menu_all_variables` is a
// DataTables grid that reads no query string, so a URL cannot name a variable —
// but a *download ID* names a saved selection and replays it exactly. The three
// below are the selections this deployment loads: fetch one and its `data.csv`
// carries the same columns as `data/Demscore_Module_Vars/<module>`, alongside
// that module's codebook and the Demscore methodology PDF. So the link is
// per-dataset, and a variable's card offers its dataset's download.
//
// The codebook link is not here: see fetchCodebookLinks().
const DATASET_META = {
  qog: {
    label: "QoG",
    title: "Quality of Government",
    download: "https://www.demscore.se/data_analysis/menu_by_id?download_id=81929b1e-8ab2-4409-a3e1-ffaff751c039",
    defaultVariable: "qog_std_ts_ti_cpi",
  },
  repdem: {
    label: "REPDEM",
    title: "Representative Democracy",
    download: "https://www.demscore.se/data_analysis/menu_by_id?download_id=2ee386d8-5059-4111-b43f-19a42c662840",
    defaultVariable: "repdem_basic_enpp",
  },
  v_dem: {
    label: "V-Dem",
    title: "Varieties of Democracy",
    download: "https://www.demscore.se/data_analysis/menu_by_id?download_id=1dfe5c25-dcba-4b8d-808d-49269a1336f6",
    defaultVariable: "v2x_polyarchy",
  },
};

// How a dataset presents itself, as opposed to what it contains. The database
// supplies the variables and the year span; these come from config.
const DATASET_PRESENTATION_KEYS = ["label", "title", "description", "color", "palette", "download", "image"];

// Mirrors the mapfile's own VALIDATION block for these parameters.
const VARIABLE_KEY_PATTERN = /^[A-Za-z0-9_]+$/;
const YEAR_MIN = 1500;
const YEAR_MAX = 2100;

const DEFAULTS = {
  dataset: "v_dem",
  variable: "v2x_polyarchy",
  year: 2020,
  hexSize: 200000,
};

const pool = new Pool({
  host: process.env.PGHOST || "db",
  port: Number.parseInt(process.env.PGPORT || "5432", 10),
  database: process.env.PGDATABASE || "demscore",
  user: process.env.PGUSER || "demscore",
  password: process.env.PGPASSWORD || "demscore",
  max: Number.parseInt(process.env.PG_MAX_CLIENTS || "10", 10),
});

const app = express();
app.use(cors());
app.use(express.json());

function isTruthy(value) {
  return ["1", "true", "yes", "on"].includes(String(value).trim().toLowerCase());
}

function asyncRoute(handler) {
  return (req, res, next) => {
    Promise.resolve(handler(req, res, next)).catch(next);
  };
}

async function readJsonConfig(fileName, fallbackValue = {}) {
  const filePath = path.join(CONFIG_DIR, fileName);
  try {
    const contents = await fs.readFile(filePath, "utf8");
    return JSON.parse(contents);
  } catch (error) {
    if (error.code === "ENOENT") return fallbackValue;
    throw error;
  }
}

function normalizeDatasetConfig(rawConfig) {
  if (!rawConfig || typeof rawConfig !== "object") {
    return { defaults: { ...DEFAULTS }, datasets: {} };
  }

  const datasets = rawConfig.datasets && typeof rawConfig.datasets === "object"
    ? rawConfig.datasets
    : {};

  const defaults = rawConfig.defaults && typeof rawConfig.defaults === "object"
    ? { ...DEFAULTS, ...rawConfig.defaults }
    : { ...DEFAULTS };

  return { defaults, datasets };
}

async function fetchVariablesConfigFromDb() {
  const query = `
    WITH vars AS (
      SELECT
        dataset,
        array_agg(variable ORDER BY variable) AS variables
      FROM demscore.variables
      -- Superseded variants (REPDEM's wecee twins) stay in the table and still
      -- render on a direct WMS request, but are not offered in the variable list.
      WHERE NOT hidden
      GROUP BY dataset
    ),
    coverage_by_year AS (
      SELECT
        v.dataset,
        v.variable,
        dv.year::INT AS year
      FROM demscore.variables v
      JOIN demscore.dataset_values dv ON dv.variable_id = v.id
      WHERE dv.country_id IS NOT NULL
        AND NOT v.hidden
      GROUP BY v.dataset, v.variable, dv.year
    ),
    coverage AS (
      SELECT
        dataset,
        variable,
        MIN(year)::INT AS year_min,
        MAX(year)::INT AS year_max,
        array_agg(year ORDER BY year) AS available_years
      FROM coverage_by_year
      GROUP BY dataset, variable
    ),
    years AS (
      SELECT
        dataset,
        MIN(year_min)::INT AS year_min,
        MAX(year_max)::INT AS year_max
      FROM coverage
      GROUP BY dataset
    ),
    coverage_by_dataset AS (
      SELECT
        dataset,
        jsonb_object_agg(
          variable,
          jsonb_build_object(
            'yearMin', year_min,
            'yearMax', year_max,
            'availableYears', to_jsonb(available_years)
          )
          ORDER BY variable
        ) AS variable_coverage
      FROM coverage
      GROUP BY dataset
    )
    SELECT
      vars.dataset,
      vars.variables,
      years.year_min,
      years.year_max,
      coverage_by_dataset.variable_coverage
    FROM vars
    LEFT JOIN years ON years.dataset = vars.dataset
    LEFT JOIN coverage_by_dataset ON coverage_by_dataset.dataset = vars.dataset
    ORDER BY vars.dataset;
  `;

  const result = await pool.query(query);
  if (result.rowCount === 0) {
    return null;
  }

  const codebooks = await fetchCodebookLinks();
  const datasets = {};
  for (const row of result.rows) {
    const datasetKey = row.dataset;
    const variables = Array.isArray(row.variables) ? row.variables : [];
    const fallbackMeta = DATASET_META[datasetKey] || {};
    const defaultVariable = variables.includes(fallbackMeta.defaultVariable)
      ? fallbackMeta.defaultVariable
      : (variables[0] || fallbackMeta.defaultVariable || "");

    datasets[datasetKey] = {
      label: fallbackMeta.label || datasetKey,
      title: fallbackMeta.title || fallbackMeta.label || datasetKey,
      color: fallbackMeta.color,
      codebook: codebooks[datasetKey],
      download: fallbackMeta.download,
      defaultVariable,
      yearMin: Number.isInteger(row.year_min) ? row.year_min : DEFAULTS.year,
      yearMax: Number.isInteger(row.year_max) ? row.year_max : DEFAULTS.year,
      variableCoverage: row.variable_coverage || {},
      variables,
    };
  }

  const defaultDataset = datasets[DEFAULTS.dataset]
    ? DEFAULTS.dataset
    : (Object.keys(datasets)[0] || DEFAULTS.dataset);
  const defaultVariable = datasets[defaultDataset]?.variables?.includes(DEFAULTS.variable)
    ? DEFAULTS.variable
    : (datasets[defaultDataset]?.defaultVariable || DEFAULTS.variable);

  return {
    defaults: {
      ...DEFAULTS,
      dataset: defaultDataset,
      variable: defaultVariable,
    },
    datasets,
  };
}

// Each module's codebook is served straight out of data/Demscore_Module_Vars
// (the `web` container mounts it under /codebooks/), so the PDF a reader opens
// is the one the import read the variable titles and the credits from, and a
// new export's codebook is served as soon as it is dropped in beside its
// data.csv. variable_metadata.source_pdf records which file that was.
async function fetchCodebookLinks() {
  let result;
  try {
    result = await pool.query(`
      SELECT dataset, min(source_pdf) AS source_pdf
      FROM demscore.variable_metadata
      GROUP BY dataset
    `);
  } catch (error) {
    // No codebook has been loaded yet; the map works without one.
    if (error.code === "42P01") return {};
    throw error;
  }

  const links = {};
  for (const row of result.rows) {
    // Same pattern the web container's nginx serves, so a link is never offered
    // for a file it would refuse.
    const match = /Demscore_Module_Vars\/([A-Za-z0-9_-]+)\/codebook\.pdf$/.exec(row.source_pdf || "");
    if (match) links[row.dataset] = `./codebooks/${match[1]}/codebook.pdf`;
  }
  return links;
}

// `DATASET_META` is only a built-in default. `webapp/config/variables.json` is
// the documented source of a dataset's presentation metadata, but the database
// path never read it, so anything added there — a colour palette, say — was
// silently ignored unless the whole `demscore.variables` table was missing.
function overlayDatasetPresentation(dbConfig, fileConfig) {
  const fileDatasets =
    fileConfig?.datasets && typeof fileConfig.datasets === "object" ? fileConfig.datasets : {};

  for (const [datasetKey, dataset] of Object.entries(dbConfig.datasets)) {
    const fromFile = fileDatasets[datasetKey];
    if (!fromFile || typeof fromFile !== "object") continue;

    for (const key of DATASET_PRESENTATION_KEYS) {
      if (fromFile[key] !== undefined) dataset[key] = fromFile[key];
    }
    // A default the file names only counts if the dataset still has it.
    if (
      typeof fromFile.defaultVariable === "string" &&
      dataset.variables.includes(fromFile.defaultVariable)
    ) {
      dataset.defaultVariable = fromFile.defaultVariable;
    }
  }
  return dbConfig;
}

async function getVariablesConfig() {
  try {
    const dbConfig = await fetchVariablesConfigFromDb();
    if (dbConfig) {
      return overlayDatasetPresentation(dbConfig, await readJsonConfig("variables.json", null));
    }
  } catch (error) {
    if (error.code !== "42P01") {
      throw error;
    }
  }

  const fileConfig = await readJsonConfig("variables.json", {
    defaults: { ...DEFAULTS },
    datasets: {},
  });
  return normalizeDatasetConfig(fileConfig);
}

async function fetchVariableMetadataSummaryFromDb(datasetKey = null) {
  const params = [];
  const whereClause = datasetKey ? "WHERE dataset = $1" : "";
  if (datasetKey) {
    params.push(datasetKey);
  }

  const query = `
    SELECT
      dataset AS dataset_key,
      (array_agg(dataset_citation ORDER BY variable)
        FILTER (WHERE dataset_citation IS NOT NULL))[1] AS citation,
      jsonb_object_agg(
        variable,
        COALESCE(NULLIF(trim(title), ''), variable)
        ORDER BY variable
      ) AS vars
    FROM demscore.variable_metadata
    ${whereClause}
    GROUP BY dataset
    ORDER BY dataset;
  `;

  const result = await pool.query(query, params);
  if (datasetKey) {
    const row = result.rows?.[0];
    return row
      ? {
          citation: row.citation,
          variables: row.vars || {},
        }
      : { citation: null, variables: {} };
  }

  const payload = {};
  for (const row of result.rows || []) {
    payload[row.dataset_key] = {
      citation: row.citation,
      variables: row.vars || {},
    };
  }
  return payload;
}

async function fetchSingleVariableMetadataFromDb(datasetKey, variableKey) {
  const query = `
    SELECT jsonb_strip_nulls(
      jsonb_build_object(
        'title', COALESCE(NULLIF(trim(title), ''), variable),
        'dataset_tag', NULLIF(trim(dataset_tag), ''),
        'heading_raw', NULLIF(trim(heading_raw), ''),
        'source_long_tag', NULLIF(trim(source_long_tag), ''),
        'source_pdf', NULLIF(trim(source_pdf), ''),
        'original_tag', NULLIF(trim(original_tag), ''),
        'dataset_citation', NULLIF(trim(dataset_citation), ''),
        'variable_citation', NULLIF(trim(variable_citation), ''),
        'description', NULLIF(trim(description), ''),
        'description_full', NULLIF(trim(description_full), ''),
        'raw_block_text', NULLIF(trim(raw_block_text), ''),
        'additional_versions', NULLIF(trim(additional_versions), ''),
        'question', NULLIF(trim(question), ''),
        'clarification', NULLIF(trim(clarification), ''),
        'scale', NULLIF(trim(scale), ''),
        'sources', NULLIF(trim(sources), ''),
        'data_release', NULLIF(trim(data_release), ''),
        'aggregation', NULLIF(trim(aggregation), ''),
        'cross_coder_aggregation', NULLIF(trim(cross_coder_aggregation), ''),
        'country_year_aggregation', NULLIF(trim(country_year_aggregation), ''),
        'matched_by', NULLIF(trim(matched_by), '')
      )
    ) AS payload
    FROM demscore.variable_metadata
    WHERE dataset = $1
      AND variable = $2
    LIMIT 1;
  `;

  const result = await pool.query(query, [datasetKey, variableKey]);
  return result.rows?.[0]?.payload || null;
}

function normalizeDatasetMetadataSummary(datasetPayload) {
  if (!datasetPayload || typeof datasetPayload !== "object") {
    return { citation: null, variables: {} };
  }
  const variables = {};
  if (datasetPayload.variables && typeof datasetPayload.variables === "object") {
    for (const [variable, value] of Object.entries(datasetPayload.variables)) {
      if (typeof value === "string") {
        variables[variable] = value;
      } else if (value && typeof value === "object" && typeof value.title === "string") {
        variables[variable] = value.title;
      } else {
        variables[variable] = variable;
      }
    }
  }
  return {
    citation: typeof datasetPayload.citation === "string" ? datasetPayload.citation : null,
    variables,
  };
}

async function getVariableMetadataSummary(datasetKey = null) {
  try {
    return await fetchVariableMetadataSummaryFromDb(datasetKey);
  } catch (error) {
    if (error.code !== "42P01") {
      throw error;
    }
  }

  const fallback = await readJsonConfig("variable_metadata.json", {});
  if (!datasetKey) {
    const payload = {};
    for (const [key, value] of Object.entries(fallback || {})) {
      payload[key] = normalizeDatasetMetadataSummary(value);
    }
    return payload;
  }
  return normalizeDatasetMetadataSummary(fallback?.[datasetKey]);
}

async function getFullVariableMetadata(datasetKey, variableKey) {
  try {
    const payload = await fetchSingleVariableMetadataFromDb(datasetKey, variableKey);
    if (payload) return payload;
  } catch (error) {
    if (error.code !== "42P01") {
      throw error;
    }
  }

  const fallback = await readJsonConfig("variable_metadata.json", {});
  const datasetPayload = fallback?.[datasetKey];
  if (!datasetPayload || typeof datasetPayload !== "object") {
    return null;
  }
  const variablePayload = datasetPayload.variables?.[variableKey];
  if (!variablePayload) {
    return null;
  }
  if (typeof variablePayload === "string") {
    return { title: variablePayload };
  }
  if (typeof variablePayload === "object") {
    return variablePayload;
  }
  return null;
}

async function getLegendSemanticsConfig() {
  return readJsonConfig("legend_semantics.json", {});
}

async function getVariablePolarityConfig() {
  return readJsonConfig("variable_polarity.json", {});
}

// Built offline by scripts/build_variable_coverage.sh. The variable list draws a
// coverage strip under every row at once, so unlike the map timeline — which only
// ever needs the one selected variable — it cannot afford the live per-year
// aggregate over demscore.dataset_values.
async function getVariableCoverageConfig() {
  return readJsonConfig("variable_coverage.json", { datasets: {} });
}

// Built offline by scripts/build_attribution.sh from demscore.countries joined to
// the hand-maintained register in webapp/config/attribution_sources.json. It is
// what the always-visible credit line under the map and the "Sources & licences"
// dialog are both drawn from, so the two cannot name different sources.
//
// The fallback is empty rather than a hard-coded line: the client carries its own
// constant for the line (see MapController), because an attribution that depends
// on a fetch succeeding is not an attribution.
async function getAttributionConfig() {
  return readJsonConfig("attribution.json", {});
}

// Curated cross-dataset topics for the variable list. Hand-maintained rather than
// derived: the codebook section a variable sits under is dataset-scoped and, for
// this selection, mostly one variable per section, so it seeds the mapping but
// cannot be it.
async function getVariableTopicsConfig() {
  return readJsonConfig("variable_topics.json", { order: [], topics: {}, assignments: {} });
}

// The legend paints seven quantile classes; these are the value spans behind
// them. Same source as the map -- demscore.country_scores() is what the WMS
// layer classes on -- so the numbers the legend shows on hover are the numbers
// the hexagons were coloured by, not a second, separately computed set.
//
// The two totals ride along because the map's spoken summary needs them and
// this is already the one request made for every dataset/variable/year the map
// draws. A country with no value for this year is not drawn at all, so
// `countriesTotal - countriesWithData` is how much of the map is bare land --
// which is a reading of the data, not a gap in it, and the summary has to say so.
async function getClassBreaks(dataset, variable, year) {
  const [classes, totals] = await Promise.all([
    pool.query(
      `SELECT
         class_idx::INT AS class_idx,
         min(value)::DOUBLE PRECISION AS min_value,
         max(value)::DOUBLE PRECISION AS max_value,
         count(*)::INT AS country_count
       FROM demscore.country_scores($1, $2, $3)
       WHERE class_idx IS NOT NULL
       GROUP BY class_idx
       ORDER BY class_idx;`,
      [dataset, variable, year],
    ),
    pool.query(
      `WITH scores AS (
         SELECT country_id
         FROM demscore.country_scores($1, $2, $3)
       )
       SELECT count(*)::INT AS total
       FROM demscore.countries c
       WHERE c.source = 'natural_earth'
          OR EXISTS (
            SELECT 1 FROM scores s WHERE s.country_id = c.id
          );`,
      [dataset, variable, year],
    ),
  ]);

  const classList = classes.rows.map((row) => ({
    classIndex: row.class_idx,
    min: row.min_value,
    max: row.max_value,
    countryCount: row.country_count,
  }));

  return {
    classes: classList,
    countriesWithData: classList.reduce((sum, entry) => sum + entry.countryCount, 0),
    countriesTotal: totals.rows?.[0]?.total ?? null,
  };
}

// The map as a table: one row per current Natural Earth country, plus any
// historical CShapes country that has data for this variable-year.
//
// A WMS tile is a picture, and no assistive technology can be asked what a
// hexagon stands for, so this is the map's non-visual equivalent rather than a
// convenience export. It deliberately keeps current countries with no data:
// "Somalia is not shown for 2020" is as much of a reading as a number is, and a
// table that quietly omitted it would look complete while being wrong. Historical
// rows are different: keeping every CShapes period in every current-year table
// would make the no-data universe unreadable, so those rows enter only when the
// selected data maps to them.
//
// Same source as everything else the map draws -- demscore.country_scores() --
// so a value here is the value that country's hexagons were coloured by.
async function getMapData(dataset, variable, year) {
  const result = await pool.query(
    `WITH scores AS (
       SELECT *
       FROM demscore.country_scores($1, $2, $3)
     )
     SELECT
       c.name AS country,
       NULLIF(trim(c.iso_a3), '') AS iso3,
       cs.value::DOUBLE PRECISION AS value,
       cs.class_idx::INT AS class_idx,
       c.source AS country_source,
       c.valid_from_year,
       c.valid_to_year,
       c.geometry_source_dataset,
       c.geometry_confidence
     FROM demscore.countries c
     LEFT JOIN scores cs
       ON cs.country_id = c.id
     WHERE c.source = 'natural_earth'
        OR cs.country_id IS NOT NULL
     ORDER BY c.name, c.valid_from_year NULLS LAST;`,
    [dataset, variable, year],
  );

  return result.rows.map((row) => ({
    country: row.country,
    iso3: row.iso3,
    value: row.value,
    classIndex: row.class_idx,
    historical: row.country_source !== "natural_earth",
    validFromYear: row.valid_from_year,
    validToYear: row.valid_to_year,
    // A hexagon drawn on an 1815 snapshot and one drawn on a present-day border
    // are the same picture. This is the only place a reader can be told which,
    // so the row carries it even though the map cannot.
    geometrySource: row.geometry_source_dataset,
    geometryConfidence: row.geometry_confidence,
  }));
}

// What the source measured for this variable-year, against what the map can
// draw of it.
//
// getMapData answers "what is on the map" and getClassBreaks counts it. Neither
// can see a source country this deployment has no geometry for, and to a reader
// that is indistinguishable from the source never having measured it -- which
// is the opposite fact. demscore.source_coverage() is the other half, and this
// is where it reaches the client: the unrepresented entities by name, with the
// reason this deployment cannot draw them, and a count of how many of the drawn
// ones rest on a low-confidence historical outline.
async function getSourceCoverage(dataset, variable, year) {
  const result = await pool.query(
    `SELECT
       source_name,
       source_iso3,
       value,
       map_status,
       map_country_name,
       geometry_source_dataset,
       geometry_confidence,
       reason
     FROM demscore.source_coverage($1, $2, $3)
     ORDER BY source_name;`,
    [dataset, variable, year],
  );

  const rows = result.rows;
  const mapped = rows.filter((row) => row.map_status === "mapped");
  const unrepresented = rows.filter((row) => row.map_status !== "mapped");

  const byConfidence = { high: 0, medium: 0, low: 0 };
  for (const row of mapped) {
    if (row.geometry_confidence in byConfidence) byConfidence[row.geometry_confidence] += 1;
  }

  return {
    sourceCountries: rows.length,
    mappedCountries: mapped.length,
    unrepresentedCountries: unrepresented.length,
    mappedByGeometryConfidence: byConfidence,
    unrepresented: unrepresented.map((row) => ({
      country: row.source_name,
      iso3: row.source_iso3,
      value: row.value,
      // 'intentionally_unsupported' carries a reason; 'unresolved' means no
      // policy covers it at all, which setup is supposed to have failed on.
      status: row.map_status,
      reason: row.reason,
    })),
  };
}

async function getLandBasemapGeoJson() {
  return fs.readFile(path.join(REFERENCE_DATA_DIR, LAND_BASEMAP_FILE), "utf8");
}

app.get("/healthz", asyncRoute(async (_req, res) => {
  const dbResult = await pool.query("SELECT 1 AS ok;");
  res.json({ status: "ok", db: dbResult.rows?.[0]?.ok === 1 });
}));

app.get("/api/runtime", asyncRoute(async (_req, res) => {
  res.json({
    cacheEnabled: CACHE_ENABLED,
    mapServerBase: WMS_BASE_PATH,
  });
}));

app.get("/api/basemap/land", asyncRoute(async (_req, res) => {
  const geojson = await getLandBasemapGeoJson();
  res
    .type("application/geo+json")
    .set("Cache-Control", "public, max-age=86400")
    .send(geojson);
}));

app.get("/api/config", asyncRoute(async (_req, res) => {
  const [variables, legendSemantics, variablePolarity, variableCoverage, variableTopics, attribution] =
    await Promise.all([
      getVariablesConfig(),
      getLegendSemanticsConfig(),
      getVariablePolarityConfig(),
      getVariableCoverageConfig(),
      getVariableTopicsConfig(),
      getAttributionConfig(),
    ]);

  res.json({
    variables,
    legendSemantics,
    variablePolarity,
    variableCoverage,
    variableTopics,
    attribution,
  });
}));

app.get("/api/config/variables", asyncRoute(async (_req, res) => {
  res.json(await getVariablesConfig());
}));

app.get("/api/config/variable-metadata", asyncRoute(async (req, res) => {
  const datasetKey = typeof req.query.dataset === "string" && req.query.dataset.length > 0
    ? req.query.dataset
    : null;
  if (!datasetKey) {
    res.status(400).json({
      error: "bad_request",
      message: "dataset query parameter is required",
    });
    return;
  }
  res.json(await getVariableMetadataSummary(datasetKey));
}));

app.get("/api/config/variable-metadata/:dataset", asyncRoute(async (req, res) => {
  res.json(await getVariableMetadataSummary(req.params.dataset));
}));

app.get("/api/config/variable-metadata/:dataset/:variable", asyncRoute(async (req, res) => {
  const payload = await getFullVariableMetadata(req.params.dataset, req.params.variable);
  if (!payload) {
    res.status(404).json({ error: "not_found" });
    return;
  }
  res.json(payload);
}));

app.get("/api/config/legend-semantics", asyncRoute(async (_req, res) => {
  res.json(await getLegendSemanticsConfig());
}));

app.get("/api/config/variable-polarity", asyncRoute(async (_req, res) => {
  res.json(await getVariablePolarityConfig());
}));

app.get("/api/config/variable-coverage", asyncRoute(async (_req, res) => {
  res
    .set("Cache-Control", "public, max-age=3600")
    .json(await getVariableCoverageConfig());
}));

app.get("/api/config/variable-topics", asyncRoute(async (_req, res) => {
  res
    .set("Cache-Control", "public, max-age=3600")
    .json(await getVariableTopicsConfig());
}));

app.get("/api/config/attribution", asyncRoute(async (_req, res) => {
  res
    .set("Cache-Control", "public, max-age=3600")
    .json(await getAttributionConfig());
}));

// The three parameters every map-state read shares, validated the same way the
// mapfile validates its own, so an unknown dataset is a 400 here rather than
// silently falling back to v_dem the way country_scores() would. Returns null
// and answers the request itself when anything is off.
function readMapStateQuery(req, res) {
  const dataset = typeof req.query.dataset === "string" ? req.query.dataset.toLowerCase() : "";
  const variable = typeof req.query.variable === "string" ? req.query.variable : "";
  const year = Number.parseInt(req.query.year, 10);

  if (!DATASET_META[dataset] || !VARIABLE_KEY_PATTERN.test(variable) || !Number.isInteger(year)
      || year < YEAR_MIN || year > YEAR_MAX) {
    res.status(400).json({
      error: "bad_request",
      message: "dataset, variable and year query parameters are required and must be valid",
    });
    return null;
  }

  return { dataset, variable, year };
}

// Hovering a legend swatch asks what values it stands for, and the map's spoken
// summary asks the same question for all seven classes at once. Keyed exactly
// like the WMS request the map made (dataset, variable, year).
app.get("/api/class-breaks", asyncRoute(async (req, res) => {
  const params = readMapStateQuery(req, res);
  if (!params) return;

  const breaks = await getClassBreaks(params.dataset, params.variable, params.year);
  res
    .set("Cache-Control", "public, max-age=3600")
    .json({ ...params, ...breaks });
}));

// How many countries carry a value in each year of one variable, for the
// timeline: the hover card over a year says it, and the bars are drawn from it
// one year each. Counted exactly as scripts/build_variable_coverage.sh counts
// for the list strips -- distinct *mapped* countries -- so a bar on the timeline
// and the strip under the variable's row are the same reading.
//
// Per variable and fetched when the variable changes, rather than folded into
// /api/config/variable-coverage: every variable's per-year counts would about
// triple a config payload every page load pays for, to serve the one variable
// on screen.
app.get("/api/year-counts", asyncRoute(async (req, res) => {
  const dataset = typeof req.query.dataset === "string" ? req.query.dataset.toLowerCase() : "";
  const variable = typeof req.query.variable === "string" ? req.query.variable : "";
  if (!DATASET_META[dataset] || !VARIABLE_KEY_PATTERN.test(variable)) {
    res.status(400).json({
      error: "bad_request",
      message: "dataset and variable query parameters are required and must be valid",
    });
    return;
  }

  const result = await pool.query(
    `SELECT dv.year::INT AS year, count(DISTINCT dv.country_id)::INT AS countries
     FROM demscore.variables v
     JOIN demscore.dataset_values dv ON dv.variable_id = v.id
     WHERE v.dataset = $1
       AND v.variable = $2
       AND dv.country_id IS NOT NULL
     GROUP BY dv.year
     ORDER BY dv.year;`,
    [dataset, variable],
  );
  const counts = {};
  for (const row of result.rows) counts[row.year] = row.countries;
  res
    .set("Cache-Control", "public, max-age=3600")
    .json({ dataset, variable, counts });
}));

// How much of what the source measured this map is able to show. Same
// dataset/variable/year triple as the WMS request and the two routes above.
app.get("/api/source-coverage", asyncRoute(async (req, res) => {
  const params = readMapStateQuery(req, res);
  if (!params) return;

  const coverage = await getSourceCoverage(params.dataset, params.variable, params.year);
  res
    .set("Cache-Control", "public, max-age=3600")
    .json({ ...params, ...coverage });
}));

// The map's contents as rows, for readers who cannot be shown an image of them.
app.get("/api/map-data", asyncRoute(async (req, res) => {
  const params = readMapStateQuery(req, res);
  if (!params) return;

  const rows = await getMapData(params.dataset, params.variable, params.year);
  res
    .set("Cache-Control", "public, max-age=3600")
    .json({
      ...params,
      classCount: 7,
      countriesTotal: rows.length,
      countriesWithData: rows.filter((row) => row.value !== null).length,
      rows,
    });
}));

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({
    error: "internal_error",
    message: err.message,
  });
});

const server = app.listen(PORT, () => {
  console.log(`web-backend listening on :${PORT}`);
});

async function shutdown(signal) {
  console.log(`Received ${signal}, shutting down...`);
  server.close(async () => {
    try {
      await pool.end();
    } catch (error) {
      console.error(error);
    }
    process.exit(0);
  });
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
