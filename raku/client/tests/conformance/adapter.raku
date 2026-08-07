#!/usr/bin/env raku

# Test-only conformance executable.
#
# It speaks NDJSON adapter protocol v1 over either stdin/stdout or the single
# TCP connection the shared controller makes when ADAPTER_LISTEN is set. It is
# not public client code: it exists so the shared harness can drive the real
# Raku client, and it is the only place `debugDisconnect` is reachable.
#
# Stdout carries protocol events only. Every diagnostic goes to stderr.

use lib $?FILE.IO.parent.parent.parent.absolute;
use Convex;
use Convex::Adapter;
use Convex::CroTransport;
use Convex::CroLive;
use Convex::Live;

sub deployment-url(--> Str) {
    %*ENV<CONVEX_URL>
        // die 'CONVEX_URL is required by the conformance adapter'
}

# The controller may send a very long line. Both transports refuse to buffer
# more than one maximum-size command, and both report the same protocol error
# rather than growing.
sub line-limit(--> Int) { Convex::Adapter::MAX-NDJSON-LINE-BYTES }

my $url = normalize-deployment-url(deployment-url());
my $client = Convex::Client.new(
    deployment-url => $url,
    transport => Convex::CroTransport::CroHTTP.new,
    bearer-token => (%*ENV<CONVEX_AUTH_TOKEN> // '')
);

# ws:// for http://, wss:// for https://. The owner is the only object that
# ever touches the socket.
my $sync-url = $url.subst(/^ 'http'/, 'ws') ~ '/api/sync';
my $owner = Convex::Live::Owner.new(
    sync-url => $sync-url,
    socket-factory => Convex::CroLive::Factory.new
);

my $exit-code = 0;

sub run-with(&write-line, &read-lines, &abort-io --> Nil) {
    my $emitter = Convex::Adapter::Emitter.new(
        write-line => &write-line,
        abort-io => &abort-io
    );
    my $server = Convex::Adapter::Server.new(
        client => $client,
        live-owner => $owner,
        emitter => $emitter
    );

    read-lines(
        -> $line {
            $server.handle-line($line);
            # The controller closes the stream after its `close` command;
            # stopping here lets the process exit instead of waiting for EOF.
            $server.closed
        },
        -> $detail { $server.reject-input($detail) }
    );

    CATCH {
        default {
            note "raku adapter failed: {.message}";
            $exit-code = 1;
        }
    }

    LEAVE {
        # Drain the single writer before the process exits so the controller
        # never loses the final event.
        $emitter.shutdown or $exit-code = 1;
        $owner.close;
        $client.close;
    }
    Nil
}

# --------------------------------------------------------------------------
# Transports
# --------------------------------------------------------------------------

# Stdin/stdout. Read bytes in fixed chunks so a controller cannot make the
# runtime accumulate an unbounded unterminated line before the engine sees it.
sub read-stdin-lines(&handle, &reject --> Nil) {
    my $buffer = Buf.new;
    my $discarding = False;
    loop {
        my $chunk = $*IN.read(65536);
        last unless $chunk.defined && $chunk.bytes > 0;
        $buffer.append($chunk);
        loop {
            my $index = (^$buffer.bytes).first({ $buffer[$_] == 0x0A });
            unless $index.defined {
                if !$discarding && $buffer.bytes > line-limit() {
                    reject('command exceeds NDJSON byte limit');
                    $discarding = True;
                    $buffer = Buf.new;
                }
                last;
            }
            my $line-bytes = $buffer.subbuf(0, $index);
            $buffer = $buffer.subbuf($index + 1);
            if $discarding {
                $discarding = False;
                next;
            }
            if $line-bytes.bytes > line-limit() {
                reject('command exceeds NDJSON byte limit');
                next;
            }
            my $line;
            try {
                $line = $line-bytes.decode('utf8');
                CATCH { default { $line = Nil } }
            }
            unless $line.defined {
                reject('command is not valid UTF-8');
                next;
            }
            $line = $line.subst(/ \r $ /, '');
            return if handle($line);
        }
    }
    Nil
}

# TCP. The controller connects exactly once. Reading is incremental so an
# unterminated command can never make this process buffer more than the
# protocol limit -- the connection is dropped as soon as the pending line
# exceeds it.
sub serve-tcp(Str:D $address --> Nil) {
    my $separator = $address.rindex(':')
        // die "ADAPTER_LISTEN must be host:port, got '$address'";
    my $host = $address.substr(0, $separator);
    my $port = $address.substr($separator + 1).Int;
    $host = '0.0.0.0' if $host eq '' || $host eq '*';

    my $listener = IO::Socket::INET.new(
        localhost => $host,
        localport => $port,
        listen => True
    );
    note "raku adapter listening on $host:$port";

    my $connection = $listener.accept;
    # Exactly one controller connection is served. Closing the listener first
    # makes a second connection fail fast instead of queueing silently.
    $listener.close;

    run-with(
        -> $line {
            $connection.print("$line\n");
        },
        -> &handle, &reject {
            my $buffer = Buf.new;
            my $stop = False;
            my $discarding = False;
            until $stop {
                my $chunk = $connection.recv(65536, :bin);
                last unless $chunk.defined && $chunk.bytes > 0;
                $buffer.append($chunk);
                loop {
                    my $index = (^$buffer.bytes).first({ $buffer[$_] == 0x0A });
                    unless $index.defined {
                        if !$discarding && $buffer.bytes > line-limit() {
                            reject('command exceeds NDJSON byte limit');
                            $discarding = True;
                            $buffer = Buf.new;
                        }
                        last;
                    }
                    my $line-bytes = $buffer.subbuf(0, $index);
                    $buffer = $buffer.subbuf($index + 1);
                    if $discarding {
                        $discarding = False;
                        next;
                    }
                    if $line-bytes.bytes > line-limit() {
                        reject('command exceeds NDJSON byte limit');
                        next;
                    }
                    my $line;
                    try {
                        $line = $line-bytes.decode('utf8');
                        CATCH { default { $line = Nil } }
                    }
                    unless $line.defined {
                        reject('command is not valid UTF-8');
                        next;
                    }
                    # Tolerate CRLF from a controller that uses it.
                    $line = $line.subst(/ \r $ /, '');
                    if handle($line) {
                        $stop = True;
                        last;
                    }
                }
            }
        },
        # Fire the close in the background rather than awaiting it here. A
        # stalled controller can leave a write blocked in the kernel send
        # buffer on this same connection, and closing a socket from one
        # thread while another thread is blocked writing to it does not
        # reliably unblock that write in this Rakudo/MoarVM version -- the
        # two calls can deadlock against each other. abort-io only needs to
        # request the shutdown; it must not let a stuck close wedge the
        # emitter's writer loop, which is what stalled it in the first place.
        -> { start { try $connection.close } }
    );

    # A graceful close is what makes the controller see a clean exit rather
    # than a transport failure on its side.
    $connection.close;
    Nil
}

if %*ENV<ADAPTER_LISTEN>:exists && %*ENV<ADAPTER_LISTEN>.chars {
    serve-tcp(%*ENV<ADAPTER_LISTEN>);
}
else {
    run-with(
        -> $line {
            $*OUT.say($line);
            $*OUT.flush;
        },
        &read-stdin-lines,
        -> {
            try $*IN.close;
            try $*OUT.close;
        }
    );
}

exit $exit-code;
