# Convex from Raku

This is a small Raku program that talks to a Convex deployment over HTTP and
then watches the same query change in real time through the pinned Live sync
profile. The counter example makes the whole journey visible: read 0, subscribe,
mutate to 1, watch the update arrive, and verify that both surfaces agree.

It is educational and unofficial. It is not a production SDK, and it is not a
sanctioned Convex client library.

## Start here

Read [the canonical basic example](examples/basics/main.raku). It is the exact
source shown below, the exact source the Docker example image runs, and the
exact source the website displays. Its comments explain the Convex decisions --
why the subscription starts before the mutation, why the mutation carries a run
id, why a Live value has a deadline -- rather than explaining Raku syntax.

The client itself lives under [`client/`](client): `Convex.rakumod` is the HTTP
client, `Convex/Live.rakumod` is the reactive query owner, and the `Cro*`
modules are the thin transport boundary where an ordinary HTTP/TLS/WebSocket
library does its ordinary work.

## What works

| Area | Current status |
| --- | --- |
| Builds in Docker | `./run test raku` passes |
| HTTP query, mutation, action, and auth | Implemented; language-local tests pass |
| Realtime query (Live) | Implemented against the pinned experimental sync profile; language-local tests pass |
| Docker images and language-local tests | Built and run; all eight suites pass inside the `test` image |
| Capability badges | None. Only shared local and hosted conformance may award them, and that has not run yet. |

`./run test raku` passes: the rakudo-star toolchain assertions, the compile
checks, all eight language-local suites, and the runtime/example image policy
probes all run green inside Docker. `./run verify-example raku`, `./run verify
raku`, and `./run verify-hosted raku` against a real deployment have not run
yet, so no capability is claimed.

## Canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.raku -->
```raku
#!/usr/bin/env raku

use lib $?FILE.IO.parent.parent.parent.add('client').absolute;
use Convex;
use Convex::Values;
use Convex::Live;
use Convex::CroTransport;
use Convex::CroLive;

# The HTTP client and the Live owner are separate objects: the owner is the one
# thing that touches the WebSocket, and this program only ever asks it for the
# next value.
my $client;
my $live;

sub release(--> Nil) {
    # Both surfaces are closed on every exit path, including a failure, so the
    # deployment never keeps a subscription open for a program that has stopped.
    try { $live.close if $live.defined }
    try { $client.close if $client.defined }
    Nil
}

sub fail(Str:D $message --> Nil) {
    # Stdout is a universal conformance surface, so failures belong on stderr.
    note $message;
    release();
    exit 1;
}

sub count-from-state($value, Str:D $where --> Int) {
    # Decode only the shape this introduction needs. Convex may encode the
    # count as 0 or as 0.0, so integral-int accepts a mathematically integral
    # number and rejects quoted, fractional, non-finite, or out-of-range data
    # instead of quietly rounding a broken response.
    # The parens around the :exists check matter: without them, Raku parses
    # the adverb as trying to modify the whole && expression rather than the
    # <count> lookup ("You can't adverb &infix:<&&>").
    $value ~~ Hash && ($value<count>:exists)
        or fail("$where result omitted count");
    my $count;
    try {
        $count = integral-int($value<count>, $where);
        CATCH { default { fail(.message) } }
    }
    $count
}

sub next-live-value($subscription, Str:D $where --> Int) {
    # A Live value that never arrives has to end the run. Waiting forever would
    # turn a broken subscription into a hung container rather than a failure.
    my $waiter = start { $subscription.next-update };
    await Promise.anyof($waiter, Promise.in(30));
    $waiter.status ~~ Kept or fail("$where did not arrive within 30 seconds");
    my $update = $waiter.result;
    $update.defined or fail("$where ended before a value arrived");
    # A query that fails on the deployment is reported as a failed update
    # rather than as a value, so the example stops instead of printing a guess.
    $update.failed and fail("$where failed: {$update.error-message}");
    count-from-state($update.value, $where)
}

sub run-id(--> Str) {
    # A fresh key lets the deployment recognise this exact mutation run, so a
    # retry cannot increment the same room twice.
    DateTime.now.posix.base(36) ~ '-' ~ (2 ** 32).rand.Int.base(36)
}

my $url = %*ENV<CONVEX_URL> // fail('CONVEX_URL is required');
my $deployment-url;
try {
    $deployment-url = normalize-deployment-url($url);
    CATCH { default { fail(.message) } }
}
# The verifier passes a unique room as the first argument; the default only
# exists so the image is pleasant to run by hand.
my $room = @*ARGS[0] // %*ENV<EXAMPLE_ROOM> // 'raku-example';

# Create the HTTP client using the deployment URL supplied by the verifier.
$client = Convex::Client.new(
    deployment-url => $deployment-url,
    transport => Convex::CroTransport::CroHTTP.new
);

# The Live owner connects lazily, on the first subscription, over ws:// or
# wss:// depending on the deployment URL.
$live = Convex::Live::Owner.new(
    sync-url => $deployment-url.subst(/^ 'http'/, 'ws') ~ '/api/sync',
    socket-factory => Convex::CroLive::Factory.new
);

# Start with an HTTP query to establish the room's current state.
my $before = count-from-state($client.query('demo:state', { room => $room }).value, 'current query');
say "current count: $before";

# Subscribe before mutating, so the update caused by the mutation cannot be
# missed between the two calls.
my $subscription = $client.subscribe('demo:state', { room => $room }, live-owner => $live);
my $initial = next-live-value($subscription, 'initial Live value');
$initial == $before or fail("initial Live count was $initial, expected $before");
say "live initial count: $initial";

# Mutate the room over HTTP with a fresh idempotency key, then check the
# mutation's own answer before trusting the Live update.
my $mutation = $client.mutation('demo:increment', {
    room => $room,
    language => 'Raku',
    runId => run-id()
});
$mutation.value ~~ Hash && $mutation.value<applied> === True
    or fail('increment mutation was not applied');
my $mutated = count-from-state($mutation.value<state>, 'mutation');
$mutated == $before + 1 or fail("mutation count was $mutated, expected {$before + 1}");
say 'mutation applied: true';
say "mutation count: $mutated";

# The next Live value must be exactly the mutation's state, not merely some
# later update.
my $after = next-live-value($subscription, 'updated Live value');
$after == $mutated or fail("updated Live count was $after, expected $mutated");
say "live updated count: $after";

# This final line is printed only once HTTP and Live agree on the 0 to 1 path.
say "verified count: $before -> $after";
release();
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

    ./run test raku
    ./run verify-example raku
    ./run verify raku
    ./run verify-hosted raku

`test` installs the pinned dependencies, compiles every module and both
executables, runs the language-local suites, and probes the adapter over stdin
and stdout, all inside Docker. `verify-example` runs the exact example above in
its minimal image against a unique counter room and compares its six stdout
lines with the shared expected transcript. The last two commands add shared
black-box adapter conformance against the local backend and the hosted drift
target.

None of these have been run for this checkpoint. See `manifest.yaml` for the
exact list of what the first Docker pass has to confirm.

## Conformance and protocol notes

The test-only executable under `client/tests/conformance/` speaks strict ordered
NDJSON v1. It works over stdin and stdout, and over the single TCP connection
the shared controller makes when `ADAPTER_LISTEN` is set. Both readers consume
fixed-size byte chunks, reject invalid UTF-8, and discard an unterminated
command once it crosses the byte limit, so malformed input cannot grow the
process without bound. Every command is validated for exact field set, field
types, and a Unicode code point length of at most 128 for ids, before any client
call happens. An invalid id is never echoed back, because the shared schema
would reject the reply.

Events leave through exactly one writer thread with a bounded backlog measured
in both events and bytes. A controller that stops reading is refused, not
buffered, because dropping a protocol event would silently desynchronise the
conversation.

Live is deliberately narrow and pinned. One owner worker holds the socket, the
query set version, the reconnect schedule, and every read and write; callers
post commands to it and wait with an absolute deadline, so `close` and
`unsubscribe` stay bounded when the peer is idle, flooding, or stalled. The
owner:

- sends `Connect`, then `ModifyQuerySet`, and replays the active `Add`
  operations in a stable order after every reconnect;
- validates that each `Transition` starts from the version the client actually
  applied, and commits a transition fully before notifying any subscriber;
- compares the protocol's base64 little-endian timestamps as numbers, so
  ordering does not depend on how they happen to encode;
- suppresses an unchanged rehydration after a reconnect, which is what makes
  the `debugDisconnect` sequence exactly initial value, acknowledgement,
  external mutation, then the new value;
- resets its exponential backoff after a successful handshake or a valid
  transition, so a healthy connection does not inherit an old maximum delay;
- invalidates a relay before it acknowledges an unsubscribe or a same-id
  replacement, holding the same lock a delivery holds, which is why an already
  dequeued update cannot cross the acknowledgement;
- reports `FunctionError`, `ProtocolError`, and `TransportError` to subscribers
  without unregistering them, so the same subscription can prove recovery with
  a later valid value.

`debugDisconnect` is adapter-only. It is declared in `manifest.yaml` under
`adapter.adapterOnlyCommands` and has no equivalent in the client API.

Buffering is a decision, not an accident. Each subscription has its own bounded
queue, and all of an owner's queues share a process-wide count and byte budget,
because a count limit alone is not a memory limit when one protocol value can
approach the maximum message size. An overflowing subscription queue drops its
oldest pending value: a reactive query represents current state, so the newest
value is the one worth keeping. `client/tests/buffering.t` asserts the depth
bound, the byte bound, the drop count, and that no reservation leaks.

## Limitations

- `./run test raku` passes in Docker; shared conformance (`verify`,
  `verify-hosted`) has not run against a real deployment, so no capability is
  claimed yet.
- Closing a raw `IO::Socket::INET` from one thread while another thread is
  blocked inside `.accept()` or `.write()` on that same socket does not
  reliably unblock the pending call in this Rakudo/MoarVM version -- the two
  calls can deadlock against each other. This affects the production
  adapter's own TCP mode (used when `ADAPTER_LISTEN` is set) when a stalled
  controller triggers `abort-io`: the close is fired in a background thread
  rather than awaited synchronously, so a stuck close cannot wedge the
  emitter's writer loop that detected the stall in the first place.
- The Live profile is the explicitly pinned unversioned `/api/sync` profile
  recorded in `manifest.yaml`. It is not an official or stable public Convex
  protocol.
- Live authentication, WebSocket mutations and actions, optimistic updates, and
  `TransitionChunk` assembly are not implemented. A `TransitionChunk` is
  reported as a protocol error rather than being guessed at.
- RFC 6455 masking, fragment reassembly, and control-frame mechanics are
  delegated to Cro, which is ordinary transport work. A Raku-owned gate checks
  canonical frame lengths, masking direction, opcodes, control rules, a 2 MiB
  frame cap, and one absolute partial-frame deadline before Cro sees a frame.
  Fragment payloads are then counted incrementally under a total message cap,
  and no more than four complete messages may wait for the Live reader. These
  rules have raw-peer fixture source but still need their first Docker run. Cro
  parses HTTP response headers before the Raku header budget can inspect them,
  so a pre-parse hostile-header memory bound remains runtime-library dependent.
- The client accepts the JSON-safe value subset the counter demonstration
  exercises. Convex's extended value encodings are not decoded.
- The Raku runtime is present in both final images because it is the
  interpreter that executes this client, in the same sense that `ruby` is for a
  Ruby client. No package manager and no other language runtime ships: the
  Dockerfile removes `zef`, `apt`, `dpkg`, and `perl`, then probes for each of
  them along with every C toolchain command. Rakudo is, however, both the
  runtime and the compiler for Raku, so a command that compiles Raku source
  cannot be removed from an image that has to run Raku. Whether that satisfies
  the shared "no compiler frontend" rule is a policy question for the root
  reviewer; this branch does not decide it.
- The example block above is fenced as `text` because the shared README
  projector has no mapping for the `.raku` extension yet. Raku highlighting on
  the website and in this README needs a separate shared-infrastructure change
  to `_shared/harness/scripts/example-readme.mjs` and
  `_shared/harness/scripts/generate-site.mjs`; it must not be worked around
  inside this language directory.
