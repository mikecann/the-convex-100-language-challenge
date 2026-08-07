# Project instructions

## Purpose

This repository tests how many programming languages can support useful Convex clients. The result must remain evidence-led: a language earns a capability only when its container passes the shared black-box conformance test for that capability.

This is a content and education project. These clients are demonstrations, not
officially sanctioned Convex SDKs and not packages intended for publication.
Optimise the checked-in source for clarity on the website and in the video.
Do not add package publishing workflows, registry metadata, release automation,
or ecosystem scaffolding that exists only to make a client distributable.

## Docker-only builds

- Do not install compilers, interpreters, package managers, SDKs, or build dependencies on the host.
- Run builds, tests, formatting, linting, code generation, and package installation inside Docker containers.
- Host-side commands are limited to repository operations, Docker orchestration, and read-only inspection using tools already installed.
- Pin base image versions. Pin production and verification images by digest once a client is working.
- Treat `linux/amd64` as the initial reference platform. Additional platforms are separate verified capabilities.
- Do not mount the Docker socket into a language client container.

### Required Docker interface

Every implemented language Dockerfile must expose the same targets to the root
`./run` command:

- `test`: format or lint checks, language-local client tests, and compilation of
  the canonical basic example and conformance executable. The resulting image
  must be a genuine `linux/amd64` image, not an amd64 label over host-platform
  binaries. Assert both the container architecture and the target runtime's
  architecture inside the image when cross-platform build stages are involved.
- `example-runtime`: a minimal image whose entrypoint is the exact canonical
  `examples/basics/` program shown in the README and website, installed at
  `/usr/local/bin/convex-example`.
- `runtime`: the default minimal image whose entrypoint is the test-only
  conformance executable, installed at `/usr/local/bin/convex-adapter`.

Both runtime images must run as `65532:65532`, work with a read-only filesystem,
drop all Linux capabilities, and expose no compiler or build frontend,
package manager, Convex CLI, or undeclared delegated client runtime. A runtime
may retain a language-runtime library named `compiler` only when the runtime
itself requires it to boot; document why it is needed and prove that no compiler
command is available. The shared policy and example
verifier currently require `/bin/sh` and basic POSIX text tools in runtime
images; do not use `scratch` until that verifier is redesigned. Install only
runtime dependencies such as CA certificates and the target language runtime
declared by the manifest. Keep language-specific build layouts inside Docker
stages rather than leaking them into the educational repository.

Treat multicall binaries as their complete compiled command surface. Removing
BusyBox symlinks or hiding commands from `PATH` does not remove applets that can
still be invoked through the multicall binary or a forged `argv[0]`. Inspect the
final filesystem and applet table, then directly probe forbidden package,
network, compiler, and delegated-runtime commands. Use a restricted build or
separate binaries when the stock multicall surface is too broad.

The runtime probe rejects Node.js and Python unless the manifest declares the
one approved `targetRuntimeCommand` for JavaScript or Python. This exempts only
the interpreter that genuinely executes that target-language client. Package
tooling and every other delegated runtime remain forbidden. Extending the
allowance to another language requires a separate shared-infrastructure review;
do not weaken it inside a language branch.

Emulation engines are not interchangeable build surfaces. Rosetta-backed
Docker on Apple Silicon reliably runs heavy amd64 toolchains; QEMU-based
engines segfault many of them (observed: Julia Pkg precompile, PureScript
purs, Crystal LLVM codegen, nimpretty, BCPL Cintcode, the MoonBit bundler)
before any client source is touched. A toolchain crash that precedes the
client's own code is an environment artifact, not a source defect: rerun it
on a Rosetta or native host before diagnosing the client. Route heavy
LLVM/JIT/AOT toolchains to Rosetta or native hosts and keep QEMU hosts for
gcc- and BEAM-class builds. AOT-compiled runtimes must exercise every
adapter command flow, including failure reporting, during the ahead-of-time
workout; a specialization first reached during shared conformance fails the
whole run.

Do not infer that a minimal runtime works because the build or test stage works.
Before handoff, execute the exact `/usr/local/bin/convex-example` and
`/usr/local/bin/convex-adapter` entrypoints from their final images. Compiled
clients must copy the complete runtime library closure. TLS clients must also
carry the CA bundle, OpenSSL configuration, engines, and provider modules their
runtime actually loads. Exercise TLS from the final image so hosted verification
is not the first place a missing provider or certificate path is discovered.

## Implementation honesty

- Every language lives at `<language-id>/` in the repository root and owns its implementation, Dockerfile, test adapter, examples, and manifest.
- Declare whether an implementation is `native`, `binding`, `generated`, `transpiled`, or `bridge`.
- A native client may use normal HTTP, TLS, JSON, and WebSocket libraries for its language, but it must implement Convex-specific behavior in the target language.
- Do not shell out to another Convex client, Node.js, Python, `curl`, or the Convex CLI and present the result as a native client.
- Shared-core FFI can be useful, but it earns the binding badge rather than the native badge.
- Bridges are retained as evidence but do not count as native client libraries.
- Preserve failed attempts and their evidence. Do not mark a capability passing based only on compilation or a mocked test.

## Example code

- Treat every runnable file under `<language-id>/examples/` as teaching material, not just a smoke test.
- Comment each meaningful Convex step in plain language: configuration, client creation, authentication when used, cleanup, the HTTP query, decoding into an idiomatic value, starting Live before the mutation, the initial Live value, the mutation and its idempotency key, and the resulting Live update.
- Comment non-obvious helper functions too, including what failure they handle and why the example needs them.
- Explain intent, sequencing, and Convex behaviour. Do not merely translate the target language's syntax into prose or comment routine error handling.
- Keep comments close to the code they explain and concise enough that the example still reads naturally.
- Format every checked-in source file with the language's standard formatter before review. Never compress multiple statements onto one line to reduce file length; the README and website display the canonical source verbatim.
- The runnable `examples/basics/` file is the canonical source. Generate the README and website from it so all three surfaces always show the same commented code.
- Docker verification must compile and execute that exact canonical example against a unique room on the approved test deployment. The example must fail on an unexpected value from any operation it demonstrates; compilation alone is not enough.
- For the shared counter demonstration, use a unique room and prove the expected
  `0 -> 1` journey: initial HTTP query, initial Live value when supported,
  applied mutation, and resulting Live value when supported. Print a concise
  final verification line only after all included operations agree.
- Convex JSON numbers may arrive in an integral decimal form such as `0.0` or
  `1.0`. Example decoding must accept values that are mathematically integral
  and in range, while rejecting fractional, quoted, non-finite, or overflowing
  values. Add a focused regression instead of relying on mocked integer-only
  fixtures.
- The `/usr/local/bin/convex-example` entrypoint must accept the verifier's
  unique room ID as its first argument. A language may also provide a friendly
  default for someone running the image by hand.
- Stdout from every canonical basic example is a universal happy-path test
  surface. It must match `_shared/examples/basics.expected.txt` exactly,
  line-for-line and in order. Do not add headings, pretty JSON, debug messages,
  room IDs, timestamps, or language-specific decoration to stdout. Send useful
  diagnostics to stderr instead. The shared root verifier owns the comparison;
  do not duplicate the expected transcript or comparison logic in each language.
- Never create a second test-only version of the example. Test the exact source
  file projected into the README and website.
- Generate the site preview and inspect the canonical example before handoff.
  Confirm that line breaks, comments, and syntax highlighting all come from the
  real source file and remain readable in the rendered code panel.

## Language layout

- Put client library code under `<language-id>/client/` and its unit tests beside it, using the ecosystem's normal test convention.
- Put the canonical introductory example under `<language-id>/examples/basics/`. Keep tests there only when they exercise example-specific behaviour.
- Put the test-only conformance executable and any tests specific to it under `<language-id>/client/tests/conformance/`. It may implement the shared adapter protocol, but it is not public client code.
- Do not create repository-level `<language-id>/src/` or `<language-id>/tests/` buckets.
- Keep checked-in client source directly under `client/` where practical. If a compiler or build tool expects an ecosystem-specific directory tree, let the Docker build copy the source into that temporary layout instead of reshaping the educational repository around package publishing conventions.
- Keep build metadata needed to compile and verify the demonstration under `client/`; Docker may copy it elsewhere inside the build container. Do not treat publishability as a design goal.
- Keep cross-client black-box conformance tests under `_shared/harness/`; they do not belong to an individual client package.

An implemented language root must contain only this public shape:

```text
<language-id>/
  README.md
  Dockerfile
  manifest.yaml
  client/
  examples/
```

The validator rejects extra top-level build files or generic source and test
directories. Put necessary dependency metadata under `client/` and let Docker
copy or rename it into the toolchain's expected location.

## Test layers

Keep these claims separate:

1. The `test` image proves source formatting, compilation, and language-local
   unit behaviour entirely inside Docker.
2. `./run verify-example <id>` runs the actual canonical example in its minimal
   image against a unique room and rejects unexpected values.
3. `./run verify <id>` includes example verification and shared black-box client
   conformance against the approved local backend.
4. `./run verify-hosted <id>` repeats example and conformance checks against the
   dedicated hosted drift target.
5. `./run verify-all <id>` runs both deployment profiles from the same built
   source.

Compilation is not example evidence. Example success is not full client
conformance. Local conformance does not replace hosted protocol-drift evidence.
Only the shared result evaluator may calculate HTTP or Live capability badges.

## Conformance executable

- The language-specific executable under `client/tests/conformance/` is test
  infrastructure, not public client code.
- It must implement NDJSON adapter protocol v1, reserve stdout for protocol
  events, send diagnostics to stderr, and call the real language client for
  every operation. Support both stdin/stdout operation and the TCP mode used by
  the shared harness: when `ADAPTER_LISTEN` is set, listen on that address,
  accept one controller connection, and carry the same NDJSON stream over it.
- The `hello` response must report protocol version, language ID,
  implementation provenance string, and runtime version.
- The shared controller validates every emitted event strictly against
  `_shared/schemas/adapter.schema.json`. Optional fields must be omitted when
  absent; never serialize an absent `id`, `subscriptionId`, value, or error as
  `null` unless the schema explicitly permits null. Add language-local coverage
  for serialized success, structured HTTP error, subscription error, and close
  events before relying on shared conformance to find a shape mismatch.
- It must support clean shutdown and propagate structured function, protocol,
  and transport failures without flattening them into successful values.
- Test-only fault injection may be compiled conditionally, but it must stay out
  of normal client builds and must not grant Docker socket or host-network
  access.
- A client claiming Live must implement the adapter-only `debugDisconnect`
  command so the shared controller can prove five real reconnects. Document it
  in `manifest.yaml` under `adapter.adapterOnlyCommands`; do not expose it in
  the educational client API.
- The shared controller and result names must be parameterised by language ID.
  Never copy Go-specific test names, image paths, aliases, or entrypoint checks
  into a second client.
- Choose and document Live delivery buffering deliberately. If the client owns
  an update queue, bound it and test its overflow behaviour. If it relies on a
  runtime mailbox or a demand-driven stream, state that choice and test a slow
  consumer so future clients do not accidentally introduce an unbounded queue.
- An event-count limit is not a memory limit when one protocol value may be
  close to the maximum frame size. Enforce a conservative byte budget as well
  as any count bound, include encoded output and runtime overhead, and prove the
  real final adapter remains comfortably below the shared 128 MiB limit with a
  stopped reader and near-maximum messages.

## Live acceptance

Live implementations need deterministic language-local coverage for the
failure modes that ordinary happy-path tests miss:

- Give one worker exclusive ownership of WebSocket reads, writes, reconnects,
  and query-set version changes. Controller and subscription threads must send
  commands to that owner rather than touching the socket concurrently.
- Prove `Add` and `Remove`, an initial `QueryUpdated`, an external update, and
  `QueryFailed` followed by recovery on the same subscription.
- Make unsubscribe and same-ID replacement invalidate the old relay before the
  acknowledgement is published. Pause a relay after dequeue in a deterministic
  test and prove that no stale event can cross either acknowledgement.
- For `debugDisconnect`, acknowledge only after the old connection is retired
  and reconnect work is safely scheduled. Suppress an unchanged rehydration so
  the exact sequence is initial `0`, disconnect acknowledgement, external
  mutation, then `1`. Repeat this for five real reconnects and prove each
  connection resends the active `Add` operations.
- Carry `connectionCount`, `lastCloseReason`, and `maxObservedTimestamp`
  correctly. Reset exponential transport backoff after a successful handshake
  or valid server transition so healthy intervening connections do not inherit
  an old maximum delay.
- Decode fragmented UTF-8 messages and control frames correctly. Once any byte
  of a frame has been consumed, a timeout must preserve parser state or abandon
  that connection; it must never restart at a false frame boundary.
- Make close and unsubscribe bounded even when the peer is idle, continuously
  sending, or stalled halfway through a frame. Tests must assert the deadline,
  not merely close a cooperative fixture peer.
- Emit structured `FunctionError`, `ProtocolError`, and `TransportError` events
  without permanently stranding otherwise valid subscriptions. After a
  protocol or transport reconnect, prove that the subscription can deliver a
  later valid value.

## README order

Write each language README for a curious viewer, not as an audit log. Use this
order:

1. `# Convex from <Language>` and a short explanation of what the demonstration
   does.
2. A clear statement that it is educational, unofficial, and not a production
   SDK.
3. `Start here`, linking to the canonical basic example and explaining its
   journey.
4. A plain-language `What works` table that does not round up partial support.
5. The generated canonical example block.
6. Docker verification commands and a short explanation of what each proves.
7. Lower-level conformance and protocol notes.
8. Honest limitations and deferred behaviour.

Keep protocol pins and evidence detail, but do not make a new reader traverse
them before discovering what the example does.

## Convex safety

- Any Convex schema change requires Michael's explicit approval before it is applied.
- Use a dedicated test deployment or an approved local self-hosted deployment. Never point conformance tests at an unrelated development or production deployment.
- Never bake deploy keys, auth tokens, or other secrets into images, layers, fixtures, logs, or committed files.
- Pin the tested protocol and backend revision in verification evidence. Do not imply that an undocumented protocol is stable or officially supported.

## Parallel agents

- Use one branch and one worktree per language implementation after the pilot.
- Agents may edit only their assigned client directory unless their task explicitly includes shared infrastructure.
- Shared harness, schema, manifest schema, architecture, results, and site changes under `_shared/` must be handled separately from language batches.
- Build and test the assigned client in Docker before handing it back.
- Each language agent must start from the same reviewed shared-infrastructure
  commit. It must not compensate for a harness problem inside its language
  directory or edit another language as a workaround.
- Language builds and `./run test <id>` may run in parallel because their tags
  and source trees are isolated. Run `verify-example`, `verify`,
  `verify-hosted`, and `verify-all` serially on a shared host. Those commands
  deliberately share the backend, deployment, network, controller image, and
  evidence directories.
- Keep at most three language implementations active inside one coordinator
  task. When Michael explicitly requests greater throughput, separate top-level
  Codex tasks may own additional language worktrees. Each task must still own
  only its assigned language, may run only language-local Docker gates, and must
  leave shared verification and shared-infrastructure edits to the coordinator.
  Finish independent review and root-owned verification in bounded waves; a
  large pile of compile-only branches is not useful progress.
- An agent that starts a build on a remote host owns it to completion inside
  its own task: poll the remote log actively until the run concludes. Do not
  hand off to an external monitor or end the task with a build unresolved;
  nothing wakes a finished task when a remote job completes.

## Language handoff checklist

Before a language implementation agent reports completion, it must provide:

- The implementation provenance and any delegated libraries used for ordinary
  HTTP, TLS, JSON, or WebSocket transport.
- Exact pinned toolchain, base image, and dependency versions.
- Exact Docker commands run and their exit status.
- Known failures, deferred protocol behaviour, buffering semantics, and any
  test-only hooks.
- Confirmation that only the assigned language directory changed.

If the assigned scope includes HTTP and Live, an HTTP-only build is an
incomplete handoff, not completion. Say exactly what remains and leave all
capabilities unearned. Do not stop at compilation or substitute a list of
planned fixtures for tests that actually ran.

After the implementation and independent code review are complete, the root
integration agent must run the shared commands serially and add to the handoff:

- The canonical example's observed values and final verification line.
- Local and hosted conformance results, with HTTP and Live claimed only when
  every required test passed.
- Confirmation that the evidence records the reviewed source commit, a clean
  worktree, the expected runtime architecture, and the same built image for the
  deployment profiles.

Run shared evidence after committing the reviewed source. A successful run
with `dirty: true` or a `sourceCommit` that predates the reviewed tip must be
rerun from the clean commit before a PR is opened.

When shared evidence passes and the evaluator awards capabilities, record the
award in one complete truth-up commit — manifest capability list, README status
table, and every stale pending-verification or no-conformance line together —
then rerun the shared evidence once from that head. Every extra cleanup commit
after a green run costs a full rerun under the exact-head rule, so sweep the
language directory for stale claims before rerunning, not after.

Fixtures authored inside a checkpoint that has never executed are not
evidence-bearing. When such a fixture encodes an environment-hostile
parameterization, adjust the parameterization minimally with coordinator
sign-off and a comment preserving the tested intent; do not treat the blind
fixture as authoritative, and do not silently weaken the behavior it proves.

Generated, gitignored evidence under `_shared/results/local/` and
`_shared/results/hosted/` is exempt from the directory-only handoff rule. It is
local verification output, not source to commit.

The independent language reviewer must inspect the actual diff and rebuild and
exercise the Docker test/runtime images. The root integration reviewer must
then run the canonical example and shared conformance serially. A subagent
summary is not verification, and a language branch must not award itself a
capability before those root-owned evidence runs pass.

## Pull requests

- Start every PR body with a `## Why` section that explains what prompted the change and why it is worth making.
- Include the exact Docker build and conformance commands run.
- State the earned capability badges and any known failures without rounding up.
