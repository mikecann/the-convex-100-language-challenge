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

## Proposed replacement languages

Buildable with free toolchains in Docker, distinct from every current roster
entry, and each with a real ecosystem or historical significance worth showing:

1. Rexx (Regina)
2. PostScript (Ghostscript)
3. Emacs Lisp (batch Emacs)
4. Modula-2 (GNU gm2)
5. Oberon-07 (OBNC)
6. Icon (Unicon)
7. SNOBOL4 (CSNOBOL4)
8. Mercury
9. ATS
10. Hare
11. Roc
12. Koka
13. Red
14. Futhark

Swapping any of these in for an infeasible entry is a shared-infrastructure
roster change and follows the normal shared-change review path.
