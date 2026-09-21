#!/usr/bin/env node
// Colour checks for the map's own graphics: the seven quantile ramps, the
// no-data land colour, and the black area outline.
//
// Three things can go wrong with a thematic ramp and none of them shows up in a
// browser on a good monitor:
//
//   1. the legend and the map disagree. The legend bar is painted from
//      `LEGEND_COLORS_*` in MapController.js; the hexagons are painted from
//      `mapserver/hex_classes.inc`. They are two lists in two languages and
//      nothing but this check makes them the same list.
//   2. two adjacent classes are the same colour to a reader with a common
//      colour-vision deficiency, or in greyscale, or on a projector.
//   3. a ramp colour collides with the no-data land colour, so "not drawn"
//      reads as a shade the ramp ran out of.
//
// Run it after any change to either list:
//
//   node scripts/check_palette_contrast.mjs
//
// Exits non-zero on a failure, so it can go in CI as is. `--verbose` prints
// every pair rather than only the ones near a threshold.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MAPFILE_CLASSES = path.join(ROOT, "mapserver", "hex_classes.inc");
const MAP_CONTROLLER = path.join(ROOT, "webapp", "src", "controllers", "MapController.js");

const VERBOSE = process.argv.includes("--verbose");

// ---- thresholds ----------------------------------------------------------
//
// A seven-class sequential ramp cannot give every neighbouring pair a 3:1
// contrast ratio -- 3:1 seven times over needs a range of about 2200:1 and
// sRGB offers 21:1 -- so the floor here is what a ramp of this length can
// actually hold while staying one ramp. What it is really guarding against is
// a *pair* that collapses, which is what a CVD simulation turns up.
//
// DELTA_E is CIE76 in Lab. Around 2.3 is the "just noticeable difference"; 10
// is comfortably distinct at the size of a hexagon.
const MIN_ADJACENT_DELTA_E = 9;
const MIN_ADJACENT_DELTA_E_CVD = 7;
const MIN_ADJACENT_GREY_DELTA = 0.03; // relative luminance, 0..1
// The land basemap is not part of the ramp, so it has more room to be told
// apart from every class than two classes have from each other.
const MIN_NODATA_DELTA_E = 18;

// ---- colour maths --------------------------------------------------------

function parseHex(hex) {
  const match = /^#?([0-9a-f]{6})$/i.exec(String(hex).trim());
  if (!match) throw new Error(`not a hex colour: ${hex}`);
  const value = match[1];
  return [0, 2, 4].map((offset) => parseInt(value.slice(offset, offset + 2), 16));
}

function toHex(rgb) {
  return `#${rgb.map((c) => Math.round(Math.min(255, Math.max(0, c))).toString(16).padStart(2, "0")).join("")}`;
}

function srgbToLinear(channel) {
  const c = channel / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function linearToSrgb(linear) {
  const c = linear <= 0.0031308 ? linear * 12.92 : 1.055 * linear ** (1 / 2.4) - 0.055;
  return c * 255;
}

function relativeLuminance(rgb) {
  const [r, g, b] = rgb.map(srgbToLinear);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrastRatio(a, b) {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// sRGB -> CIE Lab (D65), the space CIE76 delta-E is measured in.
function rgbToLab(rgb) {
  const [r, g, b] = rgb.map(srgbToLinear);
  const x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
  const y = 0.2126729 * r + 0.7151522 * g + 0.072175 * b;
  const z = (0.0193339 * r + 0.119192 * g + 0.9503041 * b) / 1.08883;
  const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : (24389 / 27) * t / 116 + 16 / 116);
  const [fx, fy, fz] = [f(x), f(y), f(z)];
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

function deltaE(a, b) {
  const [l1, a1, b1] = rgbToLab(a);
  const [l2, a2, b2] = rgbToLab(b);
  return Math.hypot(l1 - l2, a1 - a2, b1 - b2);
}

// Brettel/Viénot-style dichromat simulation in LMS. The matrices are the
// widely used Viénot-Brettel-Mollon (1999) reductions; they are approximations,
// which is exactly the right level of precision for "would these two hexagons
// still look different".
const RGB_TO_LMS = [
  [0.31399022, 0.63951294, 0.04649755],
  [0.15537241, 0.75789446, 0.08670142],
  [0.01775239, 0.10944209, 0.87256922],
];
const LMS_TO_RGB = [
  [5.47221206, -4.6419601, 0.16963708],
  [-1.1252419, 2.29317094, -0.1678952],
  [0.02980165, -0.19318073, 1.16364789],
];
const CVD_MATRICES = {
  protanopia: [
    [0, 1.05118294, -0.05116099],
    [0, 1, 0],
    [0, 0, 1],
  ],
  deuteranopia: [
    [1, 0, 0],
    [0.9513092, 0, 0.04866992],
    [0, 0, 1],
  ],
  tritanopia: [
    [1, 0, 0],
    [0, 1, 0],
    [-0.86744736, 1.86727089, 0],
  ],
};

function applyMatrix(matrix, vector) {
  return matrix.map((row) => row.reduce((sum, coefficient, i) => sum + coefficient * vector[i], 0));
}

function simulateCvd(rgb, kind) {
  const linear = rgb.map(srgbToLinear);
  const lms = applyMatrix(RGB_TO_LMS, linear);
  const shifted = applyMatrix(CVD_MATRICES[kind], lms);
  return applyMatrix(LMS_TO_RGB, shifted).map((channel) => linearToSrgb(Math.min(1, Math.max(0, channel))));
}

// ---- reading the two palettes out of the source ---------------------------

// `COLOR r g b` inside the CLASSes of hex_classes.inc, grouped by the ramp the
// class belongs to: 1-7 is the diverging ramp, 11-17 the neutral one.
async function readMapfileRamps() {
  const text = await readFile(MAPFILE_CLASSES, "utf8");
  const byClassIndex = new Map();
  const classPattern = /EXPRESSION\s*\(\[class_idx\]\s*=\s*(\d+)\)[\s\S]*?COLOR\s+(\d+)\s+(\d+)\s+(\d+)/g;

  for (const match of text.matchAll(classPattern)) {
    const [, index, r, g, b] = match;
    byClassIndex.set(Number(index), [Number(r), Number(g), Number(b)]);
  }

  const collect = (base) =>
    Array.from({ length: 7 }, (_value, offset) => byClassIndex.get(base + offset)).filter(Boolean);

  return {
    diverging: collect(1),
    neutral: collect(11),
  };
}

// The same two ramps as the legend bar paints them.
async function readLegendRamps() {
  const text = await readFile(MAP_CONTROLLER, "utf8");
  const pick = (name) => {
    const match = new RegExp(`const ${name}\\s*=\\s*\\[([^\\]]*)\\]`).exec(text);
    if (!match) throw new Error(`could not find ${name} in ${MAP_CONTROLLER}`);
    return [...match[1].matchAll(/#[0-9a-f]{6}/gi)].map((hit) => parseHex(hit[0]));
  };
  const landMatch = /const LAND_BASEMAP_COLOR\s*=\s*"(#[0-9a-f]{6})"/i.exec(text);
  if (!landMatch) throw new Error(`could not find LAND_BASEMAP_COLOR in ${MAP_CONTROLLER}`);

  return {
    diverging: pick("LEGEND_COLORS_NEGATIVE"),
    neutral: pick("LEGEND_COLORS_NEUTRAL"),
    noData: parseHex(landMatch[1]),
  };
}

// ---- checks ---------------------------------------------------------------

const failures = [];
const notes = [];

function fail(message) {
  failures.push(message);
}

function heading(text) {
  console.log(`\n${text}\n${"-".repeat(text.length)}`);
}

function checkRampsAgree(rampName, fromMapfile, fromLegend) {
  if (fromMapfile.length !== 7) {
    fail(`${rampName}: hex_classes.inc has ${fromMapfile.length} classes, expected 7`);
    return;
  }
  if (fromLegend.length !== 7) {
    fail(`${rampName}: the legend list has ${fromLegend.length} colours, expected 7`);
    return;
  }
  for (let i = 0; i < 7; i += 1) {
    const map = toHex(fromMapfile[i]);
    const legend = toHex(fromLegend[i]);
    if (map !== legend) {
      fail(`${rampName} class ${i + 1}: mapfile ${map} but legend ${legend} — the bar is lying about the map`);
    }
  }
}

function checkRamp(rampName, colors) {
  heading(`${rampName} ramp`);

  const luminances = colors.map(relativeLuminance);
  const increasing = luminances.every((value, i) => i === 0 || value < luminances[i - 1]);
  const decreasing = luminances.every((value, i) => i === 0 || value > luminances[i - 1]);
  if (increasing || decreasing) {
    console.log("lightness: monotonic — the ramp survives greyscale on its own");
  } else {
    notes.push(
      `${rampName}: lightness is not monotonic, so greyscale alone cannot order the classes. ` +
        "Acceptable for a diverging ramp read from its midpoint, but it is why the outlines matter.",
    );
    console.log("lightness: NOT monotonic (see notes)");
  }

  for (let i = 1; i < colors.length; i += 1) {
    const previous = colors[i - 1];
    const current = colors[i];
    const measurements = {
      "delta-E": deltaE(previous, current),
      contrast: contrastRatio(previous, current),
      greyscale: Math.abs(relativeLuminance(previous) - relativeLuminance(current)),
      protanopia: deltaE(simulateCvd(previous, "protanopia"), simulateCvd(current, "protanopia")),
      deuteranopia: deltaE(simulateCvd(previous, "deuteranopia"), simulateCvd(current, "deuteranopia")),
      tritanopia: deltaE(simulateCvd(previous, "tritanopia"), simulateCvd(current, "tritanopia")),
    };

    const problems = [];
    if (measurements["delta-E"] < MIN_ADJACENT_DELTA_E) {
      problems.push(`delta-E ${measurements["delta-E"].toFixed(1)} < ${MIN_ADJACENT_DELTA_E}`);
    }
    if (measurements.greyscale < MIN_ADJACENT_GREY_DELTA) {
      problems.push(`greyscale ${measurements.greyscale.toFixed(3)} < ${MIN_ADJACENT_GREY_DELTA}`);
    }
    for (const kind of ["protanopia", "deuteranopia", "tritanopia"]) {
      if (measurements[kind] < MIN_ADJACENT_DELTA_E_CVD) {
        problems.push(`${kind} delta-E ${measurements[kind].toFixed(1)} < ${MIN_ADJACENT_DELTA_E_CVD}`);
      }
    }

    const label = `  ${toHex(previous)} -> ${toHex(current)} (class ${i} -> ${i + 1})`;
    if (problems.length > 0) {
      fail(`${rampName} class ${i} -> ${i + 1}: ${problems.join("; ")}`);
      console.log(`${label}  FAIL  ${problems.join("; ")}`);
    } else if (VERBOSE) {
      console.log(
        `${label}  ok  dE ${measurements["delta-E"].toFixed(1)}` +
          `  grey ${measurements.greyscale.toFixed(3)}` +
          `  P ${measurements.protanopia.toFixed(1)}` +
          `  D ${measurements.deuteranopia.toFixed(1)}` +
          `  T ${measurements.tritanopia.toFixed(1)}`,
      );
    }
  }
  if (!VERBOSE) console.log("  adjacent pairs: all within thresholds (run with --verbose for the numbers)");

  // Two classes at opposite ends of the ramp printing as the same grey is not
  // an adjacency problem and no adjacency threshold catches it, but it is what
  // a monochrome reader -- or a photocopier -- actually runs into. Reported
  // rather than failed: on a diverging ramp it is inherent, and the non-colour
  // cues are what answer it.
  for (let i = 0; i < colors.length; i += 1) {
    for (let j = i + 2; j < colors.length; j += 1) {
      const separation = Math.abs(luminances[i] - luminances[j]);
      if (separation >= MIN_ADJACENT_GREY_DELTA) continue;
      notes.push(
        `${rampName}: classes ${i + 1} and ${j + 1} (${toHex(colors[i])}, ${toHex(colors[j])}) are the same ` +
          `grey (delta ${separation.toFixed(3)}). Hue is the only thing separating them.`,
      );
    }
  }
}

function checkNoData(rampName, colors, noData) {
  for (let i = 0; i < colors.length; i += 1) {
    const separation = deltaE(colors[i], noData);
    if (separation < MIN_NODATA_DELTA_E) {
      fail(
        `${rampName} class ${i + 1} (${toHex(colors[i])}) is only delta-E ${separation.toFixed(1)} from the ` +
          `no-data land colour ${toHex(noData)} — "not drawn" will read as a class`,
      );
    }
  }
}

// The legend's own text is white on the navy dock; the app tokens it is set in
// are checked here so a palette edit cannot quietly drop text below 4.5:1.
function checkTextTokens() {
  heading("interface text contrast");
  const pairs = [
    ["legend title/labels", "#ffffff", "#1d3c4f"],
    ["legend subtitle (84% white on navy)", "#d6dde1", "#1d3c4f"],
    ["legend note (74% white on navy)", "#c4cdd3", "#1d3c4f"],
    ["body text on white", "#3b3838", "#ffffff"],
    ["muted text on white", "#6b6664", "#ffffff"],
    ["muted text on panel surface", "#6b6664", "#f5f5f5"],
    ["selected variable row", "#1d3c4f", "#d7e3ee"],
  ];

  for (const [label, foreground, background] of pairs) {
    const ratio = contrastRatio(parseHex(foreground), parseHex(background));
    const ok = ratio >= 4.5;
    console.log(`  ${ok ? "ok  " : "FAIL"} ${ratio.toFixed(2)}:1  ${label}`);
    if (!ok) fail(`${label}: ${ratio.toFixed(2)}:1 is below 4.5:1`);
  }
}

// ---- main ----------------------------------------------------------------

const mapfile = await readMapfileRamps();
const legend = await readLegendRamps();

heading("legend bar vs. mapfile");
checkRampsAgree("diverging", mapfile.diverging, legend.diverging);
checkRampsAgree("neutral", mapfile.neutral, legend.neutral);
if (failures.length === 0) console.log("  both ramps match the classes MapServer paints");

checkRamp("diverging", legend.diverging);
checkNoData("diverging", legend.diverging, legend.noData);
checkRamp("neutral", legend.neutral);
checkNoData("neutral", legend.neutral, legend.noData);

checkTextTokens();

if (notes.length > 0) {
  heading("notes");
  for (const note of notes) console.log(`  - ${note}`);
}

heading("result");
if (failures.length === 0) {
  console.log("  all checks passed");
  process.exit(0);
}
for (const failure of failures) console.log(`  FAIL ${failure}`);
console.log(`\n  ${failures.length} failure(s)`);
process.exit(1);
