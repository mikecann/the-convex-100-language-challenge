<img src="logo.png" alt="Mojo" width="234">
<!-- Logo source: https://mojolang.org/img/mojo-wordmark.svg -->

# Mojo

Mojo is a young systems programming language from Modular, first shown publicly
in 2023. It borrows Python's approachable syntax, then adds static types,
ownership-aware semantics, and native compilation influenced by languages such
as Rust, C++, and Swift. Modular is building it primarily for high-performance
AI infrastructure and code that spans CPUs, GPUs, and other accelerators.

That makes Mojo an interesting but still evolving choice in 2026, with a much
smaller application ecosystem than mainstream languages. The language's
present-day home is kernels, numerical work, and AI systems rather than ordinary
web clients like this one. Start with the [official Mojo site](https://mojolang.org/)
or the [Mojo Manual](https://docs.modular.com/mojo/manual/). This Convex client
is an educational, unofficial demonstration, not a production SDK.

## Getting Started

The canonical [`examples/basics/main.mojo`](examples/basics/main.mojo) program
reads a fresh counter, subscribes before changing it, applies one idempotent
mutation, and observes the reactive update from `0` to `1`.

From the repository root, run:

```sh
./run verify-example mojo
```

The command builds and runs that exact example inside Docker against the
approved test backend. It does not require a Mojo toolchain on your host.

## Interesting Parts

### A caret that means "take it, don't copy it"

Mojo's ownership model shows up right in a function's parameter list: an
argument is a read-only borrow by default, `mut self` asks for a mutable one,
and a `var` parameter is *owned* — the caller must hand it over. The `^`
sigil on `update^` marks that handoff explicitly, telling the compiler to move
the value into the queue rather than copy it.

```mojo
fn enqueue(mut self, var update: Update):
    """Append one delivery, dropping the oldest to stay inside both bounds."""
    var incoming = update.size()
    self.queue.append(update^)
    # TypeScript: queue.push(update) is always a reference, never a transfer.
    self.queue_bytes += incoming
    while len(self.queue) > QUEUE_CAPACITY or (
        self.queue_bytes > QUEUE_BYTE_BUDGET and len(self.queue) > 1
    ):
        var oldest = self.queue.pop(0)
        self.queue_bytes -= oldest.size()
        self.dropped += 1
```

Nothing here is garbage-collector bookkeeping — the compiler tracks who owns
`update` at every line, and `enqueue` is the only place it is ever named again.

### A `raises` you can't leave off, guarding a hand-pumped subscription

Where `useQuery` subscribes on render and lets React manage delivery, this
client's Live loop is one the caller drives by hand: `wait_update` pumps the
WebSocket until a delivery is queued or a deadline passes, and the chance of
failure is written straight into the return type via `raises`.

```mojo
fn wait_update(mut self, id: String, timeout_ms: Int) raises -> Update:
    """Pump the connection until this subscription has a delivery."""
    var deadline = now_ms() + timeout_ms
    while True:
        if self.has_update(id):
            return self.take_update(id)
        if now_ms() >= deadline:
            # TypeScript: this is the wait `useQuery`'s loading state hides.
            raise Error(
                "TransportError|timed out waiting for a Live update"
            )
        self.pump(25)
```

Every caller of `wait_update` either handles that failure or is itself marked
`raises` — Mojo won't let a possible error cross a plain function boundary
unannounced, the same way it won't let an owned value cross one unmoved.

### Python's slice syntax, pinned to a byte offset

Mojo reads like Python until a string gets sliced. A `String` here is a UTF-8
byte buffer rather than Python's abstract sequence of characters, so carving
out a substring means saying, in the slice itself, which unit is being counted.

```mojo
fn error_name_of(message: String) -> String:
    """Split the `Name|text` convention the transport layers raise with."""
    var bar = message.find("|")
    if bar > 0:
        return String(message[byte=0:bar])
    return String("Error")
```

It is the same square-bracket slice a Python programmer already reaches for,
with one extra keyword pinning down exactly what it is counting.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented |

Both HTTP and Live are earned capabilities. The missing Live features above
remain missing rather than being inferred from the passing subset.

## Example

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

## Implementation Notes

The demonstration pins Mojo `0.26.2.0` and compiles ahead of time to native
`linux/amd64` executables. Mojo is installed from its Python wheel only in the
Docker build stage. The final images contain the executable, its Mojo shared
library closure, OpenSSL, a CA bundle, and the small shell toolset required by
the repository. They contain no Python interpreter, Mojo compiler, package
manager, or delegated Convex client.

At this pinned version, the standard library does not provide the networking
and serialization stack this client needs. [`client/net.mojo`](client/net.mojo)
calls libc sockets and OpenSSL through Mojo's C FFI, while
[`client/json.mojo`](client/json.mojo), [`client/http.mojo`](client/http.mojo),
and [`client/websocket.mojo`](client/websocket.mojo) implement JSON, HTTP/1.1,
and WebSocket framing in Mojo. Convex-specific request and Live behavior stays
in [`client/convex.mojo`](client/convex.mojo). That is why the manifest records
`native` provenance rather than `binding`: ordinary transport uses system
libraries, but no other language's Convex client performs the work.

The Live API is single-threaded by design. One bounded `pump` operation owns
all reads, writes, reconnects, and subscription changes. `wait_update` repeatedly
advances that operation until a value or error is ready. Each subscription
keeps at most 16 deliveries within a 256 KiB encoded-text budget, dropping the
oldest when a slow caller exceeds either limit. Function, protocol, and
transport failures remain distinct so callers do not mistake a broken
connection for a successful Convex value.

For repository evidence, `./run test mojo` checks formatting, compilation, and
the language-local JSON, WebSocket, Live, event-shape, and adapter-transport
suites. `./run verify mojo` adds local black-box conformance, while
`./run verify-all mojo` repeats conformance against both approved deployment
profiles. Those are separate gates from the example command in Getting Started.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations, and WebSocket
   actions are not implemented. `set_auth` changes later HTTP calls only.
2. Live values support the JSON-safe subset of Convex values. Tagged Convex
   value types are deferred.
3. `TransitionChunk` assembly is not implemented. The client treats one as
   protocol drift and reconnects.
4. A slow Live consumer loses the oldest queued updates after 16 deliveries or
   256 KiB. The newest update is retained.
5. HTTP calls open a fresh connection each time. There is no keep-alive pool.
