# Convex from Mojo

A native Mojo client that calls Convex functions over HTTP and keeps queries
current over the pinned Live WebSocket profile — with every protocol layer
written in Mojo, because Mojo's standard library has none of them.

This is educational and unofficial, not a production Convex SDK.

## Start here

[`examples/basics/main.mojo`](examples/basics/main.mojo) follows one shared
counter from 0 to 1: it reads the count over HTTP, starts a Live subscription
*before* the write so no reactive update can slip through the gap, applies an
idempotent mutation, and then watches the same subscription deliver the new
value.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.mojo -->
```mojo
"""The shared counter, from 0 to 1, over HTTP and Live from Mojo."""

from std.os import getenv
from std.sys import argv, exit, stderr

from convex import Client, default_ca_file
from json import parse, quote


fn die(message: String):
    """Report a failure on stderr and stop.

    Stdout is the transcript the shared verifier compares byte for byte, so
    nothing diagnostic is ever allowed to reach it.
    """
    print(message, file=stderr)
    exit(1)


fn count_of(value_json: String) -> Int:
    """Decode the `count` field of a `demo:state` value.

    Convex JSON writes a whole count as either `0` or `0.0`, so this accepts
    any mathematically integral number and rejects a fractional, quoted or
    out-of-range one instead of silently truncating it.
    """
    try:
        var doc = parse(value_json)
        return doc.as_int(doc.member(doc.root, "count"))
    except:
        return -1


fn main() raises:
    # The deployment comes from the environment; the room is the first
    # argument, which is how the verifier gives every run its own counter.
    var url = getenv("CONVEX_URL")
    if not url:
        die(String("CONVEX_URL is required"))
    var arguments = argv()
    var room = String(arguments[1]) if len(arguments) > 1 else String(
        "mojo-basic-example"
    )

    # Create the client. It reads the CA bundle staged in this image, because
    # every hosted Convex deployment is reached over TLS.
    var client = Client(url, default_ca_file())
    var room_args = String('{"room":') + quote(room) + "}"

    # Read the counter over HTTP first, so the starting point is established
    # before anything reactive is involved.
    var initial = client.call(String("query"), String("demo:state"), room_args)
    if not initial.ok or count_of(initial.value_json) != 0:
        die(String("unexpected initial query value: ") + initial.error_message)
    print("current count: 0")

    # Subscribe before the mutation. Starting Live first is what guarantees the
    # update caused by the mutation cannot be missed in the gap between them.
    client.subscribe(String("live"), String("demo:state"), room_args)
    var first = client.wait_update(String("live"), 20000)
    if first.failed or count_of(first.value_json) != 0:
        die(String("unexpected initial Live value: ") + first.error_message)
    print("live initial count: 0")

    # The run ID makes the mutation idempotent: replaying it after a retry
    # returns the same state instead of incrementing the counter twice.
    var mutation_args = String('{"room":')
    mutation_args += quote(room)
    mutation_args += ',"language":"Mojo","runId":'
    mutation_args += quote(room + "-once")
    mutation_args += "}"
    var applied = client.call(
        String("mutation"), String("demo:increment"), mutation_args
    )
    if not applied.ok:
        die(String("mutation failed: ") + applied.error_message)
    var result = parse(applied.value_json)
    if not result.truth(result.member(result.root, "applied")):
        die(String("the mutation reported that it was not applied"))
    var state = result.member(result.root, "state")
    if result.as_int(result.member(state, "count")) != 1:
        die(String("the mutation returned an unexpected count"))
    print("mutation applied: true")
    print("mutation count: 1")

    # The same subscription now carries the reactive consequence of that write.
    var updated = client.wait_update(String("live"), 20000)
    if updated.failed or count_of(updated.value_json) != 1:
        die(String("unexpected updated Live value: ") + updated.error_message)
    print("live updated count: 1")

    # Retire the subscription and the connection before reporting success.
    client.unsubscribe(String("live"))
    client.close(2000)

    # Printed only once HTTP and Live agree on the whole 0 -> 1 journey.
    print("verified count: 0 -> 1")
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test mojo` compiles the client, the example and the adapter inside
Docker and runs the language-local suites: the JSON reader and writer, SHA-1
and the WebSocket accept token, the deterministic Live suite, the adapter
event shapes, and both adapter transports.

`./run verify-example mojo` executes the exact example above from its minimal
image against the approved backend and compares its stdout to the shared
transcript.

`./run verify mojo` adds the shared black-box conformance run, and
`./run verify-all mojo` repeats it against the hosted drift target from the
same built image.

## How it is built

Mojo compiles ahead of time to a native ELF executable. It is distributed as a
PyPI wheel, so the build stage has Python and pip in it; nothing from that
stage reaches the runtime image, which is `FROM scratch` and contains only the
compiled binary, the shared libraries it actually loads, a CA bundle, and the
shell plus POSIX text tools the shared image policy requires.

Everything Convex-specific, and every protocol layer beneath it, is Mojo:

- **Sockets and TLS** — `client/net.mojo` declares `getaddrinfo`, `socket`,
  `connect`, `poll`, `read`, `write` and the OpenSSL handshake and record-layer
  entry points through `sys.ffi.external_call`. Those are the same C functions a
  C client links against; only the spelling is Mojo. `getaddrinfo` results are
  tried in turn, so an AAAA answer on an IPv4-only Docker bridge falls through
  to the A record instead of stalling. TLS verification pins the expected
  hostname with `SSL_set1_host` and checks `SSL_get_verify_result`.
- **JSON** — `client/json.mojo` is a reader and writer over a flat node arena
  with a hard depth bound. Number tokens are kept verbatim, so a Convex value
  that arrives as `0.0` is echoed back as `0.0` rather than normalised.
- **HTTP/1.1** — `client/http.mojo` builds the request and parses the status
  line, headers, and a body delimited by `Content-Length`, chunked encoding, or
  end of stream.
- **WebSocket** — `client/websocket.mojo` implements RFC 6455 from the
  specification: the opening handshake, SHA-1 for the `Sec-WebSocket-Accept`
  check, client masking with kernel entropy, continuation assembly, and control
  frames handled mid-message.
- **Convex** — `client/convex.mojo` owns the documented HTTP function calls and
  the pinned sync state machine.

This is `native` rather than `binding` provenance: no pre-built Mojo package
wraps sockets, HTTP or WebSockets here, and no Convex protocol work is
delegated to another language's client.

## Protocol notes and limits

The adapter speaks NDJSON protocol v1 on stdin/stdout, or over the one
`ADAPTER_LISTEN` TCP connection the shared controller dials.

The client is single-threaded on purpose. A `pump` call is the only code that
reads the WebSocket, writes it, reconnects it, or advances the query-set
version, so exclusive ownership is structural rather than enforced by a lock.
`subscribe`, `unsubscribe` and the adapter-only `debugDisconnect` record intent
and `pump` performs it. Reconnects back off from 100 ms to 15 s and reset to
the floor after a successful handshake. Each new connection resends `Add` for
every active query, and an unchanged rehydration is suppressed so a reconnect
does not deliver the same value twice.

Delivery is bounded twice over: each subscription keeps the newest 16 updates
and at most 256 KiB of encoded value text, dropping the oldest when a consumer
is slow. A count limit alone would not be a memory limit when one value can
approach the maximum frame size.

Retiring a subscription — by `unsubscribe` or by re-registering the same ID —
clears its queue before the acknowledgement is published, so no value queued
for the old registration can be delivered under the new one.

A frame is consumed from the read buffer only once all of its bytes have
arrived, so a read that hits its deadline mid-frame leaves the buffer untouched
and resumes at the same boundary rather than misreading a payload byte as an
opcode. UTF-8 is validated once, on the reassembled message, because a
codepoint may legitimately straddle a fragment boundary.

## Limitations

- Live authentication, optimistic updates, WebSocket mutations and WebSocket
  actions are deferred. `setAuth` applies to HTTP calls only.
- Live values cover the JSON-safe subset; tagged Convex value types are
  deferred.
- `TransitionChunk` assembly is deferred and treated as protocol drift that
  reconnects.
- One HTTP connection is opened per call rather than pooled, so keep-alive
  reuse is deferred.
- `libNVPTX.so` is part of the shared-library closure of every compiled Mojo
  program in this release and is therefore staged in the runtime image. It is a
  runtime library, not a command: the final image contains no `mojo`, no
  compiler frontend, no interpreter and no package manager.
