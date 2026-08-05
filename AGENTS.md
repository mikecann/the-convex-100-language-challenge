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
- The runnable `examples/basics/` file is the canonical source. Generate the README and website from it so all three surfaces always show the same commented code.

## Language layout

- Put client library code under `<language-id>/client/` and its unit tests beside it, using the ecosystem's normal test convention.
- Put the canonical introductory example under `<language-id>/examples/basics/`. Keep tests there only when they exercise example-specific behaviour.
- Put the test-only conformance executable and any tests specific to it under `<language-id>/client/tests/conformance/`. It may implement the shared adapter protocol, but it is not public client code.
- Do not create repository-level `<language-id>/src/` or `<language-id>/tests/` buckets.
- Keep checked-in client source directly under `client/` where practical. If a compiler or build tool expects an ecosystem-specific directory tree, let the Docker build copy the source into that temporary layout instead of reshaping the educational repository around package publishing conventions.
- Keep build metadata needed to compile and verify the demonstration under `client/`; Docker may copy it elsewhere inside the build container. Do not treat publishability as a design goal.
- Keep cross-client black-box conformance tests under `_shared/harness/`; they do not belong to an individual client package.

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

## Pull requests

- Start every PR body with a `## Why` section that explains what prompted the change and why it is worth making.
- Include the exact Docker build and conformance commands run.
- State the earned capability badges and any known failures without rounding up.
