import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
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
const resultSchema = JSON.parse(
  fs.readFileSync(path.join(root, "_shared/schemas/result.schema.json"), "utf8"),
);
const ajv = new Ajv2020({ allErrors: true });
addFormats(ajv);
const validateResult = ajv.compile(resultSchema);
const requiredHTTPTests = [
  "oracle/adapter/hello",
  "oracle/http/query",
  "oracle/http/nested-json-and-logs",
  "oracle/http/mutation",
  "oracle/http/idempotent-mutation",
  "oracle/http/document-id-string",
  "oracle/http/action",
  "oracle/http/structured-error",
  "oracle/http/utf8-round-trip",
  "go/adapter/hello",
  "go/http/query",
  "go/http/nested-json-and-logs",
  "go/http/mutation",
  "go/http/idempotent-mutation",
  "go/http/document-id-string",
  "go/http/action",
  "go/http/structured-error",
  "go/http/utf8-round-trip",
  "go/http/bearer-token-lifecycle",
];
const requiredLiveTests = [
  "oracle/live/initial-result",
  "oracle/live/external-update",
  "oracle/live/unsubscribe",
  "oracle/live/reconnect-five-times",
  "oracle/live/query-error-recovery",
  "oracle/live/clean-close",
  "go/live/initial-result",
  "go/live/external-update",
  "go/live/unsubscribe",
  "go/live/reconnect-five-times",
  "go/live/query-error-recovery",
  "go/live/clean-close",
];

function hasPassingTests(result, requiredNames) {
  return requiredNames.every((name) => {
    const matches = result.tests.filter((test) => test.name === name);
    return matches.length === 1 && matches[0].status === "pass";
  });
}

function checkedResult(result, source, trusted) {
  if (!validateResult(result)) {
    throw new Error(`${source}: invalid result: ${ajv.errorsText(validateResult.errors)}`);
  }
  if (result.earnedCapabilities.includes("http") && !hasPassingTests(result, requiredHTTPTests)) {
    throw new Error(`${source}: HTTP capability lacks its exact required test set`);
  }
  if (result.earnedCapabilities.includes("live")) {
    if (!result.earnedCapabilities.includes("http")) {
      throw new Error(`${source}: Live must include HTTP`);
    }
    if (!hasPassingTests(result, [...requiredHTTPTests, ...requiredLiveTests])) {
      throw new Error(`${source}: Live capability lacks its exact required test set`);
    }
  }
  if (trusted) {
    if (result.dirty) throw new Error(`${source}: trusted result has a dirty source tree`);
    if (result.evidence.channel !== "github-actions" || !result.evidence.runUrl) {
      throw new Error(`${source}: trusted result lacks GitHub Actions provenance`);
    }
    if (!result.evidence.ociArchive) {
      throw new Error(`${source}: trusted result lacks its attested OCI archive reference`);
    }
  }
  return result;
}

function readOptionalResult(directory, languageId) {
  const resultPath = path.join(
    root,
    "_shared/results",
    directory,
    `${languageId}-pilot-result.json`,
  );
  if (!fs.existsSync(resultPath)) return null;
  return checkedResult(
    JSON.parse(fs.readFileSync(resultPath, "utf8")),
    resultPath,
    false,
  );
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
  const indexedResult = resultIndex.results?.[entry.id] ?? null;
  const trustedResult = indexedResult
    ? checkedResult(indexedResult, `${resultIndexPath}#${entry.id}`, true)
    : null;
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
