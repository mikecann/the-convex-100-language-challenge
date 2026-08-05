# 100 Convex clients

An experiment to make Convex usable from 100 programming languages and measure honestly how much of a client each language can support.

The project is currently in the research and architecture phase. No language counts as working until its clean Docker image passes the shared conformance suite against the approved Convex test backend.

## Capability badges

| Status | Meaning |
| --- | --- |
| Yellow: HTTP | Queries, mutations, actions, JSON-safe values, authentication, and errors work over the documented HTTP API. |
| Green: Live | The client additionally supports live query subscriptions over WebSockets. |
| Blue: Hardened | The live client passes consistency, reconnection, auth rotation, mutation ordering, full-value, and lifecycle tests. |
| Red: Failed | A clean Docker build, execution, or claimed capability test fails. |

The capability badges are cumulative. Implementation provenance is a separate label:

| Provenance | Meaning |
| --- | --- |
| Native | The target language owns the Convex-specific state machine. Normal HTTP, TLS, JSON, and WebSocket libraries are allowed. |
| Binding | The language exposes an idiomatic API over a shared Convex core through FFI, JVM, CLR, WASM, or similar. |
| Generated | An HTTP client produced from an API description such as OpenAPI. |
| Transpiled | The implementation is written in the named source language and compiled to a different host language. |
| Bridge | The code shells out to another Convex client, runtime, CLI, or sidecar. Bridges are shown but do not count as native clients. |

## Ground rules

- One source language, one audited entry in the roster.
- Every build and test runs in Docker. Language toolchains are never installed on the host.
- HTTP is the minimum useful target. Realtime and resilience are separate earned capabilities.
- A native implementation may use ordinary transport libraries, but Convex-specific behavior must be written in the target language.
- Shared-core and transpiled clients are labelled rather than hidden.
- Results are attached to a source commit, container digest, runtime version, protocol revision, and conformance-suite version.
- Experimental clients stay in this monorepo. Passing a test does not make a package officially supported by Convex.

## Planned repository shape

```text
clients/<language-id>/     source, Dockerfile, adapter, and manifest
conformance/               black-box controller, fixtures, and fault injection
convex/                    approved test backend
docs/                      selection method, architecture, and protocol notes
schemas/                   machine-readable manifest and result schemas
site/                      live capability wall and per-language reports
```

See the [roster methodology](roster/methodology.md), [exact proposed roster](roster/languages.yaml), [conformance contract](docs/conformance.md), and [implementation architecture](docs/architecture.md).
