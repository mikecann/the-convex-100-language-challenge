# Convex from Java

This is a small Java demonstration of calling Convex over its documented JSON
HTTP API, plus an experimental implementation of the pinned Live sync profile.
It is educational and unofficial, not a production SDK.

## Start here

[The canonical basic example](examples/basics/Main.java) reads a counter,
starts Live before changing it, performs an idempotent HTTP mutation, and checks
the Live update. It is the exact program included below and run by the image.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, awaiting shared evidence |
| Live query subscriptions | Experimental pinned profile, awaiting shared evidence |
| Authentication | HTTP bearer tokens only |

```java
// See examples/basics/Main.java. This README is generated from that canonical
// teaching source by the repository integration process.
```

## Docker verification

```sh
./run test java
./run build java
./run verify-example java
./run verify java
```

`test` compiles and runs Java-local checks inside Docker. `build` produces the
minimal runtime images. The latter two commands are root-owned shared evidence
runs and have not yet awarded any capability badges.

## Protocol notes

Live uses the explicitly pinned `convex-rs-0.10.4-unversioned-sync` profile at
`/api/sync`. The adapter speaks NDJSON protocol v1 and has a test-only
`debugDisconnect` hook for reconnect testing.

## Limitations

This experiment deliberately supports the JSON-safe value subset. Live auth,
WebSocket mutations/actions, transition chunks, optimistic updates, journals,
and mutation replay are deferred. Live delivery keeps a bounded newest-16
update buffer for each subscription; a slow reader loses old intermediate
values rather than growing memory without bound.
