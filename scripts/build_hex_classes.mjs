#!/usr/bin/env node
// Generates mapserver/hex_classes.inc from webapp/src/core/palettes.js.
//
// The hexagon colours have to exist in two places -- MapServer paints the map
// from a mapfile, the browser paints the legend that is the key to it from
// JavaScript -- and a legend painted in colours the map does not use is a
// legend that lies. Rather than keep two lists in step by hand, the JavaScript
// is the source and this writes the mapfile side of it.
//
//   node scripts/build_hex_classes.mjs          # write
//   node scripts/build_hex_classes.mjs --check  # fail if out of date, write nothing
//
// `scripts/check_palette_contrast.mjs` verifies the same agreement from the
// other direction, by reading both files, so a hand-edited .inc is caught even
// if this is never run.

import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  CLASS_COUNT,
  MAP_PALETTES,
  NO_DATA_CLASS_IDX,
  NO_DATA_COLOR,
  paletteBands,
} from "../webapp/src/core/palettes.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TARGET = path.join(ROOT, "mapserver", "hex_classes.inc");
const CHECK_ONLY = process.argv.includes("--check");

function toRgb(hex) {
  const match = /^#([0-9a-f]{6})$/i.exec(hex.trim());
  if (!match) throw new Error(`not a hex colour: ${hex}`);
  return [0, 2, 4].map((offset) => parseInt(match[1].slice(offset, offset + 2), 16)).join(" ");
}

// Which schemes a band serves, so the generated file says why each block is
// there rather than presenting 28 anonymous classes.
function bandUsers(base) {
  const users = [];
  for (const [key, palette] of Object.entries(MAP_PALETTES)) {
    const roles = [];
    if (palette.signed.base === base) roles.push(palette.honoursPolarity ? "signed" : "all variables");
    if (palette.neutral.base === base && palette.neutral.base !== palette.signed.base) roles.push("unsigned");
    if (roles.length > 0) users.push(`${key} (${roles.join(", ")})`);
  }
  return users.join("; ");
}

function render() {
  const lines = [
    "# GENERATED FILE -- do not edit.",
    "#",
    "# Written by scripts/build_hex_classes.mjs from webapp/src/core/palettes.js,",
    "# which is where the colours live and where they should be changed. Run the",
    "# generator after editing it; scripts/check_palette_contrast.mjs fails if this",
    "# file and the JavaScript have drifted apart.",
    "#",
    "# INCLUDEd by every hex fill layer rather than written out per layer: one mesh",
    "# is cut in Equal Earth and one in Web Mercator, and the projection a cell was",
    "# cut in has nothing to do with the colour it takes.",
    "#",
    "# Each block below is one seven-class band. The DATA query offsets class_idx",
    "# onto a band per colour scheme and polarity, so the class a hexagon lands in",
    "# carries both which scheme was asked for and which way round it reads. A band",
    "# is reversed in SQL (base + (8 - class_idx)) rather than written out twice.",
    "",
  ];

  for (const [base, colors] of paletteBands()) {
    lines.push(`# class_idx ${base + 1}-${base + CLASS_COUNT} -- ${bandUsers(base)}`);
    colors.forEach((color, index) => {
      const classIdx = base + index + 1;
      lines.push(
        "  CLASS",
        `    NAME "${classIdx}"`,
        `    EXPRESSION ([class_idx] = ${classIdx})`,
        "    STYLE",
        `      COLOR ${toRgb(color)}`,
        "      OUTLINECOLOR 255 255 255",
        "      WIDTH 0.25",
        "    END",
        "  END",
        "",
      );
    });
  }

  // Not a band: the one colour every scheme shares, for present-day countries
  // with no value this year. The DATA query emits this class_idx for them.
  lines.push(
    `# class_idx ${NO_DATA_CLASS_IDX} -- no data (every scheme, every polarity)`,
    "  CLASS",
    `    NAME "${NO_DATA_CLASS_IDX}"`,
    `    EXPRESSION ([class_idx] = ${NO_DATA_CLASS_IDX})`,
    "    STYLE",
    `      COLOR ${toRgb(NO_DATA_COLOR)}`,
    "      OUTLINECOLOR 255 255 255",
    "      WIDTH 0.25",
    "    END",
    "  END",
    "",
  );

  return `${lines.join("\n").trimEnd()}\n`;
}

const generated = render();
const existing = await readFile(TARGET, "utf8").catch(() => null);

if (generated === existing) {
  console.log(`${path.relative(ROOT, TARGET)} is up to date`);
  process.exit(0);
}

if (CHECK_ONLY) {
  console.error(
    `${path.relative(ROOT, TARGET)} is out of date with webapp/src/core/palettes.js.\n` +
      "Run: node scripts/build_hex_classes.mjs",
  );
  process.exit(1);
}

await writeFile(TARGET, generated, "utf8");
const bandCount = paletteBands().length;
console.log(
  `wrote ${path.relative(ROOT, TARGET)}: ${bandCount} bands, ${bandCount * CLASS_COUNT} classes`,
);
