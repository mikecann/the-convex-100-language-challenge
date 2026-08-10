<img src="logo.png" alt="Simula logo" width="240">
<!-- Logo source: https://commons.wikimedia.org/wiki/File:Simula_-_logo.svg -->

# Simula 67

Simula began at the Norwegian Computing Center in the 1960s, where Ole-Johan
Dahl and Kristen Nygaard were building a language for discrete-event
simulation. Simula 67 grew into a general-purpose, ALGOL 60-based language and
introduced the class and object model that helped shape Smalltalk, C++, Java,
C#, and much of modern object-oriented programming. The
[SIMULA Standard](https://portablesimula.github.io/github.io/doc/SimulaStandard86/chap_0.htm)
remains the clearest language reference.

You are unlikely to choose Simula for a new web app in 2026. Its present-day
niche is language history, teaching, and maintaining or exploring simulation
software. This demonstration uses [GNU Cim](https://www.gnu.org/software/cim/),
a Simula compiler that translates the program to C. This client is educational,
unofficial, and not a production Convex SDK.

## Getting Started

Start with the [canonical counter example](examples/basics/main.sim). It queries
`demo:state`, subscribes before changing anything, calls `demo:increment`, and
then waits for the resulting Live update.

From the repository root, run the exact example inside Docker:

```sh
./run verify-example simula
```

The verifier supplies an isolated room and checks the program's `0 -> 1`
transcript. It does not install GNU Cim or any build dependency on your host.

## Interesting Parts

### React hides the subscription; this client makes it visible

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function Counter() {
  const room = "readme-comparison";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <p>Loading...</p>;

  return (
    <button
      onClick={() =>
        increment({
          room,
          language: "typescript",
          runId: crypto.randomUUID(),
        })
      }
    >
      Count: {state.count} {/* React rerenders when the query changes. */}
    </button>
  );
}
```

**Simula 67**

```simula
procedure watchstate(host, hostlen, port, portlen, tls);
   integer array host, port;
   integer hostlen, portlen, tls;
begin
   integer array pathbuf(0:31), argsbuf(0:127), errbuf(0:255);
   integer pathlen, argslen, errbuflen, errkind, sub, initialkind, discard;

   pathlen := 0;
   discard := bufputstr(pathbuf, 32, pathlen, "demo:state");
   argslen := 0;
   discard := bufputstr(argsbuf, 128, argslen,
      "{""room"":""readme-comparison""}");

   errbuflen := 0; errkind := 0;
   livesubscribe(host, hostlen, port, portlen, tls,
      pathbuf, pathlen, argsbuf, 0, argslen,
      cxnowms + 10000, sub, errbuf, errbuflen, errkind);
   if errkind <> 0 then cxexit(1);

   comment This blocking next call pumps the socket and returns the first
      query value. The caller, rather than a UI framework, owns progress;
   initialkind := livenext(sub, 10000);
   if initialkind = 0 then cxexit(1);
   livereleasetaken;

   comment Cleanup is explicit too. The full example mutates between the
      initial delivery and the updated delivery;
   liveunsubscribe(sub, cxnowms + 5000);
   liveclose(cxnowms + 5000)
end watchstate;
```

`useQuery` owns the subscription lifecycle and causes React to rerender. The
Simula language has coroutines, but this particular client deliberately offers
a blocking `livenext` API with explicit unsubscribe and close operations. That
is a client design choice, not a limitation of the language. See the
[complete sequence](examples/basics/main.sim).

### An object-oriented failure path from 1967

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

class ExampleFailure extends Error {}

function CheckedCounter() {
  const state = useQuery(api.demo.state, { room: "readme-comparison" });

  if (state === undefined) return <p>Loading...</p>;
  if (!Number.isSafeInteger(state.count)) {
    throw new ExampleFailure("demo:state did not return a safe whole count");
  }

  return <p>Count: {state.count}</p>;
}
```

**Simula 67**

```simula
class ConvexOutcome(reasontext); text reasontext;
begin
   comment Common state inherited by every example outcome;
end ConvexOutcome;

ConvexOutcome class ExampleFailure;
begin
   procedure report;
   begin
      comment The real example writes reasontext to stderr, then exits;
      cxexit(1)
   end report;
end ExampleFailure;

begin
   ref(ExampleFailure) outcome;
   outcome :- new ExampleFailure("demo:state did not return a count");
   outcome.report
end;
```

The syntax looks old, but the ideas are familiar: subclassing, object
construction, a typed reference, and an instance method. GNU Cim 5.1 cannot
compile the parameterless virtual declaration this example would need for
polymorphic dispatch through `ConvexOutcome`, so the checked-in code calls
`report` through the concrete `ExampleFailure` reference.

## Status

| Capability | Status | What the evidence says |
| --- | --- | --- |
| HTTP query, mutation, and action | Earned | Native Simula implementation passed shared local and hosted conformance |
| Structured errors | Earned with HTTP and Live | Function, protocol, and transport errors remain distinguishable |
| Live subscribe, update, unsubscribe, and reconnect | Earned | Shared local and hosted profiles each passed 31/31 at clean exact head `9bd9b4d` |
| TLS certificate and hostname verification | Exercised by hosted conformance | The separate private-CA trust test has not been run for this client |
| WebSocket handshake verification | Partial | An HTTP 101 is required, but `Sec-WebSocket-Accept` is not checked against the client's key |
| Authentication and optimistic updates | Not implemented | Deferred rather than counted as partial support |
| Manifest capabilities | **`http`, `live`** | These are the only awarded badges |

This documentation-only edit does not claim a fresh verification run. The
table preserves the results already recorded by the manifest and prior shared
evidence.

## Example

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

## Implementation Notes

GNU Cim 5.1 translates Simula to C, then a C compiler produces the native
executable. The Docker build assembles the educational source files into one
lexically shared Simula block, compiles the canonical example and conformance
adapter, and places each executable in its own minimal runtime image.

### Source layout

This implementation does not use GNU Cim's separate-compilation support.
Instead, lexical nesting inside one `begin ... end` block lets the client
layers share the state needed by HTTP and Live. The Dockerfile assembles the
separately written files at build time, innermost first:

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
convention, confirmed by compiling a throwaway probe program with `cim -S`
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
`virtual: procedure P;` specification, confirmed by reading the compiler's
own grammar, `src/parser.y`, whose `ONE_SPEC` rule has a dedicated error
production for exactly that shape, matching the compiler's own manual's
up-front warning about limited virtual procedure parameter support. As a
result, dispatch here is through a concrete class rather than a virtual call
through the common supertype. Construction, inheritance and instance methods are
still genuine and exercised, including by a real language-local test that
constructs both classes and calls their instance methods.

### A language with no bitwise operators

Simula has no bitwise operators; the logical operators `and`, `or` and `not`
apply only to boolean operands. RFC 6455 masking, which the specification
defines as a byte-by-byte exclusive or, is written in `client/convex-ws.sim`
as an explicit eight-bit arithmetic loop (`bytexor`) instead, the same
approach this project's ALGOL 60 client uses for the same reason. Every
payload length form, including the 7-bit, 16-bit and 64-bit extended forms, is
built and parsed through plain division and multiplication by 256.

### One owner, and the barriers around it

Exactly one call path may touch the WebSocket, change the query-set version
or decide to reconnect: `client/convex-live.sim`'s procedures, driven by
whichever caller, whether the example, a test, or the conformance adapter's
poll loop, is currently inside one of them. Simula's `SIMULATION` class does
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

### Conformance and protocol notes

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

## Known Issues

1. The WebSocket upgrade requires HTTP 101 but does not verify
   `Sec-WebSocket-Accept` against SHA-1 of the client's key.
2. Live authentication, optimistic updates, WebSocket mutations and actions,
   journals, `TransitionChunk` assembly, and tagged Convex value conversions
   are deferred.
3. Live is caller-driven. Updates progress while code is inside `livenext`,
   the adapter loop, or another client procedure. The queue is bounded and
   drops the oldest undelivered event on overflow.
4. TLS ran against the hosted deployment with certificate and hostname checks,
   but this client has not had the separate private-CA trust, untrusted-CA, and
   wrong-host unit proof used by the ALGOL 60 client.
5. The language-local suite tests HTTP and WebSocket framing directly because
   `convexcall` and `livesubscribe` open their own connections and the suite has
   no concurrent fixture server.
