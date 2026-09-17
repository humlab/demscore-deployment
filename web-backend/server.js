const express = require("express");
const cors = require("cors");
const fs = require("fs/promises");
const path = require("path");
const { Pool } = require("pg");

const PORT = Number.parseInt(process.env.PORT || "8091", 10);
const CONFIG_DIR = process.env.CONFIG_DIR || path.join(__dirname, "webapp-config");
const REFERENCE_DATA_DIR = process.env.REFERENCE_DATA_DIR || path.join(__dirname, "..", "data", "reference");
const LAND_BASEMAP_FILE = "ne_110m_admin_0_countries.geojson";
const WMS_BASE_PATH = "/mapserver?map=/etc/mapserver/mapserver.map";

const DATASET_META = {
  qog: {
    label: "QoG",
    title: "Quality of Government",
    codebook: "./assets/codebooks/qog-codebook.pdf",
    defaultVariable: "qog_std_ts_ti_cpi",
  },
  repdem: {
    label: "REPDEM",
    title: "Representative Democracy",
    codebook: "./assets/codebooks/repdem-codebook.pdf",
    defaultVariable: "repdem_basic_enpp",
  },
  v_dem: {
    label: "V-Dem",
    title: "Varieties of Democracy",
    codebook: "./assets/codebooks/v-dem-codebook.pdf",
    defaultVariable: "v2x_polyarchy",
  },
};

// How a dataset presents itself, as opposed to what it contains. The database
// supplies the variables and the year span; these come from config.
const DATASET_PRESENTATION_KEYS = ["label", "title", "color", "palette", "codebook", "image"];

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
      codebook: fallbackMeta.codebook,
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

// Curated cross-dataset topics for the variable list. Hand-maintained rather than
// derived: the codebook section a variable sits under is dataset-scoped and, for
// this selection, mostly one variable per section, so it seeds the mapping but
// cannot be it.
async function getVariableTopicsConfig() {
  return readJsonConfig("variable_topics.json", { order: [], topics: {}, assignments: {} });
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
  const [variables, legendSemantics, variablePolarity, variableCoverage, variableTopics] =
    await Promise.all([
      getVariablesConfig(),
      getLegendSemanticsConfig(),
      getVariablePolarityConfig(),
      getVariableCoverageConfig(),
      getVariableTopicsConfig(),
    ]);

  res.json({
    variables,
    legendSemantics,
    variablePolarity,
    variableCoverage,
    variableTopics,
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
