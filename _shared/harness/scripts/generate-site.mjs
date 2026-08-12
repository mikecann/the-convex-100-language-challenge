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

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function plainMarkdown(value) {
  return value
    .replaceAll("**", "")
    .replaceAll("`", "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .trim();
}

function markdownTableAfter(markdown, marker) {
  const markerOffset = markdown.indexOf(marker);
  if (markerOffset === -1) throw new Error(`STATS.md: missing ${marker}`);
  const tableOffset = markdown.indexOf("\n|", markerOffset);
  if (tableOffset === -1) throw new Error(`STATS.md: missing table after ${marker}`);
  const lines = markdown.slice(tableOffset + 1).split("\n");
  const tableLines = [];
  for (const line of lines) {
    if (!line.startsWith("|")) break;
    tableLines.push(line);
  }
  const rows = tableLines.map((line) =>
    line.slice(1, -1).split("|").map((cell) => cell.trim()),
  );
  if (rows.length < 3) throw new Error(`STATS.md: incomplete table after ${marker}`);
  return rows.slice(2);
}

function numberFrom(value) {
  const parsed = Number.parseFloat(plainMarkdown(value).replace(/[^0-9.]/g, ""));
  if (!Number.isFinite(parsed)) throw new Error(`STATS.md: cannot parse number from ${value}`);
  return parsed;
}

function statByPrefix(rows, prefix) {
  const row = rows.find(([label]) => plainMarkdown(label).startsWith(prefix));
  if (!row) throw new Error(`STATS.md: missing statistic ${prefix}`);
  return plainMarkdown(row[1]);
}

function horizontalRows(rows, maximum, valueIndex = 1) {
  return rows.map((row) => {
    const label = plainMarkdown(row[0]);
    const value = numberFrom(row[valueIndex]);
    const width = (value / maximum) * 100;
    return `<li><div class="chart-row-label"><span>${escapeHtml(label)}</span><strong>${escapeHtml(plainMarkdown(row[valueIndex]))}</strong></div><div class="chart-track"><span style="--bar-width:${width.toFixed(3)}%"></span></div></li>`;
  }).join("");
}

async function renderNumbers() {
  const statsMarkdown = fs.readFileSync(path.join(root, "STATS.md"), "utf8");
  const headline = markdownTableAfter(statsMarkdown, "## Headline numbers");
  const rosterProgress = markdownTableAfter(statsMarkdown, "## The roster");
  const replacementReasons = markdownTableAfter(statsMarkdown, "## Why 25 slots were replaced");
  const providers = markdownTableAfter(statsMarkdown, "### By provider").filter(
    ([provider]) => !plainMarkdown(provider).startsWith("All providers"),
  );
  const naiveCosts = markdownTableAfter(statsMarkdown, "### 1. If every token were billed as fresh input");
  const cacheCosts = markdownTableAfter(statsMarkdown, "### 2. Cache-aware, at the same list prices");
  const actualCosts = markdownTableAfter(statsMarkdown, "### 3. What was actually paid");
  const integrity = markdownTableAfter(statsMarkdown, "## The integrity finding");
  const defectClasses = markdownTableAfter(statsMarkdown, "## Recurring defect classes");
  const recorded = statsMarkdown.match(/last recomputed on ([0-9-]+) at commit\n`([^`]+)`/);
  if (!recorded) throw new Error("STATS.md: missing recomputation date and commit");

  const verified = statByPrefix(headline, "Rostered languages verified");
  const totalTokens = statByPrefix(headline, "Total tokens moved").replace(" billion", "B");
  const cacheShare = statByPrefix(headline, "Share of those tokens");
  const sourceLines = statByPrefix(headline, "Client and example source lines");
  const replacements = statByPrefix(headline, "Slot replacements");
  const paid = statByPrefix(headline, "Actually paid");
  const latestVerified = numberFrom(rosterProgress.at(-1)[1]);
  if (latestVerified !== numberFrom(verified)) {
    throw new Error("STATS.md: latest roster count does not match the headline verified count");
  }
  const replacementTotal = replacementReasons.reduce(
    (sum, row) => sum + numberFrom(row[1]),
    0,
  );
  if (replacementTotal !== numberFrom(replacements)) {
    throw new Error("STATS.md: replacement causes do not add up to the headline total");
  }
  const providerTokens = providers.map((row) => numberFrom(row[1]));
  const providerTotal = providerTokens.reduce((sum, value) => sum + value, 0);
  const providerNames = ["Claude", "Codex", "Grok"];
  const providerSegments = providers.map((row, index) => {
    const percentage = (providerTokens[index] / providerTotal) * 100;
    return `<span class="token-segment token-segment-${index + 1}" style="--segment-width:${percentage.toFixed(3)}%" title="${providerNames[index]}: ${percentage.toFixed(1)}%"></span>`;
  }).join("");
  const providerLegend = providers.map((row, index) => {
    const percentage = (providerTokens[index] / providerTotal) * 100;
    return `<li><span class="chart-key token-segment-${index + 1}"></span><span>${providerNames[index]}</span><strong>${percentage.toFixed(1)}%</strong><small>${escapeHtml(plainMarkdown(row[1]))} tokens</small></li>`;
  }).join("");

  const progressBars = rosterProgress.map(([date, value, event]) => {
    const verifiedCount = numberFrom(value);
    return `<li><strong>${verifiedCount}</strong><div class="roster-bar"><span style="--bar-height:${verifiedCount}%"></span></div><span>${escapeHtml(plainMarkdown(date))}</span><small>${escapeHtml(plainMarkdown(event))}</small></li>`;
  }).join("");

  const replacementMaximum = Math.max(...replacementReasons.map((row) => numberFrom(row[1])));
  const defectMaximum = Math.max(...defectClasses.map((row) => numberFrom(row[1])));
  const naiveTotal = numberFrom(naiveCosts.at(-1)[1]);
  const cacheTotal = numberFrom(cacheCosts.at(-1)[1]);
  const actualTotal = numberFrom(actualCosts.at(-1)[1]);
  if (actualTotal !== numberFrom(paid)) {
    throw new Error("STATS.md: actual-cost table does not match the headline amount paid");
  }
  const costRows = [
    ["Actually paid", actualTotal, paid],
    ["Cache-aware list price", cacheTotal, "~$14,000"],
    ["Without caching", naiveTotal, "~$110,400"],
  ];
  const costChart = costRows.map(([label, value, display]) => {
    const width = (value / naiveTotal) * 100;
    return `<li><div class="chart-row-label"><span>${label}</span><strong>${display}</strong></div><div class="chart-track cost-track"><span style="--bar-width:${width.toFixed(3)}%"></span></div></li>`;
  }).join("");

  const leakedImages = statByPrefix(integrity, "Images actually leaking");
  const ledgerMarkdown = statsMarkdown.replace(/^# .+\n/m, "");
  const ledgerHtml = await renderMarkdown(ledgerMarkdown, { baseDirectory: ".", ref: "main" });

  return `
    <p class="stats-freshness">Source recomputed ${escapeHtml(recorded[1])} at commit <code>${escapeHtml(recorded[2])}</code>.</p>
    <section class="stats-headlines" aria-label="Headline project statistics">
      <div class="stat-callout"><strong>${escapeHtml(verified)}</strong><span>languages with both HTTP and Live verified</span></div>
      <div class="stat-callout"><strong>${escapeHtml(totalTokens)}</strong><span>deduplicated tokens moved across all providers</span></div>
      <div class="stat-callout"><strong>${escapeHtml(cacheShare)}</strong><span>of all tokens were cache reads</span></div>
      <div class="stat-callout"><strong>${escapeHtml(sourceLines)}</strong><span>lines of client, example and test source</span></div>
      <div class="stat-callout"><strong>${escapeHtml(replacements)}</strong><span>roster slots replaced with the evidence preserved</span></div>
      <div class="stat-callout"><strong>${escapeHtml(paid)}</strong><span>actually paid, versus roughly $14k at list API prices</span></div>
    </section>

    <div class="stats-chart-grid">
      <section class="stats-panel stats-panel-wide" aria-labelledby="roster-progress-title">
        <div class="stats-panel-heading"><h2 id="roster-progress-title">The final push</h2><p>Verified languages over five consecutive days in August 2026.</p></div>
        <ol class="roster-chart" role="img" aria-label="Verified languages rose from 57 on August 7 to 83, then 100, dipped to 97 after revalidation, and returned to 100 on August 11.">${progressBars}</ol>
      </section>

      <section class="stats-panel" aria-labelledby="provider-title">
        <div class="stats-panel-heading"><h2 id="provider-title">Tokens by provider</h2><p>Claude and Codex split almost the entire 32.13 billion-token workload.</p></div>
        <div class="token-stack" role="img" aria-label="Claude 52.1 percent, Codex 47.7 percent, Grok 0.1 percent">${providerSegments}</div>
        <ul class="token-legend">${providerLegend}</ul>
      </section>

      <section class="stats-panel" aria-labelledby="cost-title">
        <div class="stats-panel-heading"><h2 id="cost-title">What caching changed</h2><p>The same workload viewed three different ways. Bars share a linear $110,400 scale.</p></div>
        <ul class="horizontal-chart">${costChart}</ul>
        <p class="chart-note">The $472 actually paid is just 0.4% of the uncached list-price estimate.</p>
      </section>

      <section class="stats-panel" aria-labelledby="replacement-title">
        <div class="stats-panel-heading"><h2 id="replacement-title">Why slots were replaced</h2><p>Twenty-five replacements, grouped by the gate that failed.</p></div>
        <ul class="horizontal-chart compact-chart">${horizontalRows(replacementReasons, replacementMaximum)}</ul>
      </section>

      <section class="stats-panel" aria-labelledby="defect-title">
        <div class="stats-panel-heading"><h2 id="defect-title">Recurring defect classes</h2><p>The bugs that repeatedly consumed expensive verification cycles.</p></div>
        <ul class="horizontal-chart compact-chart defect-chart">${horizontalRows(defectClasses, defectMaximum)}</ul>
      </section>
    </div>

    <section class="integrity-callout" aria-labelledby="integrity-title">
      <div><strong>${escapeHtml(leakedImages)}</strong><span>runtime images were leaking forbidden tooling</span></div>
      <div><h2 id="integrity-title">The integrity finding</h2><p>Seventy-five merged images were audited. Eighteen were leaking because checks that looked strict could never fail. All eighteen were fixed, and the policy now inspects exported filesystems centrally.</p></div>
    </section>

    <details class="stats-ledger">
      <summary>Read the complete measured ledger</summary>
      <div class="rendered-markdown">${ledgerHtml}</div>
    </details>
  `;
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
const numbersHtml = await renderNumbers();
for (const page of ["graveyard", "faq", "numbers"]) {
  const pageSource = fs.readFileSync(path.join(source, `${page}.html`), "utf8");
  const pageOutput = path.join(output, page);
  fs.mkdirSync(pageOutput, { recursive: true });
  fs.writeFileSync(
    path.join(pageOutput, "index.html"),
    pageSource
      .replace("<!-- BUILD:GRAVEYARD -->", () => graveyardHtml)
      .replace("<!-- BUILD:NUMBERS -->", () => numbersHtml),
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
