const response = await fetch("data.json");
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
  hardened: {
    label: "Hardened",
    summary:
      "The realtime client passes the stricter correctness and failure tests expected for serious production use.",
    requirements: [
      "Applies realtime transitions atomically and never regresses to older state.",
      "Orders mutations and reconnects an interrupted mutation with one database effect.",
      "Does not replay an uncertain in-flight action.",
      "Supports the full pinned Convex value profile and protected subscription auth rotation.",
      "Survives lifecycle, churn, large-transition and repeated fault tests.",
    ],
    cumulative: "Hardened includes every HTTP and Live requirement.",
  },
};

document.querySelector("#language-count").textContent = data.languages.length;
document.querySelector("#working-count").textContent = data.languages.filter(
  (language) => language.result?.earnedCapabilities?.length > 0,
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
    card.querySelector(".rank").textContent = `#${language.rank}`;
    card.querySelector(".name").textContent = language.displayName;
    card.querySelector(".state").textContent = languageStatus;
    const badges = card.querySelector(".badges");
    for (const capability of capabilities(language)) badges.append(badge(capability));
    const openButton = card.querySelector(".language-card-open");
    openButton.setAttribute("aria-label", `Open ${language.displayName} details`);
    openButton.addEventListener("click", () => showLanguage(language));
    grid.append(card);
  }
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
  const title = document.createElement("h2");
  title.textContent = language.displayName;
  const intro = document.createElement("p");
  intro.textContent = `Roster rank ${language.rank}. Implementation status: ${status(language)}.`;
  dialogContent.append(title, intro);

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

  if (language.example) {
    const heading = document.createElement("h3");
    heading.textContent = language.example.path;
    const pre = document.createElement("pre");
    const code = document.createElement("code");
    code.textContent = language.example.code;
    pre.append(code);
    dialogContent.append(heading, pre);
  }

  dialog.showModal();
}

search.addEventListener("input", render);
statusFilter.addEventListener("change", render);
document.querySelector("#dialog-close").addEventListener("click", () => dialog.close());
document.querySelector("#capability-close").addEventListener("click", () => capabilityDialog.close());
for (const legendBadge of document.querySelectorAll(".legend [data-capability]")) {
  const name = legendBadge.dataset.capability;
  const definition = capabilityDefinitions[name];
  legendBadge.setAttribute("aria-haspopup", "dialog");
  legendBadge.title = `${definition.label}: ${definition.summary}`;
  legendBadge.addEventListener("click", () => showCapability(name));
}
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) dialog.close();
});
capabilityDialog.addEventListener("click", (event) => {
  if (event.target === capabilityDialog) capabilityDialog.close();
});

render();
