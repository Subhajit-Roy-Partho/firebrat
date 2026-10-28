// usage: node chapters.mjs <manifest.json>  -> prints {chapters, sectionCount, totalDurationMs} using the site's own helpers
import { readFileSync } from "node:fs";
import { buildChapters, validateChapters } from "../src/ia.js";

const manifest = JSON.parse(readFileSync(process.argv[2], "utf8"));
const chapters = buildChapters(manifest);
const check = validateChapters(chapters);
if (!check.ok) { console.error(check.errors.slice(0, 5).join("\n")); process.exit(1); }
console.log(JSON.stringify({
  chapters,
  sectionCount: chapters.length,
  totalDurationMs: chapters.reduce((a, c) => a + c.durationMs, 0),
}));
