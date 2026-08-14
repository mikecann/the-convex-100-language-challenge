<p align="center"><img src="logo.png" alt="J programming language logo" width="128"></p>
<!-- Logo source: https://www.jsoftware.com/images/jblue.png -->

# J

[J](https://www.jsoftware.com/) is a general-purpose array programming
language created by Ken Iverson and Roger Hui. It grew from the APL tradition,
but uses ASCII punctuation rather than APL's special glyphs. J remains a
focused tool for mathematical, statistical, and logical data analysis, where
applying one operation to a whole array can express a lot of work compactly.

This native client is an educational, unofficial demonstration. It is not a
production SDK or a package you should depend on.

## Getting Started

Start with [`examples/basics/main.ijs`](examples/basics/main.ijs). It reads a
counter, opens a Live subscription, sends one increment with a fresh
idempotency key, and observes the reactive update. From the repository root,
run the exact example in its Docker image with:

```sh
./run verify-example j
```

## Interesting Parts

### One assignment, three results

Iverson designed J's verbs to take one or two arguments, never more, so
multi-part calls travel as boxed lists glued together with `;` (Link) — and
replies come back the same way. A string of names on the left of `=.` splits
a reply in one stroke.

```text
args=. '{"room":',(jw_quote room),'}'

NB. TypeScript: const state = useQuery(api.demo.state, { room })
'ok value logs'=. convex_query 'demo:state';args

'pok root'=. cx_unpack2 cx_json_parse value
node=. root jfind 'count'
count=. ". jpay > node    NB. Runtime-checked; no generated types to lean on.
```

### Field access is a table search

J has no record type, and the client does not bolt one on. A decoded JSON
object is an n-by-2 boxed table of key/value rows, so looking up a field is
column extraction plus `i.` — index-of, one of the oldest APL-family
primitives. Trimmed to its heart, the client's `jfind` is:

```text
jfind=: 4 : 0
  pairs=. jpay x
  keys=. 0 {"1 pairs    NB. "1 applies { row by row: the whole key column.
  hit=. keys i. <y      NB. i. searches that column in one stroke.
  if. hit = # keys do. _1 return. end.
  1 { hit { pairs
)

node=. root jfind 'count'   NB. TypeScript: state.count, checked by tsc instead.
```

### The WebSocket mask is three array verbs

RFC 6455 makes a client XOR every outgoing payload byte with a fresh 4-byte
mask. Most clients loop; J explodes both operands into bit planes with `#:`
(antibase), combines them with `6 b.` — the Boolean function whose truth
table is XOR — and folds the planes back into bytes with `#.`.

```text
tx_xor=: 4 : 0
  bx=. (8#2) #: x        NB. Every byte becomes its 8 bits, all at once.
  by=. (8#2) #: y
  (8#2) #. bx (6 b.) by  NB. XOR the bit planes, then fold back to bytes.
)

mask=. tx_random_bytes 4
masked=. payload tx_xor (n $ mask)  NB. $ cycles the mask across the payload.
```

The same pair writes each frame's big-endian length field: `2 tx_be n` is
`(2#256) #: n`, literally "the digits of n in base 256".

### You pump the reactive loop yourself

This client earned the `live` badge, so these are real Convex sync-protocol
subscriptions — J just declines to hide the loop. Where `useQuery` subscribes
during render and re-renders on every update, this single-threaded client
gives one owner three verbs: subscribe, pump the socket, drain the queue.

```text
sok=. cx_live_subscribe (<'counter'),(<'demo:state'),(<args)

while. 1 do.
  cx_live_pump 200        NB. Give the socket 200 ms of attention.
  'ok utag value logs errname errmsg errdata'=. cx_live_next_update ''
  if. ok do. break. end.  NB. A mutation from any client lands here, unpolled.
end.
NB. TypeScript: useQuery re-renders for you; here every update is one you pumped.
```

When the counter changes — in this process or anywhere else in the world —
the next pump delivers it. Realtime, at crank speed.

## Status

Capability badges come only from shared black-box verification. This client
earned both `http` and `live`: 31 of 31 checks passed against the local backend
and 31 of 31 against the hosted deployment over real TLS, using the same clean
exact-head build.

| Capability | Status | Evidence |
| --- | --- | --- |
| Docker build and local tests | Passing | `./run test j` builds pinned jsource 9.8.0-beta6 and runs all five language-local suites. |
| HTTP query, mutation, and action | `http` earned | Both verification profiles cover bearer-token lifecycle and structured `ConvexError` data. |
| Live subscriptions | `live` earned | Both profiles cover updates, failure recovery, and five real forced reconnects. |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ijs -->
```text
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

## Implementation Notes

```sh
./run test j              # builds jsource from source, runs every local suite
./run verify-example j    # runs the exact example above against a unique room
./run verify j             # adds shared black-box conformance against the local backend
./run verify-hosted j      # repeats both against the hosted drift target
```

The implementation is native J. It uses J's `15!:0` foreign conjunction to
call libc for sockets, OpenSSL for TLS, and libcrypto for SHA-1 and random
bytes. HTTP envelopes, JSON parsing, WebSocket framing, and Convex-specific
Live behavior remain J code. Nothing delegates those jobs to another Convex
client, `curl`, Node.js, or Python.

`./run test j` builds the pinned interpreter and runs local suites. The other
commands exercise the exact canonical example and then add local or hosted
black-box conformance. They are listed here as the evidence workflow, not as a
claim that they were rerun for this documentation edit.

### Client layout

| File | Role |
| --- | --- |
| `client/json.ijs` | The JSON reader and writer: a tagged-boxed-pair value representation, verbatim number literals, `\uXXXX` escapes via J's own `u:` Unicode conversion. |
| `client/transport.ijs` | Every `15!:0` foreign binding (libc sockets, libssl TLS, libcrypto digests/randomness), deadline-bounded plain and TLS connections, base64, and the monotonic clock. |
| `client/convex.ijs` | Deployment URL parsing, the documented HTTP envelope (`query`/`mutation`/`action`), and HTTP framing (status line, headers, chunked bodies). |
| `client/websocket.ijs` | The RFC 6455 upgrade handshake and frame codec: client masking (built from whole-array bit-plane XOR, not a per-byte loop), fragment length encoding, and UTF-8 validation of a reassembled message. |
| `client/live.ijs` | The Live sync state machine: `Connect`, `ModifyQuerySet` (Add/Remove), `Transition` validation and application, reconnect with backoff, and the bounded delivery queue. |
| `client/tests/conformance/adapter.ijs` | Test-only NDJSON adapter v1 for the shared controller. |
| `examples/basics/main.ijs` | The canonical example, projected into this README verbatim. |

### Live ownership

One pump owns the WebSocket, which fits J's single-threaded execution model.
Subscriptions are rows in a boxed table, and callers alternate
`cx_live_pump` with draining the bounded delivery queue. On reconnect the pump
replays active subscriptions, suppresses unchanged rehydration values, and
keeps function failures recoverable. The sync profile is pinned because it is
not a documented, stable third-party API.

### Buffering

The client owns its Live delivery queue, so both bounds are explicit: the
newest 16 deliveries within 4 MiB. Subscription events are droppable and are
dropped oldest first. The adapter's own output queue is bounded separately
(8 events, 4 MiB including one in-flight write); responses are never
droppable, and if only responses remain when the budget is crossed the
adapter fails loudly instead of growing.

### Conformance adapter

`client/tests/conformance/adapter.ijs` is test infrastructure, not public
client code. It calls the real client for every operation and owns the
test-only `debugDisconnect` hook used to prove reconnect behavior.

### Tests

Every suite runs inside the `test` image, entirely against hand-built input
-- none of them open a socket, so they run the same whether or not a
deployment is reachable.

| Suite | What it covers |
| --- | --- |
| `json_test.ijs` | Round trips, verbatim number literals, `\uXXXX` escapes and surrogate pairs, every rejection (trailing content, duplicate keys, unpaired surrogates, control characters), and `jfind` lookup. |
| `transport_test.ijs` | Big/little-endian byte packing, bytewise XOR, base64 against RFC 4648 test vectors, SHA-1 against the standard `"abc"` vector, UUID shape, and monotonic-clock sanity. |
| `convex_test.ijs` | Deployment URL parsing and its rejections, the integral-number decoding rule at the 2^53 boundary, and HTTP status-line/header/chunked framing. |
| `websocket_test.ijs` | The RFC 6455 worked handshake example from the spec text, frame masking, and a 4-byte UTF-8 character deliberately split across a fragment boundary with a PING interleaved between the fragments -- the same fixture idea `icon/` uses for its own frame-boundary test. |
| `tests/conformance/adapter_test.ijs` | Direct coverage of `adapter_id_valid` and the `adapter_error`/`adapter_result` JSON shapes: plain-ASCII and multi-byte UTF-8 ids, empty/invalid-UTF-8/over-128-codepoint rejection, structured error data carried verbatim, and an empty id omitted rather than serialised as a bogus field. Loads `adapter.ijs` as a library via `ADAPTER_AUTOEXEC=: 0` instead of running its real stdin/TCP loop. |

## Known Issues

1. WebSocket mutations and actions, Live authentication, optimistic updates,
   journals, and `TransitionChunk` assembly are not implemented.
2. Values cover Convex's JSON-safe subset. Int64, bytes, special floats, and
   negative zero are out of scope. Strings containing U+0000 are rejected.
3. DNS resolution is the one unbounded connection step. Later TCP, TLS, read,
   and write work uses monotonic deadlines.
4. Bracketed IPv6 deployment URLs are rejected.
5. The client is single threaded, so an HTTP call can delay Live reads until
   that call reaches its own deadline.
6. The canonical `.ijs` example uses a plain-text fence because the shared
   README projector has no J syntax-highlighting mapping.
