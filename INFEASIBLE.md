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
| mql5 | Runs only inside the proprietary Windows MetaTrader terminal. |
| rpg | IBM RPG compilers exist only on IBM i systems; no free Linux toolchain. |
| sas | Proprietary licensed runtime; no free implementation of the real language. |
| scratch | Block-based GUI language with no network primitives; a Convex client cannot be expressed in Scratch itself. |
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
| 3 | matlab | **Futhark** | futhark | A purely functional array language that compiles to GPU code. Its FFI story makes the transport boundary genuinely interesting. |
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

Held in reserve, if actionscript or logo cannot be recovered:

- **Pop-11** (Poplog) — the British AI language, an incremental compiler whose
  virtual machine also hosts Prolog, Common Lisp and ML inside the same image.
  Strange in a way no modern language is.

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
