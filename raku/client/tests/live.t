use Test;
use JSON::Fast;
use lib $?FILE.IO.parent.parent.absolute;
use Convex::Errors;
use Convex::Live;

# Deterministic Live coverage.
#
# Every test drives the real owner state machine through a fake socket, so the
# assertions are about Convex protocol behaviour rather than about Cro. The
# fake socket is also how a stalled write, a retired connection, and a paused
# relay consumer become reproducible instead of timing dependent.

plan 33;

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

class TestSocket does Convex::Live::Socket {
    has Supplier $.supplier .= new;
    has Lock $!lock .= new;
    has @!sent;
    has Bool $!retired = False;
    # When set, send-text returns this promise instead of an immediately kept
    # one, which is how a stalled write is simulated.
    has Promise $.write-gate;

    method messages(--> Supply) { $!supplier.Supply }

    method send-text(Str:D $text --> Promise) {
        $!lock.protect({ @!sent.push($text) });
        $!write-gate // Promise.kept(True)
    }

    method close(--> Nil) {
        $!lock.protect({ $!retired = True });
        try $!supplier.done;
        Nil
    }

    method abort(--> Nil) {
        $!lock.protect({ $!retired = True });
        try $!supplier.done;
        Nil
    }

    method retired(--> Bool) { $!lock.protect({ $!retired }) }
    method sent(--> List) { $!lock.protect({ @!sent.List }) }
    method deliver(Str:D $text --> Nil) { $!supplier.emit($text); Nil }
}

# Hands out one prepared socket per connect attempt. `connect` returns a
# Promise, so the owner worker is never blocked while a connection is pending.
class TestFactory does Convex::Live::SocketFactory {
    has Channel $.pending .= new;
    has Lock $!lock .= new;
    has Int $!attempts = 0;

    method connect(Str:D $url, Real:D :$deadline --> Promise) {
        $!lock.protect({ $!attempts++ });
        start { $.pending.receive }
    }

    method attempts(--> Int) { $!lock.protect({ $!attempts }) }
}

sub wait-until(&condition, Real:D $seconds = 5, Str:D $what = 'condition') {
    my $deadline = now + $seconds;
    until condition() {
        die "timed out waiting for $what" if now > $deadline;
        sleep 0.005;
    }
    True
}

sub wait-for-sent(TestSocket:D $socket, Int:D $count, Str:D $what = 'frames') {
    wait-until({ $socket.sent.elems >= $count }, 5, $what);
    $socket.sent
}

# Blocking receive with a deadline so a missing update fails the test instead
# of hanging the whole file.
sub next-update($subscription, Real:D $seconds = 5) {
    my $waiter = start { $subscription.next-update };
    await Promise.anyof($waiter, Promise.in($seconds));
    $waiter.status ~~ Kept or die 'timed out waiting for a Live update';
    $waiter.result
}

sub encoded-timestamp(Int:D $value --> Str) {
    Convex::Live::base64-encode(Blob.new((^8).map({ ($value +> (8 * $_)) +& 0xff })))
}

sub transition(
    Int:D :$base-query-set = 0,
    Int:D :$new-query-set = 1,
    Int:D :$base-timestamp = 0,
    Int:D :$new-timestamp = 1,
    :@modifications
    --> Str
) {
    to-json({
        type => 'Transition',
        startVersion => {
            querySet => $base-query-set,
            identity => 0,
            ts => encoded-timestamp($base-timestamp)
        },
        endVersion => {
            querySet => $new-query-set,
            identity => 0,
            ts => encoded-timestamp($new-timestamp)
        },
        modifications => @modifications
    }, :!pretty)
}

sub query-updated(Int:D $query-id, $value --> Hash) {
    { type => 'QueryUpdated', queryId => $query-id, value => $value, logLines => [] }
}

# --------------------------------------------------------------------------
# Wire encoding
# --------------------------------------------------------------------------

is Convex::Live::base64-encode(Blob.new(0 xx 8)), 'AAAAAAAAAAA=',
    'the zero timestamp encodes exactly as the protocol initial value';
is Convex::Live::timestamp-value('AAAAAAAAAAA='), 0,
    'the protocol initial timestamp decodes to zero';
is Convex::Live::timestamp-value(encoded-timestamp(1)), 1,
    'a one-tick timestamp survives a round trip';
ok Convex::Live::timestamp-value(encoded-timestamp(0x100)) >
   Convex::Live::timestamp-value(encoded-timestamp(0xFF)),
    'little-endian bytes are compared as a number, not as encoded text';
throws-like { Convex::Live::timestamp-value('AAAA') }, X::Convex::Protocol,
    'a timestamp that is not eight bytes is rejected';
throws-like { Convex::Live::timestamp-value('AAAAAAAAAAA') }, X::Convex::Protocol,
    'an unpadded timestamp is rejected even when it decodes to eight bytes';
throws-like { Convex::Live::optional-log-lines(Any) }, X::Convex::Protocol,
    'an explicit null Live logLines is not mistaken for omission';
throws-like { Convex::Live::optional-log-lines(['ok', 42]) }, X::Convex::Protocol,
    'Live logLines never stringify non-string values';

# --------------------------------------------------------------------------
# Connect, Add, and the initial value
# --------------------------------------------------------------------------

my $factory = TestFactory.new;
my $owner = Convex::Live::Owner.new(
    sync-url => 'ws://convex.test/api/sync',
    socket-factory => $factory
);
my $socket = TestSocket.new;
$factory.pending.send($socket);

my $subscription = $owner.subscribe('demo:state', { room => 'alpha' });
my @frames = wait-for-sent($socket, 2, 'Connect and Add');
my %connect = from-json(@frames[0]);
is %connect<type>, 'Connect', 'the first frame is the pinned profile Connect';
is %connect<connectionCount>, 0, 'the first connection reports count zero';
is %connect<lastCloseReason>, 'InitialConnect', 'the first connection reports InitialConnect';
ok %connect<sessionId>.chars > 0, 'the Connect frame carries a session id';

my %add = from-json(@frames[1]);
is %add<type>, 'ModifyQuerySet', 'the query set is modified after Connect';
is %add<baseVersion>, 0, 'the first Add starts from base version zero';
is %add<newVersion>, 1, 'the first Add moves to version one';
is %add<modifications>[0]<udfPath>, 'demo:state', 'the Add carries the function path';
is-deeply %add<modifications>[0]<args>, [ { room => 'alpha' }, ],
    'the pinned profile carries one positional argument object';

$socket.deliver(transition(modifications => [ query-updated(0, { count => 0 }), ]));
my $initial = next-update($subscription);
is $initial.value<count>, 0, 'the initial QueryUpdated is delivered to the subscriber';
is $owner.max-observed-timestamp, encoded-timestamp(1),
    'the transition end timestamp becomes the maximum observed timestamp';

$socket.deliver(transition(
    base-query-set => 1,
    new-query-set => 1,
    base-timestamp => 1,
    new-timestamp => 2,
    modifications => [ query-updated(0, { count => 1 }), ]
));
is next-update($subscription).value<count>, 1, 'an external update is delivered';

# --------------------------------------------------------------------------
# A query failure must not strand the subscription
# --------------------------------------------------------------------------

$socket.deliver(transition(
    base-query-set => 1,
    new-query-set => 1,
    base-timestamp => 2,
    new-timestamp => 3,
    modifications => [ {
        type => 'QueryFailed',
        queryId => 0,
        errorMessage => 'room is empty',
        errorData => { code => 'ROOM_EMPTY' },
        logLines => []
    }, ]
));
my $failure = next-update($subscription);
ok $failure.failed, 'QueryFailed is delivered as a structured failure';
is $failure.error-data<code>, 'ROOM_EMPTY',
    'the structured error data survives to the subscriber';

$socket.deliver(transition(
    base-query-set => 1,
    new-query-set => 1,
    base-timestamp => 3,
    new-timestamp => 4,
    modifications => [ query-updated(0, { count => 2 }), ]
));
is next-update($subscription).value<count>, 2,
    'the same subscription recovers with a later valid value';

# --------------------------------------------------------------------------
# A protocol violation abandons the connection and reconnects
# --------------------------------------------------------------------------

my $second-socket = TestSocket.new;
$factory.pending.send($second-socket);
# The start version no longer matches what the client has applied.
$socket.deliver(transition(
    base-query-set => 0,
    new-query-set => 1,
    base-timestamp => 0,
    new-timestamp => 5,
    modifications => [ query-updated(0, { count => 3 }), ]
));
my $protocol-failure = next-update($subscription);
ok $protocol-failure.failed, 'a mismatched Transition start version is reported';
is $protocol-failure.error-kind, 'ProtocolError',
    'the failure is classified as a protocol error, not a value';
# fail-connection publishes the failure to subscribers before retiring the
# socket, and next-update returns as soon as the publish lands, so the worker
# may not have reached `$socket.abort` yet. Poll with the same wait-until
# helper the reconnect-replay assertions below already rely on, rather than
# asserting a fixed ordering between two different threads.
ok wait-until({ $socket.retired }, 5, 'the offending connection to be abandoned'),
    'the offending connection is abandoned rather than resynchronised';

my @replay = wait-for-sent($second-socket, 2, 'reconnect Connect and Add replay');
my %replay-add = from-json(@replay[1]);
is %replay-add<modifications>[0]<type>, 'Add',
    'the reconnect replays the active Add operations';
ok from-json(@replay[0])<lastCloseReason>.chars > 0,
    'the reconnect reports why the previous connection ended';

# The reconnected connection resends the current value. Because the last
# delivered value differs, it is published rather than suppressed.
$second-socket.deliver(transition(modifications => [ query-updated(0, { count => 9 }), ]));
is next-update($subscription).value<count>, 9,
    'a subscription still delivers values after a protocol reconnect';

# --------------------------------------------------------------------------
# Unsubscribe invalidates the relay before it is acknowledged
# --------------------------------------------------------------------------

$owner.unsubscribe($subscription);
nok $subscription.active, 'unsubscribe invalidates the relay before returning';
my $after-remove = $subscription.next-update;
nok $after-remove.defined, 'a removed subscription yields no further update';

my @remove-frames = $second-socket.sent;
my %remove = from-json(@remove-frames[*-1]);
is %remove<modifications>[0]<type>, 'Remove', 'the owner sends Remove for the retired query';

$owner.close;
ok $owner.finished, 'the owner worker stops after close';
