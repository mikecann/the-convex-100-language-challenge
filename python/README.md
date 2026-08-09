# Convex from Python

This demonstration uses native Python to query and mutate Convex through its
documented JSON HTTP API, plus a small RFC 6455 WebSocket implementation that
targets the pinned Convex Live profile.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.py`](examples/basics/main.py) is the canonical example.
It reads one unique counter room over HTTP, starts Live before changing it,
performs one idempotent mutation, and checks the resulting `0 -> 1` journey.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native stdlib JSON HTTP query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | Native stdlib WebSocket subscription, bounded update delivery, reconnect attempt, unsubscribe, and clean close target the pinned profile. |

Shared local and hosted black-box tests passed, earning HTTP and Live.

## The basic example

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

## Verify it in Docker

```sh
./run test python
./run verify-example python
./run verify python
./run verify-hosted python
./run verify-all python
```

`test` runs compilation and Python-local tests inside Docker. `verify-example`
executes the exact source above and requires its universal six-line transcript.
The remaining commands are root-owned shared local and hosted evidence runs.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` speaks NDJSON adapter
protocol v1 over stdin/stdout or TCP. `debugDisconnect` is adapter-only and
exists for reconnect testing. HTTP uses `format: "json"`; Live targets
`convex-rs-0.10.4-unversioned-sync` at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`.

## Limitations

- Live authentication and `TransitionChunk` assembly are deferred.
- Live only supports unfragmented text WebSocket frames and JSON-safe values.
- Mutations/actions use HTTP. Replay, optimistic updates, journals, and full
  Convex value encoding are outside this teaching client.
