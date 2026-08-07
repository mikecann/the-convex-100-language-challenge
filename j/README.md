# Convex from J

This is a Convex client written in J (Jsoftware), the array-oriented APL
descendant. It reads a counter over Convex's documented JSON HTTP API,
subscribes to the same query over a WebSocket, and watches its own increment
arrive on that subscription.

J has no bundled HTTP, TLS, WebSocket, or JSON library, so this client goes
straight to the operating system: J's own `15!:0` foreign conjunction (`cd`,
"call dll") declares direct bindings to `libc.so.6` for raw TCP sockets, to
`libssl.so.3` for the TLS 1.3 handshake, and to `libcrypto.so.3` for SHA-1 and
randomness. There is no compiled C helper anywhere in this client -- every
foreign call is declared in `client/transport.ijs` itself, the same
in-process approach proven end to end against this project's own hosted
deployment before any client source was written. Everything that makes it a
*Convex* client -- the JSON reader and writer, the documented HTTP envelope,
RFC 6455 WebSocket framing and masking, the pinned sync profile, and the
single-owner Live state machine with its reconnect and replay -- is J. Nothing
shells out to curl, websocat, Node, or Python; that would make this a bridge
rather than a native client.

It is an educational demonstration, not an official Convex SDK, and not a
package to depend on. Convex's realtime sync protocol is not a documented,
stable third-party API, so the profile it implements is pinned to one
inspected revision and recorded in `manifest.yaml`.

## Start here

[`examples/basics/main.ijs`](examples/basics/main.ijs) is the canonical
example. It queries `demo:state` over HTTP, subscribes before mutating so no
update can be missed, increments the counter once with a random idempotency
key, and then proves the same `0 -> 1` change arrived over Live. Every value
is checked, so the example fails rather than printing a transcript it did not
earn.

## What works

Capability badges are awarded only by the shared black-box controller, and
this client has not been through it yet.

| Capability | State | Notes |
| --- | --- | --- |
| Builds in Docker | `./run test j` passes | jsource 9.8.0-beta6 builds from source inside Docker; the runtime and example images build and pass their in-image policy probes. |
| HTTP query, mutation, action | Implemented, local tests pass, proven against the hosted deployment during development | Verified by shared local and hosted conformance |
| Live subscriptions | Implemented, local tests pass, proven against the hosted deployment during development (including five real `debugDisconnect` reconnects) | Verified by shared local and hosted conformance |
| Language-local tests | Passing | `json_test.ijs`, `transport_test.ijs`, `convex_test.ijs`, and `websocket_test.ijs` exercise the JSON codec, byte/crypto primitives, HTTP framing, and RFC 6455 frame assembly without a socket. |
| Earned capability badges | None | Nothing is claimed until `./run verify j` and `./run verify-hosted j` pass. |

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ijs -->
```j
NB. Convex from J: the shared counter journey.
NB.
NB. The program reads a room's counter over Convex's documented HTTP API,
NB. starts a Live subscription, increments the counter once, and proves
NB. that the Live subscription reported the same change without polling.
NB.
NB. Run it with:  CONVEX_URL=https://<deployment>.convex.cloud convex-example <room>

load '/project/client/live.ijs'

NB. Convex returns the room state as a JSON object. This narrows it to the
NB. non-negative integer the output contract needs, and refuses anything
NB. else -- including a fractional or out-of-range count that happened to
NB. arrive as valid JSON.
example_count=: 3 : 0
  'value operation'=. y
  'pok root'=. cx_unpack2 cx_json_parse value
  if. -. pok do. example_fail operation,' did not return a Convex object' return. end.
  if. -. 'o' -: jtag root do. example_fail operation,' did not return a Convex object' return. end.
  node=. root jfind 'count'
  if. node = _1 do. example_fail operation,' returned no count' return. end.
  if. -. 'n' -: jtag > node do. example_fail operation,' returned no count' return. end.
  literal=. jpay > node
  NB. Convex JSON may encode an integral number as 0 or as 0.0. Both are
  NB. accepted; fractional, non-finite, and out-of-range values are not.
  if. -. convex_integral literal do.
    example_fail operation,' returned a non-integral or negative count' return.
  end.
  count=. ". literal
  if. count < 0 do.
    example_fail operation,' returned a non-integral or negative count' return.
  end.
  count
)

NB. One failure channel. Diagnostics belong on stderr so that stdout stays
NB. the exact shared transcript.
example_fail=: 3 : 0
  EXAMPLE_FAILED=: 1
  msg=. 'J example failed: ', y, LF
  write_J 2;msg;(# msg)
  _1
)

NB. Wait for the next value this subscription publishes, and surface a
NB. reactive query failure as a failure rather than as a missing value.
example_next=: 3 : 0
  'tag operation deadline'=. y
  while. 1 do.
    cx_live_pump 200
    'ok utag value logs errname errmsg errdata'=. cx_live_next_update ''
    if. ok do.
      if. utag -: tag do.
        if. 0 < # errname do.
          example_fail operation,': ',errmsg return.
        end.
        example_count value;operation return.
      end.
    end.
    if. (tx_remaining deadline) = 0 do.
      example_fail operation,': timed out waiting for a Live update' return.
    end.
  end.
)

NB. Close the Live socket and drop every subscription within a bounded
NB. budget, so a stalled deployment cannot keep the example running.
example_shutdown=: 3 : 0
  status=. y
  cx_live_close 2000
  if. status < 0 do. 1 return. end.
  status
)

example_main=: 3 : 0
  EXAMPLE_FAILED=: 0
  cx_live_reset ''
  url=. tx_getenv 'CONVEX_URL'
  if. 0 = # url do. example_fail 'CONVEX_URL is required' return. end.

  NB. The verifier passes a unique room as the first argument; the literal
  NB. default only makes a hand run convenient.
  room=. 'j-example'
  argv=. ARGV
  if. 2 < # argv do. room=. > 2 { argv end.

  if. -. convex_open url;'j-0.1.0' do.
    example_shutdown example_fail convex_error_message ''
    return.
  end.
  args=. '{"room":',(jw_quote room),'}'

  NB. Read the current value through Convex's documented HTTP query
  NB. endpoint.
  'qok qvalue qlogs'=. convex_query 'demo:state';args
  if. -. qok do.
    example_shutdown example_fail 'query: ', convex_error_message ''
    return.
  end.
  current=. example_count qvalue;'current query'
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.
  echo 'current count: ', ": current

  NB. Start Live before mutating. Subscribing first is what makes the
  NB. update below an observation rather than a race.
  sok=. cx_live_subscribe (<'counter'),(<'demo:state'),(<args)
  if. -. sok do.
    example_shutdown example_fail 'subscribe: ', convex_error_message ''
    return.
  end.

  NB. The first Live value hydrates the same state the HTTP query
  NB. returned.
  initial=. example_next 'counter';'initial Live value';(tx_now_ms '')+15000
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.
  if. initial ~: current do.
    example_shutdown example_fail 'the initial Live count disagreed with HTTP'
    return.
  end.
  echo 'live initial count: ', ": initial

  NB. runId is the mutation's idempotency key. Convex records it, so a
  NB. repeated run of the same key returns the previous result instead of
  NB. incrementing twice. A fresh random key means this run really applies
  NB. its increment.
  runid=. tx_uuid ''
  mutargs=. '{"room":',(jw_quote room),',"language":"j","runId":',(jw_quote runid),'}'
  'mok mvalue mlogs'=. convex_mutation 'demo:increment';mutargs
  if. -. mok do.
    example_shutdown example_fail 'mutation: ', convex_error_message ''
    return.
  end.

  'pok mroot'=. cx_unpack2 cx_json_parse mvalue
  applied=. 0
  statecount=. _1
  if. pok do.
    if. 'o' -: jtag mroot do.
      appliednode=. mroot jfind 'applied'
      if. appliednode ~: _1 do.
        if. 't' -: jtag > appliednode do. applied=. 1 end.
      end.
      statenode=. mroot jfind 'state'
      if. statenode ~: _1 do.
        statecount=. example_count (cx_json_encode > statenode);'mutation'
      end.
    end.
  end.
  if. -. applied do.
    example_shutdown example_fail 'the mutation was not applied'
    return.
  end.
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.

  expected=. current + 1
  if. statecount ~: expected do.
    example_shutdown example_fail 'the mutation returned an unexpected count'
    return.
  end.
  echo 'mutation applied: true'
  echo 'mutation count: ', ": statecount

  NB. Receive the same change over Live, without polling HTTP again.
  updated=. example_next 'counter';'updated Live value';(tx_now_ms '')+15000
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.
  if. updated ~: expected do.
    example_shutdown example_fail 'the updated Live count disagreed with the mutation'
    return.
  end.
  echo 'live updated count: ', ": updated

  NB. Every operation agreed before this proof line is printed.
  echo 'verified count: ', (": current), ' -> ', ": updated
  example_shutdown 0
)

exit example_main ''
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test j              # builds jsource from source, runs every local suite
./run verify-example j    # runs the exact example above against a unique room
./run verify j             # adds shared black-box conformance against the local backend
./run verify-hosted j      # repeats both against the hosted drift target
```

`./run test j` proves that jsource 9.8.0-beta6 builds from source, that every
J source file parses and its local suites pass, and that the runtime and
example images satisfy the shared filesystem policy. It proves nothing about
a real deployment. `./run verify-example j` runs the canonical example itself
against Convex and compares its stdout with the shared transcript.
`./run verify j` adds the shared controller, which is the only thing that can
award HTTP or Live.

## How it is put together

| File | Role |
| --- | --- |
| `client/json.ijs` | The JSON reader and writer: a tagged-boxed-pair value representation, verbatim number literals, `\uXXXX` escapes via J's own `u:` Unicode conversion. |
| `client/transport.ijs` | Every `15!:0` foreign binding (libc sockets, libssl TLS, libcrypto digests/randomness), deadline-bounded plain and TLS connections, base64, and the monotonic clock. |
| `client/convex.ijs` | Deployment URL parsing, the documented HTTP envelope (`query`/`mutation`/`action`), and HTTP framing (status line, headers, chunked bodies). |
| `client/websocket.ijs` | The RFC 6455 upgrade handshake and frame codec: client masking (built from whole-array bit-plane XOR, not a per-byte loop), fragment length encoding, and UTF-8 validation of a reassembled message. |
| `client/live.ijs` | The Live sync state machine: `Connect`, `ModifyQuerySet` (Add/Remove), `Transition` validation and application, reconnect with backoff, and the bounded delivery queue. |
| `client/tests/conformance/adapter.ijs` | Test-only NDJSON adapter v1 for the shared controller. |
| `examples/basics/main.ijs` | The canonical example, projected into this README verbatim. |

### Live

One pump owns the WebSocket, matching J's own single-threaded execution
model: the adapter loop alternates between pumping the socket
(`cx_live_pump`) and taking one controller command, and every step is bounded
by a monotonic deadline. Subscriptions never touch the socket themselves;
they are rows in a small boxed table (`CX_SUBS`) that the pump owner reads.

- Each connection sends `Connect` with the session id, connection count, last
  close reason, and `maxObservedTimestamp`, then replays the whole active
  query set as `Add` modifications. That is what restores subscriptions after
  a drop, and it was proven against the hosted deployment with five real
  `debugDisconnect` reconnects, each followed by a mutation and a correctly
  received Live update.
- A `Transition` is validated in full -- state versions, timestamp ordering,
  and every modification -- before any part of it is published.
- A repeated identical value is suppressed via a per-subscription signature,
  so a reconnect's rehydration does not masquerade as a new update.
- `QueryFailed` becomes a typed `FunctionError` event that leaves the
  subscription active; transport and protocol faults become `TransportError`
  and `ProtocolError` events, and the same subscription still delivers later
  values after the reconnect.
- Unsubscribe invalidates the local subscription state and purges its queued
  deliveries before the acknowledgement is sent.
- Convex's 64-bit sync timestamps are base64-encoded little-endian integers,
  compared byte by byte from the most significant end rather than converted
  to one J number, so a value nowhere near J's exact-double-precision safe
  range never loses a bit.
- Fragment reassembly and a control frame arriving mid-message are handled by
  the pump loop; UTF-8 is validated exactly once, on the fully reassembled
  message, using J's own `u:` Unicode conversion plus an explicit check for
  an encoded UTF-16 surrogate half (valid input to `u:`, but not valid UTF-8).

### Buffering

The client owns its Live delivery queue, so both bounds are explicit: the
newest 16 deliveries within 4 MiB. Subscription events are droppable and are
dropped oldest first. The adapter's own output queue is bounded separately
(8 events, 4 MiB including one in-flight write); responses are never
droppable, and if only responses remain when the budget is crossed the
adapter fails loudly instead of growing.

### The adapter

`client/tests/conformance/adapter.ijs` implements NDJSON adapter protocol v1.
It is test infrastructure, not public client code: it reserves stdout for
protocol events, sends diagnostics to stderr, works over stdin/stdout by
default or the `ADAPTER_LISTEN` TCP socket the shared harness uses, and calls
the real client for every operation. It implements the adapter-only
`debugDisconnect` command, declared in `manifest.yaml` and deliberately
absent from the educational client API. Because stdin/stdout are not
sockets, the adapter's stdio transport enforces its own deadlines with
`poll()` rather than the `SO_RCVTIMEO`/`SO_SNDTIMEO` socket options the rest
of the client uses.

Optional members are omitted rather than serialized as null, because the
shared controller validates every line against
`_shared/schemas/adapter.schema.json`.

## Tests

Every suite runs inside the `test` image, entirely against hand-built input
-- none of them open a socket, so they run the same whether or not a
deployment is reachable.

| Suite | What it covers |
| --- | --- |
| `json_test.ijs` | Round trips, verbatim number literals, `\uXXXX` escapes and surrogate pairs, every rejection (trailing content, duplicate keys, unpaired surrogates, control characters), and `jfind` lookup. |
| `transport_test.ijs` | Big/little-endian byte packing, bytewise XOR, base64 against RFC 4648 test vectors, SHA-1 against the standard `"abc"` vector, UUID shape, and monotonic-clock sanity. |
| `convex_test.ijs` | Deployment URL parsing and its rejections, the integral-number decoding rule at the 2^53 boundary, and HTTP status-line/header/chunked framing. |
| `websocket_test.ijs` | The RFC 6455 worked handshake example from the spec text, frame masking, and a 4-byte UTF-8 character deliberately split across a fragment boundary with a PING interleaved between the fragments -- the same fixture idea `icon/` uses for its own frame-boundary test. |

## Known limitations and honest risks

`./run test j` passes: the jsource source build, every language-local suite,
and the runtime/example image policy probes all run green inside Docker.
During development, the full stack -- HTTP query/mutation, the WebSocket
handshake, Live subscribe/receive, and five real `debugDisconnect`
reconnects each followed by a mutation and a correctly delivered update --
was proven directly against this project's hosted deployment. `./run
verify-example j`, `./run verify j`, and `./run verify-hosted j` have not
been run yet as part of this evidence trail, so no HTTP or Live capability
badge is claimed here until they do.

- WebSocket mutations, WebSocket actions, Live authentication, optimistic
  updates, journals, and `TransitionChunk` assembly are not implemented.
- Values are limited to Convex's JSON-safe subset. Int64, bytes, special
  floats, and negative zero are not claimed, and strings containing U+0000
  are refused because the JSON reader's own end-of-input sentinel would
  otherwise collide with a genuine embedded NUL byte.
- DNS resolution is the one unbounded step in a connection; every later step
  honours a monotonic deadline.
- Bracketed IPv6 deployment URLs are refused rather than mis-parsed.
- The client is single threaded by construction. A long HTTP call delays
  Live reads until that call's own deadline expires.
- Syntax highlighting for the example block falls back to plain text, because
  the shared README projector has no `.ijs` fence mapping; `j` is used here
  as the closest available label.
