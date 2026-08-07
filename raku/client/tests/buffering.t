use Test;
use lib $?FILE.IO.parent.parent.absolute;
use Convex::Errors;
use Convex::Live;
use Convex::Adapter;

# Buffering is a deliberate design decision, so it is tested rather than
# described. Two independent bounds are proved here:
#
#   * a Live relay bounds both the number of queued updates and their bytes,
#     because one protocol value can approach the maximum message size;
#   * the adapter's single writer bounds its own backlog, so a controller that
#     stops reading cannot grow this process.
#
# The invalidation test is deterministic: a relay consumer is paused after it
# has dequeued an update, and the test proves invalidation cannot complete
# while that consumer holds the update, which is what stops a stale event from
# crossing an unsubscribe acknowledgement.

plan 14;

sub update(Int:D $count --> Convex::Live::Update) {
    Convex::Live::Update.new(value => { count => $count })
}

# --------------------------------------------------------------------------
# Count bound
# --------------------------------------------------------------------------

my $budget = Convex::Live::Budget.new;
my $relay = Convex::Live::Relay.new(budget => $budget, max-queued => 4);
$relay.offer(update($_)) for ^10;

is $relay.queued, 4, 'the relay never holds more than its depth limit';
is $relay.dropped, 6, 'every dropped update is counted';

my @received;
$relay.deliver-next(-> $item { @received.push($item.value<count>) }) for ^4;
is @received.elems, 4, 'the surviving updates are delivered in order';
is @received[*-1], 9, 'a slow consumer keeps the newest value of a reactive query';

my ($count, $bytes) = $budget.in-use;
is $count, 0, 'the shared count reservation is released after delivery';
is $bytes, 0, 'the shared byte reservation is released after delivery';

# --------------------------------------------------------------------------
# Byte bound
# --------------------------------------------------------------------------

# A budget far smaller than one update proves the byte limit, not the count
# limit, is what rejects the offer.
my $tiny-budget = Convex::Live::Budget.new(max-count => 8, max-bytes => 16);
my $tiny-relay = Convex::Live::Relay.new(budget => $tiny-budget);
nok $tiny-relay.offer(update(1)),
    'an update larger than the shared byte budget is refused';
is $tiny-budget.in-use[1], 0,
    'a refused offer leaks no byte reservation';

# --------------------------------------------------------------------------
# Invalidation cannot be crossed by an in-flight update
# --------------------------------------------------------------------------

my $gate = Promise.new;
my $gate-vow = $gate.vow;
my $handed = Promise.new;
my $handed-vow = $handed.vow;
my @published;

my $paused-relay = Convex::Live::Relay.new(budget => Convex::Live::Budget.new);
$paused-relay.offer(update(1));
$paused-relay.offer(update(2));

my $consumer = start {
    $paused-relay.deliver-next(-> $item {
        @published.push($item.value<count>);
        $handed-vow.keep(True);
        # Hold the update exactly as a paused adapter pump would.
        await $gate;
    });
};
await Promise.anyof($handed, Promise.in(5));
is $handed.status, Kept, 'the consumer dequeued the first update';

my $invalidation = start { $paused-relay.invalidate };
await Promise.anyof($invalidation, Promise.in(0.25));
nok $invalidation.status ~~ Kept,
    'invalidation cannot complete while a dequeued update is still in flight';

$gate-vow.keep(True);
await Promise.anyof($invalidation, Promise.in(5));
await Promise.anyof($consumer, Promise.in(5));
nok $paused-relay.deliver-next(-> $item { @published.push($item.value<count>) }),
    'no further update is published once the relay has been invalidated';
is @published.elems, 1, 'the second queued update never reaches a subscriber';

# --------------------------------------------------------------------------
# The adapter writer bounds its own backlog
# --------------------------------------------------------------------------

my $writer-gate = Promise.new;
my $writer-gate-vow = $writer-gate.vow;
my $emitter = Convex::Adapter::Emitter.new(
    write-line => -> $line { await $writer-gate },
    max-events => 4,
    max-bytes => 1024 * 1024
);

my $accepted = 0;
my $rejected = False;
for ^16 -> $event-number {
    # An explicit loop variable, not the implicit $_: a hash literal passed
    # directly as a call argument that interpolates the *implicit* topic
    # inside a `for` block is misparsed by this Rakudo as a Block rather
    # than a Hash ("expected Associative but got Block"), because a bare
    # `{...}` referencing $_ looks like another topicalized block to the
    # grammar. An explicit variable sidesteps the ambiguity entirely.
    try {
        $emitter.emit({ id => "event-$event-number", type => 'ack' });
        $accepted++;
        CATCH {
            when X::Convex::Transport { $rejected = True }
        }
    }
    last if $rejected;
}
ok $rejected, 'a controller that stops reading is refused, not buffered without limit';
ok $accepted <= 4, 'no more events than the configured backlog are accepted';

$writer-gate-vow.keep(True);
$emitter.shutdown;
