# Convex from Crystal

This educational, unofficial demonstration uses Crystal to query and mutate a Convex room over HTTP, then follow the same room through Convex Live.

## Start here

Read the [canonical basic example](examples/basics/main.cr). It performs an HTTP query, starts Live before the mutation, applies an idempotent increment, and checks the resulting `0 -> 1` update.

## What works

| Capability | Status |
| --- | --- |
| Native HTTP query, mutation, action | Implemented in Crystal; shared verification pending |
| Native Live query and reconnect hook | Implemented in Crystal; shared verification pending |
| Authentication | HTTP bearer token; Live auth deferred |

## Canonical example

The source above is the single checked-in example projected into the website.

## Docker verification

```sh
./run test crystal
./run verify-example crystal
./run verify crystal
./run verify-hosted crystal
```

The first command formats and compiles inside Docker. The remaining commands execute the exact minimal example and adapter against the approved deployments.

## Protocol notes

The adapter speaks NDJSON protocol v1 over stdin/stdout or `ADAPTER_LISTEN`. One Crystal worker owns the Live WebSocket and applies transitions before publishing updates. Each subscription queue is bounded to 16 events and 4 MiB of encoded values.

## Limitations

TransitionChunk assembly, Live authentication, WebSocket mutations, optimistic updates, and the complete Convex value surface remain deferred. Capability badges stay empty until shared local and hosted evidence passes.
