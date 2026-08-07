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
