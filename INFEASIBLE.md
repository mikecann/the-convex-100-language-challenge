# Languages that cannot be built honestly inside this project

The project's rules require every client to build, test, and verify inside
Docker on `linux/amd64`, with no proprietary licenses baked into images and no
GUI-only toolchains. The following roster entries cannot meet that bar. They
are recorded here rather than quietly dropped, and each needs a replacement
language so the roster still reaches one hundred.

## Infeasible — proprietary license, hosted-only, or GUI-only toolchain

| Language | Why it cannot be done here |
| --- | --- |
| apex | Executes only inside Salesforce's hosted platform; no local runtime exists. |
| labview | Proprietary NI graphical environment; no headless Linux compiler, license required. |
| matlab | Proprietary license required for the real MATLAB runtime; substituting GNU Octave would not honestly be MATLAB. |
| mql5 | Runs only inside the proprietary Windows MetaTrader terminal. Replaced by Hare, which is merged and evidenced. |
| rpg | IBM RPG compilers exist only on IBM i systems; no free Linux toolchain. Replaced by Modula-2, which is merged and evidenced. |
| sas | Proprietary licensed runtime; no free implementation of the real language. |
| visual-foxpro | Discontinued proprietary Windows product; no Linux toolchain. |
| xojo | Proprietary licensed IDE-bound compiler. |
| xpp | Microsoft Dynamics X++ executes only inside the hosted Dynamics platform. |

## Infeasible — no way to reach a socket from the language itself

These were assessed in a second sweep. Each was independently challenged by a
second reviewer arguing the opposite case; the verdicts below are what survived.
A client for any of them would be a bridge — a helper process doing the real
work while the language does something incidental — which this project rejects,
for the same reason PostScript was declined earlier on this page.

| Language | Why it cannot be done here |
| --- | --- |
| bc | Its entire outside world is a numeric stdin and a text stdout. No file handles, no `dlopen`, no FFI of any kind, so a socket could only ever be an external process. |
| solidity | The EVM has no I/O opcode and Solidity has no `extern`. A socket would have to be an invented precompile inside a foreign host program. |
| abap | No socket API and no public FFI even on a licensed SAP AS ABAP. The free open-abap route opens its sockets by embedding literal JavaScript inside `WRITE '@KERNEL …'` string literals, which is JavaScript doing the work, not ABAP. |
| elm | Elm has no socket type and no foreign *call* — only asynchronous JSON ports. Transport, stdio and the adapter listener would all live in hand-written JavaScript, leaving Elm as a message formatter. This is the PostScript ruling applied consistently. |
| cfml | Lucee, the real open CFML engine, exceeds the 128 MiB container limit and needs to unpack `.lco` files into a writable temporary directory the read-only runtime cannot provide. BoxLang clears the harness cleanly but is a different language that is merely CFML-compatible — substituting it would be the same move as substituting GNU Octave for MATLAB, already rejected above. |
| futhark | The toolchain itself is fine — `futhark` is a free, single Debian package (`apt install futhark`) that installs unattended and compiles in seconds. The language is the problem: Futhark has no I/O primitives at all, by design. `futhark c --library` emits only a numeric marshaling C API (`futhark_context`, entry points over arrays, tuples and opaque records via `futhark_new_opaque_*`/`futhark_project_opaque_*`); the non-library `futhark c` mode's standalone executable is entirely a compiler-generated CLI for Futhark's own benchmarking data format (`--runs`, `--entry-point`, `-b/--binary-output`) with no flag, hook, or extension point that touches a file descriptor, let alone a socket. There is no `extern`, no FFI directive, nothing a `.fut` source file can write to request one. The only honest structure is a C host program that owns every socket, TLS handshake and WebSocket frame while calling into Futhark for something incidental — a bridge, not a native client, exactly the shape this project has already declined for PostScript, bc and elm above. |

## Infeasible — no reproducible, non-interactive build reachable

Unlike the table above, this entry's language genuinely reaches a real socket
from its own source, natively. It is recorded separately because that is not
where it fails: it fails this project's Docker-only, hermetic-build rule, in a
way none of the other entries on this page do.

| Language | Why it cannot be done here |
| --- | --- |
| unison | The socket and TLS claim was fully proven, not just documented. Running non-interactively inside a bare `debian:trixie-slim` container on linux/amd64 via `ucm run.file` (piped stdin, zero prompts; `ucm --codebase-create` boots headless), the expression `Connection.tls (HostName "example.com") (Port "443")` opened a real TCP connection, completed a certificate-verified TLS handshake against a public host, sent a plaintext HTTP GET over it, and printed back a genuine decrypted `HTTP/1.1 200 OK` response — a full round trip, on `ucm` release/1.3.0 (built 2026-05-13). `IO.net.Socket` and the functions underneath `Connection.tls` are confirmed `builtin` (e.g. `builtin lib.unison_base_7_19_2.IO.net.Socket.client.impl`), i.e. real runtime primitives, not a foreign-process shim. What kills the entry is reproducibility, not capability: `Socket`, `Connection.tls`, and every ergonomic helper this used — even `HostName`, `Port`, and `Text.toUtf8` — live in the `base` library, and the only route to `base` in the current toolchain is `lib.install`/`pull` against `@unison/base/releases/...` on Unison Share (confirmed: `help pull` and `help lib.install` in ucm 1.3.0 document only that Share project syntax). The historical git-remote pull syntax (`pull https://github.com/user/repo:branch .path`) has been removed from the parser — attempting it now is a parse error. The `unisonweb/base` GitHub mirror is explicitly marked deprecated by Unison Computing itself ("Unison code hosting for this library has migrated to Unison Share"), so it is not a usable offline substitute either. The raw compiler builtins underneath `base`'s wrappers are real, but they are addressable only by content hash, not by name, and there is no local or offline way to discover those hashes without first consulting a codebase that has already resolved names through a Share pull; a guessed bare reference to one (`##IO.socketSend.impl`) was rejected by the REPL as unknown, confirming FFI-level builtins carry no special parser syntax the way ability types like `##IO` do. Every Dockerfile path to a working client therefore needs a `docker build`-time (or, if deferred, a container-start-time) network round trip to one hosted third-party service outside this project's control — exactly the "network access to Unison Share at build time" failure this candidate was explicitly held to before acceptance. Futhark's vacated slot (slot 3, replacing matlab) is therefore still open. |

## Infeasible — toolchain rejected by this project's container security posture

This candidate reaches neither the socket gate nor the toolchain gate cleanly:
its own bootstrap binary cannot run at all under this project's Docker
constraints, at build time or run time, for a reason that has nothing to do
with the language.

| Language | Why it cannot be done here |
| --- | --- |
| pop11 | Poplog (the toolchain behind Pop-11, held in reserve for this slot pending Seed7) bootstraps every further build stage from a "corepop" binary — a fixed-address heap image inherited from a 1980s VM design — that calls `personality(ADDR_NO_RANDOMIZE)` before it can load. Docker's default seccomp profile rejects that specific flag value; this project's `./run` script never passes a custom `--security-opt seccomp=`, so both `docker build` (BuildKit's own RUN sandbox) and every `docker run` this project performs use that same restrictive default. The result under it is not a permission error but a crash — `MEMORY ACCESS VIOLATION` — reproduced directly against all five corepop images GetPoplog ships (`010` through `050`, spanning 2012–2021 builds); `--security-opt seccomp=unconfined` makes the identical binary succeed immediately, and that flag is unavailable both inside this project's hermetic build and inside the read-only, capability-dropped runtime container the shared verifier launches. GetPoplog's own repository ships a bespoke `docker/poplog_seccomp.json` profile and a "Running poplog under Docker" wiki page for exactly this reason — a documented, upstream-acknowledged constraint of the toolchain under containers, not a one-off flake or a fixable Dockerfile mistake. |

## Infeasible — the runtime's own footprint exceeds the container limit

The only entry on this page ruled out on resource footprint rather than
capability. Both the language and the client are sound: a complete hand-rolled
client exists and passes its language-local suites, including five reconnect
cycles. It is the interpreter that does not fit.

| Language | Why it cannot be done here |
| --- | --- |
| raku | Every runtime container in this project is limited to 128 MiB, uniformly across all hundred languages. Three removable layers were stripped in turn and measured by cgroup bisection under `docker run --memory N --memory-swap N`, five trials per side. **Cro**: replacing `Cro::HTTP::Client`/`Cro::WebSocket` with hand-rolled HTTP/1.1 and RFC 6455 over `IO::Socket::INET` cut the total from 190–210 MiB to 170–185 MiB — a real 20–25 MiB, and the client still worked. **Rakudo Star**: a bare Rakudo 2026.07 built from source, compiler and VM only, has a floor of 106 MiB for `raku -e 'say 1'` versus 134–140 MiB for the Star bundle, confirming that most of the original cost was the bundled modules rather than the interpreter. **Every external module**: binding libssl and libcrypto directly through `NativeCall`, which is core to Rakudo and needs no distribution, and hand-rolling JSON, base64, SHA-1 and randomness, was measured against a real TLS handshake and HTTP round trip to the hosted deployment — 145–170 MiB with zero Convex code loaded. That last figure also corrected an earlier, flattering 140 MiB reading taken from a probe that loaded the TLS module but never opened a connection. MoarVM offers no nursery or heap-size environment variable (`MVM_NURSERY_SIZE` is a compile-time `#define`), and its one memory-relevant tunable, `MVM_SPESH_DISABLE`, is worth about 15 MiB and was already shown to make the real WebSocket workload too slow to complete. After removing every removable layer the floor is still 17–42 MiB over budget before a single line of client code runs. The hand-rolled transport work is preserved on branch `fix/raku-rp2` should the limit or the runtime ever change. |

## Infeasible — license or GUI gate (ruled, previously borderline)

Michael's ruling: entries requiring a proprietary license or a GUI toolchain are
not built. Recorded here rather than left open.

| Language | Why it cannot be done here |
| --- | --- |
| wolfram-language | The free Wolfram Engine requires Wolfram-ID activation or a metered cloud entitlement, forbids redistribution inside images, and wants a writable password file plus live egress on every kernel start. |
| q | Technically excellent — kdb+ has had a built-in WebSocket client since 2014 — but every route to the binary needs a KX account, an OAuth2 bearer token and a per-user `kc.lic` license file. |
| gml | GameMaker refuses to emit a binary without an interactive IDE sign-in, its Linux export is an OpenGL/X11 game runner rather than a headless program, and `external_define` has no Linux shared-object path. |

## At risk, not yet abandoned

| Language | State |
| --- | --- |
| actionscript | Nine real defects fixed; blocked on Apache Royale's Closure Compiler pass renaming JSON object keys on the wire, which rewrites the protocol itself. The fix is mechanical — bracket notation at every dynamic access — but spans an unknown number of call sites. |
| logo | Lhogho's `libload`/`external` is a genuine `dlopen` FFI, and `socket()`/`connect()` were driven successfully from Logo source. But it is 2012-era i386 abandonware, and this project has already learned what emulated architectures do to trust in a result. |

## Chosen replacements

Eleven entries are infeasible, so eleven replacements are needed to keep the
roster at one hundred. These were selected against four criteria: a free
toolchain that installs unattended in Docker, enough of a standard library or C
FFI to reach a socket and speak TLS, a genuine claim on a viewer's interest, and
variety across eras and paradigms rather than eleven more curly-brace
languages.

| # | Replaces | Language | Toolchain | Why it earns a slot |
| --- | --- | --- | --- | --- |
| 1 | apex | **Rexx** | Regina Rexx | The scripting language of mainframes, OS/2 and Amiga. Ubiquitous for two decades, near-invisible today. |
| 2 | labview | **Emacs Lisp** | Emacs batch mode | A Convex client inside a text editor's extension language. Emacs has real network primitives and TLS, so this is honest, not a stunt. |
| 3 | matlab | ~~Futhark~~ → see below | — | Futhark itself turned out infeasible once actually tried; see the "no way to reach a socket" table above and the note below the table. |
| 4 | mql5 | **Hare** | hare | A deliberately small systems language, self-hosted, no runtime. Modern, obscure, and a fair test of doing everything by hand. |
| 5 | rpg | **Modula-2** | GNU gm2 | Wirth's successor to Pascal, and a GCC front end, so it builds anywhere GCC does. Direct historical line from the Pascal family already on the roster. |
| 6 | sas | **Icon** | Unicon | Griswold's goal-directed evaluation with backtracking built into the language. Unlike anything else here. |
| 7 | scratch | **SNOBOL4** | CSNOBOL4 | 1962, and still the most distinctive pattern-matching model ever shipped. The oldest language in the project. |
| 8 | visual-foxpro | **Mercury** | mercury | Logic programming with strong static types and a real module system — Prolog's ideas taken seriously. |
| 9 | xbasepp | **Oberon-07** | OBNC | Wirth's final, radically minimal language. A whole client in a language whose report fits in sixteen pages. |
| 10 | xojo | **ALGOL 60** | GNU MARST | 1960, and the ancestor of nearly everything else on this roster: block structure, lexical scope, recursion and BNF all arrive here. The oldest language the project adds, and older than every entry except Fortran, Lisp and COBOL, which it predates in influence if not in date. |
| 11 | xpp | **ATS** | ats2 | Dependent types over C, proving memory safety at compile time. The most demanding type system in the project. |

Deliberately not chosen, and why:

- **PostScript** (Ghostscript) — a page-description language with no sockets;
  a client would have to be almost entirely foreign calls, which earns the
  bridge label rather than a native one.
- **Koka**, **Red** and **Roc** — all interesting, but young enough that pinning
  a reproducible Docker build is a project of its own. Roc was originally chosen
  and then displaced by ALGOL 60, which is both more interesting and, being
  finished in 1960, not going to move under us.
- **ALGOL 68** (Genie) — the packaged build has no networking primitives at all,
  so a client would need an external transport process and would earn the bridge
  label rather than the native one. ALGOL 60 via MARST avoids this because MARST
  translates to C, where a small socket and TLS boundary is normal for this
  project.

If any chosen language proves infeasible once its toolchain is actually pinned
in Docker, it moves to the table above with its reason recorded, and the next
candidate takes the slot.

Futhark (slot 3, replacing matlab) is the first case of this: confirmed
infeasible after actually pinning the toolchain and reading the generated C
API, moved to the "no way to reach a socket" table above. Hare (slot 4,
replacing mql5), tried in the same session, succeeded and is evidenced
separately.

**Unison** (the content-addressed functional language from Unison Computing,
not the unrelated Benjamin Pierce file-synchronization tool of the same
name) was tried for Futhark's now-open slot and, unlike Futhark, cleared the
socket-and-TLS proof cleanly — see the "no reproducible, non-interactive
build reachable" table above for the demonstrated TCP+TLS round trip. It is
ruled infeasible anyway, on a different axis: the language's entire standard
library, including the ergonomic `Socket`/`Tls` API that proof used, ships
only through Unison Share, and the current `ucm` (release/1.3.0) has removed
the old git-remote pull path that used to make that optional. There is no
way to reach a hermetic, non-interactive Dockerfile build for it. Slot 3
(matlab → Futhark → Unison) is still open and needs a further candidate.

## Second replacement round

The sweep above ruled out eight more entries, so eight more replacements are
needed. The same four criteria apply: a free toolchain that installs unattended
in Docker, a genuine socket and TLS route the language's own code drives, a real
claim on a viewer's interest, and variety across eras and paradigms. Slot
mapping is cosmetic — the slots are fungible.

| # | Replaces | Language | Toolchain | Why it earns a slot |
| --- | --- | --- | --- | --- |
| 12 | q | **APL** (1966) | GNU APL | The glyph language itself rather than a descendant. `⎕FIO` exposes socket, connect, send and recv, with user-compiled native functions as the sanctioned OpenSSL path. Recovers the array-language slot the KX signup form took. |
| 13 | abap | **MUMPS / M** (1966) | YottaDB | Opens its own TCP with no FFI at all — `OPEN d:(CONNECT="host:port:TCP")` — and negotiates TLS through a bundled OpenSSL plugin. Still runs a large share of the world's hospital records, which is the enterprise-invisibility story ABAP was going to tell. |
| 14 | bc | **Simula 67** (1967) | GNU Cim | Classes, objects, inheritance, virtual methods and coroutines were all invented here. Cim compiles to C and supports `external C procedure`, the same build shape as the ALGOL 60 entry that already succeeded. |
| 15 | solidity | **VHDL** (1983) | GHDL, VHPIDIRECT | A hardware description language, DoD-commissioned like Ada, that GHDL compiles to a standalone native executable. The strangest honest entry available, and the mirror image of Solidity's failure: the wrong kind of machine that turns out to have a door. |
| 16 | gml | **Oz** (1995) | Mozart 2 | Dataflow variables, constraint programming, and a concurrency model unlike anything else on the roster. `Open.socket` is native. The *Concepts, Techniques and Models* language that almost nobody has run. |
| 17 | wolfram-language | **SETL** (1969) | GNU SETL | Sets and tuples as the primitive data types, and the language NYU used to prototype the first Ada compiler — the mathematically-founded slot Wolfram was going to fill, at a fifth of the age. |
| 18 | elm | **Dylan** (1992) | Open Dylan | Apple's Lisp-with-syntax, built for the Newton and then killed. Multimethod dispatch and a real macro system behind ALGOL-ish syntax, with `define C-function` for the transport boundary. A functional slot that is genuinely dead rather than merely unfashionable. |
| 19 | cfml | **Harbour** (xBase, 1985 lineage) | Harbour | Restores the xBase family the project lost twice, to visual-foxpro and xbasepp, honestly and for free. The language behind a decade of DOS business software, compiling straight to C so the socket and TLS boundary is routine. |

Slot 3 (originally matlab) has now defeated two candidates: Futhark, which
cannot reach a socket at all, and Unison, which reaches one perfectly but
cannot be built without a network round trip to a hosted third-party service.
The third candidate is chosen against both failures at once:

- **Seed7** (Thomas Mertes, 1989 onward) — an extensible language whose syntax
  and operators are defined in the language itself rather than fixed by the
  compiler, so its own standard library reads like a grammar. It is the right
  answer to both prior failures: `s7` builds from a plain source tarball with
  gcc and no network dependency at run or build time, and its standard library
  ships `socket.s7i` and TLS support natively, so neither gate is in doubt the
  way Futhark's and Unison's were. Both gates have now been verified directly,
  not just documented: the toolchain builds unattended from the pinned
  `seed7_05_20260711` source tarball in well under a minute, and Seed7's own
  `openInetSocket`/`openTlsSocket` completed real HTTP and TLS 1.2 round trips
  (the latter through a from-scratch, non-OpenSSL TLS stack in
  `tls.s7i` — handshake, AES-GCM, HMAC, elliptic-curve key exchange, X.509
  parsing, all in Seed7 itself). A client is in progress on
  `codex/seed7-client`.

`Pop-11` (Poplog), held in reserve for this slot, was tried once Seed7's own
gates cleared and turned out infeasible for a reason specific to this
project's container security posture rather than the language; see the new
"toolchain rejected by this project's container security posture" table
above for the evidence.

Raku's slot, vacated on footprint rather than capability, is filled by:

- **Clean** (Nijmegen, 1987) — a pure lazy functional language whose
  *uniqueness types* let the compiler prove a value has exactly one live
  reference and therefore mutate it in place without breaking referential
  transparency. That is the ownership reasoning Rust made famous, arriving
  roughly twenty-five years earlier and largely unread outside its university.
  The toolchain is free, compiles to a native binary through its own ABC
  machine, and has a real C foreign-function interface for the transport
  boundary. It also answers Raku's failure directly: a compiled native binary
  has no interpreter floor to pay before it starts.

Considered in this round and not chosen:

- **Limbo** (Inferno) — Bell Labs 1995, the direct ancestor of Go, and
  `sys->dial` is native. Rejected because Inferno's security stack is its own
  Keyring design rather than X.509 TLS, so the transport would need a foreign
  process.
- **Miranda** — now BSD-licensed and Haskell's direct ancestor, but it has no
  FFI at all: the same failure shape as `bc`.
- **Occam-π** — CSP and the transputer, but the toolchain is fragile enough that
  pinning a reproducible build is a project of its own.
- **Modula-3** — good language and real C interop, but modula-2 and oberon are
  already in flight and a third Wirth-family entry buys no variety.
- **CLU** — Liskov's, and the origin of iterators and exceptions, but the
  surviving compiler is old enough that "does it build" would be the whole
  project.
