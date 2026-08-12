const response = await fetch("/data.json");
const data = await response.json();

const grid = document.querySelector("#language-grid");
const template = document.querySelector("#language-card-template");
const search = document.querySelector("#search");
const sortOrder = document.querySelector("#sort-order");
const panel = document.querySelector("#language-panel");
const panelContent = document.querySelector("#panel-content");
const capabilityDialog = document.querySelector("#capability-dialog");
const capabilityContent = document.querySelector("#capability-content");

// These descriptions are deliberately tied to the shared conformance contract.
// A badge explains what the test suite proved, not what the implementation hopes
// to support later.
const capabilityDefinitions = {
  http: {
    label: "HTTP",
    summary:
      "The client can call Convex queries, mutations and actions through the documented HTTP API.",
    requirements: [
      "Round-trips JSON-safe values and document IDs.",
      "Forwards, replaces and clears bearer tokens.",
      "Preserves structured Convex errors and keeps function logs separate from results.",
    ],
    cumulative: "This is the foundation required by every higher capability.",
  },
  live: {
    label: "Live",
    summary:
      "The client also maintains reactive query subscriptions over a WebSocket connection.",
    requirements: [
      "Receives initial and later query results without polling.",
      "Unsubscribes without ghost updates.",
      "Reconnects active subscriptions after an interrupted connection.",
      "Recovers from query errors and closes cleanly.",
    ],
    cumulative: "Live includes every HTTP requirement.",
  },
};

function capabilities(language) {
  return language.result?.earnedCapabilities ?? [];
}

function status(language) {
  if (capabilities(language).length > 0) return "working";
  if (["failed", "blocked"].includes(language.implementation.status)) return "failed";
  return language.implementation.status;
}

function logoElement(language) {
  if (language.logo) {
    const image = document.createElement("img");
    image.src = language.logo;
    image.alt = "";
    image.loading = "lazy";
    return image;
  }
  const monogram = document.createElement("span");
  monogram.className = "monogram";
  monogram.textContent = language.displayName.replace(/[^A-Za-z0-9+#]/g, "").slice(0, 2);
  return monogram;
}

function badge(name) {
  const definition = capabilityDefinitions[name];
  const button = document.createElement("button");
  button.type = "button";
  button.className = `badge ${name}`;
  button.textContent = definition?.label ?? name;
  button.dataset.capability = name;
  button.setAttribute("aria-haspopup", "dialog");
  button.title = definition ? `${definition.label}: ${definition.summary}` : name;
  button.addEventListener("click", () => showCapability(name));
  return button;
}

function showCapability(name) {
  const definition = capabilityDefinitions[name];
  if (!definition) return;

  capabilityContent.replaceChildren();
  const title = document.createElement("h2");
  title.id = "capability-title";
  title.textContent = definition.label;
  const summary = document.createElement("p");
  summary.className = "capability-summary";
  summary.textContent = definition.summary;
  const heading = document.createElement("h3");
  heading.textContent = "What it proves";
  const requirements = document.createElement("ul");
  requirements.className = "capability-requirements";
  for (const requirement of definition.requirements) {
    const item = document.createElement("li");
    item.textContent = requirement;
    requirements.append(item);
  }
  const cumulative = document.createElement("p");
  cumulative.className = "capability-cumulative";
  cumulative.textContent = definition.cumulative;

  capabilityContent.append(title, summary, heading, requirements, cumulative);
  capabilityDialog.dataset.capability = name;
  capabilityDialog.showModal();
}

function sortedLanguages() {
  const languages = [...data.languages];
  const byYear = (language) => language.firstAppeared ?? Number.MAX_SAFE_INTEGER;
  if (sortOrder.value === "popularity") {
    languages.sort((a, b) => a.rank - b.rank);
  } else if (sortOrder.value === "oldest") {
    languages.sort((a, b) => byYear(a) - byYear(b) || a.rank - b.rank);
  } else if (sortOrder.value === "newest") {
    languages.sort(
      (a, b) => (b.firstAppeared ?? 0) - (a.firstAppeared ?? 0) || a.rank - b.rank,
    );
  }
  return languages;
}

function render() {
  const term = search.value.trim().toLowerCase();
  grid.replaceChildren();

  for (const language of sortedLanguages()) {
    const languageStatus = status(language);
    if (term && !`${language.displayName} ${language.id}`.toLowerCase().includes(term)) {
      continue;
    }
    const card = template.content.firstElementChild.cloneNode(true);
    card.dataset.status = languageStatus;
    card.querySelector(".logo").append(logoElement(language));
    card.querySelector(".rank").textContent = language.firstAppeared
      ? `#${language.rank} · ${language.firstAppeared}`
      : `#${language.rank}`;
    card.querySelector(".name").textContent = language.displayName;
    // Text status is reserved for the noteworthy states; working is the norm
    // and the badges carry the proof.
    card.querySelector(".state").textContent = ["failed", "planned", "blocked"].includes(
      languageStatus,
    )
      ? languageStatus
      : "";
    const badges = card.querySelector(".badges");
    for (const capability of capabilities(language)) badges.append(badge(capability));
    const openButton = card.querySelector(".language-card-open");
    openButton.setAttribute("aria-label", `Open ${language.displayName} details`);
    openButton.addEventListener("click", () => openLanguage(language));
    grid.append(card);
  }
}

function languagePath(language) {
  return `/languages/${encodeURIComponent(language.id)}`;
}

function routedLanguage() {
  const match = window.location.pathname.match(/^\/languages\/([^/]+)\/?$/);
  if (!match) return null;
  let id;
  try {
    id = decodeURIComponent(match[1]);
  } catch {
    return null;
  }
  return data.languages.find((language) => language.id === id) ?? null;
}

function openLanguage(language, { updateHistory = true } = {}) {
  if (updateHistory && window.location.pathname !== languagePath(language)) {
    window.history.pushState({ languageId: language.id }, "", languagePath(language));
  }
  showLanguage(language);
}

function closeLanguage({ updateHistory = true } = {}) {
  document.body.classList.remove("panel-open");
  openedLanguageId = null;
  if (updateHistory && routedLanguage()) {
    window.history.pushState({}, "", "/");
  }
  document.title = "The Convex 100 Language Challenge";
}

function syncLanguageRoute() {
  const language = routedLanguage();
  if (language) {
    openLanguage(language, { updateHistory: false });
    return;
  }
  closeLanguage({ updateHistory: false });
}

function addDetailList(parent, entries) {
  const list = document.createElement("dl");
  for (const [label, value] of entries) {
    const term = document.createElement("dt");
    term.textContent = label;
    const detail = document.createElement("dd");
    detail.textContent = value ?? "Not yet verified";
    list.append(term, detail);
  }
  parent.append(list);
}

function testList(tests) {
  const list = document.createElement("ul");
  list.className = "test-list";
  for (const test of tests) {
    const item = document.createElement("li");
    item.dataset.status = test.status;
    item.textContent = `${test.status.toUpperCase()}  ${test.name}  ${test.durationMs} ms`;
    list.append(item);
  }
  return list;
}

function evidenceColumn(title, result) {
  const column = document.createElement("div");
  column.className = "evidence-column";
  const heading = document.createElement("h4");
  heading.textContent = title;
  const verdict = document.createElement("p");
  verdict.className = "evidence-verdict";
  if (result?.tests) {
    const passed = result.tests.filter((test) => test.status === "pass").length;
    verdict.textContent = `${passed} of ${result.tests.length} checks passed`;
    column.append(heading, verdict, testList(result.tests));
  } else if (result?.earnedCapabilities?.length > 0) {
    verdict.textContent = `Earned: ${result.earnedCapabilities.join(", ")}`;
    column.append(heading, verdict);
  } else {
    verdict.textContent = "No published evidence yet.";
    column.append(heading, verdict);
  }
  return column;
}

function copyButton(text) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-button";
  button.textContent = "Copy";
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
      setTimeout(() => {
        button.textContent = "Copy";
      }, 1500);
    } catch {
      button.textContent = "Copy failed";
    }
  });
  return button;
}

function tryItBlock(language) {
  const block = document.createElement("div");
  block.className = "try-it";
  const heading = document.createElement("h3");
  heading.textContent = "Try it yourself";
  const explanation = document.createElement("p");
  explanation.textContent =
    "Docker is the only prerequisite. This builds the pinned toolchain and runs the canonical example against a real backend:";
  const commands = [
    "git clone https://github.com/mikecann/100-convex-clients",
    "cd 100-convex-clients",
    `./run verify-example ${language.id}`,
  ].join("\n");
  const pre = document.createElement("pre");
  pre.className = "try-commands";
  const code = document.createElement("code");
  code.textContent = commands;
  pre.append(code);
  const actions = document.createElement("p");
  actions.className = "try-actions";
  actions.append(copyButton(commands));
  block.append(heading, explanation, pre, actions);
  return block;
}

const readmeCache = new Map();
let openedLanguageId = null;

async function loadReadme(language, container) {
  if (!readmeCache.has(language.id)) {
    readmeCache.set(
      language.id,
      fetch(language.readme).then((readmeResponse) => {
        if (!readmeResponse.ok) throw new Error(`readme ${readmeResponse.status}`);
        return readmeResponse.text();
      }),
    );
  }
  try {
    const html = await readmeCache.get(language.id);
    if (openedLanguageId !== language.id) return;
    // Repository-owned markdown rendered by the site generator, not user input.
    container.innerHTML = html;
  } catch {
    readmeCache.delete(language.id);
    if (openedLanguageId !== language.id) return;
    const fallback = document.createElement("p");
    fallback.textContent = "The README could not be loaded.";
    const link = document.createElement("a");
    link.href = `${language.sourceUrl}#readme`;
    link.textContent = "Read it on GitHub instead.";
    fallback.append(" ", link);
    container.replaceChildren(fallback);
  }
}

function showLanguage(language) {
  openedLanguageId = language.id;
  panelContent.replaceChildren();

  const titleRow = document.createElement("div");
  titleRow.className = "dialog-title";
  const titleLogo = document.createElement("span");
  titleLogo.className = "logo";
  titleLogo.setAttribute("aria-hidden", "true");
  titleLogo.append(logoElement(language));
  const title = document.createElement("h2");
  title.textContent = language.displayName;
  titleRow.append(titleLogo, title);

  const intro = document.createElement("p");
  const introParts = [`Popularity #${language.rank}`];
  if (language.firstAppeared) introParts.push(`first appeared ${language.firstAppeared}`);
  intro.textContent = `${introParts.join(" · ")}.`;
  panelContent.append(titleRow, intro);

  const badgeRow = document.createElement("div");
  badgeRow.className = "dialog-badges";
  for (const capability of capabilities(language)) badgeRow.append(badge(capability));
  panelContent.append(badgeRow);

  const links = document.createElement("p");
  links.className = "dialog-links";
  const sourceLink = document.createElement("a");
  sourceLink.href = language.sourceUrl;
  sourceLink.textContent = language.result?.sourceCommit
    ? `Source on GitHub @ ${language.result.sourceCommit.slice(0, 12)}`
    : "Source on GitHub";
  links.append(sourceLink);
  if (language.exampleUrl) {
    const exampleLink = document.createElement("a");
    exampleLink.href = language.exampleUrl;
    exampleLink.textContent = "Canonical example";
    links.append(exampleLink);
  }
  if (language.wikipediaUrl) {
    const wikipediaLink = document.createElement("a");
    wikipediaLink.href = language.wikipediaUrl;
    wikipediaLink.textContent = "Wikipedia";
    links.append(wikipediaLink);
  }
  panelContent.append(links);

  panelContent.append(tryItBlock(language));

  if (language.readme) {
    const aboutHeading = document.createElement("h3");
    aboutHeading.textContent = `About ${language.displayName}`;
    const readmeContainer = document.createElement("div");
    readmeContainer.className = "rendered-markdown";
    const loading = document.createElement("p");
    loading.className = "readme-loading";
    loading.textContent = "Loading README…";
    readmeContainer.append(loading);
    panelContent.append(aboutHeading, readmeContainer);
    loadReadme(language, readmeContainer);
  }

  if (language.example) {
    const heading = document.createElement("h3");
    heading.textContent = language.example.path;
    const highlighted = document.createElement("div");
    highlighted.className = "example-code";

    // highlightedHtml is generated from repository-owned source by Shiki. Keep
    // a text-only fallback so an older result file still renders safely.
    if (language.example.highlightedHtml) {
      highlighted.innerHTML = language.example.highlightedHtml;
    } else {
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = language.example.code;
      pre.append(code);
      highlighted.append(pre);
    }
    panelContent.append(heading, highlighted);
  }

  const evidenceHeading = document.createElement("h3");
  evidenceHeading.textContent = "The evidence";
  panelContent.append(evidenceHeading);

  addDetailList(panelContent, [
    ["Evidence channel", language.evidenceTrust],
    ["Source commit", language.result?.sourceCommit],
    ["Source dirty", language.result ? String(language.result.dirty) : null],
    ["Provenance", language.implementation.provenance],
    ["Toolchain", language.toolchain ? `${language.toolchain.name} ${language.toolchain.version}` : null],
    ["Platform", language.result?.platform],
    ["Image digest", language.result?.imageDigest],
    ["Protocol", language.result?.protocol],
    ["Verified", language.result?.finishedAt],
  ]);

  // Every badge is earned twice: once against a local backend and once against
  // a real hosted deployment. Show both runs side by side.
  const columns = document.createElement("div");
  columns.className = "evidence-columns";
  columns.append(evidenceColumn("Conformance run", language.result));
  columns.append(evidenceColumn("Hosted deployment", language.hostedResult));
  panelContent.append(columns);

  document.title = `${language.displayName} · The Convex 100 Language Challenge`;
  document.body.classList.add("panel-open");
  panel.scrollTop = 0;
}

search.addEventListener("input", render);
sortOrder.addEventListener("change", render);
document.querySelector("#panel-close").addEventListener("click", () => closeLanguage());
document.addEventListener("keydown", (event) => {
  if (
    event.key === "Escape" &&
    document.body.classList.contains("panel-open") &&
    !capabilityDialog.open
  ) {
    closeLanguage();
  }
});

// The nav chrome stays invisible while the hero title is on screen; once the
// title scrolls away, the bar fades in to carry the brand.
const heroTitle = document.querySelector(".masthead h1");
if (heroTitle) {
  new IntersectionObserver(
    ([entry]) => {
      document.body.classList.toggle("nav-solid", !entry.isIntersecting);
    },
    { rootMargin: "-64px 0px 0px 0px" },
  ).observe(heroTitle);
}
document.querySelector("#capability-close").addEventListener("click", () => capabilityDialog.close());
const disclaimerDialog = document.querySelector("#disclaimer-dialog");
document.querySelector("#disclaimer-open").addEventListener("click", () => disclaimerDialog.showModal());
document.querySelector("#disclaimer-close").addEventListener("click", () => disclaimerDialog.close());
disclaimerDialog.addEventListener("click", (event) => {
  if (event.target === disclaimerDialog) disclaimerDialog.close();
});
for (const legendBadge of document.querySelectorAll(".legend [data-capability]")) {
  const name = legendBadge.dataset.capability;
  const definition = capabilityDefinitions[name];
  legendBadge.setAttribute("aria-haspopup", "dialog");
  legendBadge.title = `${definition.label}: ${definition.summary}`;
  legendBadge.addEventListener("click", () => showCapability(name));
}
capabilityDialog.addEventListener("click", (event) => {
  if (event.target === capabilityDialog) capabilityDialog.close();
});
// Tagline language names open their panel in place; the href stays a real
// deep link for new-tab clicks and no-JS visitors.
for (const link of document.querySelectorAll("[data-language-id]")) {
  link.addEventListener("click", (event) => {
    const language = data.languages.find(
      (candidate) => candidate.id === link.dataset.languageId,
    );
    if (!language) return;
    event.preventDefault();
    openLanguage(language);
  });
}
for (const button of document.querySelectorAll("[data-copy-target]")) {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copyTarget);
    try {
      await navigator.clipboard.writeText(source.textContent);
      button.textContent = "Copied";
      setTimeout(() => {
        button.textContent = "Copy";
      }, 1500);
    } catch {
      button.textContent = "Copy failed";
    }
  });
}

render();
window.addEventListener("popstate", syncLanguageRoute);
syncLanguageRoute();
