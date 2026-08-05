import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { parse } from "yaml";
import { projectReadmeExamples } from "./example-readme.mjs";

const root = process.env.REPO_ROOT ?? "/repo";
const roster = parse(fs.readFileSync(path.join(root, "roster/languages.yaml"), "utf8"));
const manifestSchema = JSON.parse(
  fs.readFileSync(path.join(root, "_shared/schemas/manifest.schema.json"), "utf8"),
);

const ajv = new Ajv2020({ allErrors: true });
addFormats(ajv);
const validateManifest = ajv.compile(manifestSchema);
const errors = [];

for (const schemaName of ["adapter.schema.json", "result.schema.json"]) {
  const schema = JSON.parse(
    fs.readFileSync(path.join(root, "_shared/schemas", schemaName), "utf8"),
  );
  ajv.compile(schema);
}

const workflowPath = path.join(root, ".github/workflows/go-pilot.yml");
const workflow = parse(fs.readFileSync(workflowPath, "utf8"));
const workflowSteps = workflow.jobs?.conformance?.steps ?? [];
for (const step of workflowSteps) {
  if (step.uses && !/@[0-9a-f]{40}$/.test(step.uses)) {
    errors.push(`GitHub Action is not pinned by full commit: ${step.uses}`);
  }
}

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
  } else {
    const projection = projectReadmeExamples(readmePath);
    for (const error of projection.errors) {
      errors.push(`${language.id}: ${error}`);
    }
    if (projection.original !== projection.projected) {
      errors.push(`${language.id}: README example is stale; run ./run sync-examples`);
    }
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
    const projection = fs.existsSync(readmePath)
      ? projectReadmeExamples(readmePath)
      : { markerCount: 0 };
    if (projection.markerCount === 0) {
      errors.push(`${language.id}: implemented client README needs a generated example block`);
    }
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
