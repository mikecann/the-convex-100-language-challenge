# Lessons from building 100 Convex clients

Notes collected while repairing, verifying, and finishing the clients. Kept for
the write-up and the video. Every claim here comes from a real failure in this
repository, with the language and mechanism named so it can be checked.

## 1. The test environment lied more often than the code did

Six languages were declared broken by a build host and were not broken at all.

`javascript`, `typescript`, `elixir`, `erlang`, `clojure`, and `lua` all failed
on an ARM Mac running `linux/amd64` containers through QEMU emulation. The
failures looked convincing and looked different from each other: two containers
were OOM-killed under the 128 MiB limit, two blew fixed timing deadlines, one
segfaulted GCC while compiling BusyBox. On native x86-64 hardware, every one of
them passed 31 of 31 checks on the first attempt.

The same day, the opposite result: `bcpl` and `io` were suspected emulation
victims and were rerun natively out of fairness. Both segfaulted again,
identically. Those are real defects.

The lesson is not "emulation is bad." It is that **a failure is not evidence
until you know which layer produced it**, and the cheapest way to find out is to
change one layer and rerun. Rosetta ran these toolchains fine; QEMU did not.
Both are "Docker on a Mac."

## 2. The bugs that mattered were invisible to the cheap tests

Every language here has a fast local gate: compile it, run its own unit tests
against loopback fixtures. Every language also gets an expensive gate: run the
real client against a real Convex backend, then against the real hosted
deployment over real TLS, driven through 31 protocol checks alongside a
known-good reference client.

The expensive gate is where the interesting bugs lived.

- **Forth** clamped a reconnect's TLS handshake deadline to the caller's 50 ms
  scheduling slice instead of its own connect budget. Against a loopback backend
  everything completes in microseconds, so it never showed. Against real TLS,
  every automatic reconnect timed out.
- **Groovy** printed the correct six-line transcript and passed everything
  locally, then repeatedly OOM-killed against the hosted deployment. A real TLS
  handshake links a whole additional tier of JVM crypto call sites; the JIT
  compiled them and blew the 128 MiB container budget. The fix was C1-only
  compilation with raised thresholds — the JIT's *working set*, not its output,
  was the problem.
- **Tcl** verified certificates correctly in every local fixture and rejected
  the real Convex certificate. Its TLS library validates the chain but never
  exposes Subject Alternative Names, and Convex names per-deployment hosts only
  through a wildcard SAN. The local fixtures all happened to use certificates
  whose Common Name equalled the hostname, so the broken path was never taken.
  The client now decodes the SAN extension out of the certificate's own DER.
- **Standard ML** passed the example and the first two reconnects, then froze
  the entire process for exactly as long as the test harness waited before
  giving up.

A six-line happy-path transcript proves a client can work once on a good day.
It cannot prove reconnects survive, errors surface, memory stays bounded, or
TLS is verified.

## 3. Several tests were structurally incapable of failing

This category was more common than expected, and it is the most transferable
lesson: a green check is worthless if you never confirmed it can go red.

- **Nim's formatter gate** ran `nimpretty --check` — a flag that does not exist.
  The tool printed usage and exited 0. The gate was also wrapped in
  `find -exec`, which discards the exit status anyway. Two independent reasons
  it could never fail. When it was rewritten to actually compare output, it
  immediately found seven unformatted files.
- **Scala's README check** extracted the example with a `sed` range matching a
  ` ```text ` fence, but the README used ` ```scala `. The extraction produced an
  empty file and compared the example against nothing.
- **Forth** hid two genuine compile errors behind shell pipelines that swallowed
  the compiler's exit code.
- **Standard ML's** test image reported that it had run a format check that it
  had not run.
- **Ada's** 3,510-line socket test suite ran under `if test -x ./bin/tests; then
  ... fi` — one build change away from silently never running again.

The repair in every case was the same: make the gate fail on purpose once, and
confirm you see red.

## 4. Code written but never executed encodes confident, wrong assumptions

Roughly thirty clients existed as "reviewed source checkpoints" — complete,
carefully commented, thoroughly reviewed, and never once compiled. They were
not close to working. First contact with a compiler produced:

reserved words used as identifiers (`field` in BlitzMax, `local` in Pike,
`object` in Pony), a `sleep` call from a module never imported (Chapel),
placeholder values left in Dockerfiles (`EIFFELSTUDIO_SHA256=0000...`,
`CHEZ_VERSION=REPLACE_WITH_VERIFIED_...`), pinned package versions the
distribution had already dropped, a base image tag that did not exist, and in
one case 231 compile errors in a single package.

Their *test fixtures* were wrong in a more interesting way. A fixture written
without ever being run encodes the author's mental model of timing. One Chapel
fixture throttled a peer to a 1 KB receive buffer and expected an 8 MB transfer
to finish inside five seconds; on a virtualized network stack that pacing takes
about ten minutes. The client was fine. The test was fiction.

## 5. The same misunderstanding produced the same bug in different languages

Two clients, written independently in Gleam and PureScript, had the identical
defect: when the last live query is removed, the client deletes its record of
that query before the server's acknowledgement arrives, then rejects the
acknowledgement as referring to an unknown query. Both then tore down a healthy
connection and reported a protocol error to whichever subscription came next.

A `Remove` is a request, not an effect. The query stays in the server's set
until a transition says otherwise. Two authors made the same wrong assumption,
which suggests the protocol invites it — worth noting for anyone documenting
sync protocols.

## 6. Language runtimes have sharp edges in the same three places

Across very different ecosystems, the deep bugs clustered:

**Blocking calls that freeze more than themselves.** Poly/ML sets sockets
non-blocking when it creates them but not when it *accepts* them, and a thread
blocked inside its runtime never reaches a garbage-collection safe point — so
one accepted socket froze every thread in the process for ten seconds at a time.
Chapel's task scheduler would not run a background writer while the main task
sat in an unbounded `read()`, deadlocking on a single-core container.

**Memory that is not where you think it is.** Nim's `allocShared` is the calling
thread's arena under its ORC collector, so a buffer allocated by one thread and
freed by another after that thread exited corrupted the heap. The BEAM's
`-noshell` reader eagerly pulls everything available off standard input into a
process mailbox regardless of demand — 26,363 queued messages holding 27 MB, in
a client that reads 16 KB at a time. OCaml's adapter held one full decoded copy
of every active query's last value outside its own accounting: 86% of the live
heap, uncharged, scaling with subscription count.

**Cleanup that runs after you deleted the tools.** Three separate Dockerfiles
destroyed their own runtime image: Forth's prune loop deleted `/bin` and then
could not find `rm` for the next iteration; Fortran's library copier lost the
execute bit on the dynamic linker, so nothing dynamically linked could run
afterwards, including `/bin/sh`; Haxe copied absolute paths with `cp --parents`
from a working directory that was not `/`.

## 7. Verification rules have a cost, and it is worth measuring

The project's rule is that evidence must come from the exact reviewed commit,
with a clean tree. Correct — but it meant recording an earned badge (editing a
manifest line and a README table) invalidated the evidence and forced a complete
re-run: two full verification passes per language, on a queue of about fifty.

The rule was amended rather than broken: a follow-up commit provably limited to
the manifest capability list and README prose cannot change the built image or
the evaluator's award, so it may cite the parent commit's evidence. Anything
touching the Dockerfile, client, examples, or other manifest fields forfeits the
exemption.

Worth saying plainly: the fix was to make the rule *more precise*, not more
lenient. A process rule that costs double should be examined, and sometimes the
examination ends with "yes, it's worth it."

## 8. Parallel agents need isolation, and they should be suspicious

Two agents were given the same build host and both ran `git checkout` in the
same working directory. Docker reads its build context from disk *during* a
build, so one agent's branch switch silently swapped the source tree out from
under the other's running build. The resulting error — "Dockerfile not found" —
pointed at a language that was not at fault.

The agent that hit it stopped, read the reflog, diagnosed the race, and reported
it instead of retrying into it. That was the right call and it saved a
misdiagnosis. Every agent now gets its own clone.

A second incident is worth recording. A coordination instruction reached one
agent embedded inside a tool result rather than as a direct message. It declined
to act on it, reasoning that instructions arriving through that channel are not
trustworthy and that this one contradicted its original briefing. The
instruction happened to be legitimate. The caution was still correct, and it is
exactly the behaviour you want when a message like that is *not* legitimate.

## 9. Not everything on the list can be done honestly

Eleven of the hundred cannot be built under the project's own rules: they need
proprietary licences, hosted-only platforms, or GUI-bound toolchains. Apex runs
only inside Salesforce. LabVIEW, MATLAB, SAS, Xojo, Visual FoxPro, Xbase++, and
MQL5 need commercial licences or Windows-only compilers. RPG needs IBM i.
Scratch has no network primitives at all — a Convex client cannot be expressed
in it. Three more (Wolfram, q, GameMaker) are feasible only behind an
activation key.

They are recorded in `INFEASIBLE.md` with reasons and with replacement
candidates, rather than quietly dropped or faked with a lookalike. "We tried and
here is exactly why it cannot be done" is a real result.

## 10. Miscellaneous findings worth a slide

- A client passed every check except one, and the one failure was in the
  *reference* implementation used for comparison, not the client under test.
  Re-running cleared it. Knowing which side of a comparison failed matters.
- BlitzMax emitted a perfect transcript that failed byte comparison: its
  `Print` hard-codes CRLF line endings on every platform, including Linux.
- CoffeeScript's example called a helper defined further down the file.
  CoffeeScript compiles that to a plain assignment, which — unlike a JavaScript
  function declaration — is not hoisted.
- The Ring interpreter's `trim()` removes spaces but not newlines, so a test
  comparing a trimmed line against an expected string could never match.
- One test asserted a send would *fail* within its deadline. Read quickly, it
  looks like an assertion that the send succeeds. An agent nearly "fixed" the
  client to satisfy a misreading of the test; it stopped and checked instead.
