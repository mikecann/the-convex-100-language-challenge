<img src="logo.png" alt="Python logo" width="220">
<!-- Logo source: https://www.python.org/static/community_logos/python-logo-master-v3-TM-flattened.png -->

# Python

[Python](https://www.python.org/) is a general-purpose language created by
Guido van Rossum in the early 1990s as a successor to ABC. It is dynamically
typed, interpreted by its usual CPython runtime, and uses indentation rather
than braces to group statements.

Python is widely used for web services, automation, education, data analysis,
and scientific computing. Its readable syntax and large standard library make
it a familiar bridge between quick scripts and substantial applications.

This client is an educational, unofficial experiment. It is not a production
SDK, an officially sanctioned Convex client, or a package intended for
publication.

## Getting Started

Start with [`examples/basics/main.py`](examples/basics/main.py). It queries a
counter, opens a Live subscription before changing that counter, performs one
idempotent mutation, and observes the reactive update from `0` to `1`.

From the repository root, run the canonical example in its Docker image:

```sh
./run verify-example python
```

Docker supplies the pinned Python runtime and points the example at the
approved test deployment, so you do not need to install Python dependencies on
the host.

## Interesting Parts

### Plain dictionaries cross the Convex boundary

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function Count() {
  const room = "python-readme-query";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <span>Loading...</span>;
  return <span>{state.count}</span>; // state and count are type-safe here.
}
```

**Python**

```python
import os

from convex import Client

room = "python-readme-query"
client = Client(os.environ["CONVEX_URL"])
try:
    # Named Convex arguments are an ordinary Python dictionary.
    result = client.query("demo:state", {"room": room})
    print(result.value["count"])  # JSON becomes a dictionary checked at runtime.
finally:
    client.close()  # Release the client even when the request fails.
```

The React hook keeps a reactive query alive and has generated TypeScript types.
This Python call is a one-off HTTP query: `Result` is a small `dataclass` that
keeps the decoded value and Convex log lines together, while keys and value
types are checked only when the program uses them.

### The command-line client owns its Live subscription

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function Counter() {
  const room = "python-readme-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <span>Loading...</span>;

  async function addOne() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The mutation returns the new state.
  }

  // useQuery keeps this count reactive after the mutation.
  return <button onClick={addOne}>{state.count}</button>;
}
```

**Python**

```python
import os
import secrets

from convex import Client

room = "python-readme-live"
client = Client(os.environ["CONVEX_URL"])
subscription = client.subscribe("demo:state", {"room": room})
try:
    # This client exposes a blocking read so a script controls the sequence.
    initial = subscription.next_update(10)
    if initial.error:
        raise initial.error  # Query failures arrive through the subscription.
    print(initial.value["count"])

    result = client.mutation(
        "demo:increment",
        {
            "room": room,
            "language": "python",
            "runId": secrets.token_hex(8),  # Make retries idempotent.
        },
    )
    print(result.value["state"]["count"])  # The mutation returns the new state.

    changed = subscription.next_update(10)
    if changed.error:
        raise changed.error
    print(changed.value["count"])  # Read the reactive update explicitly.
finally:
    subscription.close()  # Stop this query before shutting down the worker.
    client.close()
```

React manages the hook's subscription lifecycle and rerenders the component.
This client instead gives a script a `Subscription` with blocking
`next_update` calls. That blocking API is a deliberate client design, not a
limitation of Python, which also supports callbacks, generators, and async
code.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native standard-library JSON HTTP query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | Native standard-library WebSocket subscription, bounded update delivery, reconnect attempt, unsubscribe, and clean close target the pinned profile. |

Shared local and hosted black-box tests passed, earning HTTP and Live.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.py -->
```python
#!/usr/local/bin/python3
import math, os, secrets, sys

sys.path.insert(
    0,
    os.environ.get(
        "CONVEX_CLIENT_PATH",
        os.path.abspath(os.path.join(os.path.dirname(__file__), "../../client")),
    ),
)
from convex import Client


def whole(value, operation):
    # Convex may encode a whole JSON number as 0.0. Normalize that to an int so
    # stdout stays stable, but never hide booleans, fractions, or non-finite data.
    if isinstance(value, bool):
        raise RuntimeError(
            f"{operation} count was {value!r}, expected a finite whole number"
        )
    if isinstance(value, int):
        return value
    if isinstance(value, float) and math.isfinite(value) and value.is_integer():
        return int(value)
    raise RuntimeError(
        f"{operation} count was {value!r}, expected a finite whole number"
    )


def main():
    # Create a native client for the verifier-provided Convex deployment.
    client = Client(os.environ["CONVEX_URL"])
    room = sys.argv[1] if len(sys.argv) > 1 else "python-example"
    try:
        # Query the unique room over Convex's documented JSON HTTP endpoint.
        current = whole(
            client.query("demo:state", {"room": room}).value["count"], "current query"
        )
        print(f"current count: {current}")
        # Start Live first so its initial value cannot miss the following mutation.
        subscription = client.subscribe("demo:state", {"room": room})
        try:
            initial = subscription.next_update(10)
            if initial.error:
                raise initial.error
            if whole(initial.value["count"], "initial Live value") != current:
                raise RuntimeError("initial Live value disagreed with HTTP")
            print(f"live initial count: {current}")
            # The random runId makes this logical increment idempotent on retries.
            mutation = client.mutation(
                "demo:increment",
                {"room": room, "language": "python", "runId": secrets.token_hex(8)},
            ).value
            if mutation.get("applied") is not True:
                raise RuntimeError("mutation was not applied")
            print("mutation applied: true")
            expected = current + 1
            if whole(mutation["state"]["count"], "mutation") != expected:
                raise RuntimeError("mutation count disagreed")
            print(f"mutation count: {expected}")
            changed = subscription.next_update(10)
            if changed.error:
                raise changed.error
            if whole(changed.value["count"], "updated Live value") != expected:
                raise RuntimeError("updated Live count disagreed")
            print(f"live updated count: {expected}")
            print(f"verified count: {current} -> {expected}")
        finally:
            subscription.close()
    finally:
        # Always stop the Live worker and release HTTP/WebSocket resources, even
        # when a teaching assertion above exposes unexpected server behaviour.
        client.close()


if __name__ == "__main__":
    main()
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The client uses only Python's standard library. `urllib.request` sends
synchronous JSON requests for queries, mutations, and actions. Responses become
`Result` dataclasses, while Convex failures become `FunctionError` instances
that retain structured error data and log lines.

Live is more involved. A small RFC 6455 implementation performs the WebSocket
upgrade, framing, masking, ping/pong handling, and JSON decoding. One daemon
thread owns each client's Live socket and reconnect loop. Each subscription has
a queue capped at 16 updates; when it fills, the oldest update is discarded
before the newest one is added. This bounds event count, but the client does not
also enforce a byte budget.

The [`whole`](examples/basics/main.py) helper is worth noticing because Python's
`bool` is a subclass of `int`. It rejects booleans before accepting integers,
then accepts finite integral JSON floats such as `1.0`. That keeps the teaching
output stable without silently accepting fractions or non-numeric values.

The Docker image pins Python 3.13.5 and copies a narrow CPython runtime into the
final image. The checked-in adapter is test infrastructure; normal HTTP and
Live behavior still runs through the same client shown above.

## Known Issues

1. Live authentication is not implemented. Bearer tokens apply to HTTP calls
   only.
2. The WebSocket reader accepts the unfragmented text frames used by the pinned
   profile, but rejects fragmented messages and other data-frame opcodes.
3. `TransitionChunk` assembly, mutation replay, optimistic updates, journals,
   and full Convex value encoding are deferred.
4. Mutations and actions use HTTP rather than the Live connection, and values
   are limited to JSON-safe data.
