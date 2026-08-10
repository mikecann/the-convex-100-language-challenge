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

### A familiar query shape, with explicit JSON at the boundary

In a React app, generated Convex types carry the query arguments and result into
the component. This Mojo client deliberately exposes the HTTP result as JSON
text, so the application has to construct and decode that boundary itself.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CounterState() {
  const room = "mojo-readme-query";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // `state` and `count` are type-safe here.
}
```

**Mojo**

```mojo
from std.os import getenv

from convex import Client, default_ca_file
from json import parse, quote


fn main() raises:
    var deployment_url = getenv("CONVEX_URL")
    if not deployment_url:
        raise Error("CONVEX_URL is required")

    var client = Client(deployment_url, default_ca_file())
    var room = String("mojo-readme-query")
    # This client accepts serialized JSON rather than a generated argument type.
    var args_json = String('{"room":') + quote(room) + "}"
    var response = client.call(String("query"), String("demo:state"), args_json)
    if not response.ok:
        raise Error(response.error_name + ": " + response.error_message)

    var document = parse(response.value_json)
    # The field name is checked at runtime; `count` is an Int after `as_int`.
    var count = document.as_int(document.member(document.root, "count"))
    print(count)
    client.close(2000)
```

The Mojo syntax looks Python-like, but `String`, `Client`, and `Int` are static
types. Unlike the generated TypeScript API, this small client cannot catch a
misspelled function name or JSON field at compile time.

### React owns reactivity; this command-line client owns it directly

`useQuery` subscribes during rendering and React cleans it up when the component
unmounts. The Mojo program starts the subscription itself, blocks until each
value arrives, and must unsubscribe and close the client.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CounterButton() {
  const room = "mojo-readme-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function incrementOnce() {
    const result = await increment({
      room,
      language: "TypeScript",
      runId: crypto.randomUUID(), // Fresh on every click, so each write can apply.
    });
    console.log(result.state.count); // The mutation result is generated and typed.
  }

  return (
    <button onClick={() => void incrementOnce()}>
      {state === undefined ? "Loading..." : `Count: ${state.count}`}
    </button>
  ); // A successful mutation causes `useQuery` to render the new count.
}
```

**Mojo**

```mojo
from std.base64 import b64encode
from std.os import getenv

from convex import Client, default_ca_file
from json import parse, quote
from net import random_bytes


fn main() raises:
    var deployment_url = getenv("CONVEX_URL")
    if not deployment_url:
        raise Error("CONVEX_URL is required")

    var client = Client(deployment_url, default_ca_file())
    var room = String("mojo-readme-live")
    var query_args = String('{"room":') + quote(room) + "}"

    # This program owns the subscription and asks for each delivery explicitly.
    client.subscribe(String("counter"), String("demo:state"), query_args)
    var initial = client.wait_update(String("counter"), 20000)
    var initial_json = parse(initial.value_json)
    print(initial_json.as_int(initial_json.member(initial_json.root, "count")))

    # Kernel randomness gives this write a new idempotency key on every run.
    var run_id = String("mojo-readme-") + b64encode(Span(random_bytes(16)))
    var mutation_args = String('{"room":') + quote(room)
    mutation_args += ',"language":"Mojo"'
    mutation_args += ',"runId":' + quote(run_id) + "}"
    var result = client.call(
        String("mutation"), String("demo:increment"), mutation_args
    )
    if not result.ok:
        raise Error(result.error_name + ": " + result.error_message)
    var result_json = parse(result.value_json)
    var state = result_json.member(result_json.root, "state")
    print(result_json.as_int(result_json.member(state, "count")))

    # The same subscription now yields the reactive consequence of the write.
    var updated = client.wait_update(String("counter"), 20000)
    var updated_json = parse(updated.value_json)
    print(updated_json.as_int(updated_json.member(updated_json.root, "count")))

    client.unsubscribe(String("counter"))
    client.close(2000)  # Cleanup is the caller's responsibility here.
```

The blocking `wait_update` interface is a choice made by this compact client
for a command-line demonstration, not a limitation of the Mojo language. It
also makes ownership obvious: one `Client` owns the connection and its queued
updates, while React normally hides that lifecycle behind hooks.

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
