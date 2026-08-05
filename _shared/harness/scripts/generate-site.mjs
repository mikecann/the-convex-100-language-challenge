import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { parse } from "yaml";

const root = process.env.REPO_ROOT ?? "/repo";
const output = path.join(root, "_shared/site/dist");
const source = path.join(root, "_shared/site/src");
const roster = parse(fs.readFileSync(path.join(root, "roster/languages.yaml"), "utf8"));
const resultIndexPath = path.join(root, "_shared/results/index.json");
const resultIndex = fs.existsSync(resultIndexPath)
  ? JSON.parse(fs.readFileSync(resultIndexPath, "utf8"))
  : { results: {} };
const includeLocal = process.env.INCLUDE_LOCAL_RESULTS === "true";
const evidenceChannel = process.env.EVIDENCE_CHANNEL ?? "trusted-main";

function readOptionalResult(directory, languageId) {
  const resultPath = path.join(
    root,
    "_shared/results",
    directory,
    `${languageId}-pilot-result.json`,
  );
  if (!fs.existsSync(resultPath)) return null;
  return JSON.parse(fs.readFileSync(resultPath, "utf8"));
}

function firstExample(languageId) {
  const directory = path.join(root, languageId, "example");
  if (!fs.existsSync(directory)) return null;
  const files = fs
    .readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name))
    .sort();
  const file = files[0];
  if (!file) return null;
  return {
    path: path.relative(path.join(root, languageId), file),
    code: fs.readFileSync(file, "utf8"),
  };
}

const languages = roster.languages.map((entry) => {
  const manifest = parse(
    fs.readFileSync(path.join(root, entry.id, "manifest.yaml"), "utf8"),
  );
  const trustedResult = resultIndex.results?.[entry.id] ?? null;
  const localResult = includeLocal ? readOptionalResult("local", entry.id) : null;
  const hostedResult = includeLocal ? readOptionalResult("hosted", entry.id) : null;
  return {
    ...entry,
    implementation: manifest.implementation,
    toolchain: manifest.toolchain ?? null,
    syncProfile: manifest.syncProfile ?? null,
    declaredCapabilities: manifest.capabilities,
    result: trustedResult ?? localResult,
    evidenceTrust: trustedResult ? "trusted-main" : localResult ? evidenceChannel : null,
    hostedResult,
    example: firstExample(entry.id),
  };
});

fs.mkdirSync(output, { recursive: true });
for (const filename of ["index.html", "app.js", "styles.css"]) {
  fs.copyFileSync(path.join(source, filename), path.join(output, filename));
}
fs.writeFileSync(
  path.join(output, "data.json"),
  `${JSON.stringify({ schemaVersion: 1, generatedAt: new Date().toISOString(), evidenceChannel, languages }, null, 2)}\n`,
);

console.log(`PASS generated static evidence site for ${languages.length} languages`);
