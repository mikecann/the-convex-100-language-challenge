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

The current roster records three broad selection tiers:

- `ranked`: positions 1 to 56, supported by multiple sources or a strong position in a broad ranking.
- `coverage`: positions 57 to 79, primarily broadening TIOBE and RedMonk coverage.
- `curated_backfill`: positions 80 to 100, deliberately adding active and historically important languages after eligibility filtering.

Exact adjacent positions are weak after roughly 30. After 56, coverage is more meaningful than rank.

## Feasibility is a separate axis

Popularity never changes because a language is difficult to containerize. Each roster entry contains a preliminary desk audit for Docker, outbound HTTPS, JSON, and WebSockets:

- `G`: a practical open or accessible route appears to exist.
- `A`: possible only with licensing, FFI, transpilation, a host runtime, external tools, or immature libraries.
- `R`: no practical clean Linux-container route was found.

These letters are research hypotheses, not earned capabilities. Only a pinned container build and the shared conformance suite can replace them with evidence.

The initial audit identifies likely genuine blockers including ABAP, SAS, LabVIEW, Solidity networking, Apex, X++, ActionScript on Linux, Visual FoxPro, XBase++, and `bc`. The project will preserve those failures. If the eventual objective requires 100 working implementations, a separate feasible implementation roster can transparently backfill them without rewriting the popularity research.

## Source limitations

- GitHub measures contributors and primary repository languages, and publishes only a top 10.
- Stack Overflow is a self-selected, multi-select survey and includes markup technologies.
- RedMonk correlates GitHub pull requests with Stack Overflow tags; it does not claim general usage.
- IEEE combines several proxies using editorially chosen weights.
- JetBrains is a weighted survey but still has product-user bias.
- PYPL measures English Google searches for language tutorials, which is learning interest rather than deployed software.
- TIOBE measures web and search presence. Only its first 50 entries are ordered.

Popularity, feasibility, achieved capability, and implementation provenance must remain separate in every report and website view.
