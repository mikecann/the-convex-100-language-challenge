# Convex from Scheme

This is a small native Guile Scheme client for Convex's documented JSON HTTP API.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.scm`](examples/basics/main.scm). It calls the counter's HTTP query and mutation endpoints and explains the parts that will become the full counter journey once Live is implemented.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, and structured errors | Implemented locally, awaiting root-owned shared evidence |
| Live subscriptions and the canonical 0 -> 1 example journey | Not implemented |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.scm -->
```scheme
;; The canonical Live counter example will live here once Scheme has its direct
;; RFC 6455 client. It deliberately exits non-zero today so this HTTP-only
;; branch cannot be mistaken for a passing 0 -> 1 example.
(display "Scheme Live example is not implemented yet.\n" (current-error-port))
(exit 1)
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test scheme
```

`test` runs the Scheme JSON and HTTP adapter checks inside the pinned linux/amd64 image. Root-owned `verify-example`, `verify`, and `verify-hosted` are deliberately not run from this language branch and cannot award a capability yet.

## Conformance and protocol notes

The adapter speaks NDJSON protocol v1 on stdin/stdout and calls the same Guile implementation for queries, mutations, and actions. It does not invoke another Convex client, the Convex CLI, curl, Node.js, or Python. It currently returns a structured protocol error for subscription commands rather than pretending that polling is Live.

## Limitations

Live is the blocking unfinished part of this implementation. The final Docker image is intentionally not presented as passing the canonical example or either capability badge until a direct Scheme RFC 6455 client, its ownership/reconnect tests, and root-owned shared evidence exist.
