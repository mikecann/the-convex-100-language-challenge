import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { Marked } from "marked";
import { bundledLanguages, codeToHtml, createHighlighter } from "shiki";
import { parse } from "yaml";
import { projectReadmeExamples } from "./example-readme.mjs";
import {
  customLanguageGrammars,
  customLanguageIds,
} from "./site-language-grammars.mjs";
import {
  hasPassingTests,
  requiredHTTPTests,
  requiredLiveTests,
} from "./required-tests.mjs";

const root = process.env.REPO_ROOT ?? "/repo";
const output = path.join(root, "_shared/site/dist");
const source = path.join(root, "_shared/site/src");
const repoWebUrl = "https://github.com/mikecann/100-convex-clients";
const roster = parse(fs.readFileSync(path.join(root, "roster/languages.yaml"), "utf8"));
const popularity = parse(fs.readFileSync(path.join(root, "roster/popularity.yaml"), "utf8"));
const popularityById = new Map(
  popularity.languages.map((entry) => [entry.id, entry]),
);
const languageYears = JSON.parse(
  fs.readFileSync(path.join(root, "_shared/site/language-years.json"), "utf8"),
);
const languageWikipedia = JSON.parse(
  fs.readFileSync(path.join(root, "_shared/site/language-wikipedia.json"), "utf8"),
);
const graveyardLogos = JSON.parse(
  fs.readFileSync(path.join(root, "_shared/site/graveyard-logos.json"), "utf8"),
);
const customHighlighter = await createHighlighter({
  themes: ["github-dark-default"],
  langs: Object.values(customLanguageGrammars),
});
const resultIndexPath = path.join(root, "_shared/results/index.json");
const resultIndex = fs.existsSync(resultIndexPath)
  ? JSON.parse(fs.readFileSync(resultIndexPath, "utf8"))
  : { results: {} };
const includeLocal = process.env.INCLUDE_LOCAL_RESULTS === "true";
const evidenceChannel = process.env.EVIDENCE_CHANNEL ?? "trusted-main";
const previewSnapshotPath = path.join(
  root,
  "_shared/site/evidence/local-preview.json",
);
const previewSnapshot = includeLocal && fs.existsSync(previewSnapshotPath)
  ? JSON.parse(fs.readFileSync(previewSnapshotPath, "utf8"))
  : null;
if (previewSnapshot && previewSnapshot.schemaVersion !== 1) {
  throw new Error(`${previewSnapshotPath}: unsupported schema version`);
}
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
  if (fs.existsSync(resultPath)) {
    return checkedResult(
      JSON.parse(fs.readFileSync(resultPath, "utf8")),
      resultPath,
      false,
    );
  }

  // GitHub runners do not have the ignored local verification directory. The
  // publishing snapshot contains only the result JSON already exposed by the
  // generated site's data.json, without transcripts, logs, or OCI archives.
  const snapshotResult = previewSnapshot?.results?.[directory]?.[languageId];
  return snapshotResult
    ? checkedResult(
        snapshotResult,
        `${previewSnapshotPath}#${directory}.${languageId}`,
        false,
      )
    : null;
}

const syntaxAliases = {
  "assembly-x86-64": "asm",
  "delphi-object-pascal": "pascal",
  fortran: "fortran-free-form",
  hy: "lisp",
  "visual-basic-dotnet": "vb",
  "wolfram-language": "wolfram",
};

const hasSyntax = (language) =>
  Boolean(language) && (language in bundledLanguages || customLanguageIds.has(language));

async function highlightCode(code, language) {
  let html;
  if (customLanguageIds.has(language)) {
    html = customHighlighter.codeToHtml(code, {
      lang: language,
      theme: "github-dark-default",
    });
  } else {
    html = await codeToHtml(code, {
      lang: language,
      theme: "github-dark-default",
    });
  }

  if (language === "text") return html;

  // A registered grammar can still be accidentally empty or malformed. Make
  // the publishing build prove that it produced real token colour variation,
  // rather than accepting an all-white block under a non-"text" language id.
  const tokenColors = new Set(
    [...html.matchAll(/color:#[0-9a-f]{6}/gi)].map(([color]) => color.toLowerCase()),
  );
  if (tokenColors.size < 3) {
    throw new Error(`${language}: syntax grammar produced no meaningful highlighting`);
  }
  return html;
}

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
  if (!hasSyntax(target)) {
    throw new Error(`syntax alias ${alias} resolves to unavailable Shiki language ${target}`);
  }
}

function syntaxFor(languageId, file) {
  const extension = path.extname(file).slice(1).toLowerCase();
  const candidates = [syntaxAliases[languageId], languageId, extensionAliases[extension], extension];
  return candidates.find(hasSyntax) ?? "text";
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
  if (language === "text") {
    throw new Error(`${languageId}: canonical example has no syntax grammar`);
  }
  return {
    path: relativeSource,
    code,
    language,
    highlightedHtml: await highlightCode(code, language),
  };
}

function fenceSyntax(lang) {
  const candidates = [lang, extensionAliases[lang], syntaxAliases[lang]];
  return candidates.find(hasSyntax) ?? "text";
}

// Renders repository-owned markdown (language READMEs, INFEASIBLE.md) to HTML
// for the site. Relative links are rewritten to the GitHub repository at the
// given ref so the site can quote a file without copying it, and fenced code
// is highlighted with the same Shiki theme as the canonical examples.
async function renderMarkdown(markdown, { baseDirectory, ref }) {
  const rewrite = (href, { raw = false } = {}) => {
    if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("#") || href.startsWith("/")) {
      return href;
    }
    const resolved = new URL(href, `https://resolve.invalid/${baseDirectory}/README.md`)
      .pathname.replace(/^\//, "");
    return raw
      ? `${repoWebUrl}/raw/${ref}/${resolved}`
      : `${repoWebUrl}/blob/${ref}/${resolved}`;
  };

  const marked = new Marked({ async: true, gfm: true });
  marked.use({
    walkTokens: async (token) => {
      if (token.type === "code") {
        token.highlightedHtml = await highlightCode(
          token.text,
          fenceSyntax(token.lang?.split(/\s+/)[0]?.toLowerCase()),
        );
      }
      if (token.type === "link") token.href = rewrite(token.href);
      if (token.type === "image") token.href = rewrite(token.href, { raw: true });
    },
    renderer: {
      code(token) {
        return token.highlightedHtml ?? false;
      },
    },
  });
  return marked.parse(markdown);
}

async function renderLanguageReadme(languageId, ref) {
  const readmePath = path.join(root, languageId, "README.md");
  if (!fs.existsSync(readmePath)) return null;
  const markdown = fs
    .readFileSync(readmePath, "utf8")
    // The site's dialog already shows the logo and language name, so drop the
    // README's own logo image, its source-attribution comment, and its title.
    .replace(/^<img [^>]*>\s*\n/, "")
    .replace(/^<!--[\s\S]*?-->\s*\n/, "")
    .replace(/^# .+\n/m, "");
  return renderMarkdown(markdown, { baseDirectory: languageId, ref });
}

async function renderGraveyard() {
  const markdown = fs
    .readFileSync(path.join(root, "INFEASIBLE.md"), "utf8")
    .replace(/^# .+\n/m, "");
  const graveyardEntries = [
    ...markdown.split("## Chosen replacements", 1)[0].matchAll(/^\| ([a-z0-9-]+) \|/gm),
  ]
    .map((match) => match[1])
    .filter((id) => id !== "---");
  const expectedIds = new Set(graveyardEntries);
  const logoById = new Map(graveyardLogos.map((logo) => [logo.id, logo]));

  if (logoById.size !== graveyardLogos.length) {
    throw new Error("_shared/site/graveyard-logos.json contains duplicate language IDs");
  }
  for (const id of expectedIds) {
    if (!logoById.has(id)) throw new Error(`${id}: missing graveyard logo`);
  }
  for (const logo of graveyardLogos) {
    if (!expectedIds.has(logo.id)) {
      throw new Error(`${logo.id}: graveyard logo does not match an infeasible or at-risk entry`);
    }
    const assetPath = path.join(source, "graveyard-logos", logo.asset);
    if (!fs.existsSync(assetPath)) throw new Error(`${logo.id}: missing logo asset ${logo.asset}`);
  }

  let html = await renderMarkdown(markdown, { baseDirectory: ".", ref: "main" });
  for (const logo of graveyardLogos) {
    const cell = `<td>${logo.id}</td>`;
    const brandedCell = `<td><span class="graveyard-language"><a href="${logo.sourceUrl}" aria-label="${logo.name} logo source"><img src="/graveyard-logos/${logo.asset}" alt="" width="38" height="38" loading="lazy"></a><span>${logo.name}</span></span></td>`;
    // Later replacement tables mention many of these IDs again. Brand the
    // actual graveyard row only so the record stays readable rather than
    // repeating the same mark throughout the history below it.
    html = html.replace(cell, brandedCell);
  }

  const sourceLinks = graveyardLogos
    .map((logo) => `<li><a href="${logo.sourceUrl}">${logo.name}</a></li>`)
    .join("");
  return `${html}<details class="graveyard-logo-sources"><summary>Logo sources</summary><p>Each mark links to the language's official project or vendor page and is used here only for identification.</p><ul>${sourceLinks}</ul></details>`;
}

const languages = await Promise.all(roster.languages.map(async (entry) => {
  const logoSource = path.join(root, entry.id, "logo.png");
  const manifest = parse(
    fs.readFileSync(path.join(root, entry.id, "manifest.yaml"), "utf8"),
  );
  const indexedResult = resultIndex.results?.[entry.id] ?? null;
  const trustedResult = indexedResult
    ? checkedResult(indexedResult, `${resultIndexPath}#${entry.id}`, true)
    : null;
  const localResult = includeLocal ? readOptionalResult("local", entry.id) : null;
  const hostedResult = includeLocal ? readOptionalResult("hosted", entry.id) : null;
  const result = trustedResult ?? localResult;
  // Source links pin to the exact verified commit when there is one, so what
  // the site shows is what the badge was earned against.
  const sourceRef = result?.sourceCommit ?? "main";
  const example = await firstExample(entry.id);
  const readmeHtml = await renderLanguageReadme(entry.id, sourceRef);
  const popularityEntry = popularityById.get(entry.id);
  if (!popularityEntry) {
    throw new Error(`${entry.id}: missing popularity ranking`);
  }
  return {
    ...entry,
    popularityRank: popularityEntry.popularityRank,
    firstAppeared: languageYears[entry.id] ?? null,
    wikipediaUrl: languageWikipedia[entry.id]
      ? `https://en.wikipedia.org/wiki/${languageWikipedia[entry.id]}`
      : null,
    implementation: manifest.implementation,
    toolchain: manifest.toolchain ?? null,
    syncProfile: manifest.syncProfile ?? null,
    declaredCapabilities: manifest.capabilities,
    result,
    evidenceTrust: trustedResult ? "trusted-main" : localResult ? evidenceChannel : null,
    hostedResult,
    example,
    sourceUrl: `${repoWebUrl}/tree/${sourceRef}/${entry.id}`,
    exampleUrl: example ? `${repoWebUrl}/blob/${sourceRef}/${entry.id}/${example.path}` : null,
    readme: readmeHtml ? `/readmes/${entry.id}.html` : null,
    logo: fs.existsSync(logoSource) ? `/logos/${entry.id}.png` : null,
    readmeHtml,
  };
}));

for (const entry of roster.languages) {
  if (!(entry.id in languageYears)) {
    throw new Error(`${entry.id}: missing first-appeared year in _shared/site/language-years.json`);
  }
}

fs.mkdirSync(output, { recursive: true });
for (const filename of ["index.html", "app.js", "styles.css", "hero-mark.png", "mark-icon.png"]) {
  fs.copyFileSync(path.join(source, filename), path.join(output, filename));
}

const graveyardLogoOutput = path.join(output, "graveyard-logos");
fs.rmSync(graveyardLogoOutput, { recursive: true, force: true });
fs.mkdirSync(graveyardLogoOutput, { recursive: true });
for (const logo of graveyardLogos) {
  fs.copyFileSync(
    path.join(source, "graveyard-logos", logo.asset),
    path.join(graveyardLogoOutput, logo.asset),
  );
}

// Content pages are static shells in src; build-time tokens let a page carry
// repository-owned markdown (the graveyard) without shipping it in data.json.
const graveyardHtml = await renderGraveyard();
for (const page of ["graveyard", "faq", "numbers"]) {
  const pageSource = fs.readFileSync(path.join(source, `${page}.html`), "utf8");
  const pageOutput = path.join(output, page);
  fs.mkdirSync(pageOutput, { recursive: true });
  fs.writeFileSync(
    path.join(pageOutput, "index.html"),
    pageSource.replace("<!-- BUILD:GRAVEYARD -->", () => graveyardHtml),
  );
}

// Logos live with their language implementations, which keeps ownership and
// attribution obvious. Project them into the static site just like examples.
const logoOutput = path.join(output, "logos");
fs.rmSync(logoOutput, { recursive: true, force: true });
fs.mkdirSync(logoOutput, { recursive: true });
for (const language of languages) {
  if (!language.logo) continue;
  fs.copyFileSync(
    path.join(root, language.id, "logo.png"),
    path.join(logoOutput, `${language.id}.png`),
  );
}
// README fragments are fetched lazily by the dialog; shipping them inside
// data.json would multiply the initial payload by the size of 100 READMEs.
const readmeOutput = path.join(output, "readmes");
fs.rmSync(readmeOutput, { recursive: true, force: true });
fs.mkdirSync(readmeOutput, { recursive: true });
for (const language of languages) {
  if (language.readmeHtml) {
    fs.writeFileSync(path.join(readmeOutput, `${language.id}.html`), language.readmeHtml);
  }
  delete language.readmeHtml;
}

fs.writeFileSync(
  path.join(output, "data.json"),
  `${JSON.stringify(
    {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      evidenceChannel,
      repoUrl: repoWebUrl,
      languages,
    },
    null,
    2,
  )}\n`,
);

console.log(`PASS generated static evidence site for ${languages.length} languages`);
