# Project statistics

Measured, not estimated. Every figure here comes from the repository, the
session transcripts on disk, or the Hetzner API. Where a number is approximate
or has a caveat, it says so.

Recorded for the video. Companion to `LESSONS.md` (what was learned) and
`INFEASIBLE.md` (what could not be done, and why).

## The roster

| | |
| --- | ---: |
| Languages verified with **both** `http` and `live` badges | **100** |
| Verified when this file was first written | 83 |
| Verified at the start of the 57→83 session below | 57 |
| Added in that one session | 26 |

The roster reached 100 in a second push a day later — see "The 83 → 100
push" further down. The figures immediately below (infeasible count,
directory count, source-line count) are as measured at 83 and have not
been recomputed since; nothing about them changed in a way that mattered
enough to re-run the count, but treat the roster-size row above as the
current truth and everything else in this section as a historical
snapshot from that point.

| | |
| --- | ---: |
| Recorded infeasible, with reasons | 22 |
| Language directories in the repository | 107 |
| Lines of client and example source, all languages | 355,755 |

Every badge on `main` comes from `./run verify-all` at an exact clean commit:
31 of 31 conformance checks against a local Convex backend **and** 31 of 31
against the real hosted deployment over TLS, with `dirty: false` on both. No
language carries a badge on partial evidence.

The five largest clients by source lines — Ada 11,106, COBOL 9,469, Julia 8,407,
Idris 8,062, Gleam 7,907 — are not the hardest languages. They are the ones
whose type systems or verbosity demanded the most text for the same behaviour.

## Why 22 languages could not be done

Grouped by cause, which is more interesting than the count:

| Reason | Count | Examples |
| --- | ---: | --- |
| Proprietary or GUI-gated toolchain | 11 | LabVIEW, MATLAB, SAS, Scratch, X++ |
| No socket reachable from the language itself | 6 | bc, Solidity, ABAP, Elm, CFML, Futhark |
| No hermetic, non-interactive build possible | 1 | Unison |
| Blocked by container security policy | 1 | Pop-11 |
| Runtime footprint exceeds the container limit | 1 | Raku |
| At risk, not abandoned | 2 | ActionScript, Logo |

Three of those deserve their own line, because they failed for reasons nobody
predicted:

- **Unison** proved a real certificate-verified TLS handshake from its own
  source, then failed anyway — its standard library is reachable only through a
  build-time round trip to a hosted service.
- **Pop-11** cannot start inside Docker at all. Poplog's bootstrap calls
  `personality(ADDR_NO_RANDOMIZE)`, which the default seccomp profile refuses,
  producing a memory access violation rather than a permission error.
- **Raku** is the only entry ruled out on resources. After removing Cro, then
  Rakudo Star, then *every* external module — binding libssl through core
  NativeCall — the floor was still 145–170 MiB against a 128 MiB limit, with
  zero client code loaded.

## The final session

Twenty-four hours, 57 → 83 verified.

| | |
| --- | ---: |
| Wall clock | ~24.4 hours |
| Commits | 489 |
| Pull requests merged | 80 |
| Files touched | 968 |
| Agents and workflows that reported in | 102 |
| Subagent transcripts written to disk | 288 |

## Tokens

| | Main thread | Subagents | Total |
| --- | ---: | ---: | ---: |
| Fresh input | 5,594 | 799,360 | 804,954 |
| Cache creation | 14,145,504 | 344,482,042 | 358,627,546 |
| Cache reads | 1,277,918,557 | 41,579,798,596 | 42,857,717,153 |
| **Output** | **2,307,993** | **32,019,651** | **34,327,644** |
| **Total** | 1,294,377,648 | 41,957,099,649 | **43,251,477,297** |

Three things in that table matter more than the headline:

**43.25 billion tokens moved, and 99.1% were cache reads.** Only 804,954 tokens
were ever read fresh. The expensive thing in long-running agent work is not
thinking, it is re-reading context — and nearly all of it caches. Accounting
that treats all tokens alike overstates the cost by about two orders of
magnitude.

**93% of the output came from subagents, not the coordinator.** 2.3 million
tokens against 32 million. Routing, merging and deciding is cheap; the work is
where the tokens go, and the work parallelises.

**About 1.3 million output tokens per language merged**, and strikingly stable
across languages as different as COBOL and Mojo, because the cost is dominated
by the debugging loop rather than by writing the client. Languages came in well
under when someone had already done the feasibility spike, and well over when a
confident diagnosis turned out to be wrong.

## Compute

Five rented servers, deleted at the end of the session. See `BUILD-FLEET.md`.

| | |
| --- | ---: |
| Servers | 5 (3 × 16-core, 2 × 8-core) |
| Cost | €1,233.60/month — about **€41/day** |
| Location | Hetzner Ashburn, native x86-64 |

The fleet existed because emulation lies: QEMU-backed engines segfault or OOM
heavy toolchains before any client code runs, producing failures that have
nothing to do with the code. Native hardware settles those questions.

Wall clock, not tokens, was the binding constraint — `verify-all` shares one
backend per host, so only one verification can run per machine at a time.

## The integrity finding

The single most consequential result, and it was found by reading rather than
running.

Every language's Dockerfile ended with a loop asserting that no compiler,
package manager or shell toolbox survived its prune. **None of those loops
could fail**, for three independent reasons, any one of which was sufficient:

1. A POSIX `for` loop's exit status is only its *last* iteration's.
2. POSIX exempts a pipeline beginning with `!` from `set -e`.
3. In one image `command` did not exist at all, so every lookup returned 127 —
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
`docker export` rather than running a shell inside it — because three of the
leaking images had no usable `printf`, `echo` or `command`.

## Recurring defect classes

Counted across the session. These are the shapes that cost real verification
cycles, each ~45 minutes of a rented machine.

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
cannot catch a TLS bug** — the self-hosted backend is plain HTTP, so a client
with an empty or misplaced trust store passes every local check and fails only
against the real deployment. Four languages hit it, four different ways. That
is the entire argument for the hosted profile existing.

## The 83 → 100 push

A second session, roughly a day after the one above, resumed from its 83
and carried the roster the rest of the way to complete.

| | |
| --- | ---: |
| Wall clock | ~21.1 hours (02:13 → 23:19 UTC, 2026-08-08) |
| Languages verified at the start | 83 |
| Languages verified at the end | **100** |
| Pull requests merged | 17 |
| Commits to `main` | 21 |
| Files touched | 321 |
| Distinct agents and workflow-agents that reported in | 57 |
| Session-limit mass-kills survived, zero work lost | 3 |

Three of those 17 languages needed a replacement chosen mid-session, not
just a build: Hack and Oz were ruled infeasible with full evidence
(HHVM cannot offer an ECDSA-compatible ClientHello against the real
deployment and has no FFI escape hatch; Mozart 2's own code generator
crashes deterministically, 208 consecutive times, on the header carrying
a hand-written TLS builtin) and replaced by Verilog and Modula-3
respectively, both chosen, built and verified inside the same session.

### Tokens

Measured the same way as the table above: summed directly from the
session transcript and all 57 subagent transcripts on disk, deduplicated
by message id (a handful of entries are logged more than once with
identical usage; each is counted once).

| | Main thread | Subagents | Total |
| --- | ---: | ---: | ---: |
| Fresh input | 817 | 66,257 | 67,074 |
| Cache creation | 2,656,904 | 28,305,070 | 30,961,974 |
| Cache reads | 151,801,420 | 2,706,893,261 | 2,858,694,681 |
| **Output** | **297,618** | **674,618** | **972,236** |
| **Total** | 154,756,759 | 2,735,939,206 | **2,890,695,965** |

Roughly **2.89 billion tokens moved to verify the last 17 languages**,
against 43.25 billion for the 26 languages the session before it merged —
a smaller push by design, not by ratio: this session spent most of its
wall clock on debugging loops (Clean's real compiler bug, Io's
five-session "segfault" that was never one, Modula-3's dependency wiring)
rather than the wide parallel fan-out the earlier session ran.

**98.9% of everything moved was a cache read.** Only 67,074 tokens were
ever read fresh across the entire push — every remaining language, every
repeated AGENTS.md read, every rebase, served from cache.

**69% of output came from subagents**, lower than the first session's
93%. The coordinator did more of its own investigative work this time —
reading transcripts, diffing branches, reconciling forks after each
mass-kill, root-causing the two forgotten-badge near-misses — rather than
purely routing.

## The 100 → 97 → 100 revalidation

On 10 August, a random `./run verify-all seed7` exposed that a badge earned on
another system was not enough evidence that every client still worked on the
only machine available for the project. That started a full host-focused audit,
parallel language sweeps, repairs to existing clients, and finally three
transparent roster backfills.

| | |
| --- | ---: |
| Wall clock to the final evidence commit | ~24.8 hours (01:37 UTC, 10 August → 02:24 UTC, 11 August 2026) |
| Coordinator transcripts | 1 |
| Subagent transcripts | 35 |
| Directly related commits | 38 |
| Unique files touched by those commits | 112 |
| Lines added / removed | 10,975 / 152 |
| Shared evidence profiles passed at the end | 6 (3 local, 3 hosted) |
| Conformance result in every profile | 31/31 |
| Working languages before the audit | 100 |
| Host-reliable languages after the audit | 97 |
| Working languages after backfills | **100** |

The audit repaired real issues in Seed7, Bash, Ballerina, Clojure, COBOL, D,
Lean, Odin and the shared sweep/harness path. It also distinguished client bugs
from host/runtime limits instead of forcing misleading language-local fixes.
The three slots that could not be made reliable on this Apple-Silicon Docker
host were preserved as attempts and backfilled explicitly:

| Slot | Preserved attempt | Replacement | Decisive local blocker |
| ---: | --- | --- | --- |
| 35 | MUMPS | Fennel | YottaDB's hostname transport failed intermittently under amd64 emulation |
| 45 | SETL | C3 | The GNU SETL VM used roughly 274 MiB for a trivial pretranslated program, over the 128 MiB limit |
| 52 | Modula-3 | LOLCODE | The CM3 toolchain could not complete reliably on this verification host |

Hy was also implemented and independently reviewed during the replacement
work. It remains an unrostered, passing candidate rather than displacing one of
the user's preferred replacements. Fennel, C3 and LOLCODE each finished with
the exact canonical `0 → 1` example plus all 31 local and all 31 hosted checks,
earning both `http` and `live` at clean commit `3932242`.

### Tokens

This is a snapshot at **2026-08-11 04:44:15 UTC**. It sums the final cumulative
usage record in the coordinator transcript and all 35 direct subagent
transcripts. A repeated usage event does not add tokens because only the final
cumulative value for each transcript is used. Forked context does count for
each agent that actually processed it, which is why cache reads dominate.

| | Main thread | Subagents | Total |
| --- | ---: | ---: | ---: |
| Fresh input | 4,755,070 | 41,035,325 | 45,790,395 |
| Cache creation | 0 | 0 | 0 |
| Cache reads | 233,897,728 | 2,227,849,728 | 2,461,747,456 |
| **Output** | **209,242** | **2,591,685** | **2,800,927** |
| Reasoning output, included in output above | 60,462 | 716,422 | 776,884 |
| **Total** | **238,862,040** | **2,271,476,738** | **2,510,338,778** |

**2.51 billion tokens moved, 98.1% of them cache reads.** The API reported no
separate cache-creation tokens in this session. Subagents produced 92.5% of all
output and accounted for 90.5% of total token movement. The transcripts also
record 5,554 tool calls, 1,842 from the coordinator and 3,712 from subagents.

### Models

The coordinator used `gpt-5.6-sol` at medium effort. Early parallel sweeps and
focused fixes mostly used the smaller `gpt-5.6-terra`, initially at low effort;
the longer replacement implementations and independent reviews moved to Sol.
Five long-lived subagent transcripts switched models or effort mid-task. The
table below attributes each increment in cumulative usage to the model and
effort active for that turn, so those mixed sessions are not guessed or charged
wholly to one model.

| Model / effort | Fresh input | Cache reads | Output | Reasoning output | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| `gpt-5.6-sol` / medium | 29,372,367 | 1,573,414,400 | 1,750,663 | 491,155 | **1,604,537,430** |
| `gpt-5.6-terra` / medium | 13,810,824 | 787,787,520 | 843,297 | 229,901 | **802,441,641** |
| `gpt-5.6-terra` / low | 2,607,204 | 100,545,536 | 206,967 | 55,828 | **103,359,707** |

Reasoning output is a subset of output, not an extra amount added to the total.
Across complete transcripts, eight used only Sol, 23 used only Terra, and five
used both.

<details>
<summary>Per-subagent token breakdown</summary>

The model column is the set of models and effort levels observed in that
transcript. Totals are exact cumulative transcript totals; reasoning is again a
subset of output.

| Task (agent) | Model / effort | Fresh input | Cache reads | Output | Reasoning | Total |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `brainfuck_feasibility` (Archimedes) | Sol / medium | 3,319,075 | 166,228,480 | 160,468 | 47,553 | **169,708,023** |
| `c3_websocket` (Descartes) | Sol / medium | 2,900,238 | 173,017,856 | 213,058 | 56,905 | **176,131,152** |
| `candidate_compiled` (Laplace) | Terra / medium | 2,375,906 | 141,862,912 | 141,054 | 40,970 | **144,379,872** |
| `candidate_lisp_beam` (Franklin) | Terra / medium | 2,375,825 | 138,251,520 | 145,461 | 38,466 | **140,772,806** |
| `candidate_transpiled` (Erdos) | Terra / medium | 2,274,552 | 130,232,064 | 141,440 | 39,059 | **132,648,056** |
| `debug_clu` (Wegener) | Terra / medium | 151,940 | 5,060,864 | 13,619 | 3,701 | **5,226,423** |
| `fix_ballerina` (Meitner) | Terra / low | 45,830 | 428,032 | 1,918 | 602 | **475,780** |
| `fix_bash` (Copernicus) | Sol + Terra / low + medium | 285,737 | 15,300,864 | 25,833 | 8,735 | **15,612,434** |
| `fix_bash_live_tls` (Bohr) | Sol + Terra / medium | 2,420,824 | 132,613,888 | 166,601 | 45,267 | **135,201,313** |
| `fix_clojure` (Schrodinger) | Terra / low | 53,915 | 1,306,880 | 6,611 | 1,969 | **1,367,406** |
| `fix_clojure_close` (Kuhn) | Sol + Terra / low + medium | 312,936 | 6,204,928 | 25,372 | 6,229 | **6,543,236** |
| `fix_clu` (Plato) | Terra / low | 176,891 | 2,378,496 | 4,997 | 1,737 | **2,560,384** |
| `fix_cobol` (McClintock) | Terra / low | 79,889 | 2,008,320 | 8,060 | 3,128 | **2,096,269** |
| `fix_cobol_hosted_race` (Faraday) | Terra / medium | 2,448,659 | 140,316,928 | 156,786 | 40,502 | **142,922,373** |
| `fix_cobol_live` (Hegel) | Terra / low | 46,627 | 1,056,256 | 4,224 | 1,309 | **1,107,107** |
| `fix_cobol_sigpipe` (Volta) | Terra / low | 109,766 | 4,923,392 | 13,090 | 3,742 | **5,046,248** |
| `fix_d` (Maxwell) | Terra / low | 64,105 | 1,104,128 | 4,855 | 1,476 | **1,173,088** |
| `fix_lean_close` (Banach) | Sol + Terra / low + medium | 262,722 | 8,049,920 | 23,125 | 7,820 | **8,335,767** |
| `fix_modula3` (Jason) | Terra / medium | 151,686 | 7,639,296 | 14,747 | 4,999 | **7,805,729** |
| `fix_mumps_hosted` (Arendt) | Terra / low | 49,013 | 565,248 | 3,249 | 989 | **617,510** |
| `fix_mumps_http` (Lorentz) | Terra / medium | 1,969,341 | 113,167,872 | 115,443 | 30,015 | **115,252,656** |
| `fix_odin` (Halley) | Terra / low | 51,948 | 1,289,984 | 4,462 | 762 | **1,346,394** |
| `fix_setl_example` (Confucius) | Terra / low | 102,199 | 2,209,536 | 12,612 | 2,644 | **2,324,347** |
| `lolcode_feasibility` (Lovelace) | Sol / medium | 3,827,323 | 207,727,360 | 278,738 | 71,109 | **211,833,421** |
| `optimize_setl_memory` (Parfit) | Terra / medium | 153,185 | 3,354,368 | 12,379 | 4,181 | **3,519,932** |
| `prewarm_even` (Mill) | Terra / low | 511,010 | 25,113,088 | 34,842 | 9,539 | **25,658,940** |
| `prewarm_odd` (Russell) | Terra / low | 694,037 | 34,235,392 | 41,113 | 9,387 | **34,970,542** |
| `prewarm_tail_a` (Beauvoir) | Terra / low | 101,937 | 4,792,320 | 7,031 | 1,022 | **4,901,288** |
| `prewarm_tail_b` (Nietzsche) | Terra / low | 91,382 | 4,352,256 | 6,170 | 478 | **4,449,808** |
| `review_c3` (Ptolemy) | Sol / medium | 3,526,268 | 182,232,320 | 187,062 | 56,061 | **185,945,650** |
| `review_fennel` (Kant) | Sol / medium | 2,678,864 | 159,385,088 | 167,804 | 49,022 | **162,231,756** |
| `review_hy` (Hubble) | Sol / medium | 2,648,390 | 167,929,856 | 178,050 | 52,086 | **170,756,296** |
| `review_lolcode` (Harvey) | Sol / medium | 4,200,236 | 214,616,576 | 194,977 | 57,249 | **219,011,789** |
| `validate_bash_od` (Dewey) | Sol + Terra / low + medium | 474,578 | 25,351,936 | 60,719 | 12,952 | **25,887,233** |
| `validate_bash_wget` (Sartre) | Terra / low | 98,491 | 3,541,504 | 15,715 | 4,757 | **3,655,710** |

</details>

## Across all model providers

The four transcript-derived Codex task tables in this file account for
**49,065,960,861 tokens**. A separate provider check on 7 August 2026 pulled
Claude usage from the saved local session records and Grok usage from the live
OpenRouter dashboard:

| Provider and model | Tokens | Source and caveat |
| --- | ---: | --- |
| Codex | 49,065,960,861 | The four transcript-derived Codex task tables in this file |
| Claude Opus 5 | 3,148,726,203 | Saved Claude sessions; includes 3.052B cache reads, 69.2M cache writes and 26.75M output |
| Claude Fable 5 | 193,765,957 | Saved Claude sessions; includes 188.1M cache reads, 4.67M cache writes and 1.01M output |
| Claude Sonnet 5 | 1,123,725,974 | Saved Claude sessions |
| Claude Haiku 4.5 | 16,021,031 | Saved Claude sessions |
| OpenRouter Grok 4.5 | ~45,300,000 | Live dashboard; 305 requests and approximately $21.80 |
| **All providers** | **~53,593,500,026** | Approximate because OpenRouter rounds its displayed totals |

OpenRouter showed the project API key rounded to **45M tokens**, while its
model breakdown showed **45.3M**. The table preserves 45.3M as the best
available figure rather than presenting it as exact. The Claude figures are
exactly what the saved sessions reported at the time of that provider check.

This **53.59 billion** total supersedes the earlier 18.07 billion preliminary
snapshot, which was taken before transcript accounting for the completed Codex
pushes was available. As with the session tables, the overwhelming majority was
cached context processing, not full-price fresh input.

## The README rewrite and final audit

This is the work from the review request on 10 August 2026 through the direct
push to `main` at `a34fd2d` on 11 August. The repository figures use the exact
Git range `8721f07..a34fd2d`. The model figures come from this task's transcript
and all 103 subagent transcripts it started.

The elapsed wall clock was **23 hours, 40 minutes, 42 seconds**. That includes a
12 hour, 17 minute pause while the separate whole-roster verifier task was
allowed to finish. It is elapsed time, not 23.7 hours of continuous model or
Docker activity.

### Repository change

| | |
| --- | ---: |
| Commits pushed to `main` | **101** |
| Per-language README commits | 97 |
| Merge commits | 1 |
| Files changed | **206** |
| Insertions | 18,955 |
| Deletions | 7,949 |
| Net lines added | 11,006 |
| Language READMEs rewritten | **100** |
| Root README also changed | 1 |
| Official or project-owned PNG logos added | **73** |

The remaining changed files were the shared validator, harness, site support,
the resumable verification sweep, and targeted client or Docker fixes found by
the final verification work. No schema change was made.

### What happened to the READMEs

| Across the 100 language READMEs | Before | After | Change |
| --- | ---: | ---: | ---: |
| Lines | 25,594 | 35,905 | +10,311 |
| Words | 167,821 | 192,892 | +25,071 |
| Bytes | 1,242,874 | 1,498,632 | +255,758 |
| Average lines per README | 255.94 | 359.05 | +103.11 |
| Average words per README | 1,678.21 | 1,928.92 | +250.71 |

The new `Interesting Parts` sections contain 12,051 lines in total, including
their focused TypeScript and target-language examples. The `Known Issues`
sections contain 429 numbered items. All 100 READMEs ended with the required
section order and synchronized canonical example blocks.

### Agent work

This task started **103 subagents**, all directly from the coordinator. They
ran 192 agent turns in total. There were no hidden second-generation agents.
The work split was:

| Role | Agents | Fresh input | Cache reads | Output | Total tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| README rollout lanes | 97 | 10,051,824 | 214,362,880 | 1,193,800 | 225,608,504 |
| F# model comparison and Haxe pilot | 3 | 485,917 | 6,336,256 | 46,503 | 6,868,676 |
| Final audit and reconciliation | 3 | 554,818 | 11,596,288 | 69,190 | 12,220,296 |
| **All subagents** | **103** | **11,092,559** | **232,295,424** | **1,309,493** | **244,697,476** |

The 100 authoring and pilot runs used 232,477,180 tokens, an average of about
2.32 million per run. The cheapest language lane by total tokens was JavaScript
at 1,019,264. The most expensive was Swift at 5,129,539. That spread mainly
reflects repeated context and review cycles, not README length alone.

### Models and reasoning levels

| Model and effort | Agents | Fresh input | Cache reads | Output | Total tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| GPT-5.6 Sol, medium | 101 | 10,725,001 | 227,459,328 | 1,270,741 | 239,455,070 |
| GPT-5.6 Sol, xhigh | 1 | 175,040 | 2,574,080 | 17,416 | 2,766,536 |
| GPT-5.6 Terra, ultra | 1 | 192,518 | 2,262,016 | 21,336 | 2,475,870 |

The smaller-model F# trial discussed as Luna in the conversation is recorded
by the actual task telemetry as **GPT-5.6 Terra at ultra reasoning**. Against
that run, the independent Sol xhigh run moved 11.74% more total tokens but
produced 18.37% fewer output tokens. That is a token comparison, not a dollar
comparison. Codex did not record a per-task charge or model price in these
transcripts, so inventing a monetary total would make this section less honest.

The later choice to use Sol at medium is represented by 101 real runs, not an
extrapolation. Those runs averaged about 2.37 million total tokens and 12,581
output tokens each.

### Coordinator and total token cost

| | Coordinator | Subagents | Total |
| --- | ---: | ---: | ---: |
| Fresh input | 2,405,233 | 11,092,559 | **13,497,792** |
| Cache reads | 166,088,192 | 232,295,424 | **398,383,616** |
| **Output** | **257,920** | **1,309,493** | **1,567,413** |
| **Total** | **168,751,345** | **244,697,476** | **413,448,821** |

Reasoning tokens were 72,284 for the coordinator and 359,620 for subagents,
431,904 combined. They are a subset of output tokens, so they are not added a
second time in the table.

Cache reads were **96.72% of all input**. Subagents accounted for 59.18% of all
tokens moved and 83.54% of output. The coordinator made 729 execution calls,
started 103 agents, issued 89 follow-up turns, and waited on agents 201 times
across 24 coordinator turns.

Adding this task to the two earlier Codex pushes brought the transcript-backed
Codex subtotal to **46,555,622,083 tokens**. Including the separate verifier and
replacement task recorded above brings the current Codex total to
**49,065,960,861 tokens** and the tracked all-provider total to approximately
**53,593,500,026 tokens**.

### Verification and publication

- `./run sync-examples` reported zero README blocks needing regeneration.
- `./run validate` passed the roster, all 100 manifests, and harness selftests.
- `./run site-preview` generated the 100-language static evidence site.
- All 100 README structural checks passed.
- Nine of the ten implementation-sensitive languages rerun from the clean
  reviewed commit passed local and hosted conformance, 31 of 31 checks in each
  profile. That is 558 of 558 checks across those nine languages.
- MUMPS passed its local canonical example but could not establish the hosted
  connection under the Docker Desktop amd64 Rosetta environment.
- The concurrent whole-roster sweep finished at 97 of 100 in that environment.
  MUMPS, Modula-3, and SETL retained documented environment or toolchain
  blockers rather than being rounded up.
- The final tree was clean, old README branches and worktrees were removed, and
  `a34fd2d` was pushed directly to `origin/main`.

The separate verifier task `019fe951-2e5a-7802-b1bf-b9535446c0c3` contributed
some implementation fixes included in the Git figures above. Its own model and
subagent usage remains separate from this README task's token table and is now
recorded in "The 100 → 97 → 100 revalidation" section. Keeping the tables
separate makes the accounting reproducible and avoids double-counting.

## Documentation produced

| File | Purpose | Size |
| --- | --- | ---: |
| `LESSONS.md` | What was learned, for the video | 24 sections, ~8,950 words |
| `INFEASIBLE.md` | What could not be done and why | 53 entries |
| `BUILD-FLEET.md` | Why the fleet exists, how to recreate it | — |
| `STATS.md` | This file | — |
