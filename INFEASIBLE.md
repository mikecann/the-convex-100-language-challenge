# Languages that did not make the final roster

The challenge finished with one hundred languages, each verified against both
the local and hosted Convex backends. This is the final record of the languages
that were considered or built but did not make that roster.

Only the final reason is kept here. The longer investigations and candidate
history remain available in git, but they are no longer part of the public-facing
record.

## Platform, licensing or GUI restrictions

These languages could not be built and run inside the project's unattended,
redistributable Linux containers.

| Language | Why it did not make the cut |
| --- | --- |
| apex | Apex runs only inside Salesforce's hosted platform; there is no local runtime to put in a Docker image. |
| labview | LabVIEW requires NI's proprietary graphical environment and licensed toolchain. |
| matlab | The real MATLAB runtime requires a proprietary licence; replacing it with GNU Octave would not honestly be MATLAB. |
| mql5 | MQL5 runs inside the proprietary Windows-only MetaTrader terminal. |
| rpg | IBM RPG compilers are available on IBM i, not as a free Linux toolchain. |
| sas | SAS requires a proprietary licensed runtime with no free compatible implementation. |
| scratch | Scratch is a GUI block language without the network primitives needed to implement this client. |
| visual-foxpro | Visual FoxPro is a discontinued proprietary Windows product with no Linux toolchain. |
| xbasepp | Alaska Xbase++ requires a commercial Windows compiler. |
| xojo | Xojo depends on a proprietary licensed IDE and compiler. |
| xpp | Microsoft Dynamics X++ runs only inside the hosted Dynamics platform. |
| wolfram-language | Wolfram Engine requires account activation, restricts redistribution and needs writable licensed state. |
| q | The kdb+/q runtime requires a KX account, download token and per-user licence. |
| gml | GameMaker requires an interactive IDE sign-in and produces a graphical game runtime rather than a headless Linux program. |

## No honest network path

These languages could not open and control the sockets themselves. Adding a
helper in another language would have made the result a bridge rather than a
client written in the language being tested.

| Language | Why it did not make the cut |
| --- | --- |
| bc | bc can communicate only through numeric input and text output; it has no sockets, files, FFI or dynamic loading. |
| solidity | The EVM has no network I/O and Solidity has no foreign-function escape hatch. |
| abap | ABAP exposes neither a socket API nor a public FFI; available workarounds hand the transport to embedded JavaScript. |
| elm | Elm can exchange JSON through ports, but all transport would have to live in hand-written JavaScript. |
| futhark | Futhark deliberately has no I/O primitives or FFI, so a foreign host would have to own the entire connection. |

## Toolchain or runtime constraints

These languages could express at least part of a real client, but their
available toolchain or runtime could not satisfy the same reproducible,
read-only and resource-limited container rules as the final one hundred.

| Language | Why it did not make the cut |
| --- | --- |
| cfml | Lucee exceeded the 128 MiB limit and required a writable temporary directory; the smaller BoxLang alternative is a different language. |
| hack | HHVM could open a socket but its obsolete TLS stack could not negotiate with the hosted deployment, and the compiler could not be removed from the runtime. |
| unison | Unison completed a real TLS round trip, but its standard library could only be obtained through a live build-time dependency on Unison Share. |
| pop11 | Poplog's bootstrap requires disabling address randomisation, which Docker's default security policy correctly blocks. |
| raku | Even after removing every optional module, Rakudo needed 145–170 MiB for a real TLS connection against the project's 128 MiB limit. |
| oz | Mozart/Oz could open a socket, but adding TLS required rebuilding the VM through an old code generator that crashed reproducibly. |
| actionscript | Apache Royale's optimisation pass renamed dynamic JSON keys and therefore changed the Convex protocol on the wire. |
| logo | The viable Logo FFI was available only through an abandoned 32-bit implementation, which was not a trustworthy final build target. |

## Built, but not in the final one hundred

These clients got further than the entries above. Three held roster slots before
final host revalidation exposed reliability or resource problems. Hy passed,
but arrived after the final roster was full.

| Language | Why it did not make the cut |
| --- | --- |
| mumps | The YottaDB client worked, but hosted hostname transport was intermittent under the project's amd64 verification environment. |
| setl | GNU SETL's runtime used roughly 274 MiB for a trivial pretranslated program, more than twice the shared limit. |
| modula-3 | The CM3 toolchain could not complete verification reliably on the final build host. |
| hy | Hy passed implementation and review, but the roster was already complete and it did not displace a final language. |

That leaves **31 languages outside the final roster**: 27 ruled out by platform,
language, toolchain or runtime constraints, three replaced during final host
revalidation, and one passing candidate that arrived after the last slot was
filled.

This is larger than the project's 25 slot replacements because several entries
here were replacement candidates that failed before ever occupying a roster
slot, and Hy never occupied one at all.
