# Racket

This language client is planned as roster entry 88.

No implementation exists and no capabilities have been earned.

## Current blocker

The client cannot be implemented or verified honestly in this worktree yet.
Every Racket toolchain tested under the repository's required
`docker --platform linux/amd64` target fails before it can complete
`racket -v`:

- `racket/racket:8.18-full@sha256:c9104a6ce9df82947c5753718606cca305aeaf80c0b79038546625656277f56d`
- `racket/racket:8.17-bc@sha256:f50290e1c1f6e431c5077fe59265ba88283a42bcb5ee9187ee97413baa3cb023`
- Debian Bookworm's `racket=8.7+dfsg1-1`

The upstream images likewise fail before version output. The Debian package
reports `Error: error reading from ~a (\"petite\")` and exits 134. This happens
before source, dependencies, or a Dockerfile can be tested, so adding an
implementation would be unverified. Revisit this entry on an amd64 Docker
runner where Racket starts successfully, then run the normal Docker-only test,
example, and conformance gates.

- Selection tier: `curated_backfill`
- Implementation status: `planned`
- Earned capabilities: none
