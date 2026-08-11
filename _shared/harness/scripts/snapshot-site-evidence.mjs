import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parse } from "yaml";

const root = process.env.REPO_ROOT ?? "/repo";
const roster = parse(
  fs.readFileSync(path.join(root, "roster/languages.yaml"), "utf8"),
);
const outputPath = path.join(root, "_shared/site/evidence/local-preview.json");

const results = { local: {}, hosted: {} };
const finishedAt = [];

for (const channel of Object.keys(results)) {
  for (const language of roster.languages) {
    const resultPath = path.join(
      root,
      "_shared/results",
      channel,
      `${language.id}-pilot-result.json`,
    );
    if (!fs.existsSync(resultPath)) {
      throw new Error(`${resultPath}: missing result for publishing snapshot`);
    }
    const result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
    results[channel][language.id] = result;
    if (result.finishedAt) finishedAt.push(result.finishedAt);
  }
}

const snapshot = {
  schemaVersion: 1,
  evidenceChannel: "local-preview",
  // Derive this from the evidence so refreshing an unchanged snapshot is stable.
  snapshotAt: finishedAt.sort().at(-1) ?? null,
  results,
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(snapshot, null, 2)}\n`);
console.log(`Wrote ${outputPath}`);
