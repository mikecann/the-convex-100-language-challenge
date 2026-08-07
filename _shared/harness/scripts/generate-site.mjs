import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { bundledLanguages, codeToHtml } from "shiki";
import { parse } from "yaml";
import { projectReadmeExamples } from "./example-readme.mjs";
import {
  hasPassingTests,
  requiredHTTPTests,
  requiredLiveTests,
} from "./required-tests.mjs";

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

const syntaxAliases = {
  "assembly-x86-64": "asm",
  "delphi-object-pascal": "pascal",
  fortran: "fortran-free-form",
  "visual-basic-dotnet": "vb",
  "wolfram-language": "wolfram",
};

const extensionAliases = {
  clj: "clojure",
  cs: "csharp",
  erl: "erlang",
  fs: "fsharp",
  fsx: "fsharp",
  f90: "fortran-free-form",
  h: "c",
  hs: "haskell",
  hpp: "cpp",
  kts: "kotlin",
  m: "objective-c",
  ml: "ocaml",
  mli: "ocaml",
  pl: "perl",
  ps1: "powershell",
  py: "python",
  rb: "ruby",
  rs: "rust",
  sh: "bash",
  ts: "typescript",
};

// Aliases are promises that the bundled highlighter can actually keep. Fail
// the site build if a future edit invents a plausible-looking identifier that
// Shiki silently degrades to plain text.
for (const [alias, target] of [
  ...Object.entries(syntaxAliases),
  ...Object.entries(extensionAliases),
]) {
  if (!(target in bundledLanguages)) {
    throw new Error(`syntax alias ${alias} resolves to unavailable Shiki language ${target}`);
  }
}

function syntaxFor(languageId, file) {
  const extension = path.extname(file).slice(1).toLowerCase();
  const candidates = [syntaxAliases[languageId], languageId, extensionAliases[extension], extension];
  return candidates.find((candidate) => candidate && candidate in bundledLanguages) ?? "text";
}

async function firstExample(languageId) {
  const languageDirectory = path.join(root, languageId);
  const readmePath = path.join(languageDirectory, "README.md");
  if (!fs.existsSync(readmePath)) return null;
  const projection = projectReadmeExamples(readmePath);
  if (projection.errors.length > 0) {
    throw new Error(`${languageId}: ${projection.errors.join("; ")}`);
  }
  const relativeSource = projection.sources[0];
  if (!relativeSource) return null;
  const file = path.resolve(languageDirectory, relativeSource);
  const code = fs.readFileSync(file, "utf8");
  const language = syntaxFor(languageId, file);
  return {
    path: relativeSource,
    code,
    language,
    highlightedHtml: await codeToHtml(code, {
      lang: language,
      theme: "github-dark-default",
    }),
  };
}

const languages = await Promise.all(roster.languages.map(async (entry) => {
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
    example: await firstExample(entry.id),
  };
}));

fs.mkdirSync(output, { recursive: true });
for (const filename of ["index.html", "app.js", "styles.css"]) {
  fs.copyFileSync(path.join(source, filename), path.join(output, filename));
}
fs.writeFileSync(
  path.join(output, "data.json"),
  `${JSON.stringify({ schemaVersion: 1, generatedAt: new Date().toISOString(), evidenceChannel, languages }, null, 2)}\n`,
);

console.log(`PASS generated static evidence site for ${languages.length} languages`);
