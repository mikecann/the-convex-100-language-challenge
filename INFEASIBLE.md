# Languages that did not make the final roster

The challenge finished with one hundred languages, each verified against both
the local and hosted Convex backends. This is the final record of the languages
that were considered or built but did not make that roster.

Only the final reason is kept here. The longer investigations and candidate
history remain available in git, but they are no longer part of the public-facing
record.

The roster position is the first slot a language held during the challenge.
"Not rostered" means it was considered as a replacement but never displaced a
language in the active one hundred.

## Platform, licensing or GUI restrictions

These languages could not be built and run inside the project's unattended,
redistributable Linux containers.

| Language | Original roster position | Why it did not make the cut |
| --- | ---: | --- |
| apex | #42 | Apex runs only inside Salesforce's hosted platform; there is no local runtime to put in a Docker image. |
| labview | #40 | LabVIEW requires NI's proprietary graphical environment and licensed toolchain. |
| matlab | #21 | The real MATLAB runtime requires a proprietary licence; replacing it with GNU Octave would not honestly be MATLAB. |
| mql5 | #67 | MQL5 runs inside the proprietary Windows-only MetaTrader terminal. |
| rpg | #70 | IBM RPG compilers are available on IBM i, not as a free Linux toolchain. |
| sas | #39 | SAS requires a proprietary licensed runtime with no free compatible implementation. |
| scratch | #47 | Scratch is a GUI block language without the network primitives needed to implement this client. |
| visual-foxpro | #75 | Visual FoxPro is a discontinued proprietary Windows product with no Linux toolchain. |
| xbasepp | #76 | Alaska Xbase++ requires a commercial Windows compiler. |
| xojo | #78 | Xojo depends on a proprietary licensed IDE and compiler. |
| xpp | #55 | Microsoft Dynamics X++ runs only inside the hosted Dynamics platform. |
| wolfram-language | #45 | Wolfram Engine requires account activation, restricts redistribution and needs writable licensed state. |
| q | #69 | The kdb+/q runtime requires a KX account, download token and per-user licence. |
| gml | #52 | GameMaker requires an interactive IDE sign-in and produces a graphical game runtime rather than a headless Linux program. |

## No honest network path

These languages could not open and control the sockets themselves. Adding a
helper in another language would have made the result a bridge rather than a
client written in the language being tested.

| Language | Original roster position | Why it did not make the cut |
| --- | ---: | --- |
| bc | #79 | bc can communicate only through numeric input and text output; it has no sockets, files, FFI or dynamic loading. |
| solidity | #41 | The EVM has no network I/O and Solidity has no foreign-function escape hatch. |
| abap | #35 | ABAP exposes neither a socket API nor a public FFI; available workarounds hand the transport to embedded JavaScript. |
| elm | #83 | Elm can exchange JSON through ports, but all transport would have to live in hand-written JavaScript. |
| futhark | Not rostered | Futhark deliberately has no I/O primitives or FFI, so a foreign host would have to own the entire connection. |

## Toolchain or runtime constraints

These languages could express at least part of a real client, but their
available toolchain or runtime could not satisfy the same reproducible,
read-only and resource-limited container rules as the final one hundred.

| Language | Original roster position | Why it did not make the cut |
| --- | ---: | --- |
| cfml | #56 | Lucee exceeded the 128 MiB limit and required a writable temporary directory; the smaller BoxLang alternative is a different language. |
| hack | #90 | HHVM could open a socket but its obsolete TLS stack could not negotiate with the hosted deployment, and the compiler could not be removed from the runtime. |
| unison | Not rostered | Unison completed a real TLS round trip, but its standard library could only be obtained through a live build-time dependency on Unison Share. |
| pop11 | Not rostered | Poplog's bootstrap requires disabling address randomisation, which Docker's default security policy correctly blocks. |
| raku | #53 | Even after removing every optional module, Rakudo needed 145–170 MiB for a real TLS connection against the project's 128 MiB limit. |
| oz | #52 | Mozart/Oz could open a socket, but adding TLS required rebuilding the VM through an old code generator that crashed reproducibly. |
| actionscript | #58 | Apache Royale's optimisation pass renamed dynamic JSON keys and therefore changed the Convex protocol on the wire. |
| logo | #66 | The viable Logo FFI was available only through an abandoned 32-bit implementation, which was not a trustworthy final build target. |

## Built, but not in the final one hundred

These clients got further than the entries above. Three held roster slots before
final host revalidation exposed reliability or resource problems. Hy passed,
but arrived after the final roster was full.

| Language | Original roster position | Why it did not make the cut |
| --- | ---: | --- |
| mumps | #35 | The YottaDB client worked, but hosted hostname transport was intermittent under the project's amd64 verification environment. |
| setl | #45 | GNU SETL's runtime used roughly 274 MiB for a trivial pretranslated program, more than twice the shared limit. |
| modula-3 | #52 | The CM3 toolchain could not complete verification reliably on the final build host. |
| hy | Not rostered | Hy passed implementation and review, but the roster was already complete and it did not displace a final language. |

That leaves **31 languages outside the final roster**: 27 ruled out by platform,
language, toolchain or runtime constraints, three replaced during final host
revalidation, and one passing candidate that arrived after the last slot was
filled.

This is larger than the project's 25 slot replacements because several entries
here were replacement candidates that failed before ever occupying a roster
slot, and Hy never occupied one at all.
