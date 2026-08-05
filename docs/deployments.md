# Pilot deployments

## Deterministic local backend

| Field | Value |
| --- | --- |
| Runtime | Docker Desktop local Linux VM |
| Image | `ghcr.io/get-convex/convex-backend` |
| Image digest | `sha256:467964cc6af57ba3e757e3e6cb1fa09a1c577803a19f03f0f42c9c4b134b070c` |
| Upstream revision | `19431ea0dd90bc55ae58dbbd06d9aa045f97336f` |
| Client URL | `http://127.0.0.1:3210` from the host, `http://backend:3210` on the test network |

The Docker volume is disposable pilot state. `./run backend-down` stops it
without deleting data.

## Hosted compatibility smoke

| Field | Value |
| --- | --- |
| Team | `mikec` |
| Project | `100-convex-clients` |
| Deployment | `usable-reindeer-44` |
| Type | Development |
| Region | US East (N. Virginia) |
| Client URL | `https://usable-reindeer-44.convex.cloud` |
| HTTP actions URL | `https://usable-reindeer-44.convex.site` |
| Version observed 5 August 2026 | `20260804T225444Z-ff2ecc1270b7` |

The hosted URL is public by design. Account credentials and deployment keys are
not committed. Its purpose is current HTTPS/WSS compatibility smoke testing,
not deterministic conformance or production traffic.

The Go pilot passes the complete HTTP and Live suite on this deployment,
including five forced reconnects and reactive query error recovery. The hosted
run caught a stale certificate bundle in the first candidate runtime image; the
final image now installs Alpine `ca-certificates` `20260611-r0`, and the pilot
controller deliberately tests that exact client bundle.
