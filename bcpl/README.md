# BCPL

[BCPL](https://www.cl.cam.ac.uk/~mr10/BCPL.html) is a small, typeless systems
programming language designed by Martin Richards in 1966 and first implemented
at MIT in 1967. It grew out of CPL, influenced B and then C, and was built to
make compilers and systems software portable. Today it is a historical niche,
but Richards still publishes the [Cintcode manual](https://www.cl.cam.ac.uk/~mr10/bcplman.pdf)
and example programs. Cambridge's [history of the language](https://www.cl.cam.ac.uk/newlabphotos/MR/)
summarises its influence on B and C.

This project uses BCPL to query a Convex counter over HTTPS and watch it update
over a WebSocket. It is educational, unofficial, unsupported by Convex, and not
a production SDK.

## Getting Started

Start with [`examples/basics/main.b`](examples/basics/main.b). It reads a fresh
room, subscribes before writing, increments the counter once, and checks the
Live update from `0` to `1`.

From the repository root, Docker builds and runs the exact canonical example:

```sh
./run verify-example bcpl
```

## Interesting Parts

### The linker is `GET`: the whole client arrives as source

BCPL predates the module system, the package manager and mostly the linker
itself, so a large program is assembled by textual inclusion: `GET` splices
another source file in, and a lone `.` separates independently compiled
sections. The canonical example pulls in the entire Convex client — HTTP,
WebSocket, JSON and the sync protocol — with one line.

```text
SECTION "convexclient"

GET "libhdr"      // the standard library arrives the same way
GET "convexhdr"
GET "convex.b"    // HTTP, WebSocket, JSON and the Convex sync protocol

.                 // a dot ends one section; the program itself starts here

SECTION "convexbasics"
```

The dependency graph is the order of the `GET` lines, and nothing else.

### A record is a word plus arithmetic

BCPL has exactly one data type — the machine word — and its `!` operator is
indirection: `result!1` means "the word one past where `result` points". Every
structure in this client, from JSON nodes to call results, is a vector whose
field names are `MANIFEST` constants for the offsets.

```text
MANIFEST { Rs_value = 0     // from convexhdr.h: a record layout is
           Rs_logs  = 1 }   // nothing but named word offsets

path := bbFromStr("demo:state")
result := convexCall(client, "/api/query", path, queryargs,
                     cxDeadline(Httptimeoutms))
// TypeScript: const state = useQuery(api.demo.state, { room })
started := countOf(result!Rs_value)
```

What TypeScript proves at compile time, this program establishes by naming its
offsets in one header and trusting the arithmetic.

### `VALOF` put statements inside an expression in 1966

Decades before arrow functions, BCPL let an expression run a block of
statements until `RESULTIS` supplied its value. Add `@` (address-of) and the
negative conditional `UNLESS`, and decoding a Convex value reads as a small
proof rather than a cast.

```text
AND countOf(state) = VALOF
{ LET count = 0
  // TypeScript: state.count is already typed; here the word must be checked
  UNLESS jsWholeNumber(jsObjectGet(state, "count"), @count) RESULTIS -1
  RESULTIS count
}
```

`jsWholeNumber` writes through the address `@count` only when the JSON node
really is a whole number, so `-1` is a genuine mismatch, never a truncation.

### Subscribe first, and the update cannot be missed

BCPL has no threads, so the client keeps one single-threaded Live manager that
owns the WebSocket, the query set and every reconnect decision. The blocking
`convexNextUpdate` hands you the next value; subscribing before mutating is
what guarantees the write's update cannot slip between two calls.

```text
subscription := convexSubscribe(client, bbFromStr("example"),
                                bbCopy(path), jsClone(queryargs))
// ... increment the counter over HTTP ...
// TypeScript: useQuery(api.demo.state, { room }) rerenders on its own
update := convexNextUpdate(client, subscription, cxDeadline(15000))
UNLESS countOf(update!Up_value) = finished DO
  fail("the updated Live value disagreed with the mutation")
upFree(update)
```

The same reactive delivery a React component gets from `useQuery`, expressed
as one explicit question: what changed next?

## Status

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Implemented | TLS 1.2+, certificate and hostname verified |
| Structured function errors | Implemented | `ConvexError` data is preserved, never flattened into a value |
| Bearer token lifecycle | Implemented | Set, replace and clear |
| Live subscriptions | Implemented | `Add`, `Remove`, initial value, external update, `QueryFailed` and recovery |
| Live reconnect | Implemented | Exponential backoff, query-set replay, unchanged-rehydration suppression |
| Convex log lines | Implemented | Returned with HTTP results and Live updates |
| Live authentication | Deferred | Subscriptions are unauthenticated |
| Optimistic updates | Deferred | Not implemented |
| WebSocket mutations and actions | Deferred | Mutations and actions go over HTTP |
| Chunked transitions | Deferred | `TransitionChunk` is treated as protocol drift and reconnects |
| Tagged Convex value types | Deferred | Live values cover the JSON-safe subset |
| Earned capability badges | **http, live** | 31/31 shared conformance tests pass against both the self-hosted and hosted backends |

The earned capabilities remain `http` and `live`, backed by 31/31 shared tests
against both the self-hosted and hosted backends.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.b -->
```text
// The canonical BCPL Convex example: watch a shared counter go from 0 to 1.
//
// The first section of this file is the client library itself. BCPL builds a
// multi-module program by textual inclusion, so GET "convex.b" pulls in the
// HTTP, WebSocket, JSON and sync-protocol code, and the second section below
// is the program that uses it.

SECTION "convexclient"

GET "libhdr"
GET "convexhdr"
GET "convex.b"

.

SECTION "convexbasics"

GET "libhdr"
GET "convexhdr"

// Every line of the transcript goes to the process's real stdout through the
// transport boundary. BCPL's own writef would go to the Cintcode console,
// which the launcher has pointed at stderr precisely so that runtime chatter
// can never appear in a verified transcript.
LET emit(text) BE
{ LET line = bbNew(64)
  UNLESS line RETURN
  bbPushStr(line, text)
  bbPush(line, '*n')
  cxOut(line)
  bbFree(line)
}

// Prints a label and a number that came out of Convex. Rendering the decoded
// value, rather than the constant the run is hoping for, is what makes the
// transcript evidence instead of a script.
AND emitCount(label, count) BE
{ LET line = bbNew(64)
  UNLESS line RETURN
  bbPushStr(line, label)
  bbPushNum(line, count)
  bbPush(line, '*n')
  cxOut(line)
  bbFree(line)
}

// Diagnostics belong on stderr, and a disagreement anywhere in the journey has
// to end the run: the example is only evidence if it fails on a wrong value.
AND fail(reason) BE
{ cxDiagStr(reason)
  IF errMessage DO
  { LET detail = bbNew(280)
    IF detail ~= 0 DO
    { bbPushStr(detail, "  ")
      bbPushBuffer(detail, errMessage)
      bbPush(detail, '*n')
      cxDiag(detail)
      bbFree(detail)
    }
  }
  stop(1)
}

// Convex may encode a whole count as 0 or as 0.0 depending on the path the
// value took, so both have to decode to the same integer. jsWholeNumber
// accepts either and refuses a fractional, quoted or out-of-range value rather
// than truncating it, which is what makes -1 here a genuine mismatch.
AND countOf(state) = VALOF
{ LET count = 0
  UNLESS jsWholeNumber(jsObjectGet(state, "count"), @count) RESULTIS -1
  RESULTIS count
}

// The room to use. The verifier passes a unique one as the first argument;
// running the image by hand without arguments gets a friendly default.
AND exampleRoom() = VALOF
{ LET room = cxGetenv("CONVEX_ROOM_ARG")
  IF room ~= 0 DO IF room!Bb_len > 0 RESULTIS room
  IF room ~= 0 DO bbFree(room)
  room := cxGetenv("EXAMPLE_ROOM")
  IF room ~= 0 DO IF room!Bb_len > 0 RESULTIS room
  IF room ~= 0 DO bbFree(room)
  RESULTIS bbFromStr("bcpl-basic-example")
}

LET start() = VALOF
{ LET url = 0
  LET room = 0
  LET client = 0
  LET queryargs = 0
  LET mutationargs = 0
  LET runid = 0
  LET path = 0
  LET result = 0
  LET subscription = 0
  LET update = 0
  LET applied = 0
  LET started = 0
  LET finished = 0

  // Bring up the transport boundary: the monotonic clock, the random source
  // and the process descriptors all come from it.
  UNLESS convexInit() DO
  { cxDiagStr("the BCPL native transport extension is not available")
    stop(1)
  }

  // Configure the deployment from the environment, exactly as every other
  // client in this repository does.
  url := cxGetenv("CONVEX_URL")
  IF url = 0 DO fail("CONVEX_URL is required")
  IF url!Bb_len = 0 DO fail("CONVEX_URL is required")
  room := exampleRoom()

  // Creating the client parses the deployment URL and decides whether the
  // connection will be TLS. Nothing is opened yet.
  client := convexNew(url)
  IF client = 0 DO fail("the Convex client could not be created")

  // Both the query and the subscription watch the same room.
  queryargs := jsObject()
  jsObjectPutStr(queryargs, "room", jsStringFromBuffer(bbCopy(room)))

  // Read the counter over HTTP first, so the starting point is established
  // before anything reactive is involved. The function path is a byte buffer
  // the client copies into the request; it stays this program's to free.
  path := bbFromStr("demo:state")
  result := convexCall(client, "/api/query", path, queryargs,
                       cxDeadline(Httptimeoutms))
  IF result = 0 DO fail("the initial Convex query failed")
  started := countOf(result!Rs_value)
  UNLESS started = 0 DO fail("the room did not start at zero")
  convexResultFree(result)
  emitCount("current count: ", started)

  // Subscribe before the mutation. Starting Live first is what guarantees the
  // update caused by the mutation cannot be missed between the two calls.
  // The identifier, path and arguments belong to the client from here.
  subscription := convexSubscribe(client, bbFromStr("example"),
                                  bbCopy(path),
                                  jsClone(queryargs))
  IF subscription = 0 DO fail("the Convex subscription could not be created")

  // The first Live value is the current state, delivered as soon as the
  // WebSocket handshake and the query set have been established.
  update := convexNextUpdate(client, subscription, cxDeadline(15000))
  IF update = 0 DO fail("no initial Live value arrived")
  IF update!Up_errname DO fail("the initial Live value was an error")
  UNLESS countOf(update!Up_value) = started DO
    fail("the initial Live value disagreed with the HTTP query")
  emitCount("live initial count: ", countOf(update!Up_value))
  upFree(update)

  // The run identifier makes the mutation idempotent: replaying it with the
  // same identifier reports applied=false and leaves the count alone, so a
  // retry after a network failure cannot double-count.
  runid := bbCopy(room)
  bbPushStr(runid, "-once")
  mutationargs := jsObject()
  jsObjectPutStr(mutationargs, "room", jsStringFromBuffer(bbCopy(room)))
  jsObjectPutStr(mutationargs, "language", jsStringFromStr("BCPL"))
  jsObjectPutStr(mutationargs, "runId", jsStringFromBuffer(bbCopy(runid)))

  bbFree(path)
  path := bbFromStr("demo:increment")
  result := convexCall(client, "/api/mutation", path, mutationargs,
                       cxDeadline(Httptimeoutms))
  IF result = 0 DO fail("the Convex mutation failed")
  applied := jsObjectGet(result!Rs_value, "applied")
  UNLESS jsType(applied) = Jt_true DO fail("the mutation was not applied")
  finished := countOf(jsObjectGet(result!Rs_value, "state"))
  UNLESS finished = started + 1 DO
    fail("the mutation did not advance the count by one")
  convexResultFree(result)
  emit("mutation applied: true")
  emitCount("mutation count: ", finished)

  // The same write now arrives reactively, over the connection opened earlier.
  update := convexNextUpdate(client, subscription, cxDeadline(15000))
  IF update = 0 DO fail("no updated Live value arrived")
  IF update!Up_errname DO fail("the updated Live value was an error")
  UNLESS countOf(update!Up_value) = finished DO
    fail("the updated Live value disagreed with the mutation")
  emitCount("live updated count: ", countOf(update!Up_value))
  upFree(update)

  // Removing the subscription tells the deployment to stop tracking the query
  // and closes the WebSocket with a proper closing handshake.
  convexUnsubscribe(client, subscription)

  // Only now, with the HTTP read, the mutation and both Live values agreeing,
  // is the journey verified.
  { LET line = bbNew(64)
    IF line = 0 DO fail("out of memory")
    bbPushStr(line, "verified count: ")
    bbPushNum(line, started)
    bbPushStr(line, " -> ")
    bbPushNum(line, finished)
    bbPush(line, '*n')
    cxOut(line)
    bbFree(line)
  }

  convexClose(client)
  convexFree(client)
  jsFree(queryargs)
  jsFree(mutationargs)
  bbFree(path)
  bbFree(runid)
  bbFree(room)
  bbFree(url)
  RESULTIS 0
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

### Docker gates

Everything is built and run inside Docker; nothing is installed on the host.

```sh
./run build bcpl            # build the linux/amd64 image
./run test bcpl             # hygiene checks, compilation, and the language-local tests
./run verify-example bcpl   # run the example above against a unique room
./run verify bcpl           # shared black-box conformance against the local backend
./run verify-hosted bcpl    # the same conformance against the hosted drift target
./run verify-all bcpl       # both deployment profiles from one build
```

What each proves, and what it does not:

- `test` proves the sources are clean, that the BCPL compiles, and that the
  language-local unit and loopback tests pass. It proves nothing about Convex.
- `verify-example` runs the exact example above in the minimal image against a
  unique room and compares its stdout to the shared transcript, character for
  character. Compilation is not example evidence.
- `verify` adds the shared conformance suite driving the adapter black-box.
  Example success is not full client conformance.
- `verify-hosted` repeats it against the hosted deployment, which is where
  protocol drift shows up. Local conformance does not replace it.

### How it is put together

```text
client/
  convexhdr.h    manifests, record layouts, and the global vector numbering
  base.b         the transport boundary as BCPL sees it, byte buffers, errors
  digest.b       SHA-1, base64, UTF-8 validation
  json.b         a bounded JSON reader and writer
  http.b         HTTP/1.1 over the byte transport
  ws.b           an RFC 6455 WebSocket client
  live.b         the Convex sync protocol and the subscription owner
  convex.b       the public API; GETs the modules above
  native/
    convexext.c    the entire native surface: sockets, TLS, clock, random
    convexlaunch.c the ELF entrypoint that starts the Cintcode interpreter
  tests/
    clienttests.b  JSON, digests, URLs, the handshake matrix, bounds, queues
    livetests.b    WebSocket framing, hostile peers, and the Live owner
    conformance/
      adapter.b    the NDJSON adapter protocol v1 executable (test-only)
examples/
  basics/main.b  the canonical example
```

There is no build file. The Docker build copies these sources into a scratch
directory, installs `convexhdr.h` beside the distribution's own `libhdr.h` so
that `GET "convexhdr"` resolves exactly the way `GET "libhdr"` does, and
compiles four programs from it: the adapter, the example, and the two test
programs. Nothing about that layout leaks back into the repository.

### The native boundary

`client/native/convexext.c` replaces `sysc/extfn.c` in the Cintcode
distribution, which upstream documents as *"This file can be modified by users
to provide any extension to the BCPL library that the user would like."* It is
compiled and linked into `cintsys64`, not the 32-bit `cintsys`. It exposes
these operations, none of which knows what Convex is:

| Operation | Purpose |
| --- | --- |
| `init` | install the process descriptors, the clock epoch and OpenSSL |
| `now` | monotonic milliseconds, the basis of every deadline |
| `getenv` | read a process environment value |
| `random` | cryptographic random bytes for masks, keys and session ids |
| `connect` | resolve a name, open TCP, optionally negotiate and verify TLS |
| `read` / `write` | move bytes against an absolute deadline |
| `close` | release a handle |
| `listen` / `accept` | the adapter's TCP mode |
| `wait` | readiness on up to two handles at once |
| `errtext` | the last native failure, for diagnostics |
| `tlsavail` | whether TLS is compiled in |

HTTP requests and responses, chunked bodies, WebSocket masking and framing,
the handshake proof, JSON, and every Convex message are produced and consumed
in BCPL above that line.

`client/native/convexlaunch.c` is the ELF file at
`/usr/local/bin/convex-adapter`. A Cintcode program is not an ELF binary, in
the same way a `.class` file is not one, so something has to start the
interpreter. The launcher also moves the real stdout onto a spare descriptor
and points descriptor 1 at stderr, because the Cintcode system prints a banner,
a prompt and a trailing newline of its own. Without that split those bytes
would corrupt the adapter's NDJSON and the example's transcript; with it they
become ordinary stderr diagnostics.

### Concurrency, or the absence of it

BCPL has no threads. Exclusive ownership of the WebSocket is therefore
structural rather than locked: one record, the Live manager, holds the
connection, the query-set version and every reconnect decision, and it is only
ever advanced from `lvStep`. Subscribe, unsubscribe and the adapter's
`debugDisconnect` record their intent on that record; none of them touches the
socket. The adapter interleaves controller commands and Live traffic by waiting
on both descriptors at once and giving the owner a slice each time round.

### Memory

The Cintcode memory is allocated once, at startup, at a fixed three million
64-bit words, or 24 MiB, the same byte ceiling a 32-bit build would get from six
million 32-bit words. Every BCPL allocation in this client comes out of it, so
the client's memory ceiling is a property of the process rather than a promise.
Inside it, each buffer is capped at 4 MiB, a WebSocket frame at 1 MiB, a
reassembled message at 2 MiB, an HTTP request body and an HTTP response body at
2 MiB each, and each subscription's delivery queue at 16 updates **and**
256 KiB. Both subscription bounds are enforced, because a count bound alone is
not a memory bound when one Convex value can approach the maximum frame size.

The request bound is separate from the buffer bound on purpose: the request
line, headers and body are assembled in one buffer before anything is written,
so a body that would not leave room for the rest of the message is refused
rather than sent truncated behind a `Content-Length` that no longer describes
it. A chunked response is decoded the same way: each consumed chunk is
trimmed off the front of the raw stream, so the encoding never has to fit in
memory beside the body it decodes to.

### Numbers

JSON numbers are kept as their literal text rather than converted. Even this
system's 64-bit words cannot hold every number a JSON document can carry. A
value near IEEE double precision's range is one example, so holding the
lexeme is what lets every value survive a round trip exactly as Convex sent
it. A caller that wants an integer asks `jsWholeNumber`, which accepts
Convex's `0` and `0.0` forms and the exponent notations that stay integral,
and refuses anything fractional, quoted, or wider than the 19 decimal digits
this system's `maxint` (9223372036854775807) can hold.

### Formatting

BCPL predates the idea of a code formatter and no BCPL implementation ships
one, so `./run test bcpl` holds the checked-in sources to an explicit hygiene
contract instead: no tabs, no carriage returns, no trailing whitespace, no
line past 100 columns, a final newline, and nothing outside printable ASCII.
It also holds the C boundary to a warning-free `-Wall -Wextra -Werror` build. Short
single-line error arms such as `UNLESS buffer DO { bbFree(other); RESULTIS 0 }`
are kept because they are the idiom the BCPL distribution itself uses
throughout, not to save lines.

The ASCII rule is not tidiness. The 2015 compiler reads its source a byte at a
time and the language never defined what a high-bit byte inside a string
literal means, so the UTF-8 the tests need is pushed byte by byte instead of
written as a literal. The client itself handles UTF-8 perfectly well; it just
never has to read any from its own source.

### Conformance and protocol notes

- The adapter at `client/tests/conformance/adapter.b` is test infrastructure,
  not public client code. It speaks NDJSON adapter protocol v1 over stdin and
  stdout, or over the TCP address in `ADAPTER_LISTEN`, and calls the same
  `convex*` entry points the example uses.
- Every event is built as a JSON value and serialised, so an absent `id`,
  `value`, `error` or `data` is absent rather than serialised as `null`.
  `client/tests/clienttests.b` checks the exact bytes of the success, structured
  HTTP error, subscription error, unattributable error and close events.
- `debugDisconnect` is adapter-only and declared in `manifest.yaml`. It
  acknowledges only after the old connection has been retired and the reconnect
  has been scheduled, and it marks every subscription as expecting a
  rehydration so an unchanged replay is suppressed.
- The sync protocol is pinned by `syncProfile` in `manifest.yaml`. It is not a
  documented or supported Convex API, and this client treats any departure from
  the pinned shape, such as an unknown message, a discontinuous `Transition`,
  or a `TransitionChunk`, as drift that
  reconnects rather than as data.
- The WebSocket reader is resumable, not blocking. Bytes accumulate and the
  parse cursor only ever advances over a frame that has arrived in full, so a
  deadline that expires halfway through a frame leaves the parser exactly where
  it was. `client/tests/livetests.b` feeds a frame in one byte at a time with a
  timeout between every byte and asserts the message still assembles.
- The hostile-peer matrix in the same file covers masked server frames,
  reserved bits, impossible lengths, fragmented and oversized control frames,
  orphan continuations, interleaved data frames, invalid UTF-8 and a one-byte
  close payload. Close is asserted against its deadline with an idle peer, a
  peer that never stops sending, and a peer stalled halfway through a frame.
- The opening handshake is validated rather than assumed. `wsHandshakeOk` takes
  a response block and the proof the client computed for its own key, so
  `client/tests/clienttests.b` can drive the whole refusal matrix without a
  deployment: a wrong `Sec-WebSocket-Accept`, a status other than 101, a
  missing or wrong `Upgrade`, a `Connection` header without the upgrade token,
  and an extension or subprotocol this client never offered.
- Retiring the last subscription, and closing the client, both perform the RFC
  6455 closing handshake instead of dropping TCP, bounded by the same two
  second deadline. Exactly one close frame leaves each connection.

## Known Issues

1. **The transport is not BCPL.** Sockets, TLS, name resolution, the monotonic
    clock, and random bytes come from the C extension because this Cintcode
    distribution does not provide them.
1. Live subscriptions are unauthenticated. `setAuth` affects HTTP calls only.
1. Optimistic updates, WebSocket mutations and WebSocket actions are not
   implemented; mutations and actions go over HTTP.
1. `TransitionChunk` assembly is not implemented.
1. Live values cover the JSON-safe subset. Tagged Convex value types such as
   `Int64` and `Bytes` are not decoded.
1. HTTP opens one connection per request. Keep-alive is not implemented.
1. Numbers outside the 64-bit Cintcode word (wider than 19 decimal digits, or
   past 9223372036854775807) round trip exactly but cannot be decoded to an
   integer.
1. The toolchain is pinned to a 2015 mirror of Martin Richards' distribution
   and is patched at build time for one gap in it: the pinned commit's
   `cintsys64.c` `dosys()` switch never received the 2014 addition of
   `sys(Sys_ext, ...)` that the 32-bit `cintsys.c` has, so there was no way for
   a 64-bit-Cintcode BCPL program to reach a user C extension at all. The
   Dockerfile patches in the same one-line `case 68` (`Sys_ext`'s value, from
   `g/libhdr.h`) that the 32-bit interpreter already has, anchored so a future
   upstream sync that already carries the fix fails the anchor assertion
   instead of silently duplicating it.
1. This client targets `cintsys64`, the distribution's 64-bit Cintcode system,
   because the 32-bit one segfaults on this architecture independently of any
   Convex code. Confirmed directly on the build host: `gdb --batch -ex run -ex
   bt` on the plain, unmodified 32-bit `bcpl` compiler compiling a five-line
   "hello world" program shows `SIGSEGV` inside libc `ftell()`, called with a
   sign-extended garbage `FILE*`. A 32-bit BCPL word was holding a raw C pointer
   that a 64-bit host handed back above `2**32`, deep inside the
   distribution's own `cintsys.c` `dosys()`, before any client source is ever
   reached. It reproduces with no Convex extension linked in at all.
