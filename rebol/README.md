# Convex from REBOL

An in-progress, educational demonstration of talking to Convex from REBOL,
using Rebol/Bulk 3.22.1 (the [Oldes/Rebol3](https://github.com/Oldes/Rebol3)
fork)'s own native `tcp://`/`tls://` port schemes -- no OpenSSL, no FFI, no
delegated runtime.

This is educational and unofficial. It is not a production Convex SDK.

## Status

Implementation is in progress. `client/convex.r3` already implements the
HTTP query/mutation/action calls, RFC 6455 WebSocket framing, and the
`/api/sync` Live state machine (`Connect` / `ModifyQuerySet` /
`Transition`, reconnect-with-backoff, and `debugDisconnect`) over
`client/x509.r3`'s verified TLS transport, and `examples/basics/main.r3`
exercises all of it end to end against a real deployment. The shared
conformance adapter (`client/tests/conformance/`) does not exist yet, so
no capability has been earned yet -- see `manifest.yaml`'s
`capabilities: []`. `Dockerfile` has verified `test` and
`example-runtime` targets; `runtime` (the conformance adapter's own
image) does not exist yet either.

## What is proven so far

The hardest and highest-risk part of a REBOL Convex client is already built
and proven, ahead of the rest: **`client/x509.r3`**, a from-scratch
certificate chain and hostname verifier written directly against this
fork's own crypto primitives.

Rebol/Bulk's native `tls://` scheme completes a genuine TLS 1.2/1.3
handshake and decodes every certificate a peer presents -- but it performs
**no chain-of-trust check and no hostname check at all**. Verified directly:
its `https://` scheme connects to `self-signed.badssl.com`,
`expired.badssl.com`, and `wrong.host.badssl.com` with no error whatsoever.

`client/x509.r3` supplies that missing verification in REBOL itself, hooked
into the TLS port's own `'connect` event -- which fires once the handshake
finishes, before any request is written or response read -- so a rejected
peer never gets a single byte of trust from this client:

1. **Hostname/SAN match** on the leaf certificate (RFC 6125-style, a single
   leftmost wildcard label only, never for an IP literal).
2. **Validity window** on every certificate in the presented chain.
3. **Signature chain** up to a small, curated, bundled set of trust anchors
   (`client/ca-bundle/`: GTS Root R1, GTS Root R4, ISRG Root X1, and
   GlobalSign Root CA -- the last specifically because Google Trust
   Services' own roots are sometimes served cross-signed by it for legacy
   client compatibility, which is exactly what the real Convex host does on
   some connections). Trust is checked at every hop in the presented chain,
   not only the last certificate, so that cross-signed case is handled
   correctly rather than rejected as untrusted.

Checks run in that order deliberately, so each rejection is reported for
its own precise reason rather than one generic failure.

`client/tests/x509-verify-test.r3` proves this against four **live** hosts,
not fixtures:

```
PASS -- accepts the real Convex chain -- accepted
PASS -- rejects a self-signed certificate -- rejected (no bundled trust anchor found for issuer ...)
PASS -- rejects an expired certificate -- rejected (certificate 1 in chain is outside its validity window ...)
PASS -- rejects a certificate for the wrong hostname -- rejected (certificate name does not match requested host ...)
ALL TESTS PASSED
```

Run it yourself:

```
docker run --rm --platform linux/amd64 -v $(pwd)/client:/work/client rebol-spike:3.22.1 --quiet /work/client/tests/x509-verify-test.r3
```

(against the pinned spike image the language's own `Dockerfile` now
supersedes for `test` and `example-runtime`; see below).

Two implementation notes worth recording honestly, since they were real
correctness traps while building this:

- Both the RSA public-key point and the DER `signature` field come back
  from this fork's own `BIT_STRING` parsing with their leading "unused
  bits" byte still attached; every key and signature this module handles
  strips it explicitly before use.
- The fork's certificate codec (`codec-crt.reb`) parses certificate
  *fields* but discards the exact raw bytes of `tbsCertificate` --the
  signed content-- once parsing finishes. Reconstructing those bytes by
  re-encoding the decoded fields would risk silently producing bytes that
  merely describe the same certificate without matching what was actually
  signed. Instead, `client/x509.r3` wraps the registered `crt` codec's own
  `decode` function (an ordinary mutable slot, not a sealed native) to
  capture the exact bytes as they pass through, with no re-encoding
  involved.

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.r3 -->
```rebol
Rebol [
    Title: "main.r3 -- the canonical Convex-from-REBOL example"
    Purpose: {
        A short tour of the native REBOL Convex client: an HTTP query, a
        Live subscription started before a mutation so the initial
        snapshot cannot be missed, an idempotent mutation, and the
        resulting Live update -- the same shared-counter 0 -> 1 journey
        every client in this repository proves.

        This program is deliberately thin: client/convex.r3 already owns
        every protocol detail (the hand-rolled JSON codec, the hardened
        TLS chain/hostname verification, HTTP framing, the RFC 6455
        WebSocket layer, and the /api/sync Live state machine). Everything
        below just calls its public convex-* functions and checks the
        values Convex actually returned; an unexpected value is a hard
        failure via QUIT/RETURN 1, never a printed warning.

        stdout carries only the six lines the website and video are meant
        to show; every diagnostic goes to stderr instead, opened as a
        plain OS file below since REBOL's own ports collapse stdout and
        stdin into a single `console` scheme with no separate stderr
        port.
    }
]

;; Widens the file-access category of REBOL's own security sandbox from
;; whatever its ambient default happens to be (observed to vary with
;; whether the process could establish a writable data folder) to a
;; known "allow", before anything else touches a file: loading
;; client/convex.r3 below needs to read it and client/ca-bundle/*.pem,
;; and `diagnose` later needs to open %/dev/stderr for writing. Every
;; other security category (network access included) keeps its
;; restrictive default.
secure [file allow]

;; client-dir is wherever THIS script lives; convex.r3 needs to be found
;; relative to it regardless of the caller's own working directory.
do %../../client/convex.r3

;; diagnose(message) -> writes one line to the real OS stderr, kept
;; entirely separate from the six lines of stdout the shared verifier
;; compares byte-for-byte against _shared/examples/basics.expected.txt.
diagnose: function [message [string!] /local err-port] [
    err-port: open/write %/dev/stderr
    write err-port rejoin [message "^/"]
    close err-port
]

;; fail(operation, message) -> reports a failed step on stderr and exits
;; non-zero. Never returns, so every call site below can rely on whatever
;; it was checking having held from this point on.
fail: function [operation [string!] message [string!]] [
    diagnose rejoin [operation ": " message]
    quit/return 1
]

;; check-result(operation, response) -> fails unless a convex-query/
;; mutation call actually succeeded; convex-call already classifies a
;; transport failure, an HTTP-level failure, and a Convex-level function
;; error into the same response/ok = false shape, so this one check
;; covers all three.
check-result: function [operation [string!] response] [
    unless response/ok [
        fail operation rejoin [convex-error-name ": " convex-error-message]
    ]
]

;; check-count(operation, value, expected) -> pulls "count" out of a
;; decoded Convex value (a query result, a mutation's returned state, or
;; a Live update) and fails unless it is exactly `expected`.
;; convex-field-integer already accepts Convex's integral-decimal
;; spellings such as 0.0, so this never has to special-case one itself;
;; a non-object value fails here too, rather than crashing on a type
;; REBOL's own function dispatch did not expect.
check-count: function [operation [string!] value expected [integer!] /local count] [
    unless map? value [fail operation "value is not a JSON object"]
    count: convex-field-integer value "count"
    unless count [fail operation "count is missing or not a whole number"]
    unless count = expected [
        fail operation rejoin ["count was " count ", expected " expected]
    ]
]

;; -- configuration: the deployment URL always comes from the
;; environment, never hardcoded, so this same image can run against any
;; approved Convex deployment.
convex-url: get-env "CONVEX_URL"
unless convex-url [
    diagnose "CONVEX_URL is required"
    quit/return 2
]

;; The shared conformance harness passes a fresh, unique room as this
;; program's own first argument, so the counter demonstrated below always
;; starts at 0; running the image by hand without one falls back to a
;; fixed room name instead.
room: either not empty? system/options/args [first system/options/args] ["rebol-basic-example"]

;; -- client creation. This example calls only a public demo function, so
;; it never sets an auth token; a client that needed one would pass it to
;; convex-set-auth instead of building a header by hand.
unless convex-open convex-url "rebol-0.1.0" [
    fail "open client" convex-error-message
]

query-args: make map! []
put query-args "room" room

;; -- the HTTP query: a plain request/response round trip through
;; client/convex.r3's own convex-query, this client's implementation of
;; Convex's documented "format":"json" /api/query endpoint.
current: convex-query "demo:state" query-args
check-result "current query" current
;; Decoding {"count": N} into a plain REBOL integer is this step's
;; "idiomatic value": everything above this line is Convex protocol
;; plumbing, and everything below just works with an ordinary number.
check-count "current query" current/value 0
print "current count: 0"

;; -- start Live before the mutation. Subscribing to the same query now
;; and reading its first value before changing anything is what makes the
;; later "updated" value unambiguous: if the mutation ran first, this
;; client could never tell a genuinely new value apart from one that was
;; already current when the subscription began.
unless convex-subscribe "counter" "demo:state" query-args [
    fail "subscribe" convex-error-message
]
initial: convex-wait-update "counter" 15000
unless initial/ok [fail "initial Live value" convex-error-message]
if initial/has-error [fail "initial Live value" initial/err-message]
check-count "initial Live value" initial/value 0
print "live initial count: 0"

;; -- the mutation, with its idempotency key. runId lets a retried
;; mutation (say, after a transient network failure between this client
;; and the deployment) return the already-applied result instead of
;; incrementing the counter a second time; a fresh random one here only
;; has to be unique to this one run, which random-bytes's process-seeded
;; random/secure already guarantees.
mutation-args: make map! []
put mutation-args "room" room
put mutation-args "language" "rebol"
put mutation-args "runId" enbase random-bytes 8 16
mutation: convex-mutation "demo:increment" mutation-args
check-result "mutation" mutation
unless (select mutation/value "applied") = true [
    fail "mutation" "was not applied"
]
print "mutation applied: true"
check-count "mutation" (select mutation/value "state") 1
print "mutation count: 1"

;; -- the resulting Live update, received without issuing a second HTTP
;; query: this is Convex's own reactivity working end to end, over the
;; RFC 6455 WebSocket + /api/sync state machine client/convex.r3
;; implements.
updated: convex-wait-update "counter" 15000
unless updated/ok [fail "updated Live value" convex-error-message]
if updated/has-error [fail "updated Live value" updated/err-message]
check-count "updated Live value" updated/value 1
print "live updated count: 1"

;; -- cleanup: stop the subscription and close the Live connection before
;; printing the final line, so a hang during teardown would itself be a
;; visible example failure rather than a silently skipped step.
convex-unsubscribe "counter"
convex-close-live 2000

;; Reached only once the HTTP query, the initial Live value, the
;; mutation, and the updated Live value all agree on the same 0 -> 1
;; journey.
print "verified count: 0 -> 1"
```
<!-- END GENERATED EXAMPLE -->

## The canonical example, and the Dockerfile

`examples/basics/main.r3` runs the shared-counter 0 -> 1 journey every
client in this repository proves: an HTTP query, a Live subscription
started before a mutation, the mutation itself with its idempotency key,
and the resulting Live update -- entirely through `client/convex.r3`'s
public `convex-*` functions. Its stdout has been byte-diffed against
`_shared/examples/basics.expected.txt` and matches exactly; two failure
paths (a missing `CONVEX_URL`, an unreachable deployment) were checked
separately and exit non-zero with stdout empty, as required.

`Dockerfile`'s `test` and `example-runtime` targets are built and
verified, including under the exact conditions the shared verifier itself
uses (`--read-only --cap-drop ALL --user 65532:65532`, no `--tmpfs`):

- `test` fetches and sha256-verifies the pinned Rebol/Bulk release,
  asserts the unpacked binary is a genuine linux/amd64 ELF, and then runs
  `json-test.r3`, `x509-verify-test.r3`, `smoke-live.r3`, and the
  canonical example itself, live, inside the build.
- `example-runtime` is `gcr.io/distroless/base-debian12:nonroot` (pinned
  by digest) plus the interpreter binary (renamed to
  `/usr/local/bin/convex-example`, with the example script wired into
  `ENTRYPOINT`'s own argument vector, so no shell is needed to glue them
  together -- this base has none) and nothing else. No compiler, package
  manager, or delegated runtime is present.

One real bug surfaced and fixed while proving that: this Rebol/Bulk build
always tries to create `~/.rebol/` once at process start, and prints one
uncontrollable warning line to stdout -- even under `--quiet` -- if it
cannot (which it never can here: read-only root filesystem, no writable
`$HOME`, no `--tmpfs /tmp` from the shared verifier's own client
container). That would have broken the exact-match stdout contract
non-deterministically. The fix is to pre-create that directory, empty,
owned by `65532:65532`, as an image layer in the `toolchain` stage and
copy it into `example-runtime`, so REBOL never tries to create it at all.

A second, unrelated finding: this build's default file-security policy is
scoped to the process's *current working directory*, not a global
allow/deny -- a `read` against an absolute path is allowed from
`WORKDIR /work` and denied from anywhere else, independent of the
filesystem's own permissions or of `$HOME`. `test` copies `client/` and
`examples/` under `WORKDIR /work` for exactly this reason, matching what
the manual command above already relied on.
`examples/basics/main.r3` instead calls `secure [file allow]` once at its
own top (before loading `client/convex.r3` or opening `%/dev/stderr` for
diagnostics), since it also needs to open a path outside any WORKDIR.

`runtime` (the conformance adapter's own image, entrypoint
`/usr/local/bin/convex-adapter`) does not exist yet -- see Remaining
work below.

Through the project's own `./run` harness rather than a manual `docker`
invocation: `./run test rebol` and `./run verify-example rebol` (against
a real self-hosted local backend deployment) both pass:

```
PASS rebol basic example returned the expected 0 -> 1 update against self-hosted
```

`./run verify` / `verify-hosted` / `verify-all` cannot pass yet --
`image_policy` requires the default (non-`--target`) build to be the
`runtime` stage with entrypoint `/usr/local/bin/convex-adapter`, which
does not exist.

## Toolchain

Rebol/Bulk 3.22.1, tag `3.22.1` from
[github.com/Oldes/Rebol3](https://github.com/Oldes/Rebol3/releases/tag/3.22.1),
asset `rebol3-bulk-linux-x64.gz`, sha256
`1932a7048b09cad5fc7bd9c6e4649f9fcfb45245d55876871d6a89e1d5dbad32`.

## Remaining work

- The NDJSON conformance adapter (`client/tests/conformance/`): protocol
  v1, `ADAPTER_LISTEN` TCP listen mode, strict schema compliance, and a
  `runtime` Dockerfile target (entrypoint `/usr/local/bin/convex-adapter`)
  to run it in. `client/convex.r3` already exposes everything the adapter
  needs (subscribe/unsubscribe, wait-for-update, `convex-debug-disconnect`
  for the shared controller's forced-reconnect proof), but nothing yet
  speaks the adapter's own NDJSON request/response protocol over a
  listening socket.
- Once the adapter exists: the fuller reconnect/backpressure proof the
  project asks for (five real reconnects via `debugDisconnect` with
  unchanged-value rehydration suppressed and observed, backoff reset after
  a good handshake, a bounded queue under a stopped reader) -- today only
  `client/tests/smoke-live.r3`'s single forced reconnect is proven.
  `client/convex.r3`'s `live-transition` already implements rehydration
  suppression and `live-maybe-reconnect` already implements backoff, but
  neither has a dedicated regression exercising it under repeated,
  scripted failures yet.
- `./run test rebol`, `./run verify-example rebol`, `./run verify rebol`,
  and `./run verify-all rebol` have not been run through the project's
  own harness yet (the Docker builds and live-backend checks above were
  run directly, not through `./run`); until the adapter and `runtime`
  target exist, `./run verify`/`verify-all` cannot pass regardless.
- `manifest.yaml`'s `capabilities: []` and the roster swap
  (`actionscript` -> `rebol` at rank 58) stay unearned/unmerged until the
  above passes the shared evaluator -- no capability is claimed here.
