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

**Readiness misunderstood as data.** The Idris client livelocked on a brand-new
connection: its pump would only read the socket when its own userspace buffer
already held bytes, but subscribing only ever *writes*, so on a fresh connection
nothing had ever performed a first read. The operating system reported the
socket readable, the adapter dutifully called the pump two million times in
fifteen seconds, and the pump declined to read every time. The same bug had
already been found and fixed in a sibling function in the same file — with a
comment explaining it — and simply never mirrored across.

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

The same mistake then appeared in a second form: two verification runs started
concurrently on one machine. Verification deliberately shares a backend, a
network, a controller image, and an evidence directory, so it must run serially
— two runs would have interleaved their results into each other's evidence
files. Caught before either finished.

The pattern behind both: **scaling out agents keeps colliding with resources
that are shared implicitly rather than declared.** A git working directory and
an evidence directory are both invisible singletons until two workers reach for
them. Worth auditing for those before adding parallelism, not after.

A second incident is worth recording. A coordination instruction reached one
agent embedded inside a tool result rather than as a direct message. It declined
to act on it, reasoning that instructions arriving through that channel are not
trustworthy and that this one contradicted its original briefing. The
instruction happened to be legitimate. The caution was still correct, and it is
exactly the behaviour you want when a message like that is *not* legitimate.

## 9. Ahead-of-time compilation only knows the paths you rehearsed

Julia's client compiles to a standalone binary ahead of time, with no
just-in-time fallback at run time. That makes an ordinary omission fatal: any
code path the pre-compilation workout never executed simply has no machine code,
and reaching it at run time aborts the process.

The failures arrived one layer at a time, and each was a path nobody thought to
rehearse. First a reconnect crashed. Fixing that revealed that the *error
reporting* for such a crash was itself uncompiled — the binary could not even
describe what had gone wrong, because formatting that particular exception was
also a path never taken. Behind that sat the real prize: delivering a
`QueryFailed` transition, a genuine function-level error from the server, had
never once been exercised, because every test fixture ever written for this
client sent only successful updates.

The general shape is worth remembering: **when a system has no fallback, your
test corpus becomes the definition of what exists.** The unexercised error path
is the one that fails at 3am, and here it could not even print why.

## 10. Sometimes the bug belongs to someone else

Midway through, every Julia build began failing before reaching project code.
Julia's package server advertised a registry hash as current and its storage
backend returned 404 for that exact hash — a real inconsistency in Julia's own
CDN, reproduced from two machines on different continents.

Two things made this tractable. The agent doing the work stated plainly that it
believed the failure was not its own, rather than thrashing on its code. And the
claim was cheaply checkable: two `curl` commands from unrelated networks either
reproduce it or they do not.

The resolution was not to wait. Julia's package server is a cache in front of a
git registry, so the build now clones the registry directly — slower, and one
fewer layer that can serve stale metadata. **A workaround that removes a
dependency is an improvement; a workaround that adds a retry is a delay.**

## 11. Not everything on the list can be done honestly

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

## 12. A wrong build triple silently disabled TLS trust

The Odin client bundles its own build of curl. Its configure line said
`--build=aarch64-linux-gnu --host=x86_64-linux-gnu` on a machine that is
genuinely x86-64 — a leftover from when builds ran on an ARM Mac. Those two
values differing is how you *declare* a cross-compile, so autoconf believed it
was cross-compiling and skipped the step that finds the system CA bundle,
noting it in a log nobody reads: "skipped the ca-cert path detection when
cross-compiling."

The result was a libcurl with no trust store compiled in. Everything built,
every local test passed, and every real HTTPS connection failed peer
verification. One stale build flag, no error, TLS trust silently switched off.

The pattern generalises past autoconf: **configuration that describes your
environment will be believed, and being wrong about your environment disables
things quietly rather than loudly.**

## 13. Choosing what not to build is part of the work

Eleven of the hundred cannot be done honestly, so eleven replacements were
chosen. The criteria were deliberate: a free toolchain that installs unattended
in Docker, enough standard library or C FFI to reach a socket and speak TLS, a
real claim on a viewer's attention, and variety across eras rather than eleven
more curly-brace languages.

That last criterion did real work. The list runs from SNOBOL4 (1962, and still
the most distinctive pattern matching ever shipped) through Rexx, Modula-2,
Icon, Oberon and Mercury to Hare, Roc, Futhark and ATS. It includes Emacs Lisp,
because a Convex client living inside a text editor's extension language is a
legitimate client — Emacs has real sockets and real TLS — and not a stunt.

Two candidates were rejected for reasons worth stating. PostScript has no
sockets at all, so a client would be almost entirely foreign calls and would
earn the "bridge" label rather than the native one — building it would produce
a misleading badge. Koka and Red are genuinely interesting but their toolchains
are young enough that pinning a reproducible Docker build is a project in
itself.

**Saying no for a stated reason is a result.** A hundred entries where eleven
are honest failures and eleven are considered substitutions is a better artifact
than a hundred entries where some are quietly faked.

## 14. The oldest language was already in the roster

Asked to add the oldest language likely to work, the honest first answer was
that the project had already done it: **Fortran, 1957**, verified with full
HTTP and Live badges. Lisp and COBOL are there too. The three oldest languages
in common use are all in and all working.

Among languages *not* yet represented, the oldest plausible candidate is
**ALGOL 60**. It is the ancestor of nearly everything else on the roster —
block structure, lexical scope, recursion and BNF all arrive with it — and
GNU MARST still translates it to C, so it builds anywhere GCC does.

The feasibility check was done before promising anything, and it is a good
illustration of how to answer "can we?" honestly. MARST built cleanly from
source in a container, ALGOL 60 programs compiled and ran, and the external-C
mechanism (`code` procedures, the standard's own escape hatch for
implementation-defined bodies) exists. Two things surfaced immediately that a
paper answer would have missed: ALGOL 60 identifiers cannot contain
underscores, and `code` procedures must be declared outside the main block.

The rejected sibling makes the point sharper. **ALGOL 68** is younger, better
known, and packaged in Debian — but the packaged build has no networking
primitives at all, so a client would be an external transport process wearing a
costume. That earns this project's "bridge" label, not "native". Older and
harder turned out to be more honest than newer and easier.

## 15. Sometimes the platform's own library is the bug

Ballerina's client reached forty-one of forty-two tests and stopped on one:
a multi-byte UTF-8 character split across a WebSocket continuation-frame
boundary came back corrupted. The diagnosis was done by elimination rather than
assertion — the fixture's frame bytes were verified by hand, the same character
delivered unfragmented worked, and four different read APIs in the platform's
websocket module either shared the identical corruption or refused text frames
outright. Four APIs failing the same way means the defect sits in native code
beneath all of them.

That is a real bug in `ballerina/websocket`, not in the client. It is also
unwaivable here, because correct fragmented-UTF-8 decoding is explicitly on this
project's Live acceptance list.

The resolution is the interesting part: **the "workaround" is what most of this
project already does.** More than a dozen verified clients — BCPL, Forth, Tcl,
AWK, Pike, Io, Smalltalk — implement RFC 6455 by hand over a raw socket,
because their languages have no WebSocket library at all. Ballerina has one,
and it is wrong, so it joins them. Having a library is not the same as having a
correct one, and the languages with nothing were never at a disadvantage on this
particular axis.

A second, duller platform defect sat alongside it: the package manager's local
publish step intermittently dropped a symbol that the packaged artefact
contained correctly every time. Proven by diffing the source, the pack output,
and the published copy. The fix was to stop round-tripping through the local
repository at all.

## 16. A faster machine is a debugging tool

The Modula-2 client's test suite passed on one build host and failed roughly
half the time on another, faster one. The temptation with an intermittent
failure is to widen a timeout. The actual cause was a memory bug that the
slower machine had been hiding.

Its test fixture computed the WebSocket handshake's `Sec-WebSocket-Accept` by
appending a GUID to the client's key and hashing the result. The append helper
tracked its output length in a parameter but never wrote a terminating NUL, and
the next line asked for the length again by scanning for that NUL — so the scan
ran off the end and hashed a garbage-length input made of whatever happened to
be on the stack. Whether it worked depended entirely on whether a stray zero
byte followed the buffer, which depends on how the stack was last used, which
depends on the machine.

Two lessons sit on top of each other. **An intermittent failure that correlates
with hardware is usually uninitialised memory, not timing** — and this project
found the same shape again in Oberon, where the compiler does not zero local
arrays. And **the fixture was wrong, not the client**: the code under test had
computed its own key and expected-accept value correctly all along.

## 17. An assumption written in a comment is still an assumption

The ALGOL 60 client stored Convex's sync-protocol timestamps as floating-point
numbers, with a comment explaining that a `real` holds every integer exactly up
to 2^53 — which is true, and beside the point. A real deployment's logical
timestamp is nanosecond-scale, routinely above 10^18, roughly two hundred times
past that bound. Every genuine timestamp was silently rounded, failed its own
round-trip check, and surfaced as a misleading "the initial Live value was a
Convex function error".

The local tests had used timestamps 0 through 4.

Two things generalise. **A bound stated correctly can still be the wrong bound**
— the comment was accurate about the format and wrong about the data. And
**test fixtures inherit the author's imagination**: nobody who believed
timestamps were small would write a fixture with a large one, so the assumption
protected itself from discovery until a real server sent a real number.

## 18. Undiagnosable failures are a design choice

An investigator spent hours on a hypothesis about container sandboxes throttling
a client's timing, because a Docker build step failed with exit 1 and no output
at all. The step was a long `&&` chain of `test` commands ending in a smoke test
that ran the adapter — so the visible tail looked like the culprit.

It was the second link. `test ! -e /usr/local/bin/convex-example` was false,
because both launchers were being staged into a shared directory that each leaf
image then inherited, while each leaf asserted the other's launcher was absent —
unsatisfiable by construction. `test` reports a false condition as exit 1 with
nothing written anywhere, so every link's failure looks exactly like every
other's.

The fix included `set -eux` on those chains, so the trace now names the failing
link. **A check that cannot say why it failed will eventually cost more than it
saves** — and the cost lands on whoever is furthest from having written it.

## 19. The agents' most expensive failure was politeness, not error

The single largest source of wasted wall-clock in this project was not a broken
build. It was agents deciding to wait.

A worker would start a long build on a remote machine, correctly recognise that
it had nothing useful to do for the next twenty minutes, and end its turn with a
sentence like "I'll pause here and resume when I'm notified that the backend is
free." That sounds like good behaviour. It is the reasonable thing a person
would do. But no such notification exists for a job launched over SSH with
`nohup` — nothing was ever going to wake them. Ten agents did this at once and
sat idle for a full window while five rented servers ran nothing, until a check
of what was actually executing found exactly one live process across the entire
fleet.

The failure is subtle because the agent's reasoning is locally correct at every
step. It knows it should not busy-wait. It knows something else is responsible
for the build. It infers that something will therefore tell it when the build is
done. That last step is the invention — a plausible mechanism assumed into
existence because the situation seemed to call for one. The same shape shows up
in the code bugs elsewhere in this document: **the confident assumption about a
thing never actually checked is the recurring failure mode**, whether the thing
is a notification channel, a socket's blocking mode, or a library's UTF-8
handling.

Two changes fixed it. Every worker brief now says, in as many words, that no
monitor and no notification exist, that it must poll inline within its own turn,
and that it must never end a turn while a build is unresolved. And the
supervisor stopped trusting status reports as a picture of the fleet, replacing
them with a direct look at what was running:

```
ps -eo etime,args | grep -E "verify-all [a-z0-9-]+$"
```

That command found more real problems than any status summary did — idle
workers, two jobs racing on one machine, and two builds wedged for thirteen
hours that everyone involved believed were progressing. **Ask the machine what
it is doing, not the agent.**

## 20. An optimiser that renames your data

ActionScript came closer to working than almost any other blocked entry, and
then failed for a reason no amount of client debugging would have found.

Nine real defects were fixed first, each interesting in its own right: a
distribution that nests one directory deeper than its documentation says, a
package layout that collides with its own source path, `RegExp.exec` returning
a result object rather than an array, a generated entry point that names its own
class wrongly on two consecutive lines, and a lone unpaired UTF-16 surrogate
that cannot survive as a compiled string literal and silently becomes `"?"`.

The blocker underneath them was structural. Apache Royale's Node release build
runs the whole program through Closure Compiler with advanced optimisations,
including property renaming, and no flag was found to turn it off. Property
renaming is safe for a statically typed program, because the compiler can see
every access. It is not safe for loosely typed `Object` and `*` values, which is
exactly what JSON is. Two things broke, both reproduced in isolation:

- An object literal's keys were renamed at compile time. `{room: "a"}` went out
  on the wire to Convex as `{"g":"a"}`. The optimiser had rewritten the
  *protocol*.
- A dot-notation read on a dynamic value was renamed to a *different* mangled
  name than the key it was meant to read, so `command.protocolVersion` returned
  `undefined` against an object whose real key was untouched.

Fixing the first surfaced the second, which existed at more than ten sites in
one file alone and very likely across eight more. Every fix is mechanical —
bracket notation instead of dot notation — but there is no way to know you have
found them all, and each round trip needs a full build.

The lesson is about where the boundary of your program actually is. **A build
step that rewrites identifiers is part of your program's semantics, even though
nothing in your source mentions it.** The client's own logic was correct. It was
compiled into something that was not.

## 21. The security boundary held, and it cost real time

Halfway through the night a worker was sent a message correcting its plan and
telling it the fleet had idle machines it could expand onto. It refused. Its
reasoning, quoted from its report, was that the message arrived mid-session
claiming to be from the coordinator, instructed it to push code to hosts that
were never in its original authorisation, and justified itself with a claim
about its own tooling that it could not confirm. So it carried on with only the
host it had been given, and flagged the message for review rather than acting
on it.

The message was genuine, and the refusal cost several hours of parallelism.

It was still the right call. An agent that will expand its own blast radius
because a message told it to is an agent that will do so when the message is
hostile, and every property that makes this project's evidence trustworthy —
one machine per worker, one verification at a time, evidence tied to an exact
clean commit — depends on workers not quietly widening their own scope. The
same suspicion appears elsewhere in this project: a worker refused to widen a
listening socket from loopback to all interfaces until a human reviewed and
approved the change, which was also correct, and the change was approved.

What the incident actually shows is that **authority has to travel through the
channel the worker was told to trust, not through the content of a message.**
Instructions embedded in something an agent reads are data. The fix is not to
teach workers to be more credulous; it is to give them a briefing complete
enough that mid-flight expansion is rarely needed, and to make the legitimate
channel unambiguous when it is.

## 22. The safety check that could not fail, three times over

The project's central claim is that every language ships a minimal runtime
image: no compiler, no package manager, no shell toolbox, nothing but what
serving Convex traffic requires. Each language's Dockerfile ends with a loop
that proves it:

```sh
for command_name in gcc cc clang make ld as apt apt-get dpkg curl wget \
    node python python3 rustc cargo npm pip convex busybox; do
  ! command -v "$command_name" >/dev/null 2>&1
done
```

Read it and it looks airtight. It cannot reject anything, for three independent
reasons, any one of which alone would be enough:

1. **A `for` loop's exit status is only its last iteration's.** POSIX says so
   plainly. Twenty of those names are evaluated and thrown away. The only one
   genuinely asserted absent is `busybox`, because it happens to be last.
2. **`set -e` does not apply to a pipeline beginning with `!`.** Also POSIX,
   also explicit. So even as a standalone statement, `! command -v gcc` never
   aborts a build.
3. **In at least one image, `command` did not exist.** That client builds a
   purpose-trimmed BusyBox without the `cmdcmd` applet, so `command` was
   neither a builtin nor on disk and every lookup returned 127 — "not found",
   which `!` obligingly turned into success.

Thirty-three merged languages carried some version of this. The correct form
was already in the repository — one client wrote `! command -v "$name" || exit
1` — so this was not ignorance, it was a broken shape getting copied from
neighbour to neighbour faster than the working one.

Two things make this worth a slide rather than a footnote. First, it is the
same failure as the never-failing unit tests earlier in this document, in a
completely different language and layer: **a check nobody has ever seen fail is
indistinguishable from a check that cannot fail, and the only way to tell them
apart is to break something on purpose and confirm it screams.** Second, it was
found by reading, not by running. No verification run would ever have surfaced
it, because the symptom of a vacuous check is that everything passes.

There is a real question underneath, and honesty requires separating it from
the defect: were the images actually clean? The gate being broken does not by
itself mean anything got through it. So it was measured — all thirty-three
images built, and the check run the way it should have been written.

**Twelve of the thirty-three leaked.** This was not a paperwork problem.

Seven of them — cpp, crystal, dart, elixir, go, pony and rust — are built
`FROM` the stock BusyBox image, which ships `httpd`, `ftpd`, `inetd`, `wget`,
`nc`, `telnet`, `ar`, `dpkg` and `rpm` as applets. So an image described as
containing nothing beyond what serving Convex traffic requires contained a web
server, an FTP daemon and two network clients. Perl leaked into three images
that declare Node as their runtime and into one that has nothing to do with
Perl.

The best detail is rust's. Its Dockerfile reads `FROM ${BUSYBOX_IMAGE} AS
runtime-base`, and five lines later its policy loop lists `busybox` among the
commands it asserts are absent. **The image asserted the absence of the thing
it was built on.** That is not a check that failed to notice a leak; it is a
check whose success was impossible to reconcile with the file directly above
it, and nobody noticed because it never spoke.

A second sweep then covered the forty-two merged languages the first audit had
not reached, and found six more: bash, c, php, csharp, rescript, and — worst of
the lot — hare, which had been merged that same night and shipped fourteen
BusyBox applets including an FTP daemon and a web server.

That brings it to **eighteen leaking out of seventy-five checked**, and the
distribution is the point. They fall into exactly two shapes: a runtime built
`FROM` the stock BusyBox image, or a Debian base that was never stripped. This
is not a scatter of individual mistakes. It is two wrong patterns, each copied
faithfully across many languages, with a check that could not object.

Three things follow, and the third is the one worth arguing about:

1. The check now lives in the shared harness, once, where it cannot be copied
   wrong — rather than as a stanza pasted into a hundred Dockerfiles.
2. It reads the image's filesystem listing through `docker export` instead of
   running a shell inside the image. Three of the leaking images turned out to
   have no usable `printf`, `echo` or `command` at all, which is precisely how
   an in-image check becomes unreliable in the images that need it most.
3. Finding this *late* was expensive, and it was found only because someone
   asked whether a passing check had ever actually rejected anything. That
   question is cheap and almost never asked. **The audit that matters is not
   "do the checks pass" but "has any check here ever failed, and can I make it
   fail on purpose right now?"**

## 23. Miscellaneous findings worth a slide

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
- A minimal image reported `awk: not found` while `awk` was still sitting in
  `/usr/bin`. Debian points `/usr/bin/awk` at mawk through `/etc/alternatives`,
  and the prune deleted that directory. The allow-list had carefully preserved
  both `awk` and `mawk` by name — and left the first as a dangling symlink.
  Preserving a *name* is not preserving a *program*.
- For a young language, the fastest route was reading the standard library's
  source. Mojo 0.26.2's stdlib does not match anything a model has been trained
  on: `sys.ffi` moved to `std.ffi`, `alias` became `comptime`, `UnsafePointer`
  grew mutability and origin parameters and lost `.alloc`, and string slicing
  now needs an explicit `[byte=a:b]`. Guessing costs an afternoon of
  compiler-error ping-pong. Cloning the compiler's own repository at the tag
  matching the installed release, and reading it, costs minutes. There is also
  a trap worth naming: `external_call["write", …]` fails to compile because
  `print` has already instantiated the standard library's own declaration of
  `write`, and yours must match its signature exactly.
- Ballerina's platform betrayed it twice, in two different libraries. The known
  defect was `ballerina/websocket` corrupting multi-byte UTF-8 split across a
  continuation frame, fixed by not using it — hand-rolled RFC 6455 over a raw
  socket, the same route a dozen clients here already take. The second was
  found only by testing against the real hosted deployment: **`ballerina/tcp`'s
  TLS client never sends SNI.** That was confirmed by disassembling the
  library's own native jar and seeing it call Netty's single-argument
  `SslContext.newHandler(ByteBufAllocator)` rather than the host-aware
  overload. Convex's hosted deployment sits behind Cloudflare, which requires
  SNI, so every handshake died with a fatal alert. `ballerina/http` is
  unaffected, because its Netty wiring does pass the host through — the same
  runtime, two TLS paths, one of them wrong.
- The fixture was too polite again, in a new way. Ballerina's handshake reader
  decoded its whole read buffer as UTF-8 looking for the end of the HTTP
  headers. That works until a server pipelines its first binary frame straight
  after the `101` response — which the real backend does and no local fixture
  ever did. Every local test passed; the first real connection failed.
- EiffelStudio miscompiles its own output past a certain size. Bundle enough
  classes with inline-C bodies into one translation unit and the generated
  C file comes out one `#include` short, so gcc reports the last class's
  functions redeclared with conflicting linkage. The workaround is to put the
  TLS and socket calls in an ordinary separately-compiled C file instead —
  which is the same C-interop boundary every other native client here uses, so
  nothing is lost. Separately, Eiffel's incremental "workbench" runtime reports
  an ordinary `EINTR` as a fatal operating-system-signal exception; only the
  finalised build behaves.
- SNOBOL4 exited 0 and printed nothing, and both facts were correct. Its C
  shim called `_exit()`, which skips libc's stdio flush. Under Docker stdout is
  a pipe, not a terminal, so it is fully buffered — the transcript was sitting
  in a buffer that was never drained, and every test had missed it because
  tests write to unbuffered stderr. The documented remedy, closing the output
  unit from SNOBOL, was tried and *empirically did not work*: it updates the
  interpreter's own unit table without ever reaching the OS. The fix was
  `fflush(NULL)` before `_exit()`. **A success with no output is a bug report,
  not a pass** — and it only appeared after an earlier fix let the program
  reach its success path for the very first time.
- BCPL crashed because a pointer no longer fits in a word. Its 32-bit Cintcode
  interpreter stores a raw C pointer — the `FILE*` returned by `fopen()` — in a
  32-bit BCPL word. On a 64-bit host that address routinely lands above 2^32,
  so the low half alone is not a pointer, and the crash happened inside the
  distribution's own runtime before a line of client code ran. It reproduces on
  the unmodified compiler with nothing linked in. Targeting the distribution's
  64-bit Cintcode, whose word is wide enough for a real pointer, fixes it.
  BCPL is from 1967, when a word held an address by definition; the assumption
  is older than the problem.
- Typelessness has a bill, and it arrives late. BCPL does not check argument
  counts, so a mismatch between a function and its two callers went unnoticed
  until the toolchain worked for the first time — at which point it silently
  read stack poison (`0xDEADC0DE`) and crashed a coroutine. Code that has never
  executed has never been checked, in a language that never checks.
- The unfixable client bug was two bugs in the test fixture. SNOBOL4's
  WebSocket reconnection looked genuinely broken and unsalvageable. It was the
  fixture: a resubscribed value collided with an already-delivered one, which
  defeated the client's own — correct — deduplication, and an unconditional
  return swallowed an accept timeout. This is now the fourth time in this
  project that a confident diagnosis of "the client is wrong" turned out to be
  the harness, the fixture, or the reference implementation. **When the code
  under test looks impossibly broken, suspect the thing doing the testing.**
- A self-test paired the client against a server that never answers. V's
  Dockerfile proves its TLS closure works by talking to `openssl s_server -www`
   — which replies to a GET immediately and to a POST not at all. The client
  sends a POST. The stage could therefore never pass, no matter how correct the
  client was, and `strace` confirmed the handshake and the request were both
  fine. Worse, the permanently-failing test was masking a real bug underneath
  it: a 20-second deadline that never fired, leaving a blocking read sitting
  indefinitely. **A test that always fails hides bugs exactly as effectively as
  a test that always passes** — this document already has a section about the
  second kind, and the first kind is rarer only because someone usually
  deletes it.
- One character silently downgraded every secure connection. Icon's scheme
  detection compared against `"https"` where the parsed value was `"https:"`,
  so every `wss://` subscription quietly opened as plain `ws://` — and the
  visible symptom was a Cloudflare 301 redirect, which looks like a routing
  problem, not a security one. The same off-by-one was duplicated in the
  example and the adapter.
- A timeout set once and never cleared crashed Factor. Its outbox writer put a
  five-second write timeout on the shared controller socket and left it there,
  so any idle gap longer than five seconds between commands raised an uncaught
  `io-timeout` and took the whole adapter down through Factor's default `die`
  handler. It presented as a hosted-only failure and was assumed to be a TLS or
  network-variability problem; it reproduced locally too, once someone waited
  long enough. **"Only fails against the real thing" is a hypothesis, not a
  diagnosis.**
- gm2 passes large `ARRAY OF CHAR` parameters by value on the stack. Modula-2's
  `CopyText` took its source by value, and three 2 MiB call sites blew the
  stack during module initialisation — before `main()`, so nothing printed. The
  crash then masked two further bugs, a missing `/api/sync` path and a UUID
  off-by-three, which only appeared once it stopped faulting.
- OpenSSL needs files that `ldd` will never tell you about. Two languages
  passed every local check and then failed the hosted profile with `SSL
  routines / STORE routines::unregistered scheme`. The build stage has a full
  OS, so `openssl.cnf` and the `ossl-modules/*.so` providers are simply there;
  the stripped runtime image carries neither, and `SSL_CTX_set_default_verify_
  paths` needs both at connect time. A closure computed from `ldd` cannot find
  them, because they are not shared-library dependencies of anything — they are
  data and dlopened plugins. **A dependency closure is only as complete as the
  definition of "dependency" you used to build it.**
- A zero was mistaken for the end of a string. The Live protocol's timestamp
  can legitimately be all-zero bytes, and base64 `"AAAAAAAAAAA="` decodes to
  exactly that. Carried through any NUL-terminated string type — Mercury's
  `string`, or anything reached over a C-string FFI — it silently became a
  zero-length value. Both languages hit it independently. The fix is to decode
  straight to an integer in C and never let the raw bytes exist as a
  language-level string at all.
- A stack trace pointed at the garbage collector and the bug was a missing pair
  of parentheses. Mercury reported "caught strange segmentation violation",
  which looks exactly like a Boehm-GC problem. The cause was calling a 0-arity
  Mercury function exported to C without its parentheses: C reads that as a
  function-pointer value, compiles it silently, and corrupts everything
  downstream.
- The local profile cannot catch a TLS bug, and twice in one night it didn't.
  The self-hosted backend is plain `http://`, so a client with an empty or
  misplaced trust store passes every local check and fails only against the
  real deployment. Icon deleted Debian's OPENSSLDIR and never recreated it.
  FreeBASIC's OpenSSL had a compiled-in `OPENSSLDIR` of `/usr/lib/ssl` while
  the CA bundle was copied to `/etc/ssl/certs`. Same symptom, different cause,
  and neither is visible until the profile that uses TLS runs. **A test suite
  that never exercises a dependency cannot report anything about it** — which
  is the whole argument for the hosted profile existing at all.
- COBOL's compiler disagreed with COBOL's standard about a self-copy. A buffer
  ended up simultaneously the source of a parse call and the destination of
  another `REDEFINES` — a copy from an address to itself. The standard implies
  a no-op; GnuCOBOL corrupted the data, and the first casualty was the
  `protocolVersion` of the very first message. Undefined behaviour is not
  always dramatic; sometimes it is one field, in one message, at startup.
- FreeBASIC segfaulted only against the real backend. `dmesg` put the fault
  inside libc with the address a few bytes from the stack pointer — a stack
  overflow. `ThreadCreate`'s default stack was too small for the Live thread's
  real call chain, and the local fixture's smaller responses never went deep
  enough to reach it. The bug was in the client the whole time; the test data
  was just too polite to find it.
- A default file mode made an image unbootable, twenty-two layers later. Nim's
  runtime stage swaps `/usr/lib/x86_64-linux-gnu` for a trimmed closure using a
  small Perl copier, because the process doing the swap cannot depend on the
  directory it is replacing. Perl's `open($to, '>')` creates at 0666 minus
  umask, and BuildKit's umask is 0022, so every copied file landed at 0644 —
  including `ld-linux-x86-64.so.2`, which `ldd` reports as part of a binary's
  dependency closure. Shared libraries `dlopen` perfectly well without the
  execute bit. An ELF *interpreter* does not: the kernel loads it through the
  same `MAY_EXEC` check as the binary itself. So the copy succeeded, the stage
  succeeded, and three layers later `/bin/sh` could not be executed at all.
  The error named a file that was never touched.
- Unison could open the socket and still could not be built. The proof was
  real: a certificate-verified TLS handshake against a public host and a
  decrypted `HTTP/1.1 200 OK` read back, from Unison source, with the socket
  functions confirmed as genuine runtime builtins. It failed on the other axis
  entirely — the only route to the standard library is a build-time round trip
  to one hosted third-party service, because the git-remote syntax has been
  removed from the parser and the GitHub mirror is deprecated. The builtins
  underneath are still there, but they are addressable only by content hash,
  and there is no offline way to learn a hash without first asking the service
  that knows the name. A language where nothing has a name until something
  tells you what the hashes are called cannot be built hermetically.
- The framework was larger than the budget, and then the interpreter was too.
  Raku's client loaded in about 200 MB against a 128 MiB limit, and roughly
  140 MB of that looked like `Cro::HTTP::Client` — the framework, not the
  client. So the transport was hand-rolled onto plain sockets, which worked and
  saved a real 20–25 MB. It was still not enough, and the bisection that
  followed is the actual lesson: `raku -e 'say 1'`, with **zero** project code
  loaded, holds 134–140 MB. The budget was already spent before the program
  started. Every earlier measurement had been attributing to the library what
  belonged to the runtime, because nobody had measured the empty case first.
  **Measure the floor before optimising the building.**
- V's `net.ssl` verified nothing. Passing `validate: true` looks like it turns
  certificate checking on, but vlib loads a trust store only when a separate
  `verify` field names one, and it never calls
  `SSL_CTX_set_default_verify_paths`. The context is left with no CA at all, so
  every handshake fails — and the image's `SSL_CERT_FILE` is not consulted,
  because vlib does not read it. The flag named after the security property was
  not the flag that supplied it.
- A library copied by `cp -a` arrived as a dangling symlink. `ldd` reports the
  SONAME, `libgmp.so.10`, which on Debian is a symlink to `libgmp.so.10.4.1`;
  `cp -a` preserves symlinks rather than following them, so the pointer was
  staged and the file it pointed at never was. Six libraries in that image were
  dangling. Three others happened to be real files rather than symlinks, which
  is the only reason the image got far enough to fail informatively.
- Two Pharo defects were stacked, and the first completely hid the second. Only
  after the image stopped crashing at boot did anything reach the adapter's
  listening socket, which then failed every `accept()` because the listen
  backlog was 1. Fixing a bug is also how you find the next one.
