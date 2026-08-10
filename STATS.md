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

## Across all model providers

The two Codex sessions above account for **46,142,173,262 tokens**. A separate
provider check on 7 August 2026 pulled Claude usage from the saved local session
records and Grok usage from the live OpenRouter dashboard:

| Provider and model | Tokens | Source and caveat |
| --- | ---: | --- |
| Codex | 46,142,173,262 | The two transcript-derived tables above |
| Claude Opus 5 | 3,148,726,203 | Saved Claude sessions; includes 3.052B cache reads, 69.2M cache writes and 26.75M output |
| Claude Fable 5 | 193,765,957 | Saved Claude sessions; includes 188.1M cache reads, 4.67M cache writes and 1.01M output |
| Claude Sonnet 5 | 1,123,725,974 | Saved Claude sessions |
| Claude Haiku 4.5 | 16,021,031 | Saved Claude sessions |
| OpenRouter Grok 4.5 | ~45,300,000 | Live dashboard; 305 requests and approximately $21.80 |
| **All providers** | **~50,669,712,427** | Approximate because OpenRouter rounds its displayed totals |

OpenRouter showed the project API key rounded to **45M tokens**, while its
model breakdown showed **45.3M**. The table preserves 45.3M as the best
available figure rather than presenting it as exact. The Claude figures are
exactly what the saved sessions reported at the time of that provider check.

This **50.67 billion** total supersedes the earlier 18.07 billion preliminary
snapshot, which was taken before the transcript accounting for both completed
Codex pushes was available. As with the session tables, the overwhelming
majority was cached context processing, not full-price fresh input.

## Documentation produced

| File | Purpose | Size |
| --- | --- | ---: |
| `LESSONS.md` | What was learned, for the video | 24 sections, ~8,950 words |
| `INFEASIBLE.md` | What could not be done and why | 53 entries |
| `BUILD-FLEET.md` | Why the fleet exists, how to recreate it | — |
| `STATS.md` | This file | — |
