const express = require("express");
const cors = require("cors");
const fs = require("fs/promises");
const path = require("path");
const { Pool } = require("pg");

const PORT = Number.parseInt(process.env.PORT || "8091", 10);
const CONFIG_DIR = process.env.CONFIG_DIR || path.join(__dirname, "webapp-config");
const WMS_BASE_PATH = "/mapserver?map=/etc/mapserver/mapserver.map";

const DATASET_META = {
  qog: {
    label: "QoG",
    codebook: "./assets/codebooks/qog-codebook.pdf",
    defaultVariable: "qog_std_ts_ti_cpi",
  },
  repdem: {
    label: "REPDEM",
    codebook: "./assets/codebooks/repdem-codebook.pdf",
    defaultVariable: "repdem_basic_enpp",
  },
  v_dem: {
    label: "V-Dem",
    codebook: "./assets/codebooks/v-dem-codebook.pdf",
    defaultVariable: "v2x_polyarchy",
  },
};

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
      GROUP BY dataset
    ),
    years AS (
      SELECT
        v.dataset,
        MIN(dv.year)::INT AS year_min,
        MAX(dv.year)::INT AS year_max
      FROM demscore.variables v
      JOIN demscore.dataset_values dv ON dv.variable_id = v.id
      GROUP BY v.dataset
    )
    SELECT
      vars.dataset,
      vars.variables,
      years.year_min,
      years.year_max
    FROM vars
    LEFT JOIN years ON years.dataset = vars.dataset
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
      codebook: fallbackMeta.codebook,
      defaultVariable,
      yearMin: Number.isInteger(row.year_min) ? row.year_min : DEFAULTS.year,
      yearMax: Number.isInteger(row.year_max) ? row.year_max : DEFAULTS.year,
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

async function getVariablesConfig() {
  try {
    const dbConfig = await fetchVariablesConfigFromDb();
    if (dbConfig) {
      return dbConfig;
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

app.get("/healthz", asyncRoute(async (_req, res) => {
  const dbResult = await pool.query("SELECT 1 AS ok;");
  res.json({ status: "ok", db: dbResult.rows?.[0]?.ok === 1 });
}));

app.get("/api/runtime", asyncRoute(async (_req, res) => {
  res.json({
    mapServerBase: WMS_BASE_PATH,
  });
}));

app.get("/api/config", asyncRoute(async (_req, res) => {
  const [variables, legendSemantics, variablePolarity] = await Promise.all([
    getVariablesConfig(),
    getLegendSemanticsConfig(),
    getVariablePolarityConfig(),
  ]);

  res.json({
    variables,
    legendSemantics,
    variablePolarity,
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
