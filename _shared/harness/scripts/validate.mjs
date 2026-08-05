import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import Ajv2020 from "ajv/dist/2020.js";
import { parse } from "yaml";

const root = process.env.REPO_ROOT ?? "/repo";
const roster = parse(fs.readFileSync(path.join(root, "roster/languages.yaml"), "utf8"));
const manifestSchema = JSON.parse(
  fs.readFileSync(path.join(root, "_shared/schemas/manifest.schema.json"), "utf8"),
);

const ajv = new Ajv2020({ allErrors: true });
const validateManifest = ajv.compile(manifestSchema);
const errors = [];

if (roster.schemaVersion !== 1 || roster.languages.length !== 100) {
  errors.push("roster must contain exactly 100 schema-v1 languages");
}

const ids = new Set();
const ranks = new Set();

for (const language of roster.languages) {
  if (ids.has(language.id)) errors.push(`duplicate id: ${language.id}`);
  if (ranks.has(language.rank)) errors.push(`duplicate rank: ${language.rank}`);
  ids.add(language.id);
  ranks.add(language.rank);

  const directory = path.join(root, language.id);
  const manifestPath = path.join(directory, "manifest.yaml");
  const readmePath = path.join(directory, "README.md");

  if (!fs.existsSync(directory)) {
    errors.push(`${language.id}: missing top-level directory`);
    continue;
  }
  if (!fs.existsSync(manifestPath)) {
    errors.push(`${language.id}: missing manifest.yaml`);
    continue;
  }
  if (!fs.existsSync(readmePath)) {
    errors.push(`${language.id}: missing README.md`);
  }

  const manifest = parse(fs.readFileSync(manifestPath, "utf8"));
  if (!validateManifest(manifest)) {
    errors.push(
      `${language.id}: invalid manifest: ${ajv.errorsText(validateManifest.errors)}`,
    );
  }
  for (const key of ["id", "displayName", "rank", "selectionTier"]) {
    if (manifest[key] !== language[key]) {
      errors.push(`${language.id}: manifest ${key} does not match roster`);
    }
  }

  if (manifest.implementation?.status !== "planned") {
    for (const required of [
      "Dockerfile",
      "src",
      "example",
      "adapter",
      "tests",
    ]) {
      if (!fs.existsSync(path.join(directory, required))) {
        errors.push(`${language.id}: implemented client missing ${required}`);
      }
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(`FAIL ${error}`);
  process.exit(1);
}

console.log(`PASS roster and ${ids.size} language manifests are structurally valid`);
