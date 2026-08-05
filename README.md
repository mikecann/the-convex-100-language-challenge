# 100 Convex clients

An educational experiment demonstrating Convex from 100 programming languages
and measuring honestly how much useful client behaviour each language can
support.

These implementations are made for the project, website, and video. They are
not officially sanctioned Convex clients and are not intended to become
published packages or production SDKs.

The repository foundation and first native client pilot now exist. Go passes the
shared HTTP and Live suites against both the pinned local backend and the
dedicated hosted drift target. Its badges remain candidate evidence until the
branch passes native `linux/amd64` CI and trusted-main publishes the result
index.

## Capability badges

| Status | Meaning |
| --- | --- |
| Yellow: HTTP | Queries, mutations, actions, JSON-safe values, bearer-token forwarding, and errors work over the documented HTTP API. |
| Green: Live | The client additionally supports live query subscriptions over WebSockets. |
| Red: Failed | A clean Docker build, execution, or claimed capability test fails. |

Live includes HTTP. Implementation provenance is a separate label:

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
- Every runnable example is a commented guided tour of the verified client API, and that same source is shown in its README and on the website.
- Checked-in layouts favour readable educational source. Docker may rearrange files into temporary toolchain-specific paths during a build.
- Package publishing, registry metadata, and release automation are outside the project's scope.
- A native implementation may use ordinary transport libraries, but Convex-specific behavior must be written in the target language.
- Shared-core and transpiled clients are labelled rather than hidden.
- Results are attached to a source commit, container digest, runtime version, protocol revision, and conformance-suite version.
- Experimental clients stay in this monorepo. Passing a test does not make a package officially supported by Convex.

## Repository shape

```text
<language-id>/             one top-level directory per roster language
  manifest.yaml            declared intent, toolchain, and provenance
  Dockerfile               pinned build and runtime image
  client/                  idiomatic client library and its unit tests
  examples/basics/         the shared counter-room example and its own tests
  tests/conformance/       test-only NDJSON conformance executable
  README.md                usage, evidence, and limitations
_shared/                   trusted backend, harness, schemas, site, and results
run                         Docker-only orchestration entrypoint
roster/                    sourced language selection and feasibility audit
```

The repository root is intentionally visual: the accepted roster appears as 100
peer language directories. Popularity rank lives in metadata, so a ranking
change never renames a directory. Shared infrastructure is kept under
`_shared/` and is protected separately from language implementation changes.

Build status and verified platforms are recorded as evidence. They are not
capability badges. A successful build alone does not mean a client can talk to
Convex.

## Docker-only commands

The root script is the supported entrypoint. It invokes Docker for every build,
test, package operation, and generated artifact.

```sh
./run doctor
./run validate
./run verify go
./run verify-hosted go
./run verify-all go
./run site-preview
./run site-serve
```

The last two commands generate a clearly labelled local evidence preview and
serve it at `http://127.0.0.1:4173`. `./run site` is stricter: it ignores local
results and renders only the trusted-main result index.

See the [roster methodology](roster/methodology.md), [exact proposed roster](roster/languages.yaml), [conformance contract](docs/conformance.md), and [implementation architecture](docs/architecture.md).
