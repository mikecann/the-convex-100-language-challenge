# Convex from D

This is a small native D client for Convex's documented JSON HTTP function API.

It is educational and unofficial, not a production SDK.

## Start here

The HTTP client lives in [`client/convex.d`](client/convex.d). It validates a deployment URL, sends the documented query, mutation, and action envelope, replaces bearer tokens safely, and retains Convex error data and logs.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Implemented and real-socket Docker-tested, but blocked from shared evidence by the required Live example |
| Bearer-token replacement and structured function errors | Implemented and real-socket Docker-tested |
| NDJSON adapter over stdin/stdout and one TCP connection | Implemented and Docker-tested |
| Live queries | Not implemented, no capability claimed |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.d -->
```d
/**
 * Live has not been implemented in this educational D client yet, so there is
 * no canonical basic example. The universal example requires a real 0 -> 1
 * Live journey and would be misleading if it used polling instead.
 */
module basics_main;

import std.stdio : stderr;

void main() {
    stderr.writeln("The D Convex example awaits native Live support.");
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test d` compiles the D source, runs its unit tests, and exercises the adapter's stdin and TCP protocols inside Docker. `./run build d` produces the restricted adapter runtime image.

The shared `verify-example`, `verify`, and `verify-hosted` gates are intentionally not run yet: the universal basic example requires real Live support, which this branch does not claim.

## Protocol notes and limits

The adapter implements NDJSON protocol v1 for `hello`, HTTP calls, `setAuth`, and `close`. It sends structured `FunctionError`, `ProtocolError`, and `TransportError` events and never uses stdout for diagnostics. `subscribe`, `unsubscribe`, and `debugDisconnect` return a structured `ProtocolError` instead of pretending that a polling or delegated client is Live support.

The implementation uses Phobos `std.net.curl`, backed by libcurl, for ordinary HTTP and TLS transport. Convex-specific envelopes and response decoding are D code. The installed LDC 1.30 standard binding does not expose libcurl's WebSocket API, so this branch intentionally stops before claiming a partial Live implementation.
