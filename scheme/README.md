# Convex from Scheme

This is a small native Guile Scheme client for Convex's documented JSON HTTP API.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

The future canonical counter example will be [`examples/basics/main.scm`](examples/basics/main.scm). It is an explicit failing placeholder, because the required direct Live WebSocket implementation is not ready yet.

## What works

| Capability | Status |
| --- | --- |
| HTTP query/mutation/action envelope and adapter scaffolding | Attempting, with JSON and input-validation unit checks only |
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

`test` runs the Scheme JSON and adapter-lifecycle unit checks inside the pinned linux/amd64 image. It does not demonstrate a real Convex HTTP request yet. Root-owned `verify-example`, `verify`, and `verify-hosted` are deliberately not run from this language branch and cannot award a capability yet.

## Conformance and protocol notes

The partial adapter speaks NDJSON protocol v1 on stdin/stdout and routes queries, mutations, and actions to the same Guile implementation. It does not invoke another Convex client, the Convex CLI, curl, Node.js, or Python. TCP adapter mode and all Live operations remain missing, so this is not yet an executable conformance client.

## Limitations

This branch is preserved as an implementation attempt, not a usable client. The blockers are: a direct Scheme RFC 6455 client with owner/reconnect safety; a TCP adapter; deterministic real HTTP coverage; the six-line counter example; and hardened final runtime images. Until all of those exist and root-owned shared evidence passes, both capability arrays stay empty.
