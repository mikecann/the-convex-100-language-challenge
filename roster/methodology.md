# Language roster methodology

There is no objective, fully ordered list of the 100 most popular programming languages.

The only current source exposing 100 entries is TIOBE. It ranks positions 1 to 50, then explicitly publishes positions 51 to 100 alphabetically because the differences are too small. GitHub publishes a top 10, and the other useful sources cover different populations and smaller sets.

This project therefore uses a sourced composite roster. It is an implementation priority list, not a claim that adjacent positions are statistically distinct.

## Frozen source snapshot

The initial roster freezes sources as retrieved on 5 August 2026:

- [GitHub Octoverse 2025](https://github.blog/news-insights/octoverse/octoverse-a-new-developer-joins-github-every-second-as-ai-leads-typescript-to-1/)
- [Stack Overflow 2025 technology results](https://survey.stackoverflow.co/2025/technology) and [official raw CSV](https://github.com/StackExchange/Survey/raw/refs/heads/main/packages/archive/2025/results.csv)
- [RedMonk January 2026](https://redmonk.com/sogrady/2026/04/14/language-rankings-1-26/)
- [IEEE Spectrum 2025](https://spectrum.ieee.org/top-programming-languages-2025) and [methodology](https://spectrum.ieee.org/top-programming-languages-methodology-2025)
- [JetBrains 2025](https://devecosystem-2025.jetbrains.com/tools-and-trends) and [language CSV](https://devecosystem-2025.jetbrains.com/_data/pl_dynamics_large.csv)
- [TIOBE July 2026](https://www.tiobe.com/tiobe-index/) and [methodology](https://www.tiobe.com/tiobe-index/programminglanguages_definition/)
- [PYPL](https://pypl.github.io/PYPL.html)

Runtime coverage was sanity-checked against [Judge0](https://ce.judge0.com/docs) and [Piston](https://github.com/engineer-man/piston). Those systems prove that a runtime can be containerized; they do not prove that a useful Convex library can be built in it.

## Normalization

- Normalize aliases before scoring.
- Exclude markup and style languages such as HTML and CSS.
- Exclude query and database languages such as SQL, PL/SQL, Transact-SQL, MDX, and SQR.
- Exclude configuration and build languages such as HCL.
- Exclude hardware and PLC languages such as VHDL, Verilog, Ladder Logic, and Structured Text.
- Exclude runtime versions and duplicate aliases that are not meaningfully different source languages.
- Pin ambiguous entries. For example, Assembly means x86-64 NASM for the initial attempt.

## Composite score

The research ranking uses weighted reciprocal-rank fusion:

```text
score(language) = sum(sourceWeight / (20 + sourceRank))
```

Weights:

| Source | Weight |
| --- | ---: |
| GitHub Octoverse | 1.25 |
| Stack Overflow | 1.0 |
| RedMonk | 1.0 |
| IEEE Spectrum | 1.0 |
| JetBrains | 1.0 |
| TIOBE | 0.75 |
| PYPL | 0.5 |

TIOBE's unordered 51 to 100 group is assigned a tied rank of 75.5. An unlisted language contributes zero from that source.

The frozen research ranking records three broad selection tiers:

- `ranked`: positions 1 to 56, supported by multiple sources or a strong position in a broad ranking.
- `coverage`: positions 57 to 79, primarily broadening TIOBE and RedMonk coverage.
- `curated_backfill`: positions 80 to 100, deliberately adding active and historically important languages after eligibility filtering.

Exact adjacent positions are weak after roughly 30. After 56, coverage is more meaningful than rank.

## Current site popularity order

The implementation-slot number above is intentionally frozen, so it cannot be shown as a popularity claim after a failed language is replaced. The website instead reads a separate, reproducible ranking from [`popularity.yaml`](popularity.yaml) for the 100 languages that are actually active.

That order fuses two signals with equal weight:

- [PLDB 12.0.0](https://github.com/breck7/pldb), published 3 December 2024, supplies complete coverage. Its ranking combines estimated users, jobs, downstream language foundations, influence, and measurement coverage.
- [GitHub Innovation Graph 2026 Q1](https://github.com/github/innovationgraph/blob/054c7dbc527518fa2ecfd316efe2aa01f3986c39/data/languages.csv), released 7 July 2026, supplies the current-activity signal. For each language, the project sums unique pushers across economies, then ranks the active roster by that total.

Each source is first ranked only within the active 100, then combined with reciprocal-rank fusion:

```text
popularityScore(language) = 1 / (20 + pldbRosterRank)
                          + 1 / (20 + githubRosterRank)
```

GitHub reports 76 of the active languages in the 2026 Q1 dataset. A language with no reported GitHub activity is tied below the observed set at rank 101 rather than treated as having literally zero users. The final 1 to 100 order sorts by the fused score, with PLDB's global rank as the deterministic tie-breaker.

This is a useful relative ordering, not a claim of precise market share. GitHub covers public activity and suppresses small economy-level observations; PLDB gives the obscure tail coverage that contemporary surveys lack, but its reproducible published snapshot is older. Exact neighbouring positions near the bottom should be read as roughly comparable niche languages.

## Feasibility is a separate axis

Popularity never changes because a language is difficult to containerize. Each roster entry contains a preliminary desk audit for Docker, outbound HTTPS, JSON, and WebSockets:

- `G`: a practical open or accessible route appears to exist.
- `A`: possible only with licensing, FFI, transpilation, a host runtime, external tools, or immature libraries.
- `R`: no practical clean Linux-container route was found.

These letters are research hypotheses, not earned capabilities. Only a pinned container build and the shared conformance suite can replace them with evidence.

The initial audit identifies likely genuine blockers including ABAP, SAS, LabVIEW, Solidity networking, Apex, X++, ActionScript on Linux, Visual FoxPro, XBase++, and `bc`. The project preserves failed attempts and their evidence rather than deleting them.

## Feasible implementation backfills

The active 100-language implementation roster follows the frozen ranking until a language cannot pass on the project's only verification host. A backfill keeps the original rank as an implementation slot, not as a new popularity claim. The replaced directory and its failure evidence remain in the repository.

On 11 August 2026, the project made these explicit host-compatibility backfills:

| Implementation slot | Preserved attempt | Active replacement | Reason |
| ---: | --- | --- | --- |
| 35 | MUMPS | Fennel | The YottaDB hostname transport failed intermittently under the current amd64-on-Apple-Silicon environment. |
| 45 | SETL | C3 | The GNU SETL VM exceeded the shared 128 MiB runtime limit even for a trivial pretranslated program. |
| 52 | Modula-3 | LOLCODE | The CM3 toolchain could not complete reliably on the current verification host. |

Fennel, C3, and LOLCODE therefore inherit those implementation slots and selection tiers solely to keep a stable 100-entry roster. Their inclusion does not revise the frozen source rankings above.

## Source limitations

- GitHub measures contributors and primary repository languages, and publishes only a top 10.
- Stack Overflow is a self-selected, multi-select survey and includes markup technologies.
- RedMonk correlates GitHub pull requests with Stack Overflow tags; it does not claim general usage.
- IEEE combines several proxies using editorially chosen weights.
- JetBrains is a weighted survey but still has product-user bias.
- PYPL measures English Google searches for language tutorials, which is learning interest rather than deployed software.
- TIOBE measures web and search presence. Only its first 50 entries are ordered.

Popularity, feasibility, achieved capability, and implementation provenance must remain separate in every report and website view.
