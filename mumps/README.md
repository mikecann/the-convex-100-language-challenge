# Convex from MUMPS

This demonstration uses YottaDB's implementation of M (MUMPS) to call
Convex's documented JSON HTTP endpoints and to keep a reactive query current
through a native M WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.m`](examples/basics/main.m) is the canonical example.
It reads a new counter room over HTTP, starts Live before changing it,
applies an idempotent mutation, and proves the same `0 -> 1` journey arrived
through the subscription. The block below is generated from that exact
runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, reconnect-on-drop with exponential backoff, unchanged-rehydration suppression, reactive error recovery, and clean close are implemented and pass shared local and hosted black-box conformance, including a debugDisconnect-triggered five-reconnect proof and a QueryFailed-then-recovery cycle. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m -->
```mumps
main ; Convex from MUMPS: the shared counter journey.
 ;
 ; The program reads a room's counter over Convex's documented HTTP API,
 ; starts a Live subscription, increments the counter once, and proves that
 ; the Live subscription reported the same change without polling.
 ;
 ; Run it with: CONVEX_URL=https://<deployment>.convex.cloud mumps -run main^main <room>
 ;
 do setup^convex
 new status set status=$$run()
 zhalt $select(status=0:0,1:1)
 ;
run()
 new url,room,args,current,initial,updated,expected
 new q set q=$char(34)
 ;
 ; Configuration: the deployment URL is required; the room comes from the
 ; verifier's first command-line argument, an environment variable for a
 ; convenient hand run, or a literal fallback so the example still does
 ; something when run with neither.
 set url=$ztrnlnm("CONVEX_URL")
 if url="" write "MUMPS example failed: CONVEX_URL is required",! quit 1
 set room=$piece($zcmdline," ",1)
 if room="" set room=$ztrnlnm("EXAMPLE_ROOM")
 if room="" set room="mumps-example"
 ;
 ; Client creation: one native MUMPS client for the deployment the container
 ; names. `open` resolves the URL and mints a fresh Live session id; nothing
 ; has touched the network yet.
 if '$$open^convex(url,"mumps-0.1.0") quit $$bail($$errorMessage^convex())
 set args="{"_q_"room"_q_":"_q_room_q_"}"
 ;
 ; Read the current value through Convex's documented HTTP query endpoint.
 new response
 if '$$query^convex("demo:state",args,.response) quit $$bail("query: "_$$errorMessage^convex())
 set current=$$count(response("value"),"current query")
 if current=-1 quit $$bail("")
 write "current count: ",current,!
 ;
 ; Start Live before mutating. Subscribing first is what makes the update
 ; below an observation rather than a race.
 if '$$subscribe^convex("counter","demo:state",args) quit $$bail("subscribe: "_$$errorMessage^convex())
 ;
 ; The first Live value hydrates the same state the HTTP query returned.
 set initial=$$next("initial Live value")
 if initial=-1 quit $$bail("")
 if initial'=current quit $$bail("the initial Live count disagreed with HTTP")
 write "live initial count: ",initial,!
 ;
 ; runId is the mutation's idempotency key. Convex records it, so a repeated
 ; run of the same key returns the previous result instead of incrementing
 ; twice. A fresh random key means this run really applies its increment.
 new mutation set mutation="{"_q_"room"_q_":"_q_room_q_","_q_"language"_q_":"_q_"mumps"_q_","_q_"runId"_q_":"_q_$$randomHex^convex(16)_q_"}"
 if '$$mutation^convex("demo:increment",mutation,.response) quit $$bail("mutation: "_$$errorMessage^convex())
 ;
 new mark,root,appliedNode,stateNode,applied,state
 set mark=$$jMark^convex()
 set root=$$jParse^convex(response("value"))
 set appliedNode=$select(root<0:-1,1:$$jFind^convex(root,"applied"))
 set stateNode=$select(root<0:-1,1:$$jFind^convex(root,"state"))
 set applied=$select(appliedNode>=0:$$jType^convex(appliedNode),1:"")
 set state=$select(stateNode>=0:$$jEncode^convex(stateNode),1:"")
 do jRelease^convex(mark)
 if applied'="true" quit $$bail("the mutation was not applied")
 ;
 set expected=current+1
 set state=$$count(state,"mutation")
 if state=-1 quit $$bail("")
 if state'=expected quit $$bail("the mutation returned an unexpected count")
 write "mutation applied: true",!
 write "mutation count: ",state,!
 ;
 ; Receive the same change over Live, without polling HTTP again.
 set updated=$$next("updated Live value")
 if updated=-1 quit $$bail("")
 if updated'=expected quit $$bail("the updated Live count disagreed with the mutation")
 write "live updated count: ",updated,!
 ;
 ; Every operation agreed before this proof line is printed.
 write "verified count: ",current," -> ",updated,!
 do closeLive^convex(2000)
 quit 0
 ;
 ; Wait for the next value this subscription publishes, and surface a
 ; reactive query failure as a failure rather than as a missing value.
next(operation)
 new hasError,errName,errMsg,value
 if '$$waitUpdate^convex("counter",15000,.hasError,.errName,.errMsg,.value) quit $$bail(operation_": "_$$errorMessage^convex())
 if hasError quit $$bail(operation_": "_errMsg)
 quit $$count(value,operation)
 ;
 ; Convex returns the room state as a JSON object. This narrows it to the
 ; non-negative integer the output contract needs, and refuses anything else.
count(value,operation)
 new mark,root,node,literal,result
 set mark=$$jMark^convex()
 set root=$$jParse^convex(value)
 if root<0!($$jType^convex(root)'="object") do  quit -1
 . do jRelease^convex(mark)
 . new discard set discard=$$bail(operation_" did not return a Convex object")
 set node=$$jFind^convex(root,"count")
 if node<0!($$jType^convex(node)'="number") do  quit -1
 . do jRelease^convex(mark)
 . new discard set discard=$$bail(operation_" returned no count")
 set literal=$$jText^convex(node)
 do jRelease^convex(mark)
 ; Convex JSON may encode an integral number as 0 or as 0.0. Both are
 ; accepted; fractional, non-finite, and out-of-range values are not.
 if '$$integral^convex(literal)!(literal<0) quit $$bail(operation_" returned a non-integral or negative count")
 quit literal+0
 ;
 ; One failure channel. Diagnostics belong on stderr so that stdout stays the
 ; exact shared transcript.
bail(message)
 do closeLive^convex(2000)
 ; `/dev/stderr` is a Unix path, not automatically an M device. The final
 ; image deliberately has no `/tmp`; a hosted transport failure used to reach
 ; this branch and then fatal with IONOTOPEN before it could print its real
 ; diagnostic. Open the already-mounted stderr stream first, just as the
 ; adapter does, so error handling remains safe in that stripped image.
 if message'="" open "/dev/stderr":append:5 use "/dev/stderr" write "MUMPS example failed: ",message,! use $principal
 quit -1
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test mumps            # installs YottaDB r2.06 (with its OpenSSL TLS
                             # plugin) from the pinned installer, compiles
                             # the client, and runs the real loopback
                             # HTTP/Live fixtures and unit tests, entirely
                             # offline
./run verify-example mumps  # runs the exact block above against a unique
                             # room on the local self-hosted backend
./run verify mumps          # verify-example plus shared black-box conformance
./run verify-hosted mumps   # verify-example plus conformance against the
                             # dedicated hosted drift target, over real TLS
./run verify-all mumps      # builds once, then runs both profiles above
```

`./run test mumps` installs YottaDB r2.06 from its pinned installer script
(Debian does not package it), building the OpenSSL-backed TLS plugin from
source as part of the same install, compiles every checked-in `.m` source to
a native object with `mumps -object`, runs `client/tests/jsontest.m` and
`client/tests/cryptotest.m` (the JSON codec and the SHA-1/base64 digest
primitives the WebSocket handshake depends on) with no network at all, and
runs `client/tests/httptest.m` and `client/tests/livetest.m` against real
`127.0.0.1` sockets served by `client/tests/fixture.m` -- not mocks -- so a
bug in the client's own request framing or WebSocket codec cannot pass by
construction. The local fixtures speak plain HTTP, so they never exercise
TLS; `verify-hosted`/`verify-all` are what first proved the real TLS path
against a real deployment.

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync`, matching every other client in this project.
- Every socket is opened with M's own `OPEN`/`USE`/`READ`/`WRITE` device
  syntax (device type `"SOCKET"`); TLS is a `WRITE /TLS(...)` on that same
  device, backed by YottaDB's OpenSSL plugin (`libgtmtls.so`, built from
  source with the installer's `--encplugin` option). No foreign process or
  shim is involved for the Convex protocol itself, for either plain or
  encrypted transport -- but YottaDB's TLS plugin never sends TLS Server
  Name Indication (confirmed by reading its source: `gtm_tls_connect()`
  calls `SSL_connect()` directly, with no `SSL_set_tlsext_host_name` call
  anywhere, and by cross-checking every documented `WRITE /TLS` config
  option, none of which touch SNI), which a real hosted deployment's
  TLS-terminating front requires to select a certificate at all --
  reproduced directly with `openssl s_client -noservername` against the
  same host, which fails with the identical handshake alert. `client/
  sni_shim.c` is a small `LD_PRELOAD` interposer that sets the SNI hostname
  from `CONVEX_URL` before delegating to the real `SSL_connect`; it carries
  no Convex, HTTP, JSON, or WebSocket logic, the same narrow pattern this
  project already uses for a language runtime missing exactly one native
  primitive (see `icon/client/shim.c`).
- `sockOpen` deliberately opens an empty `SOCKET` device first and `USE`s it
  with `CONNECT`, then reads `$KEY` while it is the current device, rather
  than trusting `$DEVICE` on a single combined `OPEN`/`CONNECT`: `$DEVICE`
  was observed reporting success for both a live connection and a genuinely
  refused one, which YottaDB's own documentation attributes to `$DEVICE`/
  `$KEY` only being meaningful for the device actually `USE`d. `$KEY`
  reliably reports `"ESTABLISHED|handle|address"` on success and `""` on
  failure.
- `sockRead` uses the uncounted form of `READ`, not `READ var#count:timeout`:
  direct experiment against a peer that writes a few bytes and then holds
  the connection open confirmed the counted form blocks for the whole
  timeout (or EOF) instead of returning as soon as any data is ready, which
  would make every read on a live connection cost its entire budget.
- Live delivery buffering is deliberate and bounded in two layers. The
  client itself keeps only the latest value per subscription (a Transition
  overwrites the prior one in place -- no unbounded queue). The test-only
  conformance adapter (`client/tests/conformance/adapter.m`) adds a bounded
  output queue on top of that for backpressure toward the controller: 8
  slots, a 4 MiB byte budget, subscription events droppable oldest-first,
  and `hello`/`result`/`error`/`ack`/`closed` responses never dropped.
- Reconnect-on-drop uses exponential backoff (250ms base, doubling, capped
  at 30s), reset to the base the moment a handshake next succeeds so a
  healthy connection never inherits a stale, grown delay from an earlier,
  unrelated run of failures. `liveMaybeReconnect` is polled once per
  adapter main-loop pass rather than run on its own thread -- M here is
  single-threaded, so the Live socket, the controller connection, and
  reconnect scheduling are all driven from that one loop, never touched
  concurrently.
- A reconnect resends every active subscription's `Add` and arms a
  one-shot rehydration guard per subscription. If the very next
  `QueryUpdated` for that subscription is byte-identical to the value it
  had before the drop, it is suppressed rather than delivered a second
  time; a changed value, or a `QueryFailed`, clears the guard and is
  delivered normally. This keeps a debugDisconnect-triggered reconnect's
  observable sequence exactly initial value, disconnect acknowledgement,
  external change, updated value -- not an extra unchanged rehydration in
  between.
- `subscribe` sends its query's `Add` two different ways depending on
  whether a Live connection is already up: a cold start's `Add` rides
  along in the same `ModifyQuerySet` that `liveConnect` uses to replay
  every active subscription, while a second (or later) subscription on an
  already-open connection sends its own incremental `ModifyQuerySet`.
  Getting the branch between those two cases backwards silently drops the
  second path entirely -- shared conformance (`client/live/external-update`
  onward) is what caught this, since the language-local fixture only ever
  exercises a single subscription per connection.
- `client/tests/conformance/adapter.m` implements NDJSON adapter protocol
  v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode, and declares
  `debugDisconnect` as its one adapter-only command.
- Fragmented WebSocket messages are reassembled correctly: continuation
  frames are concatenated as raw payload bytes into the message in
  progress, control frames (ping/pong/close) are handled between the
  fragments of a data message per RFC 6455 without disturbing that
  assembly, and UTF-8 is never separately validated by this client (Convex
  JSON payloads are decoded byte-for-byte in M mode; the JSON parser itself
  rejects malformed encoding while parsing string literals).
- YottaDB always attaches a database region at process startup, even though
  this client never references a `^global`; a region is created once at
  build time (`mupip create`) and shipped read-only inside the runtime
  images, never written again.

## Limitations

- Live authentication, WebSocket-issued mutations/actions, journals, and
  `TransitionChunk` assembly are deferred; a `TransitionChunk` is reported
  as protocol drift and the connection reconnects.
- A YottaDB process always runs in byte-oriented M mode here (`ydb_chset=M`
  for every stage), not UTF-8 mode. `--utf8` is deliberately never passed to
  the installer: it would only add a second, ICU-linked engine variant this
  client never selects, at the cost of an extra dependency.
