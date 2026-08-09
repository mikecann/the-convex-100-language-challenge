# Convex from ALGOL 60

This is a Convex client written in ALGOL 60, the 1960 report language that is
the direct ancestor of block structure, lexical scope, recursion and BNF
grammar notation — ideas nearly every other language on this roster inherits.
It reads a shared counter over Convex's documented JSON HTTP endpoint,
subscribes to the same query over Convex Live, applies a mutation, and shows
the change arriving reactively, all from a language with no strings as
values, no records, no bitwise operators, and no identifier underscores.

It is educational, unofficial, and not a production SDK. It exists to answer
one question honestly: can a sixty-five-year-old language, translated to C by
GNU MARST, support a useful Convex client? Nothing here is supported by
Convex. The shared local and hosted black-box conformance suites earned HTTP
and Live for this educational implementation.

## Start here

The whole demonstration is one file:
[`examples/basics/main.alg`](examples/basics/main.alg).

It walks a single journey and refuses to print its final line unless every
step agrees:

1. Query `demo:state` over HTTP and read the current count.
2. Subscribe to the same query over Live, **before** mutating, so no update
   can fall into the gap.
3. Check that the first Live value hydrates the same count the HTTP query
   returned.
4. Apply `demo:increment` with a fresh idempotency key.
5. Receive the new count over Live, with no second HTTP request.

Against a fresh room, that is the `0 -> 1` journey printed below.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented, Docker gate green | Written in ALGOL 60 over the native transport layer |
| Structured Convex errors | Implemented, Docker gate green | `FunctionError`, `ProtocolError` and `TransportError` keep name, message, data and log lines |
| TLS with certificate and hostname verification | Implemented, Docker gate green | Verified against a private CA in the Docker test stage |
| Live subscribe, update, unsubscribe | Implemented, Docker gate green | RFC 6455 framing written in ALGOL 60 |
| Live reconnect and rehydration | Implemented, Docker gate green | Adapter-only `debugDisconnect`, unchanged rehydration suppressed |
| WebSocket handshake response verification | Partial | HTTP 101 upgrade is required; `Sec-WebSocket-Accept` is not checked against SHA-1, see limitations |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented | Deferred; see limitations |
| Earned badges | **HTTP and Live** | Shared local and hosted conformance passed |

The Docker test stage, language-local suites, TLS suite, canonical example,
and shared local and hosted black-box conformance all passed. The manifest
records the earned HTTP and Live result.

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.alg -->
```algol
comment Convex from ALGOL 60: read a shared counter over HTTP, watch it
   over Live, and prove a mutation arrives on both. Against a fresh
   room the journey is 0 to 1.
   This file is the canonical example projected into the README and
   the website, so every step below is commented for a reader meeting
   Convex, and ALGOL 60, for the first time. It is assembled together
   with convex-native.alg, convex-buffer.alg, convex-json.alg,
   convex-http.alg, convex-ws.alg and convex-live.alg by the Docker
   build - see the Dockerfile for the exact command;

comment ---------------------------------------------------------------
   Reads count from a Convex demo record - {"count": N, ...} - and
   insists on a whole number. Convex may encode an integral count in
   decimal form, as 0 or as 0.0, and jsonparseint accepts both while
   rejecting a fractional, quoted or out of range value;
integer procedure examplecount(buf, off, limit, ok);
   value off, limit;
   integer array buf;
   integer off, limit, ok;
begin
   integer voff, vlen, found;
   integer array errbuf[0:255];
   integer errbuflen, errkind;
   errbuflen := 0; errkind := 0;
   jsonfindfield(buf, off, limit, "count", voff, vlen, found, errbuf, errbuflen,
      errkind);
   if errkind != 0 | found = 0 then
      ok := 0
   else
      examplecount := jsonparseint(buf, voff, vlen, ok)
end examplecount;

comment prints a caption, a nonnegative integer, and a newline, built
   as bytes and written with cxwrite rather than with ALGOL 60's own
   outinteger, which pads every number with a trailing separator space
   that would break the byte-for-byte match this example's stdout
   owes the canonical transcript. Every printed line in this example
   goes through this one procedure or printplain below, so stdout is
   never a mix of buffered ALGOL 60 output and raw written bytes,
   which this client's own tests found can interleave unpredictably;
procedure printline(caption, num);
   value num;
   string caption;
   integer num;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, caption);
   discard := bufputint(line, 256, linelen, num);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestdout, line, 0, linelen)
end printline;

comment prints one literal line with no number in it;
procedure printplain(text);
   string text;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, text);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestdout, line, 0, linelen)
end printplain;

comment writes a diagnostic to stderr, ALGOL 60's sigma channel, and
   exits with status 1. A missing value or a disagreement between
   HTTP and Live is a failed demonstration, not something to retry;
procedure givingup(msg);
   string msg;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, msg);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestderr, line, 0, linelen);
   discard := cxexit(1)
end givingup;

comment ---------------------------------------------------------------
   Example-wide state. One client, one deployment, exactly like every
   procedure in convex-http.alg and convex-live.alg expects to be
   handed explicitly, since ALGOL 60 has no way to share it silently.
   ------------------------------------------------------------------;

integer examplestderr;
integer examplestdout;
integer discard;
integer array examplehost[0:255];
integer examplehostlen;
integer array exampleport[0:15];
integer exampleportlen;
integer exampletls;
integer array exampleauth[0:1];
integer exampleroom;
integer array exampleroombuf[0:63];
integer exampleroomlen;

comment ---------------------------------------------------------------
   Building this example's arguments. Every Convex function below
   takes room, the shared counter's identity, so this is written once
   and reused for the query, the subscribe, and the mutation.
   ------------------------------------------------------------------;
procedure examplebuildargs(argsbuf, argscap, argslen, includemutationfields,
   runidbuf, runidlen);
   value argscap, includemutationfields, runidlen;
   integer array argsbuf, runidbuf;
   integer argscap, argslen, includemutationfields, runidlen;
begin
   integer discard;
   argslen := 0;
   discard := bufputbyte(argsbuf, argscap, argslen, 123);
   discard := bufputstr(argsbuf, argscap, argslen, "\"room\":");
   discard := jsonwritestring(argsbuf, argscap, argslen, exampleroombuf, 0,
      exampleroomlen);
   if includemutationfields != 0 then
      begin
      discard := bufputstr(argsbuf, argscap, argslen,
         ",\"language\":\"algol60\",\"runId\":");
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
   integer array urlbuf[0:1023];
   integer urllen, discard;
   integer array namebuf[0:15];
   integer namelen;
   integer array errbuf[0:255];
   integer errbuflen, errkind;

   comment Configuration: every native client in this project reads
      its deployment from CONVEX_URL, and ALGOL 60 has no environment
      access of its own, so this is the one place the example calls
      the shim's cxgetenv rather than a pure ALGOL 60 procedure;
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "CONVEX_URL");
   urllen := cxgetenv(namebuf, namelen, urlbuf, 1024);
   if urllen < 0 then givingup("CONVEX_URL is required");

   comment client creation: parse the deployment URL once into a host,
      a port and a scheme, exactly as convex-http.alg's HTTP calls and
      convex-live.alg's WebSocket connect both need them;
   errbuflen := 0; errkind := 0;
   deploymentparse(urlbuf, urllen, exampletls, examplehost, 256, examplehostlen,
      exampleport, 16, exampleportlen, errbuf, errbuflen, errkind);
   if errkind != 0 then givingup("CONVEX_URL could not be parsed");

   comment the verifier passes a unique room as this container's
      first argument, forwarded here as EXAMPLE_ROOM by the Docker
      image's entry script, and running the image by hand without one
      still works;
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "EXAMPLE_ROOM");
   exampleroomlen := cxgetenv(namebuf, namelen, exampleroombuf, 64);
   if exampleroomlen < 0 then
      begin
      exampleroomlen := 0;
      discard := bufputstr(exampleroombuf, 64, exampleroomlen,
         "algol60-example")
      end;

   liveinit;

   begin
      integer array pathbuf[0:31];
      integer pathlen;
      integer array argsbuf[0:511];
      integer argslen;
      integer array msgbuf[0:511];
      integer array bodybuf[0:8191];
      integer statuscode, kind, valoff, vallen, msglen;
      integer hasdata, dataoff, datalen, haslogs, logsoff, logslen;
      integer current, currentok;

      comment the HTTP query: ask Convex for the room's current state
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
      if errkind != 0 then givingup("the HTTP query failed");
      if kind = 1 then
         givingup("the HTTP query returned a Convex function error");

      comment decoding into an idiomatic value: Convex's JSON is
         parsed only as far as the one field this example promises;
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
         if errkind != 0 then givingup("the Live subscribe failed");

         begin
            integer initialkind, initial, initialok;
            integer array valuecopy[0:2047];
            integer valuelen;

            comment the initial Live value: the first delivery on a
               fresh subscription hydrates the same state the HTTP
               query above just read, over the WebSocket sync
               protocol rather than a second HTTP request;
            initialkind := livenext(sub, 10000);
            if initialkind = 0 then
               givingup("the initial Live value did not arrive "
                  "before the deadline");
            if initialkind = 2 then
               givingup("the initial Live value was a Convex "
                  "function error");
            valuelen := 0;
            livetakencopyvalue(valuecopy, 2048, valuelen);
            livereleasetaken;
            initial := examplecount(valuecopy, 0, valuelen, initialok);
            if initialok = 0 | initial != current then
               givingup("the initial Live count disagreed with HTTP");
            printline("live initial count: ", initial);

            begin
               integer array runid[0:31];
               integer runidlen;
               integer expected, appliedoff, appliedlen, afound, applied,
                  countoff, countlen, cfound, count, countok;
               integer array mutationpath[0:31];
               integer mutationpathlen;

               comment the mutation and its idempotency key: runId is
                  fresh random bytes on every run, and Convex uses it
                  to replay the earlier result rather than counting
                  twice if the same key ever arrived again;
               runidlen := 0;
               begin
                  integer array randbytes[0:15];
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
               if errkind != 0 then givingup("the mutation failed");
               if kind = 1 then
                  givingup("the mutation returned a Convex function error");
               expected := current + 1;
               jsonfindfield(bodybuf, valoff, valoff + vallen, "applied",
                  appliedoff, appliedlen, afound, errbuf, errbuflen, errkind);
               applied := if afound != 0 & bufeqstr(bodybuf, appliedoff,
                  appliedlen, "true") then 1 else 0;
               if applied = 0 then givingup("the mutation was not applied");
               jsonfindfield(bodybuf, valoff, valoff + vallen, "state",
                  countoff, countlen, cfound, errbuf, errbuflen, errkind);
               count := if cfound != 0 then examplecount(bodybuf, countoff,
                  countoff + countlen, countok) else 0;
               if cfound = 0 | countok = 0 | count != expected then
                  givingup("the mutation returned an unexpected count");
               comment printline always prints a trailing integer, and
                  this narration line has none, so it is written
                  directly with ALGOL 60's own outstring instead;
               printplain("mutation applied: true");
               printline("mutation count: ", count);

               begin
                  integer updatedkind, updated, updatedok;
                  integer array updatedcopy[0:2047];
                  integer updatedlen;

                  comment receiving the same change reactively: the
                     Live subscription delivers the mutation's result
                     with no second HTTP request at all;
                  updatedkind := livenext(sub, 10000);
                  if updatedkind = 0 then
                     givingup("the updated Live value did not arrive "
                        "before the deadline");
                  if updatedkind = 2 then
                     givingup("the updated Live value was a Convex "
                        "function error");
                  updatedlen := 0;
                  livetakencopyvalue(updatedcopy, 2048, updatedlen);
                  livereleasetaken;
                  updated := examplecount(updatedcopy, 0, updatedlen,
                     updatedok);
                  if updatedok = 0 | updated != expected then
                     givingup("the updated Live count disagreed "
                        "with the mutation");
                  printline("live updated count: ", updated);

                  comment only now, with the HTTP query, the initial
                     Live value, the mutation and the updated Live
                     value all agreeing, print the proof line;
                  begin
                     integer array line[0:255];
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

         comment cleanup: unsubscribe and close use the client's own
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
discard := cxexit(0)
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

Everything builds and runs inside Docker; nothing is installed on the host.

```sh
./run test algol60
```

Builds GNU MARST 2.7 from source, runs the style gate, compiles the native
support library, and executes the language-local suites: strict JSON and the
number rules, HTTP framing and the Convex envelope, the WebSocket codec and
the sync protocol, the adapter's wire shapes, and TLS verification against a
private CA. It also proves the example fails cleanly with no deployment
configured and prints nothing on stdout when it does.

```sh
./run verify-example algol60
```

Builds the minimal example image and runs the exact canonical example against
a unique room, comparing stdout byte for byte with the shared transcript.

```sh
./run verify algol60
./run verify-hosted algol60
./run verify-all algol60
```

Add shared black-box conformance against the approved local backend, then the
hosted drift target, then both from the same built source. Only the shared
result evaluator may award a badge.

## How it is put together

MARST has no linker for separately compiled ALGOL 60 units and no shared
global state across outer-level procedures — only lexical nesting inside a
`begin ... end` block shares variables — so the client is assembled from
layered source files at build time, innermost first:

| File | Responsibility |
| --- | --- |
| `client/convex-native.alg` | `code`-procedure headings for every native primitive |
| `client/convex-buffer.alg` | Byte buffers, base64, hex, and integer-division helpers |
| `client/convex-json.alg` | A strict JSON reader and writer, with no floating point |
| `client/convex-http.alg` | HTTP/1.1 framing and Convex's documented JSON HTTP functions |
| `client/convex-ws.alg` | RFC 6455 WebSocket framing |
| `client/convex-live.alg` | The sync profile, its single socket owner, and its delivery queue |
| `client/convexrt.c` | The only native code: sockets, TLS, poll, clock, entropy, environment |

The Dockerfile concatenates these files (plus a program-specific tail: the
example, a test suite, or the conformance adapter) into one `.alg` source
before handing it to `marst`. See the Dockerfile's `assemble_flat` and
`assemble_live` shell functions for the exact order.

### What the native library is, and is not

Standard ALGOL 60 has no sockets, no TLS, no monotonic clock, no entropy
source and no environment variable access, so `client/convexrt.c` supplies
exactly those, as fourteen `code`-procedure bodies declared outside the main
block. It is a little over six hundred lines and it contains no HTTP, no
WebSocket framing, no JSON, no retry policy and no Convex knowledge. Every
loop, deadline and bound is driven from ALGOL 60.

The boundary between the two languages is MARST's own calling convention —
scalar by-value arguments arrive as a `struct arg` thunk that must be
evaluated against the caller's dynamic storage area, and `integer array`
arguments arrive as a `struct dv*` dope vector — confirmed by reading the C
MARST itself generates, not assumed from documentation.

TLS verification is switched on inside that file rather than from ALGOL 60,
because a mistake there fails silently: peer verification, the default CA
bundle and `SSL_set1_host` hostname checking are all set together. The Docker
test stage proves it by connecting three ways to a local TLS server — trusted,
untrusted issuer, and wrong hostname — and only the first may succeed.

### A language with no strings, records or bitwise operators

Every buffer in this client is a parallel `integer array` of bytes with an
explicit length, never a string value: ALGOL 60 strings are literal constants
that can be passed through a `code` procedure but never built, compared byte
by byte, or returned. There are no record or struct types either, so a
structured result — an HTTP response, a parsed JSON node, a WebSocket frame
header — is a set of parallel scalar output parameters passed by name, not one
aggregate value.

There are no bitwise operators. Base64, hex and WebSocket masking are all
written with explicit `div`-by-power-of-two and a hand-written `intmod`
helper, because ALGOL 60's `%` operator is truncating integer division, not
remainder — `intmod(a, b)` is `a - (a div b) * b`, spelled out because the
project's own style gate would otherwise let `%` silently mean the wrong
thing in a base64 or WebSocket opcode calculation.

### One owner, and the barriers around it

Exactly one call path may touch the WebSocket, change the query-set version
or decide to reconnect: `client/convex-live.alg`'s procedures, driven by
whichever caller — the example, a test, or the conformance adapter's poll
loop — is currently inside one of them. ALGOL 60 has no concurrency of its
own, so this single-owner discipline is not a design choice on top of threads;
it is the only shape the language allows.

After a reconnect the server resends the current value of every active query.
Publishing that unchanged value would turn one logical update into two, so
each subscription remembers the exact bytes it last published and suppresses
an identical rehydration. Publishing an error clears that memory, which is
what lets a `QueryFailed` be followed by the same value again and still read
as a recovery.

### Framing that survives a timeout

The WebSocket reader never consumes a byte until the whole frame is buffered.
That one rule is what makes a mid-frame timeout safe: the partial frame stays
in the stream buffer and the next attempt resumes at the same offset instead
of re-synchronising on a byte that only looks like a frame header. A frame's
declared payload length is checked against the configured ceiling before any
payload byte is requested, so an inflated length header cannot make the
client reserve memory on a peer's behalf. `client/tests/live-test.alg` stops
in the middle of a frame, lets the deadline expire, and continues.

## Conformance and protocol notes

`client/tests/conformance/adapter.alg` is test infrastructure, not public
client code. It speaks NDJSON adapter protocol v1 over stdin and stdout, or
over one accepted TCP connection when `ADAPTER_LISTEN` is set, and calls the
real client for every operation. Stdout carries protocol events only; every
diagnostic goes to stderr.

It implements the adapter-only `debugDisconnect` command, declared in
`manifest.yaml` under `adapter.adapterOnlyCommands`, so the shared controller
can prove real reconnects. That command is not part of the educational client
API.

Optional fields are omitted rather than serialized as null: an absent command
id, an absent error `data` and an absent value never appear as `null`. Local
tests in `client/tests/live-test.alg` and `client/tests/client-test.alg`
check the underlying encoded shapes, so a mismatch is caught next to the code
that caused it instead of as an opaque schema failure during shared
conformance.

The pinned sync profile is recorded in `manifest.yaml`. It is an undocumented
protocol, and nothing here implies it is stable or officially supported.

## Limitations and deferred behaviour

- Shared local and hosted conformance passed, earning HTTP and Live. The
  limitations below remain deliberately outside those capabilities.
- The WebSocket handshake does not verify the server's `Sec-WebSocket-Accept`
  response header against SHA-1 of the client's key. Implementing SHA-1
  through arithmetic emulation, with no bitwise operators available, was
  judged out of scope for this checkpoint. A valid HTTP 101 upgrade response
  is still required, and every frame exchanged afterward is real RFC 6455
  framing; only that one header's cryptographic check is skipped.
- `convexcall` and `livesubscribe` open their own connection internally, and
  ALGOL 60 has no concurrency primitive to run a fixture server and the
  client under test in the same process. `client/tests/client-test.alg`
  therefore exercises the HTTP framing and envelope layers directly, and
  `client/tests/live-test.alg` pre-seeds an already-open loopback WebSocket
  handle rather than driving a real connect and handshake.
- Live is driven by the caller. Because ALGOL 60 has no concurrency, reactive
  updates arrive only while a caller is inside `livenext`, the adapter's
  event loop, or another client procedure.
- Live authentication, optimistic updates, WebSocket mutations, WebSocket
  actions, journals and `TransitionChunk` assembly are deferred.
- Live values cover Convex's JSON-safe subset; tagged Convex value
  conversions are deferred.
- JSON numbers are accepted only when mathematically integral and
  representable exactly as a MARST `integer` (32-bit) or, for timestamps,
  within the exact-integer range of a MARST `real` (an IEEE double, exact
  through 2^53); fractional and out-of-range values are rejected at the point
  of use.
- Active Live subscriptions and the delivery queue are bounded; a value too
  large for the configured byte budget becomes an observable `ProtocolError`
  without changing the subscription's last delivered value, and queue
  overflow drops the oldest undelivered event rather than growing without
  bound.
- MARST's own comment rule — a comment ends at the first semicolon, even
  inside a sentence — means every doc comment in this client was written, and
  is reviewed, to avoid a mid-sentence semicolon rather than to read as
  naturally as a comment in a modern language could.
