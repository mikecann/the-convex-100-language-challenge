use Test;
use JSON::Fast;
use lib $?FILE.IO.parent.parent.parent.absolute;
use Convex::Errors;
use Convex::Live;
use Convex::Adapter;

# Adapter protocol coverage.
#
# The shared controller validates every emitted event against
# `_shared/schemas/adapter.schema.json`, so the shapes below are asserted
# locally first: a serialized success, a structured HTTP error, a subscription
# value, a subscription error, and a clean close. Getting a shape wrong here is
# much cheaper to find than in a shared conformance run.

plan 27;

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

class TestResult {
    has $.value;
    has @.logs;
}

class TestClient {
    has Str $.auth = '';
    has Bool $.closed is rw = False;

    method query(Str $path, %args) {
        if $path eq 'demo:fail' {
            die X::Convex::Function.new(
                message-text => 'Intentional conformance failure',
                operation => 'query',
                data => { code => 'RAKU_EXPECTED' },
                logs => ['log line']
            );
        }
        if $path eq 'demo:unreachable' {
            die X::Convex::Transport.new(detail => 'connection refused', operation => 'http');
        }
        TestResult.new(value => { room => %args<room>, count => 0 }, logs => ['[LOG] demo:state'])
    }

    method mutation(Str $path, %args) { TestResult.new(value => { applied => True }) }
    method action(Str $path, %args) { TestResult.new(value => { message => 'hello' }) }
    method set-auth(Str $token) { $!auth = $token }
    method close() { $!closed = True }
}

# A stand-in owner that hands out real relays, so the adapter's pump, its
# invalidation rules, and its event shapes are exercised for real.
class TestOwner {
    has Convex::Live::Budget $.budget = Convex::Live::Budget.new;
    has %.live;
    has Int $!next-id = 0;
    has Bool $.closed is rw = False;
    has Bool $.disconnected is rw = False;

    method subscribe(Str $path, %args) {
        my $subscription = Convex::Live::Subscription.new(
            query-id => $!next-id++,
            path => $path,
            args => %args,
            relay => Convex::Live::Relay.new(budget => $!budget)
        );
        %!live{$subscription.query-id} = $subscription;
        $subscription
    }

    method unsubscribe($subscription) {
        %!live{$subscription.query-id}:delete;
        $subscription.relay.invalidate;
    }

    method debug-disconnect-for-adapter() { $!disconnected = True }
    method close() { $!closed = True; .relay.invalidate for %!live.values; %!live = () }
}

my @lines;
my $lines-lock = Lock.new;
my $emitter = Convex::Adapter::Emitter.new(
    write-line => -> $line { $lines-lock.protect({ @lines.push($line) }) }
);
my $client = TestClient.new;
my $owner = TestOwner.new;
my $server = Convex::Adapter::Server.new(
    client => $client,
    live-owner => $owner,
    emitter => $emitter
);

sub emitted(--> List) { $lines-lock.protect({ @lines.List }) }

# Events leave through the single writer thread, so a test waits for them
# rather than assuming they are already visible.
sub wait-for-events(Int:D $count, Real:D $seconds = 5 --> List) {
    my $deadline = now + $seconds;
    until emitted().elems >= $count {
        die "timed out waiting for $count events, saw {emitted().elems}" if now > $deadline;
        sleep 0.005;
    }
    emitted()
}

sub event-at(Int:D $index --> Hash) {
    from-json(wait-for-events($index + 1)[$index])
}

# --------------------------------------------------------------------------
# hello
# --------------------------------------------------------------------------

$server.handle-line('{"protocolVersion":1,"id":"hello-1","op":"hello"}');
my %ready = event-at(0);
is %ready<type>, 'ready', 'hello produces a ready event';
is %ready<id>, 'hello-1', 'the ready event echoes the command id';
is %ready<protocolVersion>, 1, 'the ready event reports protocol version 1';
is %ready<language>, 'raku', 'the ready event reports the language id';
ok %ready<implementation>.chars > 0, 'the ready event reports implementation provenance';
ok %ready<runtime>.contains('rakudo'), 'the ready event reports the runtime version';

# --------------------------------------------------------------------------
# Strict command validation
# --------------------------------------------------------------------------

$server.handle-line('{"protocolVersion":1,"id":"hello-2","op":"hello","extra":true}');
my %unexpected = event-at(1);
is %unexpected<error><kind>, 'ProtocolError', 'an unexpected command field is rejected';

$server.handle-line('{"id":42,"op":"query","path":"demo:state","args":{}}');
my %bad-id = event-at(2);
nok %bad-id<id>:exists, 'a command id of the wrong type is never echoed back';

my $long-id = 'x' x 129;
$server.handle-line(to-json({ id => $long-id, op => 'close' }, :!pretty));
my %long = event-at(3);
nok %long<id>:exists, 'an id longer than 128 characters is never echoed back';

$server.handle-line('not json at all');
is event-at(4)<error><kind>, 'ProtocolError', 'a non-JSON command is answered, not fatal';

$server.handle-line(to-json({ id => '   ', op => 'close' }, :!pretty));
nok event-at(5)<id>:exists, 'a whitespace-only command id is never echoed back';

my $astral-id = "\x[1F680]" x 128;
$server.handle-line(to-json({ protocolVersion => 1, id => $astral-id, op => 'hello' }, :!pretty));
is event-at(6)<id>, $astral-id, 'the 128-code-point Unicode id boundary is accepted';

# --------------------------------------------------------------------------
# Calls
# --------------------------------------------------------------------------

$server.handle-line(to-json(
    { id => 'q1', op => 'query', path => 'demo:state', args => { room => 'r1' } },
    :!pretty
));
my %result = event-at(7);
is %result<type>, 'result', 'a query produces a result event';
is %result<value><count>, 0, 'the result carries the decoded value';
is %result<logs>[0], '[LOG] demo:state', 'the result carries the deployment log lines';

$server.handle-line(to-json(
    { id => 'q2', op => 'query', path => 'demo:fail', args => {} },
    :!pretty
));
my %failed = event-at(8);
is %failed<type>, 'error', 'a Convex function rejection produces an error event';
is %failed<error><data><code>, 'RAKU_EXPECTED',
    'the structured error data reaches the controller';

$server.handle-line(to-json(
    { id => 'q3', op => 'query', path => 'demo:unreachable', args => {} },
    :!pretty
));
is event-at(9)<error><kind>, 'TransportError',
    'a transport failure is not flattened into a successful value';

# --------------------------------------------------------------------------
# Subscriptions
# --------------------------------------------------------------------------

$server.handle-line(to-json(
    { id => 's1', op => 'subscribe', subscriptionId => 'sub-a', path => 'demo:state', args => {} },
    :!pretty
));
my %ack = event-at(10);
is %ack<type>, 'ack', 'subscribe is acknowledged';
is %ack<subscriptionId>, 'sub-a', 'the acknowledgement names the subscription';

my $subscription = $owner.live{0};
$subscription.relay.offer(Convex::Live::Update.new(value => { count => 7 }));
my %update = event-at(11);
is %update<type>, 'subscription', 'a relay update becomes a subscription event';
is %update<value><count>, 7, 'the subscription event carries the value';

$subscription.relay.offer(Convex::Live::Update.new(
    kind => 'error',
    error-kind => 'FunctionError',
    error-message => 'room is empty',
    error-data => { code => 'ROOM_EMPTY' }
));
is event-at(12)<error><data><code>, 'ROOM_EMPTY',
    'a subscription failure keeps its structured error data';

$server.handle-line(to-json({
    id => 'u1',
    op => 'unsubscribe',
    subscriptionId => 'sub-a',
    path => 'demo:state',
    args => {}
}, :!pretty));
is event-at(13)<type>, 'ack', 'unsubscribe accepts the shared schema optional fields';
nok $subscription.active, 'the relay is invalidated before the acknowledgement';

# --------------------------------------------------------------------------
# Clean close
# --------------------------------------------------------------------------

$server.handle-line(to-json({ id => 'c1', op => 'close' }, :!pretty));
is event-at(14)<type>, 'closed', 'close produces exactly one closed event';
$server.handle-line(to-json({ id => 'c2', op => 'close' }, :!pretty));
is emitted().elems, 15, 'a repeated close does not emit a second closed event';

$emitter.shutdown;
