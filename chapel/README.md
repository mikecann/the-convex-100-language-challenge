# Convex from Chapel

This folder shows Chapel calling Convex queries, mutations, and actions over
HTTPS, then following a query over a Live WebSocket connection.

This is an educational, unofficial demonstration. It is not a production SDK
or a package intended for publication.

## Start here

[`examples/basics/main.chpl`](examples/basics/main.chpl) follows one isolated
counter room from 0 to 1. It queries the current state, starts Live before the
write, applies an idempotent mutation, and receives the resulting Live value.

## What works

| Capability | Status |
| --- | --- |
| HTTPS queries, mutations, and actions | Implemented; shared verification pending |
| Bearer-token lifecycle and structured function errors | Implemented; shared verification pending |
| Initial and updated Live query values | Implemented; shared verification pending |
| Unsubscribe, reconnect, hydration suppression, and clean shutdown | Implemented; shared verification pending |
| Canonical example executed against Convex | Shared example verification pending |
| Live authentication and tagged Convex values | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.chpl -->
```text
module ChapelConvexBasics {
  use IO;
  use Convex;
  use ConvexTransport;

  // Turn the JSON shape used by this demo into an application value. The C
  // JSON transport helper performs exact decimal validation, so 1.0 is valid
  // while fractional, quoted, non-finite, and overflowing counts are rejected.
  proc countFromState(operation: string, stateJson: string): int(64) {
    const (valid, count) = jsonIntegralField(stateJson, "count");
    if !valid then
      halt("decode ", operation, ": count must be an in-range integer");
    return count;
  }

  // Every demonstrated operation is checked before anything claims success.
  proc expectCount(operation: string, actual: int(64), expected: int(64)) {
    if actual != expected then
      halt(operation, " count was ", actual, ", expected ", expected);
  }

  proc requireSuccess(operation: string,
                      const ref result: callResult): string {
    if !result.ok then halt(operation, " failed: ", result.failure.message);
    return result.valueJson;
  }

  proc main(args: [] string) {
    const deploymentUrl = environment("CONVEX_URL");
    if deploymentUrl.numBytes == 0 then halt("CONVEX_URL is required");

    // Create a Convex client connected to the deployment from the environment.
    var client = new owned Client(deploymentUrl);

    // Close the HTTP and Live resources before the example exits.
    defer client.close();

    const room = if args.size > 1 then args[1] else "chapel-example";
    const roomArgs = "{\"room\":" + jsonQuote(room) + "}";

    // Run a Convex query over HTTPS to get this room's current state.
    const currentJson = requireSuccess(
      "current query", client.query("demo:state", roomArgs)
    );

    // Decode the raw JSON into the Chapel integer used by the application.
    const currentCount = countFromState("current query", currentJson);
    expectCount("current query", currentCount, 0);
    writeln("current count: ", currentCount);

    // Start Live before mutating so it cannot miss the demonstrated change.
    const (subscription, subscribeFailure) =
      client.subscribe("demo:state", roomArgs);
    if subscribeFailure.isPresent || subscription == nil then
      halt("subscribe failed: ", subscribeFailure.message);

    // Stop the query on scope exit. Shared ownership keeps an active reader
    // alive until its task has observed the terminal close.
    defer subscription!.close();

    // Convex Live first sends a snapshot. Read and validate it before writing.
    const initial = subscription!.next(10.0);
    if !initial.available || initial.failure.isPresent ||
       !initial.hasValue then
      halt("Live subscription did not deliver its initial value");
    const initialCount = countFromState(
      "initial Live value", initial.valueJson
    );
    expectCount("initial Live value", initialCount, currentCount);
    writeln("live initial count: ", initialCount);

    // Run the mutation over HTTPS. runId is its idempotency key, so a retry
    // cannot accidentally apply a second increment.
    const mutationArgs = "{\"room\":" + jsonQuote(room) +
      ",\"language\":\"chapel\",\"runId\":" +
      jsonQuote(randomUUID()) + "}";
    const mutationJson = requireSuccess(
      "mutation", client.mutation("demo:increment", mutationArgs)
    );
    const (hasApplied, appliedJson) = jsonRaw(mutationJson, "applied");
    if !hasApplied || appliedJson != "true" then
      halt("mutation was not applied");
    writeln("mutation applied: true");
    const (hasState, mutationState) = jsonRaw(mutationJson, "state");
    if !hasState then halt("mutation result omitted state");
    const mutationCount = countFromState("mutation", mutationState);
    expectCount("mutation", mutationCount, 1);
    writeln("mutation count: ", mutationCount);

    // Receive the changed room through Live without another HTTP query.
    const changed = subscription!.next(10.0);
    if !changed.available || changed.failure.isPresent ||
       !changed.hasValue then
      halt("Live subscription did not deliver the changed value");
    const changedCount = countFromState(
      "updated Live value", changed.valueJson
    );
    expectCount("updated Live value", changedCount, 1);
    writeln("live updated count: ", changedCount);

    // Reaching here proves HTTPS and Live agreed on the same 0 -> 1 change.
    writeln("verified count: ", currentCount, " -> ", changedCount);
  }
}
```
<!-- END GENERATED EXAMPLE -->

The block above is projected from the exact source compiled into
`/usr/local/bin/convex-example` and shown on the evidence site.

## Docker verification

No Chapel tooling runs on the host.

```sh
./run test chapel
./run verify-example chapel
./run verify chapel
./run verify-hosted chapel
./run verify-all chapel
```

`test` is the language-local formatting, unit, architecture, adapter, and
compilation gate. It includes raw HTTP, TLS, and RFC 6455 peers which exercise
body and frame limits, absolute deadlines, strict upgrades, fragmented UTF-8,
control frames, malformed-101 rejection before any Convex message, continuous
ping and slow-write deadlines, exact RFC 6455 decoding after forced short
writes, non-2xx HTTP rejection, repeated reconnects without pre-establishment
transport events, one-byte frame-header retirement after Add, complete/complete
and complete/partial buffered decoder states, repeated idle timeouts followed
by healthy traffic, hydration suppression, query failures, generation barriers,
and a real stopped-reader adapter below 128 MiB. The other
commands execute the canonical example and shared black-box contracts; only
their recorded results may award HTTP or Live badges.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` speaks strict NDJSON
protocol v1 on stdin/stdout or one `ADAPTER_LISTEN` TCP connection. It reserves
stdout for events and calls the real Chapel client for every operation. Its
`debugDisconnect` command is adapter-only and waits until the old socket is
retired before acknowledging the controller. Commands reject unknown fields,
wrong JSON types, blank or overlong identifiers, paths outside 3 to 1024 Unicode
scalars, and non-object arguments before dispatch.

libcurl supplies HTTP, TLS, and WebSocket transport, while json-c supplies
dynamic JSON parsing. Chapel owns Convex envelopes, the pinned `/api/sync`
state machine, query-set versions, little-endian timestamp ordering, reconnect
backoff, hydration suppression, generation barriers, and structured failures.
The WebSocket boundary independently validates status 101, case-insensitive
Upgrade and Connection tokens, and the SHA-1/Base64 accept proof using a
constant-time comparison. JSON string extraction is length-aware and rejects
embedded NUL wherever Chapel exposes a scalar string.
Receive calls caused by socket activity or plausible libcurl-buffered data run
under a per-call watchdog tied to the current `CURLINFO_ACTIVESOCKET`. A stalled
header decoder is shut down at the message's absolute one-second deadline, and
the watchdog is always joined before cleanup can reuse the descriptor. True
idle waits stay in `poll` and do not create a watchdog.
HTTP bodies, WebSocket messages, and NDJSON lines cross the Chapel/C boundary
with explicit byte lengths. C rejects invalid UTF-8, embedded NUL, or bytes past
the declared text before Chapel constructs a string; decoding uses recoverable
`try` blocks rather than process-aborting `try!`. A fully consumed bad NDJSON
line emits a structured error and the next command is still accepted.
Authorization fixtures record the exact outgoing header and prove opaque token
bytes are preserved, replacement takes effect, and an empty token omits the
header entirely.

Each subscription transfers complete updates through Chapel synchronization
slots and retains the newest 16 within a 4 MiB byte budget. Relay tasks retain a
shared subscription handle until they observe close. At most 64 subscriptions
are active at once and retired slots are reusable. One 32 MiB aggregate budget
covers every retained path, argument object, last value, queued value, logs, and
error payload across all subscriptions, including conservative runtime overhead.
The adapter has a separate
sole output writer bounded to 16 encoded records and 8 MiB including
conservative overhead. Subscription overflow drops the oldest value, while
adapter overflow fails closed; neither can grow without limit.
One Client lifecycle lock serializes closed-state changes with Live owner
creation, snapshots, and removal, while shared task intents keep each selected
owner alive after that short critical section.
Subscriptions hold a shared accounting/lifecycle handle rather than a borrowed
manager pointer. `Subscription.close()` snapshots that handle once under its own
lock, so concurrent Client and subscription closure cannot dereference a retired
Live owner or create an ownership cycle. Accounting underflow is detected and
the pressure regression returns the shared counter to exactly zero.
Counter release uses a compare/exchange loop, so an underflow attempt is
reported without ever publishing a transient negative value. Adapter teardown
shares one three-second absolute budget across all 64 subscriptions, the Client,
and the sole output writer. Live dial attempts are capped at one second so a
closing Client can join its owner inside that budget. The adapter writes
`closed` only after every owner and the output writer report successful stop;
otherwise it retains the first failure, attempts a terminal error, and exits
nonzero.

The final image contains the compiled adapter and example plus a real POSIX
shell and the verifier's `id`, `grep`, `sed`, and `awk`. BusyBox and its
multicall links, package managers, compilers, scripting runtimes, and CLI network
clients are removed. The image gate executes the exact example binary and
expects its controlled connection failure against an unreachable local URL.
The runtime build also removes `/sbin/apk` explicitly and audits every executable
regular file across the filesystem, allowing only the documented binaries and
their runtime libraries.
The Chapel base and Alpine runtime are digest-pinned. Apt is additionally fixed
to the `20260806T000000Z` Debian snapshot, and the build records the exact
libcurl, json-c, OpenSSL, and Python package versions in
`/out/material-versions`. A test-only child of the stripped runtime runs the raw
peer suite with a locally trusted, hostname-validated TLS certificate; the final
adapter and example stages depend on its success marker.
Transport injection symbols and their Chapel wrappers compile only in the two
test binaries under `CHAPEL_TRANSPORT_TEST`; an `nm` gate rejects those symbols
from every production and runtime-bound binary.

The language-local stopped-reader fixture proves the writer deadline is what
interrupts blocked input using exactly one near-2 MiB valid response, so adapter
queue overflow cannot be the cause. A second real-adapter regression drives 64
subscriptions through the command loop, stops the Client owner, and joins an
unread output socket under one three-second absolute budget. It requires the
writer failure to propagate as a structured terminal failure and a nonzero
exit, with both owner and writer stopped. The independent
final-image cgroup memory proof remains a remote Docker gate and is not claimed
by source inspection.

## Limitations

The Live implementation is pinned to the unversioned profile identified in
`manifest.yaml`; it is not a compatibility promise. Live authentication,
optimistic updates, tagged Convex values, WebSocket mutations/actions, and
`TransitionChunk` assembly are deferred. No capability is claimed until the
shared local and hosted evidence passes for this exact source.
