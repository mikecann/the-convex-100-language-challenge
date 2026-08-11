# Project statistics

Measured, not estimated. Every figure here comes from the repository, the
session transcripts on disk, the Hetzner API, or a published price list. Where
a number is approximate, assumed, or has a caveat, it says so.

Recorded for the video. Companion to `LESSONS.md` (what was learned) and
`INFEASIBLE.md` (what could not be done, and why).

Repository-derived figures were last recomputed on 2026-08-11 at commit
`5cb61ce`. Token figures were recomputed the same day from the primary
transcripts on disk with a single methodology (see the correction note under
Tokens). The detailed per-session histories that earlier revisions carried are
preserved in git history.

## Headline numbers

| | |
| --- | ---: |
| Rostered languages verified with **both** `http` and `live` badges | **100** |
| Total tokens moved, all providers, deduplicated | **~32.13 billion** |
| Share of those tokens that were cache reads | 98.2% |
| Estimated cost at list API prices, cache-aware | ~$14,000 |
| Estimated cost at list API prices if caching did not exist | ~$110,000 |
| Actually paid | ~$472 |
| Client and example source lines, all language directories, tests included | 446,759 |
| Language directories in the repository | 104 |
| Slot replacements across the project | 25 |
| Peak build fleet | 5 Hetzner x86 servers, ~€41/day |

The 104 directories are the 100 rostered languages, the three preserved
attempts whose slots were backfilled late (MUMPS, SETL, Modula-3), and Hy,
an unrostered candidate that passed but never displaced a rostered entry.

Every badge on `main` comes from `./run verify-all` at an exact clean commit:
31 of 31 conformance checks against a local Convex backend **and** 31 of 31
against the real hosted deployment over TLS, with `dirty: false` on both. No
language carries a badge on partial evidence.

## The roster

How the verified count moved over the project's life:

| Date (2026) | Verified | Event |
| --- | ---: | --- |
| Aug 7 | 57 | Start of the first big push |
| Aug 8 | 83 | After the 24-hour session |
| Aug 9 | 100 | Roster complete |
| Aug 10 | 97 | Host-focused revalidation exposed 3 unreliable slots |
| Aug 11 | **100** | Fennel, C3 and LOLCODE backfilled and verified |

### Size of the clients

Counted 2026-08-11 over `client/` plus `examples/` per language. Two methods,
because test suites dominate some languages:

Largest, tests included: x86-64 assembly 11,347 · Ada 11,106 · COBOL 9,705 ·
Julia 8,407 · Idris 8,062.

Largest, tests excluded: x86-64 assembly 9,074 · Pony 6,140 · COBOL 5,679 ·
Idris 5,600 · Julia 4,644.

Two things worth noting. The assembly client is now the largest under either
method (an earlier version of this file listed Ada first, measured before the
assembly client merged). And Ada is the most test-heavy client in the project:
4,007 lines of client and example carrying 7,099 lines of tests, which is very
Ada of it.

Smallest rostered client: Bash, whose three shell files (`convex.sh`,
`live.sh`, and the example) total 592 lines, with the entire HTTP client in
one 82-line file. The largest clients are not the hardest languages, they are
the ones whose type systems or verbosity demanded the most text for the same
behaviour.

## Why 25 slots were replaced

22 infeasibility rulings plus 3 late host-reliability backfills. Grouped by
cause, which is more interesting than the count:

| Reason | Count | Examples |
| --- | ---: | --- |
| Proprietary or GUI-gated toolchain | 11 | LabVIEW, MATLAB, SAS, Scratch, X++ |
| No socket reachable from the language itself | 6 | bc, Solidity, ABAP, Elm, CFML, Futhark |
| No hermetic, non-interactive build possible | 1 | Unison |
| Blocked by container security policy | 1 | Pop-11 |
| Runtime footprint exceeds the container limit | 1 | Raku |
| At risk, superseded by replacements | 2 | ActionScript, Logo |
| Could not verify reliably on the Apple-Silicon host | 3 | MUMPS, SETL, Modula-3 |

Some rulings hit replacement candidates rather than original roster entries
(Unison, for example, was itself a candidate), and two of the host-reliability
backfills replaced languages that were themselves replacements: ABAP → MUMPS →
Fennel, and Oz → Modula-3 → LOLCODE. Every ruling is recorded with evidence in
`INFEASIBLE.md`, whose first rule is that nothing on that page is ever deleted.

Three failures deserve their own line, because nobody predicted them:

- **Unison** proved a real certificate-verified TLS handshake from its own
  source, then failed anyway: its standard library is reachable only through a
  build-time round trip to a hosted service.
- **Pop-11** cannot start inside Docker at all. Poplog's bootstrap calls
  `personality(ADDR_NO_RANDOMIZE)`, which the default seccomp profile refuses,
  producing a memory access violation rather than a permission error.
- **Raku** is the only entry ruled out on resources. After removing Cro, then
  Rakudo Star, then *every* external module, binding libssl through core
  NativeCall, the floor was still 145–170 MiB against a 128 MiB limit, with
  zero client code loaded.

The three host-reliability blockers, for the record: YottaDB's hostname
transport failed intermittently under amd64 emulation (MUMPS), the GNU SETL VM
used roughly 274 MiB for a trivial pretranslated program against the 128 MiB
limit (SETL), and the CM3 toolchain could not complete reliably on the
verification host (Modula-3). Fennel, C3 and LOLCODE each finished with the
exact canonical `0 → 1` example plus all 31 local and all 31 hosted checks,
earning both badges at clean commit `3932242`. Hy was implemented and
independently reviewed during the same work and remains an unrostered, passing
candidate.

## Tokens

**Correction, 2026-08-11.** Earlier revisions of this file attributed the two
big pushes to Codex and carried a ~53.6B all-provider total. Transcript
forensics showed three compounding errors: both pushes were actually Claude
sessions (the model is recorded on every transcript line), their totals
double-counted duplicated usage lines, and the genuinely-Codex era that built
the first 57 languages had never been counted at all. Every figure below is
recomputed from the primary transcripts with one methodology: Claude usage is
counted once per unique API message id; Codex usage attributes cumulative
token-counter deltas to the model and effort in force for each turn. All 344
project Codex rollouts and every project Claude session on disk were
processed, with zero unparseable files.

### By provider

| Provider | Tokens | Note |
| --- | ---: | --- |
| Anthropic (Claude) | 16,745,400,062 | The two big pushes, per-language worktree agents, pilot reviews |
| OpenAI (Codex, GPT-5.6 family) | 15,338,654,656 | The 0→57 build-out and the revalidation + README phases |
| xAI (Grok 4.5 via OpenRouter) | ~45,300,000 | Dashboard figure only; $21.80 actual spend |
| **All providers** | **~32,129,354,718** | Project-only variant: ~32.07B, excluding the video-script sessions (58.4M) |

One caveat survives: memory notes record some Claude agents running on two
other home machines (tinker-desk and bruce) during the pre-push era. Their
transcripts are not on this Mac and are absent from every total here.

### By model

| Provider | Model | Fresh input | Cache write | Cache read | Output | Total |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Claude | Sonnet 5 | 216,102 | 104,615,303 | 13,786,283,139 | 19,951,088 | **13,911,065,632** |
| Claude | Opus 5 | 148,016 | 40,796,672 | 2,380,822,935 | 14,241,013 | **2,436,008,636** |
| Claude | Fable 5 | 7,491 | 7,379,007 | 381,880,123 | 1,285,803 | **390,552,424** |
| Claude | Haiku 4.5 | 1,866 | 319,512 | 7,398,115 | 53,877 | **7,773,370** |
| Codex | GPT-5.6 Sol | 231,709,872 | 0 | 11,904,042,624 | 25,155,079 | **12,160,907,575** |
| Codex | GPT-5.6 Terra | 45,661,088 | 0 | 2,087,151,616 | 4,503,993 | **2,137,316,697** |
| Codex | GPT-5.6 Luna | 21,167,897 | 0 | 1,016,952,576 | 2,216,152 | **1,040,336,625** |
| Codex | auto-review | 23,453 | 0 | 69,888 | 418 | 93,759 |

The workhorse split is stark: Sonnet 5 subagents carried the two big pushes
(83% of all Claude tokens), and Sol carried the Codex eras (79% of all Codex
tokens). The premium models (Opus 5, Fable 5) were coordinators and reviewers,
not workers.

### By reasoning effort

Recorded for Codex only; Claude transcripts do not carry an effort field.

| Effort | Tokens |
| --- | ---: |
| medium (Sol 6,419,158,809 · Terra 982,112,125 · Luna 96,774,070) | 7,498,045,004 |
| high (Sol 2,829,680,542 · Terra 1,048,578,166 · Luna 940,060,990) | 4,818,319,698 |
| xhigh (Sol 2,912,068,224 · Terra 790,829) | 2,912,859,053 |
| low (Terra 103,359,707 · Luna 3,501,565) | 106,861,272 |
| ultra (Terra) | 2,475,870 |

The pre-push era used genuinely high reasoning (high and xhigh dominate it);
the later phases ran mostly at medium with cheap fixes at low.

### The work, session by session

Deduplicated totals, reconciled to the grand total:

| Work | Provider and models | When | Tokens |
| --- | --- | --- | ---: |
| 0 → 57 build-out, 193 rollouts | Codex: Sol-heavy, Luna's only real outing | Aug 5–6 | 12,402,208,626 |
| Per-language worktree agents | Claude: Opus 5 | Aug 6 | 1,610,273,930 |
| Pilot review sessions | Claude: Opus 5 / Fable 5 | Aug 5 | 9,952,173 |
| The 57 → 83 push, ~24.4 h | Claude: Sonnet 5 subagents, Opus 5 + Fable 5 coordinating | Aug 6–8 | 11,974,785,462 |
| Bridge session + the 83 → 100 push | Claude: same pattern | Aug 8–10 | 2,940,863,228 |
| Revalidation, backfills, READMEs, site | Codex: Sol / Terra | Aug 10–11 | 2,936,375,774 |
| Website design worktree | Claude | Aug 11 | 151,165,681 |
| Video-script sessions (not project work) | Claude | Aug 10–11 | 58,359,588 |

Observations that survived the recount, corrected where the duplication had
inflated them:

- **98.2% of all tokens were cache reads.** On the Claude side the fresh-input
  number is almost comical: 373,475 tokens read fresh across 16.7 billion
  moved, or 0.002%.
- **Subagents produce the work.** ~95% of the big push's tokens were Sonnet 5
  subagent traffic; the coordinator models routed and reviewed.
- **Roughly 0.6–0.7 million deduplicated output tokens per language merged**
  in the big push (an earlier revision said 1.3M; that figure was doubled by
  the duplicated-line bug).
- **Three session-limit mass-kills were survived with zero work lost**, using
  a sweep-commit-verify recovery drill written up in `LESSONS.md`.

## What it cost

Three answers, because they answer three different questions. List prices as
of August 2026: GPT-5.6 Sol $5 input / $30 output per million tokens, Terra
$2 / $12, Luna $0.20 / $1.20, cached input at 10% of the input rate; Claude
Opus 5 $5 / $25, Sonnet 5 $2 / $10 (introductory), Fable 5 $10 / $50, Haiku
4.5 $1 / $5, cache reads at 10% of input, cache writes at the standard 1.25×
input.

### 1. If every token were billed as fresh input

The scary number, and the wrong one:

| Provider | Naive cost |
| --- | ---: |
| Claude (Sonnet $27,982 · Opus $12,465 · Fable $3,957 · Haiku $8) | ~$44,400 |
| Codex (Sol $61,433 · Terra $4,320 · Luna $210) | ~$66,000 |
| Grok | $22 |
| **Total** | **~$110,400** |

### 2. Cache-aware, at the same list prices

The honest API-price estimate, each token class at its actual list rate:

| Provider | Cache-aware cost |
| --- | ---: |
| Claude Sonnet 5 | $3,219 |
| Claude Opus 5 | $1,802 |
| Claude Fable 5 | $538 |
| Claude Haiku 4.5 | $1 |
| Codex GPT-5.6 Sol | $7,865 |
| Codex GPT-5.6 Terra | $563 |
| Codex GPT-5.6 Luna | $27 |
| Grok | $22 |
| **Total** | **~$14,000** |

Caching changes the answer by about a factor of eight. Anyone quoting an AI
project's cost from its raw token count without the cache ratio is
overstating it several times over.

Remaining assumptions, all small: Anthropic cache writes priced at the
standard 1.25× (the 1-hour-cache 2× rate would add roughly $80); Sonnet
priced at its introductory rate, which applied during the project; the
off-machine tinker-desk and bruce agents are absent from the totals.

### 3. What was actually paid

The project ran on subscriptions and one prepaid key, not on API billing:

| Item | Actual cost |
| --- | ---: |
| Codex: $200/month subscription, plus previously banked usage resets, all consumed | $200 |
| Claude: $200/month subscription, one full cycle consumed | $200 |
| OpenRouter (Grok) | $21.80 |
| Hetzner: two $25 credit payments made 7 Aug; the metered invoice for the fleet's ~2 days at ~€41/day arrives with monthly billing | $50 so far |
| **Total out of pocket so far** | **~$472** |

The gap between line 2 and line 3 is the point: two consumer subscriptions
and about seventy dollars of incidentals absorbed a workload that lists at
roughly fourteen thousand dollars cache-aware, and six figures naively.

## Compute

Five rented servers, deleted the moment the roster completed. See
`BUILD-FLEET.md`.

| | |
| --- | ---: |
| Servers | 5 (3 × 16-core, 2 × 8-core) |
| Cost | €1,233.60/month, about **€41/day** |
| Location | Hetzner Ashburn, native x86-64 |

The fleet existed because emulation lies: QEMU-backed engines segfault or OOM
heavy toolchains before any client code runs, producing failures that have
nothing to do with the code. Native hardware settles those questions.

Wall clock, not tokens, was the binding constraint: `verify-all` shares one
backend per host, so only one verification can run per machine at a time.

## The integrity finding

The single most consequential result, and it was found by reading rather than
running.

Every language's Dockerfile ended with a loop asserting that no compiler,
package manager or shell toolbox survived its prune. **None of those loops
could fail**, for three independent reasons, any one of which was sufficient:

1. A POSIX `for` loop's exit status is only its *last* iteration's.
2. POSIX exempts a pipeline beginning with `!` from `set -e`.
3. In one image `command` did not exist at all, so every lookup returned 127,
   which `!` turned into success.

| | |
| --- | ---: |
| Merged images audited | 75 |
| Images actually leaking | **18** |
| Distinct root causes | 2 |

Two shapes only: a runtime built `FROM` the stock busybox image (which ships
`httpd`, `ftpd`, `inetd`, `wget`, `nc` and `telnet` as applets), or a Debian
base that was never stripped. Rust's Dockerfile listed `busybox` as forbidden
*while being built on busybox*.

All 18 are fixed. The check now lives once, in `toolchain_policy()` in the
repo-root `run` script, and reads the image's filesystem listing via
`docker export` rather than running a shell inside it, because three of the
leaking images had no usable `printf`, `echo` or `command`.

## Recurring defect classes

Counted across the 24-hour push. These are the shapes that cost real
verification cycles, each roughly 45 minutes of a rented machine.

| Class | Instances |
| --- | ---: |
| A prune deleting a binary it later calls (`rm`, `find`, `mkdir`, `chmod`) | 5 |
| Broken TLS trust: deleted OPENSSLDIR, mismatched OPENSSLDIR, missing `openssl.cnf`/providers, no SNI | 4 |
| A check that could not fail | 4 |
| The fixture, harness or reference implementation was the bug, not the client | 4 |
| `cp -a` staging a SONAME symlink without its target | 2 |
| Blocked by Docker's default seccomp profile | 2 |
| Permission bits stripped off the dynamic linker | 2 |

The TLS row is the one worth dwelling on. **The local profile structurally
cannot catch a TLS bug**: the self-hosted backend is plain HTTP, so a client
with an empty or misplaced trust store passes every local check and fails only
against the real deployment. Four languages hit it, four different ways. That
is the entire argument for the hosted profile existing.

## Documentation produced

| File | Purpose | Size |
| --- | --- | ---: |
| `LESSONS.md` | What was learned, for the video | 24 sections, ~8,950 words |
| `INFEASIBLE.md` | What could not be done and why | 10 sections, 66 recorded rows |
| `BUILD-FLEET.md` | Why the fleet exists, how to recreate it | — |
| `STATS.md` | This file | — |
