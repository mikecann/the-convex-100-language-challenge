unit module Convex::Adapter;

use JSON::Fast;
use Convex;
use Convex::Errors;
use Convex::Live;

# Test-only NDJSON adapter protocol v1 engine.
#
# This module is conformance infrastructure, not public client code: it exists
# so the shared controller can drive the real Raku client. It reserves its
# output stream for protocol events, validates every command strictly before
# calling the client, and bounds everything it buffers.

our constant MAX-NDJSON-LINE-BYTES = 2 * 1024 * 1024;

# The shared schema limits ids to 128 characters. The controller validates with
# Ajv, which counts Unicode code points, so `.codes` is the matching measure --
# `.chars` counts graphemes and would accept an id the controller rejects.
our constant MAX-ADAPTER-ID-CODES = 128;

# Output backlog limits. A controller that stops reading must not be able to
# grow this process: both an event count and a byte budget are enforced,
# because one protocol value can be close to the maximum line size.
our constant MAX-QUEUED-EVENTS = 512;
our constant MAX-QUEUED-EVENT-BYTES = 8 * 1024 * 1024;
our constant SHUTDOWN-DEADLINE-SECONDS = 5;
our constant OUTPUT-WRITE-DEADLINE-SECONDS = 1;

# Serialised event lines leave through exactly one writer thread, in the order
# they were accepted. Nothing else may write to the adapter stream: interleaved
# writes from a subscription pump and a command reply would corrupt NDJSON.
class Emitter {
    has &.write-line is required;
    # Closing the output alone is not enough when the command reader is also
    # blocked. The transport supplies one idempotent callback that retires both
    # directions and makes the adapter process leave its reader loop.
    has &.abort-io = -> { };
    has Int $.max-events = MAX-QUEUED-EVENTS;
    has Int $.max-bytes = MAX-QUEUED-EVENT-BYTES;
    has Channel $!queue .= new;
    has Lock $!lock .= new;
    has Int $!queued-events = 0;
    has Int $!queued-bytes = 0;
    has Bool $!closed = False;
    has Bool $!stalled = False;
    has $!writer;

    submethod TWEAK() {
        $!writer = start {
            loop {
                my $item = try $!queue.receive;
                last unless $item.defined;
                my $line = $item[0];
                my $bytes = $item[1];
                # The write happens outside the budget lock so a slow consumer
                # blocks only this thread, never a protocol thread.
                my $write = start { &!write-line($line) };
                await Promise.anyof(
                    $write,
                    Promise.in(OUTPUT-WRITE-DEADLINE-SECONDS)
                );
                my $written = $write.status ~~ Kept;
                unless $written {
                    $!lock.protect({ $!stalled = True });
                    try &!abort-io();
                }
                $!lock.protect({
                    $!queued-events--;
                    $!queued-bytes -= $bytes;
                });
                unless $written {
                    # No event may be delivered after an output deadline. Drop
                    # the now-unobservable queue and release every reservation
                    # before the writer task exits.
                    loop {
                        my $pending = $!queue.poll;
                        last unless $pending.defined;
                        $!lock.protect({
                            $!queued-events-- if $!queued-events > 0;
                            $!queued-bytes -= $pending[1];
                            $!queued-bytes = 0 if $!queued-bytes < 0;
                        });
                    }
                    last;
                }
            }
        };
    }

    method stalled(--> Bool) { $!lock.protect({ $!stalled }) }
    method queued(--> List) { $!lock.protect({ ($!queued-events, $!queued-bytes) }) }

    # Serialising before taking the lock lets a bad application value fail
    # without holding up the writer.
    method emit(%event --> Nil) {
        my $line = to-json(%event, :!pretty);
        my $bytes = $line.encode('utf8').bytes + 1;
        $bytes <= MAX-NDJSON-LINE-BYTES
            or die X::Convex::Protocol.new(detail => 'adapter event exceeds NDJSON line limit');

        $!lock.protect({
            die X::Convex::Closed.new if $!closed;
            if $!stalled
                || $!queued-events + 1 > $!max-events
                || $!queued-bytes + $bytes > $!max-bytes {
                # Dropping a protocol event would desynchronise the controller,
                # so an exhausted budget is terminal for the whole adapter.
                $!stalled = True;
                die X::Convex::Transport.new(
                    detail => 'adapter output backlog exceeded its bound; controller stopped reading',
                    operation => 'adapter'
                );
            }
            $!queued-events++;
            $!queued-bytes += $bytes;
        });
        my $sent = try { $!queue.send([$line, $bytes]); True };
        unless $sent {
            $!lock.protect({
                $!queued-events-- if $!queued-events > 0;
                $!queued-bytes -= $bytes;
                $!queued-bytes = 0 if $!queued-bytes < 0;
            });
            die X::Convex::Closed.new;
        }
        Nil
    }

    # Stop accepting events, let the writer drain, and give up after a bounded
    # wait so a stalled consumer cannot hang the process on exit.
    method shutdown(Real:D :$deadline = SHUTDOWN-DEADLINE-SECONDS --> Bool) {
        my $first = $!lock.protect({
            my $was = $!closed;
            $!closed = True;
            !$was
        });
        return False unless $first;
        $!queue.close;
        await Promise.anyof($!writer, Promise.in($deadline));
        $!writer.status ~~ Kept
    }
}

# One command engine. The reader loop is single threaded, so command replies
# keep their order; subscription events arrive from per-subscription pumps and
# are serialised by the emitter.
class Server {
    has $.client is required;
    has $.live-owner is required;
    has Emitter $.emitter is required;
    has Str $.implementation = 'native-raku';
    has %!subscriptions;
    has %!pumps;
    has Lock $!lock .= new;
    has Bool $!closed = False;

    method closed(--> Bool) { $!lock.protect({ $!closed }) }

    method handle-line(Str:D $line --> Nil) {
        # Bounding the command before parsing keeps a hostile controller from
        # making this process allocate an unbounded string.
        $line.encode('utf8').bytes <= MAX-NDJSON-LINE-BYTES
            or do { self!protocol-error('', 'command exceeds NDJSON byte limit'); return };

        my $command = try from-json($line);
        without $command {
            self!protocol-error('', 'command is not valid JSON');
            return;
        }
        $command ~~ Hash
            or do { self!protocol-error('', 'command must be a JSON object'); return };
        self!dispatch($command);
        Nil
    }

    # The incremental transport readers use this when bytes cannot become a
    # valid bounded NDJSON line. Keeping the response in the engine preserves
    # the same schema-valid error shape as every other malformed command.
    method reject-input(Str:D $detail --> Nil) {
        self!protocol-error('', $detail);
        Nil
    }

    method !dispatch(%command --> Nil) {
        my $id = %command<id>;
        # An invalid id is never echoed: the shared schema would reject the
        # reply, and the controller has to be able to recover from exactly one
        # malformed command.
        unless $id ~~ Str
            && 1 <= $id.codes <= MAX-ADAPTER-ID-CODES
            && $id.trim.chars {
            self!protocol-error('', 'id must be a non-empty string of at most 128 characters');
            return;
        }

        my $op = %command<op>;
        unless $op ~~ Str {
            self!protocol-error($id, 'op must be a string');
            return;
        }

        if $op eq 'hello' {
            return unless self!only-fields($id, %command, <protocolVersion id op>);
            unless %command<protocolVersion> ~~ Int
                && %command<protocolVersion> !~~ Bool
                && %command<protocolVersion> == 1 {
                self!protocol-error($id, 'protocolVersion must equal 1');
                return;
            }
            self!emit({
                protocolVersion => 1,
                id => $id,
                type => 'ready',
                language => 'raku',
                implementation => $!implementation,
                runtime => "rakudo {$*RAKU.compiler.version}"
            });
        }
        elsif $op eq 'query' | 'mutation' | 'action' {
            return unless self!only-fields($id, %command, <id op path args>);
            unless %command<path> ~~ Str && %command<path>.codes >= 3 {
                self!protocol-error($id, 'path must be a string of at least three characters');
                return;
            }
            unless %command<args> ~~ Hash {
                self!protocol-error($id, 'args must be an object');
                return;
            }
            self!call($id, $op, %command<path>, %command<args>);
        }
        elsif $op eq 'setAuth' {
            return unless self!only-fields($id, %command, <id op token>);
            unless %command<token> ~~ Str {
                self!protocol-error($id, 'token must be a string');
                return;
            }
            self!guarded($id, {
                $.client.set-auth(%command<token>);
                self!emit({ id => $id, type => 'ack' });
            });
        }
        elsif $op eq 'subscribe' {
            return unless self!only-fields($id, %command, <id op subscriptionId path args>);
            self!subscribe($id, %command);
        }
        elsif $op eq 'unsubscribe' {
            # path and args are optional fields in the shared command schema.
            # Accept and validate them when present even though unsubscribe
            # needs only the subscription id operationally.
            return unless self!only-fields($id, %command, <id op subscriptionId path args>);
            if %command<path>:exists && %command<path> !~~ Str {
                self!protocol-error($id, 'path must be a string');
                return;
            }
            if %command<args>:exists && %command<args> !~~ Hash {
                self!protocol-error($id, 'args must be an object');
                return;
            }
            self!unsubscribe($id, %command<subscriptionId>);
        }
        elsif $op eq 'debugDisconnect' {
            return unless self!only-fields($id, %command, <id op>);
            self!guarded($id, {
                $.live-owner.debug-disconnect-for-adapter;
                self!emit({ id => $id, type => 'ack' });
            });
        }
        elsif $op eq 'close' {
            return unless self!only-fields($id, %command, <id op>);
            self!close($id);
        }
        else {
            self!protocol-error($id, "unsupported adapter operation '$op'");
        }
        Nil
    }

    method !call(Str:D $id, Str:D $op, Str:D $path, %args --> Nil) {
        self!guarded($id, {
            my $result = $op eq 'query'
                ?? $.client.query($path, %args)
                !! $op eq 'mutation'
                    ?? $.client.mutation($path, %args)
                    !! $.client.action($path, %args);
            self!emit({
                id => $id,
                type => 'result',
                value => $result.value,
                logs => $result.logs
            });
        });
    }

    method !subscribe(Str:D $id, %command --> Nil) {
        my $sid = %command<subscriptionId>;
        unless $sid ~~ Str
            && 1 <= $sid.codes <= MAX-ADAPTER-ID-CODES
            && $sid.trim.chars {
            self!protocol-error($id, 'subscriptionId must be a non-empty string of at most 128 characters');
            return;
        }
        unless %command<path> ~~ Str && %command<path>.codes >= 3 {
            self!protocol-error($id, 'path must be a string of at least three characters');
            return;
        }
        unless %command<args> ~~ Hash {
            self!protocol-error($id, 'args must be an object');
            return;
        }

        self!guarded($id, {
            # Same-id replacement retires the old subscription first. The owner
            # invalidates the old relay before it returns, so a paused pump
            # cannot publish a stale event after the new acknowledgement.
            self!retire-subscription($sid);
            my $subscription = $.live-owner.subscribe(%command<path>, %command<args>);
            $!lock.protect({ %!subscriptions{$sid} = $subscription });
            self!start-pump($sid, $subscription);
            self!emit({ id => $id, subscriptionId => $sid, type => 'ack' });
        });
    }

    method !unsubscribe(Str:D $id, $sid --> Nil) {
        unless $sid ~~ Str
            && 1 <= $sid.codes <= MAX-ADAPTER-ID-CODES
            && $sid.trim.chars {
            self!protocol-error($id, 'subscriptionId must be a non-empty string of at most 128 characters');
            return;
        }
        self!guarded($id, {
            self!retire-subscription($sid);
            self!emit({ id => $id, subscriptionId => $sid, type => 'ack' });
        });
    }

    # Removal happens on the owner, which invalidates the relay before it
    # answers. Only then is the pump allowed to finish.
    method !retire-subscription(Str:D $sid --> Nil) {
        my $subscription = $!lock.protect({ %!subscriptions{$sid}:delete });
        return unless $subscription.defined;
        $.live-owner.unsubscribe($subscription);
        my $pump = $!lock.protect({ %!pumps{$sid}:delete });
        await Promise.anyof($pump, Promise.in(SHUTDOWN-DEADLINE-SECONDS)) if $pump.defined;
        Nil
    }

    method !start-pump(Str:D $sid, $subscription --> Nil) {
        my $relay = $subscription.relay;
        my $pump = start {
            # deliver-next hands each update to this sink while holding the
            # relay's validity lock, so an invalidated relay can never publish.
            while $relay.deliver-next(-> $update { self!emit-subscription($sid, $update) }) {
                # Nothing else to do: the sink already emitted the event.
            }
            CATCH {
                default {
                    note "raku adapter subscription pump for $sid stopped: {.message}";
                }
            }
        };
        $!lock.protect({ %!pumps{$sid} = $pump });
        Nil
    }

    method !emit-subscription(Str:D $sid, $update --> Nil) {
        my %event = type => 'subscription', subscriptionId => $sid;
        if $update.failed {
            my %error = name => $update.error-kind, message => $update.error-message;
            %error<data> = $update.error-data if $update.error-data.defined;
            %event<error> = %error;
        }
        else {
            %event<value> = $update.value;
            %event<logs> = $update.logs;
        }
        self!emit(%event);
        Nil
    }

    # Run one command body, mapping every structured failure onto the matching
    # adapter event instead of flattening it into a success or a crash.
    method !guarded(Str:D $id, &body --> Nil) {
        try {
            body();
            CATCH {
                when X::Convex::Function {
                    my %error = (
                        kind => 'FunctionError',
                        name => 'ConvexError',
                        message => .message-text
                    );
                    %error<data> = .data if .data.defined;
                    my %event = id => $id, type => 'error', error => %error;
                    %event<logs> = .logs if .logs.elems;
                    self!emit(%event);
                }
                when X::Convex::Protocol {
                    self!protocol-error($id, .detail);
                }
                when X::Convex::Closed {
                    # Capturing $_ into a named variable before building the
                    # hash literal, rather than calling .message on the
                    # implicit topic inline: a {...} that references the
                    # topic of its own enclosing `when`/`default` is
                    # misparsed as a Block instead of a Hash by this Rakudo
                    # version ("Don't know how to jsonify Block" surfaces
                    # later, at the to-json call in emit).
                    my $closed = $_;
                    self!emit({
                        id => $id,
                        type => 'error',
                        error => { kind => 'ProtocolError', name => 'ClientClosed', message => $closed.message }
                    });
                }
                default {
                    my $failure = $_;
                    self!emit({
                        id => $id,
                        type => 'error',
                        error => {
                            kind => 'TransportError',
                            name => 'TransportError',
                            message => $failure.message
                        }
                    });
                }
            }
        }
        Nil
    }

    method !only-fields(Str:D $id, %command, @expected --> Bool) {
        my %allowed = @expected.map({ $_ => True });
        for %command.keys -> $key {
            unless %allowed{$key}:exists {
                self!protocol-error($id, "unexpected command field '$key'");
                return False;
            }
        }
        True
    }

    method !protocol-error(Str:D $id, Str:D $message --> Nil) {
        my %event = (
            type => 'error',
            error => { kind => 'ProtocolError', name => 'ProtocolError', message => $message }
        );
        # An absent id is omitted, never serialised as null.
        %event<id> = $id if $id.chars;
        self!emit(%event);
        Nil
    }

    method !emit(%event --> Nil) {
        $.emitter.emit(%event);
        Nil
    }

    # Clean shutdown: stop every pump, close Live and HTTP, acknowledge, then
    # let the writer drain. `close` is idempotent so a repeated command cannot
    # produce a second `closed` event.
    method !close(Str:D $id --> Nil) {
        my $first = $!lock.protect({
            my $was = $!closed;
            $!closed = True;
            !$was
        });
        return unless $first;

        my @sids = $!lock.protect({ %!subscriptions.keys.list });
        for @sids -> $sid {
            self!retire-subscription($sid);
        }
        # Close is a best-effort resource retirement operation. The protocol
        # still owes the controller exactly one terminal event if one surface
        # was already broken while shutting down.
        try { $.live-owner.close }
        try { $.client.close }
        self!emit({ id => $id, type => 'closed' });
        Nil
    }
}
