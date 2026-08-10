<img src="logo.png" alt="Rebol 3 project artwork" width="640">
<!-- Logo source: https://github.com/user-attachments/assets/8b71fff1-b421-4254-a1c0-eea4f4791cc5 -->

# REBOL

REBOL, short for Relative Expression Based Object Language, is an interpreted language created by Carl Sassenrath and introduced by REBOL Technologies in 1998. Its signature idea is that the same compact, typed values and blocks can represent code, data, and small domain-specific languages called dialects. It was built for lightweight networked programs and data exchange, and it later inspired related languages including Red. The original [REBOL site](https://www.rebol.com/what-rebol.html) explains the language's history and dialect model.

Today REBOL is a niche community language rather than a mainstream application stack. This project uses the actively maintained [Oldes/Rebol3](https://github.com/Oldes/Rebol3) fork and its feature-rich Bulk build. Its current downloads and language reference live at [rebol.tech](https://rebol.tech/). This client is an educational, unofficial demonstration, not a production Convex SDK or a package intended for publication.

## Getting Started

The [canonical example](examples/basics/main.r3) queries a fresh counter, starts a Live subscription before changing it, applies an idempotent mutation, and receives the reactive update. From the repository root, run:

```sh
./run verify-example rebol
```

That command builds the pinned `linux/amd64` example image in Docker and runs the exact source shown later in this README against an approved test deployment.

## Interesting Parts

### Maps are explicit, and returned JSON is checked at runtime

In TypeScript, generated Convex types check the mutation arguments and result while you write the component.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);
  const [room] = useState(() => `react-readme-${crypto.randomUUID()}`);

  async function handleClick() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(), // A retry can reuse this ID safely.
    });
    console.log(result.state.count); // The result and count are type-safe here.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**REBOL**

```rebol
do %../../client/convex.r3

convex-url: get-env "CONVEX_URL"
unless convex-open convex-url "rebol-readme-0.1.0" [
    print convex-error-message
    quit/return 1
]

room: rejoin ["rebol-readme-" enbase random-bytes 8 16]
mutation-args: make map! []
put mutation-args "room" room
put mutation-args "language" "rebol"
put mutation-args "runId" enbase random-bytes 8 16

result: convex-mutation "demo:increment" mutation-args
unless result/ok [
    print convex-error-message
    quit/return 1
]
count: convex-field-integer (select result/value "state") "count"
unless count [
    print "count was not a safe whole number"
    quit/return 1
]
print count
```

`map!` is the REBOL counterpart to the TypeScript argument object. Square-bracket blocks hold ordered REBOL values, so `make map! []` starts from an empty block and the `unless [...]` blocks contain executable code. These are ordinary REBOL blocks, not a custom dialect. Function specifications enforce top-level types at runtime, but decoded JSON fields are dynamic, so this client deliberately validates `count` instead of pretending it has TypeScript-style static field inference.

### React hides the subscription lifecycle; this client exposes it

`useQuery` subscribes when the component mounts, updates it when arguments change, and cleans it up when the component unmounts.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const [room] = useState(() => `react-live-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <p>Loading...</p>;

  return (
    <button
      onClick={() =>
        increment({ room, language: "typescript", runId: crypto.randomUUID() })
      }
    >
      Count: {state.count} {/* This rerenders when the query result changes. */}
    </button>
  );
}
```

**REBOL**

```rebol
do %../../client/convex.r3

convex-url: get-env "CONVEX_URL"
unless convex-open convex-url "rebol-live-readme-0.1.0" [
    print convex-error-message
    quit/return 1
]

room: rejoin ["rebol-live-" enbase random-bytes 8 16]
query-args: make map! []
put query-args "room" room

;; This command-line client owns setup and teardown itself.
unless convex-subscribe "counter" "demo:state" query-args [
    print convex-error-message
    quit/return 1
]
initial: convex-wait-update "counter" 15000
unless initial/ok [
    print convex-error-message
    quit/return 1
]
print convex-field-integer initial/value "count"

mutation-args: make map! []
put mutation-args "room" room
put mutation-args "language" "rebol"
put mutation-args "runId" enbase random-bytes 8 16
mutation: convex-mutation "demo:increment" mutation-args
unless mutation/ok [
    print convex-error-message
    quit/return 1
]

updated: convex-wait-update "counter" 15000
unless updated/ok [
    print convex-error-message
    quit/return 1
]
print convex-field-integer updated/value "count"  ;; The reactive result.

convex-unsubscribe "counter"
convex-close-live 2000
```

The blocking `convex-wait-update` call is a design choice in this small command-line client, not a limitation of REBOL's event system. It keeps the ownership and ordering visible: subscribe, consume the initial value, mutate, consume the update, then clean up. The complete example below adds all value and error checks.

## Status

| Capability | Evidence-backed status |
| --- | --- |
| HTTP query, mutation, and action | Earned |
| Live queries | Earned |
| Local and hosted shared conformance | All 31 required checks passed on both profiles |
| Implementation provenance | Native REBOL, with no delegated Convex client or runtime |

The implementation is `working` in the `coverage` selection tier. The recorded evidence under `_shared/results/` was produced from the same clean source image for the local and hosted deployment profiles. This README does not claim that those historical checks were rerun for this documentation edit.

## Example

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

## Implementation Notes

### Docker verification

```
./run test rebol
```

fetches and sha256-verifies the pinned Rebol/Bulk release, asserts the
unpacked binary is a genuine linux/amd64 ELF, and runs every unit and
regression test in this table inside the Dockerfile's `test` stage:
`client/json.r3` (the JSON codec), `client/x509.r3` (chain/hostname
verification against four live hosts), `client/tests/smoke-live.r3` (one
forced reconnect end to end), `client/tests/live-reconnect-test.r3` (five
real reconnects with backoff-reset and rehydration-suppression proofs),
`client/tests/conformance/queue-test.r3` (the adapter's bounded output
queue under a simulated stopped reader), a `hello`/`close` smoke check of
the conformance adapter over both its transports (stdin/stdout, and
`ADAPTER_LISTEN` via a test-only `busybox nc`), and the canonical example
run live against a fresh room.

```
./run verify-example rebol   # the canonical example against the local backend
./run verify rebol           # + shared black-box conformance, local backend
./run verify-hosted rebol    # the same, against the hosted drift target
./run verify-all rebol       # both deployment profiles from one built image
```

build the `example-runtime` and `runtime` Docker stages -- a minimal,
non-root, read-only, all-capabilities-dropped image for each -- and run the
example and the shared conformance controller against them. `./run
verify-all rebol` is the evidence in
`_shared/results/local/rebol-pilot-result.json` and
`_shared/results/hosted/rebol-pilot-result.json`: all 31 required HTTP and
Live checks passing on both deployment profiles from the same built image
(`imageDigest` identical in both files), `dirty: false`, at the exact commit
this README was updated alongside. Only the shared result evaluator computes
the `http`/`live` capability badges from that evidence; this README does not
round up ahead of it.

### The TLS chain-of-trust and hostname verification (`client/x509.r3`)

The hardest and highest-risk part of a REBOL Convex client was built and
proven ahead of the rest: **`client/x509.r3`**, a from-scratch certificate
chain and hostname verifier written directly against this fork's own crypto
primitives.

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
its own precise reason rather than one generic failure:

```
PASS -- accepts the real Convex chain -- accepted
PASS -- rejects a self-signed certificate -- rejected (no bundled trust anchor found for issuer ...)
PASS -- rejects an expired certificate -- rejected (certificate 1 in chain is outside its validity window ...)
PASS -- rejects a certificate for the wrong hostname -- rejected (certificate name does not match requested host ...)
ALL TESTS PASSED
```

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

### The conformance adapter

`client/tests/conformance/main.r3` is test infrastructure, not public client
code: it wraps `client/convex.r3`'s public `convex-*` functions with the
shared NDJSON adapter protocol v1 (`hello`, `query`/`mutation`/`action`,
`subscribe`/`unsubscribe`, `setAuth`, the adapter-only `debugDisconnect`, and
`close`), over stdin/stdout or one accepted controller connection when
`ADAPTER_LISTEN=host:port` is set. It reserves stdout (or the controller
socket) for protocol events; every diagnostic goes to stderr. Every event is
built as a real REBOL `map!` (nesting a second `map!` for a structured
`error`) and handed to `json-encode`, so an absent optional field (`id` on
most events, `subscriptionId` outside a subscription event) is naturally
omitted -- a key that is never `put` is never iterated -- while a genuinely
null Convex value or error `data` still encodes as an explicit `null`.

Its output queue is bounded (8 slots, a 4 MiB byte budget): subscription
push events are dropped oldest-first under backpressure, while
`hello`/`result`/`error`/`ack`/`closed` responses are never dropped -- if the
budget cannot be freed without evicting one of those, the adapter fails
loudly (`client/tests/conformance/queue-test.r3` proves both halves of that
directly, with no network involved).

Two environment findings shaped its transport code specifically, both
confirmed directly against this build rather than assumed:

- `system/ports/input` (stdin) does not participate in this build's async
  `wait`/`awake` event model at all: the standard pattern this client
  already relies on for `tcp://` ports elsewhere (install an `awake`
  handler, call `read` to queue the operation, then `wait` and let the
  handler's `'read` event fire) was tested directly against stdin with data
  already sitting in the pipe before the process even started -- no
  `'read` event ever fired, and `wait` returned `none` only after burning
  its full requested timeout regardless of length. A plain synchronous
  `read` works and blocks correctly, but with no way to bound it, so the
  adapter's stdin/stdout transport mode cannot interleave pumping Live with
  waiting for the next controller line the way its `ADAPTER_LISTEN` TCP
  mode does (a real `tcp://` port on both sides there). It also drops the
  very last trailing newline once the writer closes stdin without a delay,
  confirmed directly: `ad-read-command`'s stdio branch treats a non-empty
  leftover buffer at true EOF as one final complete line for exactly this
  reason, rather than silently discarding it.
- A listening `tcp://` port needs `func` (not `function`) for both the
  opening routine and its nested `awake` closure -- an initial
  `function`-declared handler silently shadowed its own `accepted` local
  instead of mutating the enclosing scope's, the same FUNCTION-vs-FUNC trap
  `client/convex.r3`'s own header documents, and `ADAPTER_LISTEN` mode
  accepted nothing at all until fixed.

The shared harness's own conformance run uses `ADAPTER_LISTEN`, where the
stdin gap above does not apply; stdin/stdout mode still fully implements
protocol v1 (proven with a build-time `hello`/`close` probe) for any other
caller that wants a plain pipe.

The `runtime` Docker stage needs `/bin/sh` for the shared `image_policy`
check (which execs `--entrypoint /bin/sh` against it directly) without
shipping a full distribution, unlike `example-runtime` above it (whose
distroless base has no shell at all, and needs none: its `ENTRYPOINT`
array invokes the interpreter directly). `/usr/local/bin/convex-adapter`
is therefore a `#!/bin/sh` launcher script -- `image_policy` also requires
`Config.Entrypoint` to equal exactly the single-element array
`["/usr/local/bin/convex-adapter"]`, so the real interpreter lives at
`/opt/convex/bin/rebol3` instead -- staged into a `debian:bookworm-slim`
pruned to nothing else via a bind-mounted `busybox`, matching the pattern
`setl/Dockerfile` and `mumps/Dockerfile` both use. No OpenSSL or system CA
store is staged at all: `client/x509.r3`'s trust bundle
(`client/ca-bundle/*.pem`) is entirely separate from the system trust
store.

### REBOL lessons learned along the way

- This Rebol/Bulk build always tries to create `~/.rebol/` once at process
  start, and prints one uncontrollable warning line to stdout -- even
  under `--quiet` -- if it cannot (which it never can under a read-only
  root filesystem with no writable `$HOME`). That would have broken the
  canonical example's exact-match stdout contract non-deterministically.
  The fix is to pre-create that directory, empty, owned by `65532:65532`,
  as an image layer in the `toolchain` stage and copy it into every
  runtime image, so REBOL never tries to create it at all.
- This build's default file-security policy is scoped to the process's
  *current working directory*, not a global allow/deny -- a `read`
  against an absolute path is allowed from `WORKDIR /work` and denied from
  anywhere else, independent of the filesystem's own permissions or of
  `$HOME`. The `test` Dockerfile stage copies `client/` and `examples/`
  under `WORKDIR /work` for exactly this reason; `examples/basics/main.r3`
  and `client/tests/conformance/main.r3` instead call `secure [file
  allow]` once at their own top, since both also need to open
  `%/dev/stderr`, which is outside any `WORKDIR` regardless.
- A fresh process draws the exact same deterministic `random/secure` byte
  sequence on every run until something calls `random/seed` -- left
  unseeded, every room/runId this client generates would collide across
  every Docker run. `client/convex.r3` reseeds once per process from
  `now/precise`'s sub-second wall clock, which is enough for this client's
  own uses of randomness (none of which are a cryptographic guarantee it
  relies on).
- See "The conformance adapter" above for the two findings specific to
  the adapter's own transport code: `system/ports/input`'s non-functional
  `wait` integration, and the FUNCTION-vs-FUNC trap for a listening
  `tcp://` port's nested `awake` closure.

### Toolchain

Rebol/Bulk 3.22.1, tag `3.22.1` from
[github.com/Oldes/Rebol3](https://github.com/Oldes/Rebol3/releases/tag/3.22.1),
asset `rebol3-bulk-linux-x64.gz`, sha256
`1932a7048b09cad5fc7bd9c6e4649f9fcfb45245d55876871d6a89e1d5dbad32`.

## Known Issues

1. `system/ports/input`'s `wait` integration does not work in this build
  (see above); the conformance adapter's stdin/stdout transport mode
  cannot interleave pumping Live with waiting for the next controller
  command the way its `ADAPTER_LISTEN` TCP mode does. The shared harness
  uses `ADAPTER_LISTEN`, where this does not apply.
2. The trust bundle (`client/ca-bundle/`) is a small curated set (GTS Root
  R1, GTS Root R4, ISRG Root X1, GlobalSign Root CA), sha256-verified
  against each publisher's own listing at the time it was bundled -- not
  the full system trust store.
3. Live authentication (`setAuth` while a Live connection is open, rather
  than before one starts), WebSocket-issued mutations and actions, and
  `TransitionChunk` assembly are not implemented; an unrecognized
  Transition modification is reported as a `ProtocolError` and the
  connection reconnects.
4. The client keeps only the latest delivered value per subscription (no
  unbounded queue); the conformance adapter's own bounded output queue
  (8 slots, 4 MiB) is what bounds memory toward a slow or stopped
  consumer, proven directly by `client/tests/conformance/queue-test.r3`.
