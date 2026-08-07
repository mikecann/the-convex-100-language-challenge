unit module Convex::CroLive;

use Base64;
use Cro::HTTP::Client;
use Cro::HTTP::Header;
use Cro::WebSocket::Client::Connection;
use Cro::WebSocket::Message;
use Crypt::Random;
use Digest::SHA1::Native;
use Convex::Errors;
use Convex::Live;

# Production WebSocket transport.
#
# Cro owns TLS, RFC 6455 framing, masking, fragment reassembly, and control
# frames -- ordinary transport work that a native client is allowed to delegate
# to its language's normal WebSocket library. Everything Convex-specific stays
# in Convex::Live.
#
# Every call into Cro that this checkpoint could not exercise on the host is
# marked with `DOCKER-CHECK`. Those are the exact call sites the first Docker
# pass has to confirm against the pinned Cro version before any Live capability
# may be claimed.

# The pinned profile only ever exchanges text messages. Anything else means the
# deployment is speaking a protocol this client does not implement.
our constant MAX-MESSAGE-BYTES = Convex::Live::MAX-MESSAGE-BYTES;
our constant FRAME-DEADLINE-SECONDS = Convex::Live::WRITE-DEADLINE-SECONDS;

# Cro 0.8.9 correctly handles framing mechanics but accepts non-canonical
# 16/64-bit length encodings and does not expose a partial-frame deadline. This
# bounded gate validates one complete server frame before forwarding its exact
# bytes into Cro's parser. It never buffers more than one capped frame, while
# fragmented-message total size is enforced by CroSocket below.
class StrictFrameStream {
    has Supply $.source is required;
    has Supplier $!output = Supplier::Preserving.new;
    has Lock $!lock .= new;
    has Buf $!buffer .= new;
    has Int $!timer-generation = 0;
    has Bool $!fragmented = False;
    has Bool $!finished = False;
    has $!tap;

    submethod TWEAK() {
        $!tap = $!source.tap(
            -> $bytes { self!consume($bytes) },
            done => { self!finish },
            quit => -> $error { self!fail($error) }
        );
    }

    method supply(--> Supply) { $!output.Supply }

    method !consume($bytes --> Nil) {
        unless $bytes ~~ Blob {
            self!fail(X::Convex::Protocol.new(
                detail => 'WebSocket transport emitted a non-byte chunk'
            ));
            return;
        }
        my @ready;
        my $failure;
        $!lock.protect({
            return if $!finished;
            my $was-empty = $!buffer.bytes == 0;
            $!buffer.append($bytes);
            self!arm-deadline if $was-empty && $!buffer.bytes;
            try {
                loop {
                    my $frame = self!take-frame;
                    last unless $frame.defined;
                    @ready.push($frame);
                    if $!buffer.bytes {
                        self!arm-deadline;
                    }
                    else {
                        $!timer-generation++;
                    }
                }
                CATCH { default { $failure = $_ } }
            }
        });
        if $failure.defined {
            self!fail($failure);
        }
        else {
            $!output.emit($_) for @ready;
        }
        Nil
    }

    method !take-frame(--> Blob) {
        return Blob unless $!buffer.bytes >= 2;
        my $first = $!buffer[0];
        my $second = $!buffer[1];
        ($first +& 0x70) == 0
            or die X::Convex::Protocol.new(detail => 'WebSocket RSV bit was set');
        ($second +& 0x80) == 0
            or die X::Convex::Protocol.new(detail => 'server WebSocket frame was masked');
        my $fin = so ($first +& 0x80);
        my $opcode = $first +& 0x0f;
        $opcode == 0 | 1 | 2 | 8 | 9 | 10
            or die X::Convex::Protocol.new(detail => "invalid WebSocket opcode $opcode");

        my $marker = $second +& 0x7f;
        my $header = 2;
        my $length;
        if $marker < 126 {
            $length = $marker;
        }
        elsif $marker == 126 {
            return Blob unless $!buffer.bytes >= 4;
            $length = $!buffer.read-uint16(2, BigEndian);
            $length >= 126
                or die X::Convex::Protocol.new(detail => 'non-canonical WebSocket 16-bit length');
            $header = 4;
        }
        else {
            return Blob unless $!buffer.bytes >= 10;
            ($!buffer[2] +& 0x80) == 0
                or die X::Convex::Protocol.new(detail => 'WebSocket 64-bit length set its high bit');
            $length = $!buffer.read-uint64(2, BigEndian);
            $length > 65535
                or die X::Convex::Protocol.new(detail => 'non-canonical WebSocket 64-bit length');
            $header = 10;
        }
        $length <= MAX-MESSAGE-BYTES
            or die X::Convex::Protocol.new(detail => 'WebSocket frame exceeds byte limit');
        if $opcode >= 8 {
            $fin && $length <= 125
                or die X::Convex::Protocol.new(detail => 'invalid fragmented or oversized control frame');
        }
        elsif $opcode == 0 {
            $!fragmented
                or die X::Convex::Protocol.new(detail => 'unexpected WebSocket continuation frame');
        }
        else {
            !$!fragmented
                or die X::Convex::Protocol.new(detail => 'new data frame interrupted a fragmented message');
        }

        return Blob unless $!buffer.bytes >= $header + $length;
        $!fragmented = !$fin if $opcode < 8;
        my $frame = Blob.new($!buffer.subbuf(0, $header + $length));
        $!buffer = $!buffer.subbuf($header + $length);
        $frame
    }

    method !arm-deadline(--> Nil) {
        my $generation = ++$!timer-generation;
        Promise.in(FRAME-DEADLINE-SECONDS).then({
            my $expired = $!lock.protect({
                !$!finished
                    && $generation == $!timer-generation
                    && $!buffer.bytes > 0
            });
            self!fail(X::Convex::Transport.new(
                detail => 'WebSocket frame exceeded its absolute deadline',
                operation => 'live'
            )) if $expired;
        });
        Nil
    }

    method !finish(--> Nil) {
        my ($first, $partial) = $!lock.protect({
            my $was = $!finished;
            my $had = $!buffer.bytes > 0;
            $!finished = True;
            $!timer-generation++;
            (!$was, $had)
        });
        return unless $first;
        if $partial {
            $!output.quit(X::Convex::Protocol.new(
                detail => 'WebSocket peer closed during a frame'
            ));
        }
        else {
            $!output.done;
        }
        Nil
    }

    method !fail($error --> Nil) {
        my $first = $!lock.protect({
            my $was = $!finished;
            $!finished = True;
            $!timer-generation++;
            !$was
        });
        if $first {
            try $!tap.close if $!tap.defined;
            $!output.quit($error);
        }
        Nil
    }
}

class CroSocket does Convex::Live::Socket {
    our constant MAX-QUEUED-SOCKET-MESSAGES = 4;
    has $.connection is required;
    has Supplier $!messages .= new;
    has Channel $!incoming .= new;
    has Lock $!incoming-lock .= new;
    has Int $!incoming-count = 0;
    has Bool $!reader-stopped = False;
    has $!tap;
    has $!reader;

    submethod TWEAK() {
        # The wrapper republishes complete text messages only. A message that
        # is too large, is not text, or fails to decode as UTF-8 ends the
        # connection instead of being partially delivered: once any byte of a
        # frame has been consumed there is no safe way to resynchronise, so the
        # owner abandons this connection rather than guessing a frame boundary.
        # Cro emits a fragmented message as soon as its first frame arrives,
        # then supplies continuation payloads through body-byte-stream. Never
        # await that body inside the source Supply callback: doing so would
        # prevent Cro from parsing the continuation frames that complete it.
        $!tap = $!connection.messages.tap(
            -> $message {
                my $accepted = $!incoming-lock.protect({
                    if $!reader-stopped
                        || $!incoming-count >= MAX-QUEUED-SOCKET-MESSAGES {
                        False
                    }
                    else {
                        $!incoming-count++;
                        True
                    }
                });
                if $accepted {
                    $!incoming.send(['message', $message]);
                }
                else {
                    self!stop-reader('quit', X::Convex::Transport.new(
                        detail => 'Live incoming message backlog exceeded its bound',
                        operation => 'live'
                    ));
                    start { self.abort };
                }
            },
            done => { self!stop-reader('done') },
            quit => -> $error { self!stop-reader('quit', $error) }
        );
        $!reader = start {
            loop {
                my $item = $!incoming.receive;
                given $item[0] {
                    when 'message' {
                        $!incoming-lock.protect({
                            $!incoming-count-- if $!incoming-count > 0
                        });
                        self!forward($item[1]);
                    }
                    when 'quit' {
                        $!messages.quit($item[1]);
                        last;
                    }
                    default {
                        $!messages.done;
                        last;
                    }
                }
            }
        };
    }

    method !forward($message --> Nil) {
        my $failure;
        try {
            # DOCKER-CHECK: `.is-text` on Cro::WebSocket::Message.
            unless $message.is-text {
                die X::Convex::Protocol.new(detail => 'Live peer sent a non-text message');
            }
            my $buffer = Buf.new;
            my $body-finished = Promise.new;
            my $body-vow = $body-finished.vow;
            my $body-tap = $message.body-byte-stream.tap(
                -> $chunk {
                    if $chunk !~~ Blob {
                        try $body-vow.break(X::Convex::Protocol.new(
                            detail => 'Live body stream emitted a non-byte chunk'
                        ));
                    }
                    elsif $body-finished.status ~~ Planned {
                        if $buffer.bytes + $chunk.bytes > MAX-MESSAGE-BYTES {
                            $body-vow.break(X::Convex::Protocol.new(
                                detail => 'Live message exceeds byte limit'
                            ));
                        }
                        else {
                            $buffer.append($chunk);
                        }
                    }
                },
                done => { try $body-vow.keep(True) },
                quit => -> $error { try $body-vow.break($error) }
            );
            await Promise.anyof(
                $body-finished,
                Promise.in(Convex::Live::WRITE-DEADLINE-SECONDS)
            );
            unless $body-finished.status ~~ Kept {
                $body-tap.close;
                die $body-finished.status ~~ Broken
                    ?? $body-finished.cause
                    !! X::Convex::Transport.new(
                        detail => 'Live fragmented message exceeded its absolute deadline',
                        operation => 'live'
                    );
            }
            my $text;
            try {
                $text = $buffer.decode('utf8');
                CATCH {
                    default {
                        die X::Convex::Protocol.new(
                            detail => 'Live text message is not valid UTF-8'
                        );
                    }
                }
            }
            $!messages.emit($text);
            CATCH { default { $failure = $_ } }
        }
        if $failure.defined {
            $!messages.quit($failure);
            self.abort;
        }
        Nil
    }

    method messages(--> Supply) {
        $!messages.Supply
    }

    # Cro's send enqueues the message on the connection's outgoing supply, so
    # this Promise reports "handed to the transport", not "flushed to the peer".
    # The owner still races it against an absolute write deadline, and the idle
    # deadline is what proves the peer is actually consuming.
    method send-text(Str:D $text --> Promise) {
        start {
            # DOCKER-CHECK: `$connection.send($str)` accepts a Str and sends one
            # text message in the pinned Cro version.
            $!connection.send($text);
            True
        }
    }

    method close(--> Nil) {
        # A graceful close is best effort: the owner has already stopped caring
        # about this connection by the time it calls us.
        try {
            self!stop-reader('done');
            $!tap.close if $!tap.defined;
            my $closed = $!connection.close(
                1000,
                timeout => Convex::Live::WRITE-DEADLINE-SECONDS
            );
            await Promise.anyof($closed, Promise.in(Convex::Live::WRITE-DEADLINE-SECONDS))
                if $closed ~~ Promise;
        }
        $!messages.done;
        Nil
    }

    # Immediate retirement. There is no public application API for this: the
    # owner uses it for deadlines and for the adapter-only debugDisconnect.
    method abort(--> Nil) {
        try {
            self!stop-reader('done');
            $!tap.close if $!tap.defined;
            # A zero Cro close timeout ends its outgoing stream immediately.
            # The HTTP pipeline then retires the TCP connection without making
            # the owner wait for a cooperative close frame.
            start { try $!connection.close(1000, timeout => 0) };
        }
        Nil
    }

    method !stop-reader(Str:D $kind, $error = Nil --> Nil) {
        my $first = $!incoming-lock.protect({
            my $was = $!reader-stopped;
            $!reader-stopped = True;
            !$was
        });
        if $first {
            $!incoming.send($kind eq 'quit'
                ?? ['quit', $error]
                !! ['done']);
        }
        Nil
    }
}

class Factory does Convex::Live::SocketFactory {
    has Str $.client-version = 'raku-0.1.0';

    method connect(Str:D $url, Real:D :$deadline --> Promise) {
        my $result = Promise.new;
        my $vow = $result.vow;
        my $client-version = $!client-version;

        # One absolute deadline covers DNS, TCP, TLS, the upgrade request, and
        # the 101 response, because it wraps the whole of Cro's connect.
        my $attempt = start {
            my $out = Supplier::Preserving.new;
            my $key = encode-base64(crypt_random_buf(16), :str);
            my $accept = encode-base64(
                # Match Cro 0.8.9's own proven handshake calculation. This
                # Digest::SHA1::Native API accepts the key plus GUID as Str.
                sha1($key ~ '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'),
                :str
            );
            my @headers =
                Cro::HTTP::Header.new(name => 'Upgrade', value => 'websocket'),
                Cro::HTTP::Header.new(name => 'Connection', value => 'Upgrade'),
                Cro::HTTP::Header.new(name => 'Sec-WebSocket-Version', value => '13'),
                Cro::HTTP::Header.new(name => 'Sec-WebSocket-Key', value => $key),
                Cro::HTTP::Header.new(name => 'Convex-Client', value => $client-version);
            my $response = await Cro::HTTP::Client.get(
                $url.subst(/^ 'ws'/, 'http'),
                headers => @headers,
                body-byte-stream => $out.Supply,
                http => '1.1',
                timeout => $deadline,
                follow => 0
            );
            $response.status == 101
                or die X::Convex::Protocol.new(
                    detail => "WebSocket upgrade returned HTTP {$response.status}"
                );
            header-has-token($response.header('Upgrade'), 'websocket')
                or die X::Convex::Protocol.new(
                    detail => 'WebSocket Upgrade header omitted websocket token'
                );
            header-has-token($response.header('Connection'), 'upgrade')
                or die X::Convex::Protocol.new(
                    detail => 'WebSocket Connection header omitted Upgrade token'
                );
            ($response.header('Sec-WebSocket-Accept') // '').trim eq $accept
                or die X::Convex::Protocol.new(
                    detail => 'WebSocket Sec-WebSocket-Accept did not match the request key'
                );
            my $strict = StrictFrameStream.new(source => $response.body-byte-stream);
            # Cro::WebSocket::Client::Connection itself composes the inbound
            # FrameParser + MessageParser and outbound MessageSerializer +
            # masked FrameSerializer. Its `in` and `out` constructor values are
            # deliberately raw byte supplies, exactly as used by Cro 0.8.9's
            # own Client.connect implementation.
            Cro::WebSocket::Client::Connection.new(
                in => $strict.supply,
                out => $out
            )
        };
        Promise.anyof($attempt, Promise.in($deadline)).then({
            if $attempt.status ~~ Kept {
                $vow.keep(CroSocket.new(connection => $attempt.result));
            }
            else {
                # Cro's underlying connect may complete after our deadline.
                # Close that late connection rather than leaking a socket the
                # owner will never see.
                $attempt.then({
                    try { .result.close if .status ~~ Kept }
                });
                $vow.break(X::Convex::Transport.new(
                    detail => $attempt.status ~~ Broken
                        ?? $attempt.cause.message
                        !! "Live connect exceeded its $deadline second deadline",
                    operation => 'live'
                ));
            }
        });
        $result
    }
}

sub header-has-token($value, Str:D $wanted --> Bool) {
    return False unless $value ~~ Str;
    so $value.split(',').map(*.trim.lc).first(* eq $wanted.lc)
}
