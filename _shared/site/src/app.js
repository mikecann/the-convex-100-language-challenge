const response = await fetch("/data.json");
const data = await response.json();

const grid = document.querySelector("#language-grid");
const template = document.querySelector("#language-card-template");
const search = document.querySelector("#search");
const statusFilter = document.querySelector("#status-filter");
const dialog = document.querySelector("#language-dialog");
const dialogContent = document.querySelector("#dialog-content");
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

document.querySelector("#language-count").textContent = data.languages.length;
document.querySelector("#working-count").textContent = data.languages.filter(
  (language) => language.result?.earnedCapabilities?.length > 0,
).length;
document.querySelector("#live-count").textContent = data.languages.filter(
  (language) => language.result?.earnedCapabilities?.includes("live"),
).length;

if (data.evidenceChannel !== "trusted-main") {
  const notice = document.querySelector("#evidence-notice");
  notice.hidden = false;
  notice.textContent =
    "Local evidence preview. Passing badges shown here are candidates until trusted main CI publishes them.";
}

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

function render() {
  const term = search.value.trim().toLowerCase();
  const filter = statusFilter.value;
  grid.replaceChildren();

  for (const language of data.languages) {
    const languageStatus = status(language);
    if (term && !`${language.displayName} ${language.id}`.toLowerCase().includes(term)) {
      continue;
    }
    if (filter === "working" && languageStatus !== "working") continue;
    if (filter === "planned" && languageStatus !== "planned") continue;
    if (filter === "failed" && languageStatus !== "failed") continue;

    const card = template.content.firstElementChild.cloneNode(true);
    card.dataset.status = languageStatus;
    card.querySelector(".logo").append(logoElement(language));
    card.querySelector(".rank").textContent = `#${language.rank}`;
    card.querySelector(".name").textContent = language.displayName;
    card.querySelector(".state").textContent = languageStatus;
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
  if (dialog.open) dialog.close();
  if (updateHistory && routedLanguage()) {
    window.history.pushState({}, "", "/");
  }
  document.title = "100 Convex clients";
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

function showLanguage(language) {
  dialogContent.replaceChildren();
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
  intro.textContent = `Roster rank ${language.rank}. Implementation status: ${status(language)}.`;
  dialogContent.append(titleRow, intro);

  const badgeRow = document.createElement("div");
  badgeRow.className = "dialog-badges";
  for (const capability of capabilities(language)) badgeRow.append(badge(capability));
  dialogContent.append(badgeRow);

  addDetailList(dialogContent, [
    ["Evidence channel", language.evidenceTrust],
    ["Source commit", language.result?.sourceCommit],
    ["Source dirty", language.result ? String(language.result.dirty) : null],
    ["Provenance", language.implementation.provenance],
    ["Toolchain", language.toolchain ? `${language.toolchain.name} ${language.toolchain.version}` : null],
    ["Platform", language.result?.platform],
    ["Image digest", language.result?.imageDigest],
    ["Protocol", language.result?.protocol],
    ["Verified", language.result?.finishedAt],
    ["Hosted drift", language.hostedResult?.earnedCapabilities?.join(", ")],
  ]);

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
    dialogContent.append(heading, highlighted);
  }

  if (language.result?.tests) {
    const heading = document.createElement("h3");
    heading.textContent = "Conformance evidence";
    const tests = document.createElement("ul");
    tests.className = "test-list";
    for (const test of language.result.tests) {
      const item = document.createElement("li");
      item.dataset.status = test.status;
      item.textContent = `${test.status.toUpperCase()}  ${test.name}  ${test.durationMs} ms`;
      tests.append(item);
    }
    dialogContent.append(heading, tests);
  }

  document.title = `${language.displayName} · 100 Convex clients`;
  if (!dialog.open) dialog.showModal();
}

search.addEventListener("input", render);
statusFilter.addEventListener("change", render);
document.querySelector("#dialog-close").addEventListener("click", () => closeLanguage());
document.querySelector("#capability-close").addEventListener("click", () => capabilityDialog.close());
for (const legendBadge of document.querySelectorAll(".legend [data-capability]")) {
  const name = legendBadge.dataset.capability;
  const definition = capabilityDefinitions[name];
  legendBadge.setAttribute("aria-haspopup", "dialog");
  legendBadge.title = `${definition.label}: ${definition.summary}`;
  legendBadge.addEventListener("click", () => showCapability(name));
}
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) closeLanguage();
});
dialog.addEventListener("cancel", (event) => {
  event.preventDefault();
  closeLanguage();
});
capabilityDialog.addEventListener("click", (event) => {
  if (event.target === capabilityDialog) capabilityDialog.close();
});

render();
window.addEventListener("popstate", syncLanguageRoute);
syncLanguageRoute();
