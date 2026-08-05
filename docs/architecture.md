# Implementation architecture

## Goals

- Attempt the sourced 100-language roster without installing language toolchains on the host.
- Award capabilities from repeatable black-box evidence rather than self-reported implementation status.
- Preserve useful failures and implementation provenance.
- Make it safe to add many clients concurrently without letting agents rewrite the test oracle.
- Start with a static evidence website, then add controlled live demonstrations later.

## Repository boundaries

```text
clients/<id>/
  manifest.yaml          declared intent, toolchain, and provenance
  Dockerfile             pinned multi-stage build
  src/                   client library
  adapter/               thin NDJSON conformance adapter
  tests/                 language-local unit tests
  README.md              idiomatic usage and limitations

conformance/
  controller/            trusted black-box test controller
  reference/             pinned official Convex reference clients
  vectors/               versioned HTTP and value fixtures
  scenarios/             HTTP, live, hardened, and lifecycle tests
  fault-proxy/           deterministic disconnect and network fault control
  protocol/              pinned realtime protocol profiles

convex/                  approval-gated test backend
docs/                    architecture, contracts, profiles, and decisions
roster/                  sourced language selection and feasibility audit
schemas/                 manifest, roster, result, and adapter schemas
tooling/                 Dockerized orchestration and policy checks
site/                    results wall and per-language evidence
results/                 small trusted-main summaries, never client-authored
```

Client pull requests may modify only their own `clients/<id>/` directory. Changes to the harness, schemas, vectors, protocol profiles, or generated results belong in separate reviewed pull requests.

## Docker policy

`linux/amd64` is the first authoritative platform because it has the broadest legacy and proprietary-toolchain compatibility. `linux/arm64` is reported separately later.

Every client uses one multi-stage Dockerfile:

1. A pinned toolchain and dependency stage.
2. A verification stage containing language-local tests.
3. A minimal non-root runtime containing only the library and adapter.

Rules:

- Build, test, lint, format, package, and generate code only through Docker.
- Never mount the repository into the final running client.
- Pin toolchain versions and lock dependencies. Pin base images by digest once a client first passes.
- Use BuildKit secret mounts for private inputs. Never pass secrets through `ARG`, `ENV`, copied files, or image layers.
- Produce SBOM and provenance attestations for trusted CI images.
- Do not download packages during conformance execution. Dependency restoration happens during the image build.
- The language container never receives the Docker socket.

The authoritative build shape will be equivalent to:

```text
docker buildx build \
  --platform linux/amd64 \
  --provenance=mode=max \
  --sbom=true \
  clients/<id>
```

Local development may use emulation, but an emulated pass does not replace the native amd64 CI result.

## Adapter and controller

Each client image runs a language-native adapter that reads NDJSON commands from stdin and emits NDJSON events on stdout. The adapter provides a common control surface while exercising the actual public client API underneath it.

The controller owns:

- Random fixture values and per-run nonces.
- State reset through an approved reference path.
- External mutations using an official reference client.
- Fault-proxy configuration.
- Timeouts, clocks, assertions, repetition, and badge calculation.
- Sanitized result and evidence generation.

For local and trusted CI runs, the controller may receive a Docker socket so it can start clients and attach to their streams. It runs on a disposable worker or context. Client containers never receive that socket.

## Runtime isolation

Client containers run with controls equivalent to:

- Read-only root filesystem.
- Non-root user.
- All Linux capabilities dropped.
- `no-new-privileges`.
- Bounded processes, memory, CPU, file descriptors, execution time, and log size.
- Temporary filesystems only where the runtime needs them.
- No host mounts.
- No access to the Docker socket.

For hosted Convex tests, all HTTP and WebSocket traffic passes through an allowlist gateway restricted to the dedicated test deployment. A pinned self-hosted Convex backend can provide fast deterministic tests on the internal network, while a hosted smoke test checks HTTPS, WSS, and cloud compatibility.

Credentials are short-lived, supplied at runtime, redacted by the controller, and limited to the expendable test deployment.

## Evidence and anti-cheat policy

Compilation alone earns no badge. Black-box tests use randomized nonces, independent mutations, and repeated network faults so hard-coded results fail.

Trusted CI records:

- Source commit and client tree hash.
- Dirty-worktree flag.
- Dockerfile, base image, and final image digests.
- Runtime and compiler versions.
- Platform and declared provenance.
- Harness, vectors, backend, and protocol profile revisions.
- Per-test status, duration, logs hash, and failure reason.
- SBOM and build provenance locations.
- Earned capability badges.

Policy checks inspect source, manifests, image history, SBOMs, child processes, and outbound destinations. This detects obvious delegation to `curl`, Node, Python, the Convex CLI, or an undeclared shared core. Native provenance still requires review because automated checks are evidence, not proof.

Clients cannot commit their own earned results. Only trusted-main CI may update the small result index, and the website accepts only that signed index.

## CI strategy

### Pull requests

1. Validate roster and manifest schemas.
2. Enforce allowed path scope.
3. Build changed client images from a clean context.
4. Run smoke tests and every claimed badge suite.
5. Upload the result, logs, SBOM, and provenance as artifacts.

### Main and scheduled verification

- Generate a matrix from the roster, initially one language per job.
- Limit concurrency to control spend and external load.
- Scope BuildKit caches per language and toolchain lock hash.
- Run the full current suite nightly.
- Perform a weekly no-cache rebuild to detect disappearing packages, images, licences, or toolchains.
- Require 20 consecutive passes for hardened fault cases.
- Weight future shards by observed p95 duration and memory rather than alphabetically.

The initial images remain private in GHCR. No public language package is published until it has a maintainer and a separate release decision.

## Parallel-agent workflow

1. Freeze shared schemas, harness behavior, vectors, and the first protocol profile.
2. Create one branch and worktree per language, named `client/<id>`.
3. Give each agent one client directory, a fixed time/token budget, the same conformance contract, and no authority over the oracle.
4. Require exact Docker commands and honest failures in handoff notes.
5. Review provenance separately from automated capability results.
6. Merge valuable red attempts so the project preserves evidence rather than erasing difficulty.

Scale in batches only after the previous batch shows that the harness is finding real bugs rather than multiplying harness bugs.

## Website phases

### Phase 1: static evidence wall

Render signed CI summaries, code examples, provenance, image digests, and per-test evidence. This phase runs no visitor-controlled code.

### Phase 2: fixed live demonstrations

The public API accepts only an allowlisted `{ languageId, demoAction }`. It never accepts source code, commands, arguments, environment variables, or image references.

A separate worker:

1. Resolves a signed immutable image digest from the trusted result index.
2. Starts it in a disposable sandbox with strict resource and egress limits.
3. Streams sanitized typed adapter events to the website.
4. Destroys the sandbox after the bounded run.

The control plane performs any shared mutation. Visitors never receive deployment credentials or direct container access. Queue, IP, and global rate limits plus a kill switch are required before public launch.

## Staged implementation

### Stage 0: foundation

- Freeze roster and schemas.
- Define the NDJSON adapter protocol.
- Build the controller, official JavaScript reference, fault proxy, and one golden HTTP and Live scenario.
- Propose the exact Convex test schema and auth fixture for Michael's approval.

### Stage 1: official-client calibration

Run adapters for official JavaScript, Rust, Python, Swift, and Kotlin clients. Their results calibrate the harness and correctly record native or binding provenance.

### Stage 2: diverse pilot

Implement a small missing-client batch across different ecosystems, for example Go, Java, C#, Ruby, Elixir, Lua, C++, and Haskell. Do not scale until the tests have exposed and correctly diagnosed failures across multiple implementations.

### Stage 3: HTTP expansion

Prioritize practical `GGGG` roster entries. Establish Yellow before attempting realtime work. Generated OpenAPI clients may accelerate coverage but remain labelled `generated + HTTP`.

### Stage 4: realtime expansion

Pin one protocol profile, initially proposed as the inspected `convex-rs` profile, and implement Live in clients with credible WebSocket ecosystems. Add hosted drift tests because the wire API is internal.

### Stage 5: difficult and conditional languages

Attempt FFI, transpiled, licensed, and legacy candidates under fixed budgets. Preserve blocked and failed results. Any backfill needed to reach 100 working languages lives in a separate implementation roster and never rewrites the sourced popularity roster.

## Approval gates

- Exact Convex schema and indexes before any schema is created or applied.
- Choice of self-hosted versus hosted test deployment and its credentials.
- Any commercial runtime or licence acceptance.
- Public package publication.
- Public live runner and its spending limits.
