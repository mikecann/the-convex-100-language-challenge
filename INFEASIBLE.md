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
| xbasepp | Commercial Windows-only Alaska Xbase++ compiler. |
| xojo | Proprietary licensed IDE-bound compiler. |
| xpp | Microsoft Dynamics X++ executes only inside the hosted Dynamics platform. |

## Borderline — feasible only with an activation or licensing decision

| Language | Condition |
| --- | --- |
| wolfram-language | The free Wolfram Engine for Developers runs headless in Docker but requires account activation with a license key at build or run time. |
| q | kdb+ personal edition is gratis but license-gated and closed; redistribution inside images needs a decision. |
| gml | GameMaker's compiler is proprietary; open reimplementations are only partially compatible. |

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
| 10 | xojo | **Roc** | roc | A young pure-functional language with a platform/host split that maps unusually well onto a client with an FFI transport. |
| 11 | xpp | **ATS** | ats2 | Dependent types over C, proving memory safety at compile time. The most demanding type system in the project. |

Deliberately not chosen, and why:

- **PostScript** (Ghostscript) — a page-description language with no sockets;
  a client would have to be almost entirely foreign calls, which earns the
  bridge label rather than a native one.
- **Koka** and **Red** — both interesting, but their toolchains are young enough
  that a reproducible pinned Docker build is a project of its own.

If any chosen language proves infeasible once its toolchain is actually pinned
in Docker, it moves to the table above with its reason recorded, and the next
candidate takes the slot. The three borderline entries (wolfram-language, q,
gml) still await a licensing decision and are not counted as replaced.
