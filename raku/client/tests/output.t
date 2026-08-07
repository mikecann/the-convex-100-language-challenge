use Test;
use lib $?FILE.IO.parent.parent.absolute;
use Convex::Adapter;

# A real TCP peer that never reads. The emitter must retire the socket after
# one cumulative write deadline, release its accounting, and let shutdown
# finish even though the kernel send buffer is full.

plan 5;

my $listener = IO::Socket::INET.new(
    localhost => '127.0.0.1',
    localport => 0,
    listen => True
);
my $client = IO::Socket::INET.new(
    host => '127.0.0.1',
    port => $listener.localport
);
my $server = $listener.accept;
$listener.close;

my $aborted = False;
my $abort-lock = Lock.new;
my $emitter = Convex::Adapter::Emitter.new(
    write-line => -> $line {
        # IO::Socket::INET.print is a blocking, unbuffered syscall -- it has
        # no .flush method. Calling one that does not exist here used to
        # throw as soon as the first (small) write returned, which broke the
        # write Promise almost instantly instead of letting it genuinely
        # block on a full kernel send buffer the way this test intends.
        $server.print("$line\n");
    },
    abort-io => -> {
        $abort-lock.protect({ $aborted = True });
        # Closing $server from this callback while the orphaned write-line
        # thread above is still blocked inside .print() on the same socket
        # can deadlock in this Rakudo/MoarVM version, so the close is fired
        # in the background rather than awaited -- matching the production
        # fix in client/tests/conformance/adapter.raku's serve-tcp.
        start { try $server.close };
    }
);

my $payload = 'x' x 1_900_000;
for ^4 -> $sequence {
    $emitter.emit({ type => 'subscription', subscriptionId => 'stopped', value => {
        sequence => $sequence,
        payload => $payload
    }});
}

my $deadline = now + 3;
until $emitter.stalled || now > $deadline { sleep 0.01 }
ok $emitter.stalled, 'stopped TCP reader trips the cumulative write deadline';
ok $abort-lock.protect({ $aborted }), 'deadline retires the blocked socket';

my $shutdown-start = now;
ok $emitter.shutdown(deadline => 2), 'ordered writer task finishes after socket retirement';
ok now - $shutdown-start < 2.5, 'stopped-reader shutdown has a hard upper bound';
is-deeply $emitter.queued, (0, 0), 'all queued event count and byte reservations are released';

try $client.close;
