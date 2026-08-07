use Test;
use JSON::Fast;
use Base64;
use Crypt::Random;
use Digest::SHA1::Native;
use lib $?FILE.IO.parent.parent.absolute;
use Convex::CroLive;
use Convex::Errors;
use Convex::Live;

# Raw RFC 6455 peers for the production handshake, strict frame gate, Cro
# framing machinery, and Convex owner. No WebSocket server library is used, so
# a permissive framework cannot normalize the deliberately bad wire bytes.

sub recv-exact(IO::Socket::INET:D $socket, Int:D $wanted --> Blob) {
    my $buffer = Buf.new;
    while $buffer.bytes < $wanted {
        my $part = $socket.recv($wanted - $buffer.bytes, :bin);
        last unless $part.defined && $part.bytes;
        $buffer.append($part);
    }
    $buffer.bytes == $wanted or die "peer closed with {$buffer.bytes}/$wanted bytes";
    Blob.new($buffer)
}

sub send-frame(
    IO::Socket::INET:D $socket,
    Blob:D $payload,
    Int:D :$opcode = 1,
    Bool:D :$fin = True,
    Str:D :$length-form = 'canonical'
    --> Nil
) {
    my @header = ($fin ?? 0x80 !! 0) +| $opcode;
    if $length-form eq '16' {
        @header.append(126, ($payload.bytes +> 8) +& 0xff, $payload.bytes +& 0xff);
    }
    elsif $length-form eq '64' {
        @header.push(127);
        @header.append(0, 0, 0, 0, 0, 0, 0, $payload.bytes);
    }
    elsif $payload.bytes < 126 {
        @header.push($payload.bytes);
    }
    elsif $payload.bytes <= 65535 {
        @header.append(126, ($payload.bytes +> 8) +& 0xff, $payload.bytes +& 0xff);
    }
    else {
        @header.push(127);
        @header.append((^8).reverse.map({ ($payload.bytes +> (8 * $_)) +& 0xff }));
    }
    # IO::Socket::INET.write is a blocking, unbuffered syscall in Rakudo -- it
    # has no .flush method to pair it with (unlike Cro's async socket API,
    # which the client itself uses and which does buffer).
    $socket.write(Blob.new(|@header, |$payload));
    Nil
}

class Peer {
    has IO::Socket::INET $.socket is required;

    method send-text(Str:D $text --> Nil) {
        send-frame($!socket, $text.encode('utf8'))
    }

    method send-fragmented(Str:D $left, Str:D $right --> Nil) {
        send-frame($!socket, $left.encode('utf8'), fin => False);
        send-frame($!socket, 'p'.encode('utf8'), opcode => 9);
        send-frame($!socket, $right.encode('utf8'), opcode => 0);
        Nil
    }

    method read-text(Real:D $deadline = 5 --> Str) {
        my $reader = start {
            my $result;
            loop {
                my $head = recv-exact($!socket, 2);
                my $opcode = $head[0] +& 0x0f;
                my $length = $head[1] +& 0x7f;
                $length = recv-exact($!socket, 2).read-uint16(0, BigEndian)
                    if $length == 126;
                $length = recv-exact($!socket, 8).read-uint64(0, BigEndian)
                    if $length == 127;
                my $masked = so ($head[1] +& 0x80);
                my $mask = $masked ?? recv-exact($!socket, 4) !! Blob.new;
                my $payload = recv-exact($!socket, $length);
                if $masked {
                    $payload = Blob.new((^$length).map({ $payload[$_] +^ $mask[$_ % 4] }));
                }
                if $opcode == 1 {
                    $result = $payload.decode('utf8');
                    last;
                }
                if $opcode == 8 {
                    $result = '';
                    last;
                }
                # Pong and other control traffic is not a Convex message.
            }
            $result
        };
        await Promise.anyof($reader, Promise.in($deadline));
        $reader.status ~~ Kept or die 'timed out reading client WebSocket frame';
        $reader.result
    }

    method close(--> Nil) { try $!socket.close; Nil }
}

class RawServer {
    has Int $.status = 101;
    has Str $.upgrade = 'WebSocket';
    has Str $.connection = 'keep-alive, Upgrade';
    has Bool $.bad-accept = False;
    has IO::Socket::INET $!listener;
    has Channel $!peers .= new;
    has Bool $!closed = False;
    has $!acceptor;

    submethod TWEAK() {
        $!listener = IO::Socket::INET.new(
            localhost => '127.0.0.1',
            localport => 0,
            listen => True
        );
        $!acceptor = start {
            until $!closed {
                my $socket = try $!listener.accept;
                last unless $socket.defined;
                # `close` connects to this listener to unblock a pending
                # accept; that connection is not a real handshake attempt, so
                # do not try to read one from it.
                if $!closed {
                    try $socket.close;
                    last;
                }
                try {
                    my $request = '';
                    until $request.contains("\r\n\r\n") {
                        my $part = $socket.recv(4096);
                        die 'upgrade request ended early' unless $part.defined && $part.chars;
                        $request ~= $part;
                    }
                    my $key = '';
                    for $request.lines -> $line {
                        $key = $0.trim if $line ~~ /:i ^ 'Sec-WebSocket-Key:' (.*) $/;
                    }
                    my $accept = $!bad-accept
                        ?? 'definitely-wrong'
                        !! encode-base64(
                            sha1($key ~ '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'),
                            :str
                        );
                    if $!status == 101 {
                        $socket.print(
                            "HTTP/1.1 101 Switching Protocols\r\n"
                            ~ "Upgrade: $!upgrade\r\n"
                            ~ "Connection: $!connection\r\n"
                            ~ "Sec-WebSocket-Accept: $accept\r\n\r\n"
                        );
                    }
                    else {
                        $socket.print(
                            "HTTP/1.1 $!status Refused\r\n"
                            ~ "Content-Length: 0\r\nConnection: close\r\n\r\n"
                        );
                    }
                    $!peers.send(Peer.new(:$socket));
                    CATCH {
                        default {
                            try $socket.close;
                            note "raw WebSocket handshake failed: {.message}";
                        }
                    }
                }
            }
        };
    }

    method url(--> Str) { "ws://127.0.0.1:{$!listener.localport}/api/sync" }
    method next-peer(Real:D $deadline = 5 --> Peer) {
        my $waiter = start { $!peers.receive };
        await Promise.anyof($waiter, Promise.in($deadline));
        $waiter.status ~~ Kept or die 'timed out waiting for raw WebSocket peer';
        $waiter.result
    }
    method close(--> Nil) {
        $!closed = True;
        # The acceptor thread above is parked in a blocking `.accept()` call.
        # Closing the listener from this thread while that call is still
        # blocked does not reliably unblock it in this Rakudo/MoarVM version
        # -- the close and the pending accept can deadlock against each
        # other. Connecting to our own listener first forces `.accept()` to
        # return, so the acceptor loop observes `$!closed` and exits on its
        # own before the listener is actually torn down.
        try {
            my $unblock = IO::Socket::INET.new(host => '127.0.0.1', port => $!listener.localport);
            $unblock.close;
        }
        try $!listener.close;
        Nil
    }
}

sub await-result(Promise:D $promise, Real:D $deadline = 5) {
    await Promise.anyof($promise, Promise.in($deadline));
    $promise.status ~~ Planned and die 'promise exceeded fixture deadline';
    $promise
}

sub socket-message($socket) {
    my $answer = Promise.new;
    my $vow = $answer.vow;
    my $tap = $socket.messages.tap(
        -> $text { try $vow.keep($text) },
        done => { try $vow.break('socket ended') },
        quit => -> $error { try $vow.break($error) }
    );
    # `$tap` is captured by both callbacks so it remains alive until the first
    # terminal value, then retires itself.
    $answer.then({ try $tap.close });
    $answer
}

# Correct accept plus case-insensitive comma-token response headers.
my $fragment-server = RawServer.new;
my $fragment-connect = Convex::CroLive::Factory.new.connect(
    $fragment-server.url,
    deadline => 2
);
my $fragment-peer = $fragment-server.next-peer;
my $fragment-socket = await-result($fragment-connect).result;
my $fragment-result = socket-message($fragment-socket);
$fragment-peer.send-fragmented('hel', 'lo');
is await-result($fragment-result).result, 'hello',
    'fragmented text survives an interleaved Ping control frame';
$fragment-socket.close;
$fragment-peer.close;
$fragment-server.close;

my $bad-accept-server = RawServer.new(bad-accept => True);
my $bad-accept = Convex::CroLive::Factory.new.connect($bad-accept-server.url, deadline => 2);
$bad-accept-server.next-peer;
await-result($bad-accept);
ok $bad-accept.status ~~ Broken, 'wrong Sec-WebSocket-Accept rejects the upgrade';
$bad-accept-server.close;

my $bad-token-server = RawServer.new(connection => 'keep-alive');
my $bad-token = Convex::CroLive::Factory.new.connect($bad-token-server.url, deadline => 2);
$bad-token-server.next-peer;
await-result($bad-token);
ok $bad-token.status ~~ Broken, 'missing Connection Upgrade token rejects the upgrade';
$bad-token-server.close;

my $bad-upgrade-server = RawServer.new(upgrade => 'h2c');
my $bad-upgrade = Convex::CroLive::Factory.new.connect($bad-upgrade-server.url, deadline => 2);
$bad-upgrade-server.next-peer;
await-result($bad-upgrade);
ok $bad-upgrade.status ~~ Broken, 'missing Upgrade websocket token rejects the upgrade';
$bad-upgrade-server.close;

my $bad-status-server = RawServer.new(status => 200);
my $bad-status = Convex::CroLive::Factory.new.connect($bad-status-server.url, deadline => 2);
$bad-status-server.next-peer;
await-result($bad-status);
ok $bad-status.status ~~ Broken, 'HTTP status other than 101 rejects the upgrade';
$bad-status-server.close;

# The strict frame gate rejects a short payload encoded through the 16-bit
# form, which Cro 0.8.9 itself accepts.
my $canonical-server = RawServer.new;
my $canonical-connect = Convex::CroLive::Factory.new.connect($canonical-server.url, deadline => 2);
my $canonical-peer = $canonical-server.next-peer;
my $canonical-socket = await-result($canonical-connect).result;
my $canonical-result = socket-message($canonical-socket);
send-frame($canonical-peer.socket, 'x'.encode('utf8'), length-form => '16');
await-result($canonical-result);
ok $canonical-result.status ~~ Broken, 'non-canonical 16-bit frame length is rejected';
$canonical-peer.close;
$canonical-server.close;

my $canonical64-server = RawServer.new;
my $canonical64-connect = Convex::CroLive::Factory.new.connect($canonical64-server.url, deadline => 2);
my $canonical64-peer = $canonical64-server.next-peer;
my $canonical64-socket = await-result($canonical64-connect).result;
my $canonical64-result = socket-message($canonical64-socket);
send-frame($canonical64-peer.socket, 'x'.encode('utf8'), length-form => '64');
await-result($canonical64-result);
ok $canonical64-result.status ~~ Broken, 'non-canonical 64-bit frame length is rejected';
$canonical64-peer.close;
$canonical64-server.close;

# An incomplete declared frame gets one absolute deadline, even if bytes have
# already arrived and the TCP connection itself remains open.
my $partial-server = RawServer.new;
my $partial-connect = Convex::CroLive::Factory.new.connect($partial-server.url, deadline => 2);
my $partial-peer = $partial-server.next-peer;
my $partial-socket = await-result($partial-connect).result;
my $partial-result = socket-message($partial-socket);
$partial-peer.socket.write(Blob.new(0x81, 126, 0, 128, 0x7b));
await-result($partial-result, 7);
ok $partial-result.status ~~ Broken, 'partial frame is abandoned on its absolute deadline';
$partial-peer.close;
$partial-server.close;

sub ts(Int:D $value --> Str) {
    Convex::Live::base64-encode(
        Blob.new((^8).map({ ($value +> (8 * $_)) +& 0xff }))
    )
}

sub transition(Int:D $value, Int:D :$start = 0, Int:D :$end = 1 --> Str) {
    to-json({
        type => 'Transition',
        startVersion => { querySet => ($start ?? 1 !! 0), identity => 0, ts => ts($start) },
        endVersion => { querySet => 1, identity => 0, ts => ts($end) },
        modifications => [ { type => 'QueryUpdated', queryId => 0, value => { count => $value }, logLines => [] }, ]
    }, :!pretty)
}

sub next-update($subscription, Real:D $deadline = 5) {
    my $waiter = start { $subscription.next-update };
    await Promise.anyof($waiter, Promise.in($deadline));
    $waiter.status ~~ Kept or die 'timed out waiting for subscription update';
    $waiter.result
}

# Five genuine TCP reconnects. Every new connection must carry Connect then
# replay the same Add. Unchanged hydration must not publish an extra value.
my $owner-server = RawServer.new;
my $owner = Convex::Live::Owner.new(
    sync-url => $owner-server.url,
    socket-factory => Convex::CroLive::Factory.new
);
my $subscription = $owner.subscribe('demo:state', { room => 'raw-five' });
my $peer = $owner-server.next-peer;
is from-json($peer.read-text)<type>, 'Connect', 'owner sends Connect on the first TCP session';
is from-json($peer.read-text)<modifications>[0]<type>, 'Add', 'owner sends the initial Add';
$peer.send-text(transition(0));
is next-update($subscription).value<count>, 0, 'raw peer delivers the initial value';

for 1..5 -> $cycle {
    $owner.debug-disconnect-for-adapter;
    $peer = $owner-server.next-peer;
    my %connect = from-json($peer.read-text);
    my %add = from-json($peer.read-text);
    is %connect<connectionCount>, $cycle, "reconnect $cycle carries the exact connection count";
    is %add<modifications>[0]<type>, 'Add', "reconnect $cycle replays Add";
    $peer.send-text(transition(0));
    sleep 0.05;
    is $subscription.relay.queued, 0, "reconnect $cycle suppresses unchanged hydration";
}

$peer.send-text(transition(1, start => 1, end => 2));
is next-update($subscription).value<count>, 1, 'same subscription receives an external update after five reconnects';

$peer.send-text(to-json({
    type => 'Transition',
    startVersion => { querySet => 1, identity => 0, ts => ts(2) },
    endVersion => { querySet => 1, identity => 0, ts => ts(3) },
    modifications => [ {
        type => 'QueryFailed',
        queryId => 0,
        errorMessage => 'raw failure',
        errorData => { code => 'RAW_FAIL' },
        logLines => ['raw log']
    }, ]
}, :!pretty));
my $failed = next-update($subscription);
ok $failed.failed, 'raw QueryFailed is delivered without retiring the subscription';
is $failed.error-data<code>, 'RAW_FAIL', 'raw QueryFailed preserves error data';
is $failed.logs[0], 'raw log', 'raw QueryFailed preserves logs';

$peer.send-text(transition(2, start => 3, end => 4));
is next-update($subscription).value<count>, 2, 'QueryFailed recovers with a later valid value';

$owner.unsubscribe($subscription);
is from-json($peer.read-text)<modifications>[0]<type>, 'Remove', 'unsubscribe sends Remove before returning';
nok $subscription.active, 'the old relay is revoked before unsubscribe acknowledgement';
$peer.send-text(transition(99, start => 4, end => 5));
sleep 0.05;
is $subscription.relay.queued, 0, 'a late raw update cannot enter the revoked relay';

my $close-start = now;
$owner.close;
ok now - $close-start < 6, 'owner close is bounded against an idle raw peer';
$peer.close;
$owner-server.close;

done-testing;
