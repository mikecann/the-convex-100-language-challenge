# Convex from Simula 67

This is a Convex client written in Simula 67, the language that introduced
classes, objects, inheritance, virtual methods and coroutines to programming
— ideas nearly every language written since has inherited. It reads a shared
counter over Convex's documented JSON HTTP endpoint, subscribes to the same
query over Convex Live, applies a mutation, and shows the change arriving
reactively, all translated to C by GNU Cim and linked against one small,
reviewed native shim for sockets and TLS.

It is educational, unofficial, and not a production SDK. It exists to answer
one question honestly: can a fifty-eight-year-old language that predates
TCP/IP by over a decade, compiled by a small GNU project compiler, support a
useful Convex client? Nothing here is supported by Convex. Shared local and
hosted black-box conformance earned HTTP and Live.

## Start here

The whole demonstration is one file:
[`examples/basics/main.sim`](examples/basics/main.sim).

It walks a single journey and refuses to print its final line unless every
step agrees:

1. Query `demo:state` over HTTP and read the current count.
2. Subscribe to the same query over Live, **before** mutating, so no update
   can fall into the gap.
3. Check that the first Live value hydrates the same count the HTTP query
   returned.
4. Apply `demo:increment` with a fresh idempotency key.
5. Receive the new count over Live, with no second HTTP request.

Against a fresh room, that is the `0 -> 1` journey printed below. The
failure path behind every `givingup` call is a real Simula class,
`ExampleFailure`, built with `new` and dispatched with `.report` — the same
class mechanism Simula gave to nearly every language that followed it.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented, conformance green | Written in Simula over the native transport layer |
| Structured Convex errors | Implemented, conformance green | `FunctionError`, `ProtocolError` and `TransportError` keep name, message, data and log lines |
| TLS with certificate and hostname verification | Implemented, exercised by hosted conformance | Same reviewed design as this project's ALGOL 60 client, and the hosted profile's 31/31 ran over real TLS against the deployment. The dedicated trust/untrusted/wrong-host unit proof is still not run; see limitations |
| Live subscribe, update, unsubscribe | Implemented, conformance green | RFC 6455 framing written in Simula |
| Live reconnect and rehydration | Implemented, conformance green | Adapter-only `debugDisconnect`, unchanged rehydration suppressed |
| WebSocket handshake response verification | Partial | HTTP 101 upgrade is required; `Sec-WebSocket-Accept` is not checked against SHA-1, see limitations |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented | Deferred; see limitations |
| Earned badges | **`http` and `live`** | 31/31 on both the local and hosted profiles, from clean exact head `9bd9b4d` |

Every row above says "Docker gate green" deliberately, not "verified": the
The language-local suite has 60 unmocked assertions. The Docker test stage,
native shim build, canonical example, adapter probe, and shared local and
hosted black-box conformance all passed. The manifest records the earned HTTP
and Live result.

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sim -->
```simula
comment Convex from Simula 67: read a shared counter over HTTP, watch it
   over Live, and prove a mutation arrives on both. Against a fresh room
   the journey is 0 to 1.
   This file is the canonical example projected into the README and the
   website, so every step below is commented for a reader meeting
   Convex, and Simula, for the first time. It is assembled together with
   convex-native.sim, convex-buffer.sim, convex-json.sim, convex-http.sim,
   convex-ws.sim and convex-live.sim by the Docker build inside one
   shared begin block - see the Dockerfile for the exact command.
   The failure path below is where this example leans on Simula's own
   invention: a small class hierarchy, ConvexOutcome and its subclass
   ExampleFailure, gives every way this journey can fail a real object
   with its own report method, rather than one flat error code - the
   same idea, class, inheritance and instance method, that Simula
   contributed to nearly every language written after it;

comment ---------------------------------------------------------------
   A tiny class hierarchy for reporting how the journey failed. Every
   Convex error this client can raise is one of exactly three kinds
   (function, protocol, transport, see the manifest), and each becomes
   its own class here rather than one shared record with a discriminant
   field, so the object that describes a failure and the object that
   caused it are the same shape.
   ------------------------------------------------------------------;

class ConvexOutcome(reasontext); text reasontext;
begin
   comment base class shared by every structured way this example can
   give up. Holds only the one field every subclass needs;
end ConvexOutcome;

ConvexOutcome class ExampleFailure;
begin
   procedure report;
   comment writes this outcomes reason to stderr and exits with status
   1. A missing value or a disagreement between HTTP and Live is a
   failed demonstration, not something to retry;
   begin
      integer array line(0:255);
      integer linelen, discard;
      linelen := 0;
      discard := bufputstr(line, 256, linelen, reasontext);
      discard := bufputbyte(line, 256, linelen, 10);
      discard := cxwrite(examplestderr, line, 0, linelen);
      cxexit(1)
   end report;
end ExampleFailure;

procedure givingup(msg);
   comment raises an ExampleFailure for msg. Every failure exit in this
   example goes through this one procedure;
   text msg;
begin
   ref(ExampleFailure) outcome;
   outcome :- new ExampleFailure(msg);
   outcome.report
end givingup;

comment ---------------------------------------------------------------
   Reads count from a Convex demo record - {"count": N, ...} - and
   insists on a whole number. Convex may encode an integral count in
   decimal form, as 0 or as 0.0, and jsonparseint accepts both while
   rejecting a fractional, quoted or out of range value;
integer procedure examplecount(buf, off, limit, ok);
   name ok;
   integer array buf;
   integer off, limit, ok;
begin
   integer voff, vlen, found;
   integer array errbuf(0:255);
   integer errbuflen, errkind;
   errbuflen := 0; errkind := 0;
   jsonfindfield(buf, off, limit, "count", voff, vlen, found, errbuf, errbuflen,
      errkind);
   if errkind <> 0 or found = 0 then
      ok := 0
   else
      examplecount := jsonparseint(buf, voff, vlen, ok)
end examplecount;

comment prints a caption, a nonnegative integer, and a newline, built as
   bytes and written with cxwrite rather than with Simulas own OutInt,
   which does not share a stream with cxwrite and would leave stdout
   interleaved unpredictably between buffered Simula output and raw
   written bytes. Every printed line in this example goes through this
   one procedure or printplain below, so stdout is always exactly what
   this example intends and nothing else;
procedure printline(caption, num);
   text caption;
   integer num;
begin
   integer array line(0:255);
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, caption);
   discard := bufputint(line, 256, linelen, num);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestdout, line, 0, linelen)
end printline;

comment prints one literal line with no number in it;
procedure printplain(text2);
   text text2;
begin
   integer array line(0:255);
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, text2);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestdout, line, 0, linelen)
end printplain;

comment ---------------------------------------------------------------
   Example-wide state. One client, one deployment, matching every
   procedure in convex-http.sim and convex-live.sim, which expect this
   passed explicitly, since Simula procedures do not share state across
   separately compiled files any more than this projects ALGOL 60
   client does.
   ------------------------------------------------------------------;

integer examplestderr;
integer examplestdout;
integer discard;
integer array examplehost(0:255);
integer examplehostlen;
integer array exampleport(0:15);
integer exampleportlen;
integer exampletls;
integer array exampleauth(0:1);
integer exampleroom;
integer array exampleroombuf(0:63);
integer exampleroomlen;

comment ---------------------------------------------------------------
   Building this examples arguments. Every Convex function below takes
   room, the shared counters identity, so this is written once and
   reused for the query, the subscribe, and the mutation.
   ------------------------------------------------------------------;
procedure examplebuildargs(argsbuf, argscap, argslen, includemutationfields,
      runidbuf, runidlen);
   name argslen;
   integer array argsbuf, runidbuf;
   integer argscap, argslen, includemutationfields, runidlen;
begin
   integer discard;
   argslen := 0;
   discard := bufputbyte(argsbuf, argscap, argslen, 123);
   discard := bufputstr(argsbuf, argscap, argslen, """room"":");
   discard := jsonwritestring(argsbuf, argscap, argslen, exampleroombuf, 0,
      exampleroomlen);
   if includemutationfields <> 0 then begin
      discard := bufputstr(argsbuf, argscap, argslen,
         ",""language"":""simula"",""runId"":");
      discard := jsonwritestring(argsbuf, argscap, argslen, runidbuf, 0,
         runidlen)
   end;
   discard := bufputbyte(argsbuf, argscap, argslen, 125)
end examplebuildargs;

comment ---------------------------------------------------------------
   The example itself.
   ------------------------------------------------------------------;

procedure examplerun;
begin
   integer array urlbuf(0:1023);
   integer urllen, discard;
   integer array namebuf(0:15);
   integer namelen;
   integer array errbuf(0:255);
   integer errbuflen, errkind;

   comment configuration: every native client in this project reads its
      deployment from CONVEX_URL, and Simula has no environment access
      of its own, so this is the one place the example calls the shims
      cxgetenv rather than a pure Simula procedure;
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "CONVEX_URL");
   urllen := cxgetenv(namebuf, namelen, urlbuf, 1024);
   if urllen < 0 then givingup("CONVEX_URL is required");

   comment client creation: parse the deployment URL once into a host, a
      port and a scheme, exactly as convex-http.sims HTTP calls and
      convex-live.sims WebSocket connect both need them;
   errbuflen := 0; errkind := 0;
   deploymentparse(urlbuf, urllen, exampletls, examplehost, 256, examplehostlen,
      exampleport, 16, exampleportlen, errbuf, errbuflen, errkind);
   if errkind <> 0 then givingup("CONVEX_URL could not be parsed");

   comment the verifier passes a unique room as this containers first
      argument, forwarded here as EXAMPLE_ROOM by the Docker images
      entry script, and running the image by hand without one still
      works;
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "EXAMPLE_ROOM");
   exampleroomlen := cxgetenv(namebuf, namelen, exampleroombuf, 64);
   if exampleroomlen < 0 then begin
      exampleroomlen := 0;
      discard := bufputstr(exampleroombuf, 64, exampleroomlen, "simula-example")
   end;

   liveinit;

   begin
      integer array pathbuf(0:31);
      integer pathlen;
      integer array argsbuf(0:511);
      integer argslen;
      integer array msgbuf(0:511);
      integer array bodybuf(0:8191);
      integer statuscode, kind, valoff, vallen, msglen;
      integer hasdata, dataoff, datalen, haslogs, logsoff, logslen;
      integer current, currentok;

      comment the HTTP query: ask Convex for the rooms current state
         through its documented JSON HTTP endpoint, /api/query;
      pathlen := 0;
      discard := bufputstr(pathbuf, 32, pathlen, "demo:state");
      examplebuildargs(argsbuf, 512, argslen, 0, argsbuf, 0);
      errbuflen := 0; errkind := 0;
      convexcall("query", examplehost, examplehostlen, exampleport,
         exampleportlen, exampletls,
         exampleauth, 0, pathbuf, pathlen, argsbuf, 0, argslen, cxnowms + 10000,
         statuscode, kind, valoff, vallen, msgbuf, 512, msglen,
         hasdata, dataoff, datalen, haslogs, logsoff, logslen, bodybuf, 8192,
         errbuf, errbuflen, errkind);
      if errkind <> 0 then givingup("the HTTP query failed");
      if kind = 1 then
         givingup("the HTTP query returned a Convex function error");

      comment decoding into an idiomatic value: Convexs JSON is parsed
         only as far as the one field this example promises;
      current := examplecount(bodybuf, valoff, valoff + vallen, currentok);
      if currentok = 0 then givingup("the HTTP query did not return a count");
      printline("current count: ", current);

      begin
         integer sub;

         comment starting Live before the mutation: subscribing first
            means no reactive update, including the one the mutation
            below is about to cause, can fall into the gap between
            reading and watching;
         examplebuildargs(argsbuf, 512, argslen, 0, argsbuf, 0);
         errbuflen := 0; errkind := 0;
         livesubscribe(examplehost, examplehostlen, exampleport, exampleportlen,
            exampletls,
            pathbuf, pathlen, argsbuf, 0, argslen, cxnowms + 10000, sub, errbuf,
               errbuflen, errkind);
         if errkind <> 0 then givingup("the Live subscribe failed");

         begin
            integer initialkind, initial, initialok;
            integer array valuecopy(0:2047);
            integer valuelen;

            comment the initial Live value: the first delivery on a
               fresh subscription hydrates the same state the HTTP
               query above just read, over the WebSocket sync protocol
               rather than a second HTTP request;
            initialkind := livenext(sub, 10000);
            if initialkind = 0 then
               givingup("the initial Live value did not arrive "
                  & "before the deadline");
            if initialkind = 2 then
               givingup("the initial Live value was a Convex "
                  & "function error");
            valuelen := 0;
            livetakencopyvalue(valuecopy, 2048, valuelen);
            livereleasetaken;
            initial := examplecount(valuecopy, 0, valuelen, initialok);
            if initialok = 0 or initial <> current then
               givingup("the initial Live count disagreed with HTTP");
            printline("live initial count: ", initial);

            begin
               integer array runid(0:31);
               integer runidlen;
               integer expected, appliedoff, appliedlen, afound, applied,
                  countoff, countlen, cfound, count, countok;
               integer array mutationpath(0:31);
               integer mutationpathlen;

               comment the mutation and its idempotency key: runId is
                  fresh random bytes on every run, and Convex uses it
                  to replay the earlier result rather than counting
                  twice if the same key ever arrived again;
               runidlen := 0;
               begin
                  integer array randbytes(0:15);
                  discard := cxrandom(randbytes, 16);
                  discard := hexencode(randbytes, 0, 16, runid, 32, runidlen)
               end;
               mutationpathlen := 0;
               discard := bufputstr(mutationpath, 32, mutationpathlen,
                  "demo:increment");
               examplebuildargs(argsbuf, 512, argslen, 1, runid, runidlen);
               errbuflen := 0; errkind := 0;
               convexcall("mutation", examplehost, examplehostlen, exampleport,
                  exampleportlen, exampletls,
                  exampleauth, 0, mutationpath, mutationpathlen, argsbuf, 0,
                     argslen, cxnowms + 10000,
                  statuscode, kind, valoff, vallen, msgbuf, 512, msglen,
                  hasdata, dataoff, datalen, haslogs, logsoff, logslen, bodybuf,
                     8192,
                  errbuf, errbuflen, errkind);
               if errkind <> 0 then givingup("the mutation failed");
               if kind = 1 then
                  givingup("the mutation returned a Convex function error");
               expected := current + 1;
               jsonfindfield(bodybuf, valoff, valoff + vallen, "applied",
                  appliedoff, appliedlen, afound, errbuf, errbuflen, errkind);
               applied := if afound <> 0 and bufeqstr(bodybuf, appliedoff,
                  appliedlen, "true") then 1 else 0;
               if applied = 0 then givingup("the mutation was not applied");
               jsonfindfield(bodybuf, valoff, valoff + vallen, "state",
                  countoff, countlen, cfound, errbuf, errbuflen, errkind);
               count := if cfound <> 0 then examplecount(bodybuf, countoff,
                  countoff + countlen, countok) else 0;
               if cfound = 0 or countok = 0 or count <> expected then
                  givingup("the mutation returned an unexpected count");
               comment printline always prints a trailing integer, and
                  this narration line has none, so it is written with
                  printplain instead;
               printplain("mutation applied: true");
               printline("mutation count: ", count);

               begin
                  integer updatedkind, updated, updatedok;
                  integer array updatedcopy(0:2047);
                  integer updatedlen;

                  comment receiving the same change reactively: the
                     Live subscription delivers the mutations result
                     with no second HTTP request at all;
                  updatedkind := livenext(sub, 10000);
                  if updatedkind = 0 then
                     givingup("the updated Live value did not arrive "
                        & "before the deadline");
                  if updatedkind = 2 then
                     givingup("the updated Live value was a Convex "
                        & "function error");
                  updatedlen := 0;
                  livetakencopyvalue(updatedcopy, 2048, updatedlen);
                  livereleasetaken;
                  updated := examplecount(updatedcopy, 0, updatedlen,
                     updatedok);
                  if updatedok = 0 or updated <> expected then
                     givingup("the updated Live count disagreed "
                        & "with the mutation");
                  printline("live updated count: ", updated);

                  comment only now, with the HTTP query, the initial
                     Live value, the mutation and the updated Live
                     value all agreeing, print the proof line;
                  begin
                     integer array line(0:255);
                     integer linelen, discard2;
                     linelen := 0;
                     discard2 := bufputstr(line, 256, linelen,
                        "verified count: ");
                     discard2 := bufputint(line, 256, linelen, current);
                     discard2 := bufputstr(line, 256, linelen, " -> ");
                     discard2 := bufputint(line, 256, linelen, updated);
                     discard2 := bufputbyte(line, 256, linelen, 10);
                     discard2 := cxwrite(examplestdout, line, 0, linelen)
                  end
               end
            end
         end;

         comment cleanup: unsubscribe and close use the clients own
            bounded deadlines rather than waiting on a peer that may
            never answer;
         liveunsubscribe(sub, cxnowms + 5000)
      end
   end;
   liveclose(cxnowms + 5000)
end examplerun;

examplestdout := cxadopt(1);
examplestderr := cxadopt(2);
examplerun;
cxexit(0);
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

Everything builds and runs inside Docker; nothing is installed on the host.

```sh
./run test simula
```

Builds GNU Cim 5.1 from source, runs the style gate, compiles the native
support library on its own, and executes the language-local suite: strict
JSON and the number rules, HTTP framing and the Convex envelope, RFC 6455
frame build/read round trips, and deployment URL parsing. It also proves the
example fails cleanly with no deployment configured and prints nothing on
stdout when it does, and that the conformance adapter answers `hello` and
`close` correctly.

```sh
./run verify-example simula
```

Builds the minimal example image and runs the exact canonical example against
a unique room, comparing stdout byte for byte with the shared transcript.

```sh
./run verify simula
./run verify-hosted simula
./run verify-all simula
```

Add shared black-box conformance against the approved local backend, then the
hosted drift target, then both from the same built source. Only the shared
result evaluator may award a badge.

## How it is put together

GNU Cim has no linker for separately compiled Simula units the way a
production Simula system would, and, like this project's ALGOL 60 client, no
shared global state across files declared outside one shared block — only
lexical nesting inside a `begin ... end` block shares variables between
separately written source files here. The client is assembled from layered
source files at build time, innermost first:

| File | Responsibility |
| --- | --- |
| `client/convex-native.sim` | `external C procedure` headings for every native primitive |
| `client/convex-buffer.sim` | Byte buffers, base64, hex, and integer-division helpers |
| `client/convex-json.sim` | A strict JSON reader and writer, with no floating point |
| `client/convex-http.sim` | HTTP/1.1 framing and Convex's documented JSON HTTP functions |
| `client/convex-ws.sim` | RFC 6455 WebSocket framing |
| `client/convex-live.sim` | The sync profile, its single socket owner, and its delivery queue |
| `client/convexrt.c` | The only native code: sockets, TLS, poll, clock, entropy, environment |

The Dockerfile concatenates these files (plus a program-specific tail: the
example, the test suite, or the conformance adapter) into one `.sim` source
before handing it to `cim`. See the Dockerfile for the exact assembly order.

### What the native library is, and is not

Standard Simula has no sockets, no TLS, no monotonic clock, no entropy
source and no environment variable access, so `client/convexrt.c` supplies
exactly those, as fourteen `external C procedure` bodies. It contains no
HTTP, no WebSocket framing, no JSON, no retry policy and no Convex
knowledge. Every loop, deadline and bound is driven from Simula.

The boundary between the two languages is GNU Cim's own calling
convention — confirmed by compiling a throwaway probe program with `cim -S`
and reading the C it generated, rather than assumed from the manual. A
by-value `integer` parameter, and an `integer procedure`'s return value, are
both a plain 64-bit C `long`, matching every `integer array` element, which
arrives as `long *` pointing at its first element. A by-value `text`
parameter arrives as a malloc'd, NUL-terminated `char *`.

Along the way, this checkpoint found and fixed a genuine upstream packaging
bug: GNU Cim 5.1's release tarball ships two pre-generated bootstrap C files
(`lib/simset.c`, `lib/simulation.c`) that hardcode
`#include "../../lib/cim.h"`, a relative path that only resolves from a
source tree nested two directories deeper than a plain tarball extraction.
The Dockerfile rewrites both to the working `#include "cim.h"` before
building.

It also found that GNU Cim's default runtime memory pool is far too small
for this client's real buffer footprint (a little over a megabyte of
declared integer arrays once every layer is assembled): a program compiled
without a larger pool aborts with `Alloc: Virtual memory exhausted` while
allocating its own top-level array declarations, before any code runs.
Every program in this client is compiled with `cim -m32 -M96`.

### A class hierarchy for how the example can fail

`examples/basics/main.sim` gives every way the demonstration can fail a real
object rather than a flat error code: `ConvexOutcome` is the base class, and
`ExampleFailure` is a subclass with its own constructor parameter and its
own `report` instance method, constructed with `new` and invoked through a
typed reference. GNU Cim 5.1 turned out not to support a bare, parameterless
`virtual: procedure P;` specification — confirmed by reading the compiler's
own grammar, `src/parser.y`, whose `ONE_SPEC` rule has a dedicated error
production for exactly that shape, matching the compiler's own manual's
up-front warning about limited virtual procedure parameter support — so
dispatch here is through a concrete class rather than a virtual call through
the common supertype. Construction, inheritance and instance methods are
still genuine and exercised, including by a real language-local test that
constructs both classes and calls their instance methods.

### A language with no bitwise operators

Simula has no bitwise operators; the logical operators `and`, `or` and `not`
apply only to boolean operands. RFC 6455 masking, which the specification
defines as a byte-by-byte exclusive or, is written in `client/convex-ws.sim`
as an explicit eight-bit arithmetic loop (`bytexor`) instead, the same
approach this project's ALGOL 60 client uses for the same reason. Every
payload length form — the 7-bit, 16-bit and 64-bit extended forms — is built
and parsed through plain division and multiplication by 256.

### One owner, and the barriers around it

Exactly one call path may touch the WebSocket, change the query-set version
or decide to reconnect: `client/convex-live.sim`'s procedures, driven by
whichever caller — the example, a test, or the conformance adapter's poll
loop — is currently inside one of them. Simula's `SIMULATION` class does
provide real coroutines, but this client, like this project's ALGOL 60
client, does not use them for socket ownership; single-owner discipline is
enforced by convention rather than by the language.

After a reconnect the server resends the current value of every active
query. Publishing that unchanged value would turn one logical update into
two, so each subscription remembers the exact bytes it last published and
suppresses an identical rehydration. Publishing an error clears that memory,
which is what lets a `QueryFailed` be followed by the same value again and
still read as a recovery.

### Framing that survives a timeout

The WebSocket reader never consumes a byte until the whole frame is
buffered. That one rule is what makes a mid-frame timeout safe: the partial
frame stays in the stream buffer and the next attempt resumes at the same
offset instead of re-synchronising on a byte that only looks like a frame
header. A frame's declared payload length is checked against the configured
ceiling before any payload byte is requested, so an inflated length header
cannot make the client reserve memory on a peer's behalf.

## Conformance and protocol notes

`client/tests/conformance/adapter.sim` is test infrastructure, not public
client code. It speaks NDJSON adapter protocol v1 over stdin and stdout, or
over one accepted TCP connection when `ADAPTER_LISTEN` is set, and calls the
real client for every operation. Stdout carries protocol events only; every
diagnostic goes to stderr.

It implements the adapter-only `debugDisconnect` command, declared in
`manifest.yaml` under `adapter.adapterOnlyCommands`, so the shared controller
can prove real reconnects. That command is not part of the educational
client API.

Optional fields are omitted rather than serialized as null: an absent
command id, an absent error `data` and an absent value never appear as
`null`.

The pinned sync profile is recorded in `manifest.yaml`. It is an
undocumented protocol, and nothing here implies it is stable or officially
supported.

## Limitations and deferred behaviour

- Shared local and hosted conformance passed, earning HTTP and Live. The
  limitations below remain deliberately outside those capabilities.
- TLS has not been separately unit-tested against a private CA the way this
  project's ALGOL 60 client does. `client/convexrt.c`'s TLS code is the same
  reviewed design (peer verification, the default CA bundle, and
  `SSL_set1_host` hostname checking, all switched on together), but that
  specific trust/untrusted/wrong-host proof has not been run for this
  checkpoint.
- The WebSocket handshake does not verify the server's
  `Sec-WebSocket-Accept` response header against SHA-1 of the client's key,
  matching this project's ALGOL 60 client. A valid HTTP 101 upgrade response
  is still required, and every frame exchanged afterward is real RFC 6455
  framing; only that one header's cryptographic check is skipped.
- `convexcall` and `livesubscribe` open their own connection internally, and
  the language-local test suite has no fixture server to connect to, so it
  exercises HTTP framing, the Convex envelope decoder, and RFC 6455 frame
  build/read round trips directly rather than through a live connection.
- Live is driven by the caller. Reactive updates arrive only while a caller
  is inside `livenext`, the adapter's event loop, or another client
  procedure.
- Live authentication, optimistic updates, WebSocket mutations, WebSocket
  actions, journals and `TransitionChunk` assembly are deferred.
- Live values cover Convex's JSON-safe subset; tagged Convex value
  conversions are deferred.
- JSON numbers are accepted only when mathematically integral and
  representable exactly within a safe 64-bit range; fractional and
  out-of-range values are rejected at the point of use.
- Active Live subscriptions and the delivery queue are bounded; a value too
  large for the configured byte budget becomes an observable
  `ProtocolError` without changing the subscription's last delivered value,
  and queue overflow drops the oldest undelivered event rather than growing
  without bound.
