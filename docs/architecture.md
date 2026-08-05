# Implementation architecture

## Goals

- Attempt the sourced 100-language roster without installing language toolchains on the host.
- Award capabilities from repeatable black-box evidence rather than self-reported implementation status.
- Preserve useful failures and implementation provenance.
- Make it safe to add many clients concurrently without letting agents rewrite the test oracle.
- Start with a static evidence website, then add controlled live demonstrations later.

## Repository boundaries

```text
<id>/
  manifest.yaml          declared intent, toolchain, and provenance
  Dockerfile             pinned multi-stage build
  src/                   client library
  example/               shared counter-room example
  adapter/               thin NDJSON conformance adapter
  tests/                 language-local unit tests
  README.md              idiomatic usage and limitations

_shared/
  backend/               approved Convex test backend
  harness/               controller, reference client, vectors, and scenarios
  protocol/              versioned adapter and pinned realtime profiles
  schemas/               manifest, roster, result, and adapter schemas
  site/                  static evidence wall and per-language evidence
  results/               trusted summaries, never client-authored

docs/                    architecture, contracts, profiles, and decisions
roster/                  sourced language selection and feasibility audit
run                      root Docker-only orchestration entrypoint
```

### Example comments

Examples should use a small number of comments to explain Convex-specific
behaviour and important sequencing. Good comments explain why a subscription
starts before a mutation, where HTTP ends and Live begins, and what failure or
timeout the reader should expect. Avoid comments that merely restate the target
language's syntax or narrate every line.

Client pull requests may modify only their own `<id>/` directory. Changes under `_shared/`, `docs/`, or `roster/` belong in separate reviewed pull requests. CI path policy must enforce that split before language work is parallelized.

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

The root `./run` command is the only supported host entrypoint. It may inspect
repository metadata and invoke Docker, but compilers, package managers, code
generation, formatting, builds, tests, and site generation all execute inside
containers.

The authoritative build shape will be equivalent to:

```text
docker buildx build \
  --platform linux/amd64 \
  --provenance=mode=max \
  --sbom=true \
  <id>
```

Local development may use emulation, but an emulated pass does not replace the native amd64 CI result.

## Adapter and controller

Each client image runs a language-native adapter that reads NDJSON commands from stdin and emits NDJSON events on stdout. The adapter provides a common control surface while exercising the actual public client API underneath it.

The controller owns:

- Random fixture values and per-run nonces.
- State reset through an approved reference path.
- External mutations using an official reference client.
- Fault injection. The Go pilot currently uses an adapter-only socket break;
  an external network fault proxy remains a later harness improvement.
- Timeouts, clocks, assertions, repetition, and badge calculation.
- Sanitized result and evidence generation.

For local and trusted CI runs, the root orchestrator starts the controller and
clients. The controller and client containers do not receive the Docker socket.
Client processes are attached through ordinary stdin, stdout, and a private
Docker network.

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

The deterministic suite targets a pinned local or self-hosted Convex backend in
Docker. A dedicated hosted Convex development deployment is a compatibility
smoke target for HTTPS, WSS, and current cloud behaviour. Random room IDs isolate
fixture data, but they do not make shared hosted rate limits or credentials
deterministic.

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

The Go pilot implements source and tree revisions, image and base digests,
per-test and transcript hashes, final-image inspection, SBOM, and build
provenance. Full outbound-destination inspection and a signed trusted-main
index are not implemented yet, so pull-request and local website output stays
visibly labelled as candidate evidence.

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

### Stage 0: foundation and reconciliation

- Reconcile this flat layout, CLI name, evidence vocabulary, and trust boundary.
- Freeze roster and schemas.
- Define NDJSON adapter protocol v1 and prove the harness rejects deliberately broken adapters.
- Build the controller, official JavaScript reference, fault proxy, and one golden HTTP and Live scenario.
- Commit the exact approved Convex test schema and indexes.

### Stage 1: Go pilot

Use the pinned official JavaScript client as a semantic oracle, then implement
Go. JavaScript does not define the Yellow HTTP wire representation because the
official client uses an undocumented richer encoding. Go earns HTTP only against
the documented HTTP contract. Go may earn Live only against one explicitly
pinned realtime profile and the hosted drift smoke test.

Stop for Michael's review before starting any second language.

### Stage 2: official-client calibration debt

Run adapters for official Rust, Python, Swift, and Kotlin clients. Their results
broaden calibration and correctly record native or binding provenance.

### Stage 3: diverse pilot

Implement a small missing-client batch across different ecosystems, for example Go, Java, C#, Ruby, Elixir, Lua, C++, and Haskell. Do not scale until the tests have exposed and correctly diagnosed failures across multiple implementations.

### Stage 4: HTTP expansion

Prioritize practical `GGGG` roster entries. Establish Yellow before attempting realtime work. Generated OpenAPI clients may accelerate coverage but remain labelled `generated + HTTP`.

### Stage 5: realtime expansion

Pin one protocol profile, initially proposed as the inspected `convex-rs` profile, and implement Live in clients with credible WebSocket ecosystems. Add hosted drift tests because the wire API is internal.

### Stage 6: difficult and conditional languages

Attempt FFI, transpiled, licensed, and legacy candidates under fixed budgets. Preserve blocked and failed results. Any backfill needed to reach 100 working languages lives in a separate implementation roster and never rewrites the sourced popularity roster.

## Approval gates

- Any change to the approved Convex schema and indexes.
- Hosted deployment credentials and any move away from deterministic local tests plus hosted smoke tests.
- Any commercial runtime or licence acceptance.
- Public package publication.
- Public live runner and its spending limits.
