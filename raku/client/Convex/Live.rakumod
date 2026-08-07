unit module Convex::Live;

use JSON::Fast;
use Convex::Errors;

# --------------------------------------------------------------------------
# Budgets and deadlines
#
# Every number here is deliberately absolute. The conformance client container
# runs with 128 MiB of memory, a read-only filesystem, and a small process
# limit, so "eventually" is not an acceptable bound for any wait or any queue.
# --------------------------------------------------------------------------

# A single server message may not exceed this many encoded bytes.
our constant MAX-MESSAGE-BYTES = 2 * 1024 * 1024;

# Per-subscription queue depth, and the shared budget across every
# subscription owned by one Owner. The two together are what stop a stopped
# reader from turning one large value into unbounded memory.
our constant MAX-QUEUED-UPDATES = 64;
our constant MAX-TOTAL-QUEUED-UPDATES = 256;
our constant MAX-TOTAL-QUEUED-BYTES = 8 * 1024 * 1024;

# One absolute deadline covers DNS, TCP, TLS, the WebSocket upgrade request,
# and the 101 response. The socket factory owns it; the owner re-arms its own
# copy so a factory that forgets cannot stall the worker forever.
our constant CONNECT-DEADLINE-SECONDS = 10;

# How long the peer may stay silent once a connection is established, and how
# long a single write may take before the connection is abandoned.
our constant IDLE-DEADLINE-SECONDS = 30;
our constant IDLE-CHECK-SECONDS = 5;
our constant WRITE-DEADLINE-SECONDS = 5;

# How long a caller of subscribe/unsubscribe/close/debugDisconnect will wait
# for the owner worker before giving up. This is what makes those operations
# bounded even when the peer is idle, flooding, or stalled mid-frame.
our constant CONTROL-DEADLINE-SECONDS = 15;

our constant INITIAL-BACKOFF-SECONDS = 0.1;
our constant MAXIMUM-BACKOFF-SECONDS = 15;

# --------------------------------------------------------------------------
# Wire helpers
# --------------------------------------------------------------------------

our constant BASE64-ALPHABET =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

# The protocol carries timestamps as a base64 little-endian unsigned 64-bit
# value. Raku has no core base64 codec, and pulling in a module for twelve
# characters would add a dependency to the runtime closure for no benefit, so
# the two directions are implemented here and unit tested.
our sub base64-decode(Str:D $text --> Blob) is export {
    $text ~~ / ^ <[A..Za..z0..9+/]>* '='* $ /
        or die X::Convex::Protocol.new(detail => 'timestamp is not base64');
    my $body = $text.subst(/ '='+ $ /, '');
    my $accumulator = 0;
    my $bits = 0;
    my @bytes;
    for $body.comb -> $character {
        my $index = BASE64-ALPHABET.index($character);
        $index.defined
            or die X::Convex::Protocol.new(detail => 'timestamp is not base64');
        $accumulator = ($accumulator +< 6) +| $index;
        $bits += 6;
        if $bits >= 8 {
            $bits -= 8;
            @bytes.push: ($accumulator +> $bits) +& 0xff;
        }
    }
    Blob.new(@bytes)
}

our sub base64-encode(Blob:D $bytes --> Str) is export {
    my $text = '';
    my @chunk = @$bytes;
    while @chunk {
        my @group = @chunk.splice(0, 3);
        my $padding = 3 - @group.elems;
        @group.push: 0 for ^$padding;
        my $value = (@group[0] +< 16) +| (@group[1] +< 8) +| @group[2];
        my @indexes = ($value +> 18) +& 0x3f, ($value +> 12) +& 0x3f,
                      ($value +> 6) +& 0x3f, $value +& 0x3f;
        my $encoded = @indexes.map({ BASE64-ALPHABET.substr($_, 1) }).join;
        $text ~= ($padding == 0
            ?? $encoded
            !! $encoded.substr(0, 4 - $padding) ~ ('=' x $padding));
    }
    $text
}

# Decode the eight little-endian bytes into a comparable integer. Comparing the
# encoded strings, or the bytes in order, would order timestamps wrongly.
our sub timestamp-value(Str:D $encoded --> Int) is export {
    my $bytes = base64-decode($encoded);
    $bytes.elems == 8
        or die X::Convex::Protocol.new(
            detail => "timestamp must decode to 8 bytes, got {$bytes.elems}"
        );
    base64-encode($bytes) eq $encoded
        or die X::Convex::Protocol.new(
            detail => 'timestamp is not canonical base64'
        );
    my $value = 0;
    for (^8).reverse -> $index {
        $value = ($value +< 8) +| $bytes[$index];
    }
    $value
}

our constant INITIAL-TIMESTAMP = 'AAAAAAAAAAA=';

class StateVersion {
    has Int $.query-set = 0;
    has Int $.identity = 0;
    has Str $.timestamp = INITIAL-TIMESTAMP;

    method same-as(StateVersion:D $other --> Bool) {
        $!query-set == $other.query-set
            && $!identity == $other.identity
            && $!timestamp eq $other.timestamp
    }

    method describe(--> Str) {
        "querySet=$!query-set identity=$!identity ts=$!timestamp"
    }

    method from-json($value --> StateVersion) {
        $value ~~ Hash
            or die X::Convex::Protocol.new(detail => 'state version must be an object');
        my $query-set = $value<querySet>;
        my $identity = $value<identity>;
        my $timestamp = $value<ts>;
        $query-set ~~ Int && $query-set !~~ Bool && $query-set >= 0
            or die X::Convex::Protocol.new(detail => 'state version querySet must be a non-negative integer');
        $identity ~~ Int && $identity !~~ Bool && $identity >= 0
            or die X::Convex::Protocol.new(detail => 'state version identity must be a non-negative integer');
        $timestamp ~~ Str
            or die X::Convex::Protocol.new(detail => 'state version ts must be a string');
        # Decoding here rejects a malformed timestamp before it is ever stored.
        timestamp-value($timestamp);
        StateVersion.new(
            query-set => $query-set,
            identity => $identity,
            timestamp => $timestamp
        )
    }

    method to-json-value(--> Hash) {
        { querySet => $!query-set, identity => $!identity, ts => $!timestamp }
    }
}

# --------------------------------------------------------------------------
# Transport seams
#
# A WebSocket package performs TLS and RFC 6455 framing, masking, fragment
# reassembly, and control frames. That is ordinary transport and is allowed for
# a native client. Everything Convex-specific -- the query set, versions,
# reconnects, rehydration, and delivery ordering -- stays in Raku below.
#
# Both seams are asynchronous on purpose. If `connect` or `send-text` could
# block, a hung DNS lookup or a stalled write would also block `close` and
# `unsubscribe`, and neither would be bounded any more.
# --------------------------------------------------------------------------

role Socket {
    # A Supply of complete text messages. It must quit or finish when the
    # connection ends, and it must never emit a partially received frame.
    method messages(--> Supply) { ... }

    # Returns a Promise kept once the message has been handed to the transport.
    method send-text(Str:D $text --> Promise) { ... }

    # Graceful RFC 6455 close.
    method close(--> Nil) { ... }

    # Immediate retirement of the underlying TCP connection. The owner uses it
    # for deadlines and for the adapter-only debugDisconnect command; there is
    # no public client API for it.
    method abort(--> Nil) { ... }
}

role SocketFactory {
    # Must apply ONE absolute deadline across DNS, connect, TLS, the upgrade
    # request write, and the 101 response read, then keep the returned Promise
    # with a Socket or break it with X::Convex::Transport.
    method connect(Str:D $url, Real:D :$deadline --> Promise) { ... }
}

# --------------------------------------------------------------------------
# Delivery
# --------------------------------------------------------------------------

class Update {
    has $.value;
    has @.logs;
    # 'value' for a query result, 'error' for a QueryFailed or a structured
    # protocol/transport failure that the subscriber has to see.
    has Str $.kind = 'value';
    has Str $.error-kind = '';
    has Str $.error-message = '';
    has $.error-data;
    has Str $.timestamp = INITIAL-TIMESTAMP;

    method failed(--> Bool) { $!kind eq 'error' }
}

# Shared count and byte budget for every relay belonging to one owner. A count
# limit alone is not a memory limit when a single value can approach the
# maximum message size, so both are reserved before an update is queued.
class Budget {
    has Int $.max-count = MAX-TOTAL-QUEUED-UPDATES;
    has Int $.max-bytes = MAX-TOTAL-QUEUED-BYTES;
    has Int $!count = 0;
    has Int $!bytes = 0;
    has Lock $!lock .= new;

    method reserve(Int:D $bytes --> Bool) {
        $!lock.protect({
            return False if $!count + 1 > $!max-count;
            return False if $!bytes + $bytes > $!max-bytes;
            $!count++;
            $!bytes += $bytes;
            True
        })
    }

    method release(Int:D $bytes --> Nil) {
        $!lock.protect({
            $!count-- if $!count > 0;
            $!bytes -= $bytes;
            $!bytes = 0 if $!bytes < 0;
        });
        Nil
    }

    method in-use(--> List) {
        $!lock.protect({ ($!count, $!bytes) })
    }
}

# A bounded, invalidatable queue of updates for exactly one subscription.
#
# Two rules make unsubscribe and same-ID replacement safe:
#   * `invalidate` takes the same lock that `deliver-next` holds while it hands
#     an update to its sink, so an update that was already dequeued can never
#     be published after invalidation returns.
#   * `offer` reserves shared budget before queueing and releases exactly that
#     reservation when the update leaves the queue.
class Relay {
    has Budget $.budget is required;
    has Int $.max-queued = MAX-QUEUED-UPDATES;
    has Channel $!channel .= new;
    has Lock $!lock .= new;
    has Int $!queued = 0;
    has Int $!dropped = 0;
    has Bool $!valid = True;
    has Bool $!closed = False;

    method dropped(--> Int) { $!lock.protect({ $!dropped }) }
    method valid(--> Bool) { $!lock.protect({ $!valid }) }
    method queued(--> Int) { $!lock.protect({ $!queued }) }

    # A reactive query represents current state, so an overflowing queue drops
    # its oldest pending value rather than blocking the protocol worker or
    # growing without limit. The drop is counted so a test can assert it.
    #
    # Reservations are released on every rejection path. A leaked reservation
    # would be worse than an unbounded queue: it would slowly starve every
    # other subscription sharing the owner's budget.
    method offer(Update:D $update --> Bool) {
        my $bytes = estimate-update-bytes($update);
        return False unless $!lock.protect({ $!valid && !$!closed });

        # Make room first when this relay is already at its own depth limit.
        self!drop-oldest if $!lock.protect({ $!queued }) >= $!max-queued;

        unless $!budget.reserve($bytes) {
            self!drop-oldest;
            return False unless $!budget.reserve($bytes);
        }

        my $accepted = $!lock.protect({
            my $ok = $!valid && !$!closed;
            $!queued++ if $ok;
            $ok
        });
        unless $accepted {
            $!budget.release($bytes);
            return False;
        }
        # The channel can only be closed by invalidate, which the owner worker
        # also drives, but a defensive try keeps a late close from turning into
        # an unhandled exception on the protocol thread.
        my $sent = try { $!channel.send([$update, $bytes]); True };
        unless $sent {
            $!lock.protect({ $!queued-- if $!queued > 0 });
            $!budget.release($bytes);
            return False;
        }
        True
    }

    # Dequeue one update and hand it to the sink while holding the validity
    # lock, so delivery and invalidation are mutually exclusive.
    method deliver-next(&sink --> Bool) {
        my $item = try $!channel.receive;
        return False unless $item.defined;
        my $update = $item[0];
        my $bytes = $item[1];
        $!lock.protect({ $!queued-- if $!queued > 0 });
        $!budget.release($bytes);
        $!lock.protect({
            return False unless $!valid;
            sink($update);
            True
        })
    }

    # Blocking receive for ordinary application code such as the example.
    # Returns an undefined Update once the relay has been invalidated.
    method receive(--> Update) {
        my $item = try $!channel.receive;
        return Update unless $item.defined;
        my $update = $item[0];
        my $bytes = $item[1];
        $!lock.protect({ $!queued-- if $!queued > 0 });
        $!budget.release($bytes);
        return Update unless $!lock.protect({ $!valid });
        $update
    }

    # Invalidate first, then close, so a consumer blocked in receive wakes up
    # and sees an invalid relay instead of a stale value.
    method invalidate(--> Nil) {
        $!lock.protect({ $!valid = False; $!closed = True });
        self!drain;
        $!channel.close;
        Nil
    }

    method !drop-oldest(--> Nil) {
        my $item = $!channel.poll;
        return unless $item.defined;
        $!lock.protect({
            $!queued-- if $!queued > 0;
            $!dropped++;
        });
        $!budget.release($item[1]);
        Nil
    }

    method !drain(--> Nil) {
        loop {
            my $item = $!channel.poll;
            last unless $item.defined;
            $!lock.protect({ $!queued-- if $!queued > 0 });
            $!budget.release($item[1]);
        }
        Nil
    }
}

# Encoded size plus a fixed allowance for the Raku object graph around it. The
# allowance is what keeps the count limit honest for many small updates.
our sub estimate-update-bytes(Update:D $update --> Int) is export {
    my $encoded = try to-json($update.value, :!pretty);
    my $size = $encoded.defined ?? $encoded.encode('utf8').bytes !! 0;
    $size + $update.error-message.encode('utf8').bytes + 512
}

class Subscription {
    has Int $.query-id is required;
    has Str $.path is required;
    has %.args;
    has Relay $.relay is required;

    # Application-facing receive. Returns an undefined Update when the
    # subscription has been removed or the owner has closed.
    method next-update(--> Update) {
        $!relay.receive
    }

    method active(--> Bool) { $!relay.valid }
}

class ActiveQuery {
    has Int $.query-id is required;
    has Str $.path is required;
    has %.args;
    has Subscription $.subscription is required;
}

# --------------------------------------------------------------------------
# The owner
#
# Exactly one worker thread touches the socket, the query set, the version
# counters, and the reconnect schedule. Every public method posts a command to
# that worker and waits on a Promise with an absolute deadline; no caller ever
# reads or writes the socket itself.
# --------------------------------------------------------------------------
class Owner {
    has Str $.sync-url is required;
    has SocketFactory $.socket-factory is required;
    has Str $.client-version = 'raku-0.1.0';
    has Budget $.budget = Budget.new;

    has Channel $!inbox .= new;
    has Lock $!lock .= new;
    # The worker publishes its counters here. Public readers take the same lock,
    # so no caller ever reads protocol state straight out of the worker.
    has %!stats = (
        connection-count => 0,
        last-close-reason => 'InitialConnect',
        max-observed-timestamp => ''
    );
    has Bool $!started = False;
    has Bool $!finished = False;
    has $!worker;

    method connection-count(--> Int) { $!lock.protect({ %!stats<connection-count> }) }
    method last-close-reason(--> Str) { $!lock.protect({ %!stats<last-close-reason> }) }
    method max-observed-timestamp(--> Str) { $!lock.protect({ %!stats<max-observed-timestamp> }) }
    method finished(--> Bool) { $!lock.protect({ $!finished }) }

    # The worker starts on the first command rather than at construction, so an
    # HTTP-only program that merely builds an Owner never spawns a thread.
    method !ensure-worker(--> Nil) {
        my $start = $!lock.protect({
            my $needed = !$!started;
            $!started = True;
            $needed
        });
        $!worker = start { self!run } if $start;
        Nil
    }

    # Post a command to the worker and wait for it under an absolute deadline.
    # This is what makes subscribe, unsubscribe, debugDisconnect, and close
    # bounded even when the peer is idle, flooding, or stalled mid-frame.
    method !command(%command, Real:D :$deadline = CONTROL-DEADLINE-SECONDS) {
        self!ensure-worker;
        my $answer = Promise.new;
        %command<vow> = $answer.vow;
        $!inbox.send(%command);
        await Promise.anyof($answer, Promise.in($deadline));
        unless $answer.status ~~ Kept {
            die X::Convex::Transport.new(
                detail => $answer.status ~~ Broken
                    ?? $answer.cause.message
                    !! "Live owner did not answer '{%command<kind>}' within $deadline seconds",
                operation => 'live'
            );
        }
        $answer.result
    }

    method subscribe(Str:D $path, %args --> Subscription) {
        self!command({ kind => 'subscribe', path => $path, args => %args })
    }

    method unsubscribe(Subscription:D $subscription --> Nil) {
        self!command({ kind => 'unsubscribe', query-id => $subscription.query-id });
        Nil
    }

    # Adapter-only. It returns after the old connection has been retired and the
    # reconnect has been scheduled, so the shared controller's acknowledgement
    # can never race a surviving reader from the previous connection. There is
    # deliberately no equivalent in the educational client API.
    method debug-disconnect-for-adapter(--> Nil) {
        self!command({ kind => 'debug-disconnect' });
        Nil
    }

    method close(--> Nil) {
        return if $!lock.protect({ !$!started || $!finished });
        self!command({ kind => 'close' });
        Nil
    }

    # ----------------------------------------------------------------------
    # The worker.
    #
    # Everything below runs on exactly one thread and holds all protocol state
    # in ordinary lexicals, which is why none of it needs a lock. The helper
    # subs capture those lexicals; attributes are copied into lexicals first
    # because `$!attribute` is not visible inside a nested sub.
    # ----------------------------------------------------------------------
    method !run(--> Nil) {
        my $inbox := $!inbox;
        my $lock := $!lock;
        my %stats := %!stats;
        my $factory := $!socket-factory;
        my $sync-url := $!sync-url;
        my $budget := $!budget;

        my %active;                 # query id => ActiveQuery
        my %last-delivered;         # query id => [delivered-ok, encoded value]
        my %awaiting-rehydration;   # query id => True
        my $next-query-id = 0;
        my $query-set-version = 0;
        my $remote-version = StateVersion.new;
        my $max-observed-timestamp = '';
        my $connection-count = 0;
        my $last-close-reason = 'InitialConnect';
        my $backoff = INITIAL-BACKOFF-SECONDS;
        my $generation = 0;
        my $socket;
        my $socket-tap;
        my $connecting = False;
        my $reconnect-armed = False;
        my $last-server-response = now;

        my sub publish-stats(--> Nil) {
            $lock.protect({
                %stats<connection-count> = $connection-count;
                %stats<last-close-reason> = $last-close-reason;
                %stats<max-observed-timestamp> = $max-observed-timestamp;
            });
            Nil
        }

        my sub schedule(Real:D $delay, Str:D $kind, Int:D $for-generation --> Nil) {
            Promise.in($delay).then({
                $inbox.send({ kind => $kind, generation => $for-generation });
            });
            Nil
        }

        # Writes are raced against an absolute deadline. A transport that never
        # settles must not be able to stall the worker, and a partially written
        # frame is never retried on the same connection.
        my sub write-message(%message --> Bool) {
            return False unless $socket.defined;
            my $sent = $socket.send-text(to-json(%message, :!pretty));
            await Promise.anyof($sent, Promise.in(WRITE-DEADLINE-SECONDS));
            $sent.status ~~ Kept
        }

        my sub arm-reconnect(--> Nil) {
            return if $reconnect-armed || %active.elems == 0;
            $reconnect-armed = True;
            $generation++;
            schedule($backoff, 'reconnect', $generation);
            $backoff = min($backoff * 2, MAXIMUM-BACKOFF-SECONDS);
            Nil
        }

        # Retiring a connection bumps the generation so every in-flight message,
        # timer, and connect result from the old connection is ignored.
        my sub retire-connection(Str:D $reason, Bool:D :$reconnect! --> Nil) {
            if $socket.defined {
                $socket-tap.close if $socket-tap.defined;
                $socket-tap = Nil;
                $socket.abort;
                $socket = Nil;
                $connection-count++;
            }
            $connecting = False;
            $last-close-reason = $reason;
            # A new connection always restarts the query set and the server's
            # view of our state version.
            $query-set-version = 0;
            $remote-version = StateVersion.new;
            publish-stats();
            arm-reconnect() if $reconnect;
            Nil
        }

        my sub publish(Int:D $query-id, Update:D $update --> Nil) {
            my $query = %active{$query-id};
            $query.subscription.relay.offer($update) if $query.defined;
            Nil
        }

        # A protocol or transport failure is reported to every live
        # subscription. The subscriptions stay registered so the reconnect can
        # prove that a later valid value still arrives on the same subscription.
        my sub publish-to-all(Str:D $kind, Str:D $detail --> Nil) {
            for %active.keys.map(*.Int).sort -> $query-id {
                publish($query-id, Update.new(
                    kind => 'error',
                    error-kind => $kind,
                    error-message => $detail
                ));
                %last-delivered{$query-id}:delete;
            }
            Nil
        }

        my sub fail-connection(Str:D $kind, Str:D $detail --> Nil) {
            publish-to-all($kind, $detail);
            retire-connection($detail, reconnect => True);
            Nil
        }

        my sub add-modification(ActiveQuery:D $query --> Hash) {
            {
                type => 'Add',
                queryId => $query.query-id,
                udfPath => $query.path,
                # The pinned profile carries positional arguments; this profile
                # always sends exactly one argument object. The trailing comma
                # matters: without it, a one-element array literal wrapping a
                # single Hash flattens into that Hash's own pairs (Raku's
                # single-argument list-flattening rule), corrupting the wire
                # payload into a bag of top-level fields instead of one
                # argument object.
                args => [ $query.args, ]
            }
        }

        my sub begin-connect(--> Nil) {
            return if $socket.defined || $connecting;
            $connecting = True;
            $generation++;
            my $for-generation = $generation;
            my $attempt = $factory.connect($sync-url, deadline => CONNECT-DEADLINE-SECONDS);
            # The owner arms its own copy of the connect deadline: a factory
            # that never settles its promise must not wedge the worker.
            Promise.anyof($attempt, Promise.in(CONNECT-DEADLINE-SECONDS)).then({
                if $attempt.status ~~ Kept {
                    $inbox.send({
                        kind => 'connected',
                        generation => $for-generation,
                        socket => $attempt.result
                    });
                }
                else {
                    # The factory may ignore cancellation and eventually hand
                    # back a real socket. Retire that late result immediately
                    # so a timed-out DNS/TLS attempt cannot leak a connection.
                    $attempt.then({
                        try { .result.abort if .status ~~ Kept }
                    });
                    $inbox.send({
                        kind => 'connect-failed',
                        generation => $for-generation,
                        detail => $attempt.status ~~ Broken
                            ?? $attempt.cause.message
                            !! 'connect deadline elapsed'
                    });
                }
            });
            Nil
        }

        my sub start-connection($new-socket, Int:D $for-generation --> Nil) {
            $socket = $new-socket;
            $connecting = False;
            $last-server-response = now;
            $socket-tap = $socket.messages.tap(
                -> $text {
                    $inbox.send({
                        kind => 'message',
                        generation => $for-generation,
                        text => $text
                    });
                },
                done => {
                    $inbox.send({
                        kind => 'socket-done',
                        generation => $for-generation,
                        detail => 'peer closed the connection'
                    });
                },
                quit => -> $error {
                    $inbox.send({
                        kind => 'socket-done',
                        generation => $for-generation,
                        detail => ($error ~~ Exception ?? $error.message !! ~$error)
                    });
                }
            );

            my %connect-message =
                type => 'Connect',
                sessionId => new-session-id(),
                connectionCount => $connection-count,
                lastCloseReason => $last-close-reason,
                clientTs => 0;
            %connect-message<maxObservedTimestamp> = $max-observed-timestamp
                if $max-observed-timestamp.chars;

            my $written = write-message(%connect-message);
            if $written {
                # Replay every active query in a stable numeric order so a
                # reconnect is reproducible and a fixture can assert the frame.
                my @ids = %active.keys.map(*.Int).sort;
                if @ids {
                    my @modifications;
                    for @ids -> $query-id {
                        %awaiting-rehydration{$query-id} = True
                            if %last-delivered{$query-id}:exists;
                        @modifications.push: add-modification(%active{$query-id});
                    }
                    $written = write-message({
                        type => 'ModifyQuerySet',
                        baseVersion => 0,
                        newVersion => 1,
                        modifications => @modifications
                    });
                    $query-set-version = 1 if $written;
                }
            }
            if $written {
                # A complete Connect plus Add replay is a successful
                # handshake. Reset backoff here rather than requiring a later
                # Transition from an otherwise healthy, unchanged query.
                $backoff = INITIAL-BACKOFF-SECONDS;
                schedule(IDLE-CHECK-SECONDS, 'idle-check', $for-generation);
            }
            else {
                retire-connection('handshake write failed', reconnect => True);
            }
            Nil
        }

        my sub handle-transition(%message --> Nil) {
            my $start-version = StateVersion.from-json(%message<startVersion>);
            $start-version.same-as($remote-version)
                or die X::Convex::Protocol.new(
                    detail => "Transition start version ({$start-version.describe}) does not "
                        ~ "match local version ({$remote-version.describe})"
                );
            my $end-version = StateVersion.from-json(%message<endVersion>);

            my $modifications = %message<modifications>;
            $modifications ~~ Positional
                or die X::Convex::Protocol.new(detail => 'Transition modifications must be an array');

            my %changed;
            my %seen-query-id;
            for @$modifications -> $modification {
                $modification ~~ Hash
                    or die X::Convex::Protocol.new(detail => 'Transition modification must be an object');
                my $type = $modification<type>;
                $type ~~ Str
                    or die X::Convex::Protocol.new(detail => 'Transition modification omitted type');
                my $query-id = $modification<queryId>;
                # Bool is an Int in Raku, so a JSON `true` would otherwise be
                # accepted as query id 1.
                $query-id ~~ Int && $query-id !~~ Bool && $query-id >= 0
                    or die X::Convex::Protocol.new(
                        detail => 'Transition modification queryId must be a non-negative integer'
                    );
                %seen-query-id{$query-id}:exists
                    and die X::Convex::Protocol.new(
                        detail => "Transition contains duplicate queryId $query-id"
                    );
                %seen-query-id{$query-id} = True;

                if $type eq 'QueryUpdated' {
                    %active{$query-id}:exists
                        or die X::Convex::Protocol.new(
                            detail => "QueryUpdated named unknown queryId $query-id"
                        );
                    $modification<value>:exists
                        or die X::Convex::Protocol.new(detail => 'QueryUpdated omitted value');
                    my $update = Update.new(
                        value => $modification<value>,
                        logs => $modification<logLines>:exists
                            ?? optional-log-lines($modification<logLines>)
                            !! [],
                        timestamp => $end-version.timestamp
                    );
                    # A reconnect re-sends the current value of every query.
                    # Suppressing only an exactly equal rehydration is what makes
                    # the debugDisconnect sequence deterministic: initial value,
                    # acknowledgement, external mutation, then the new value.
                    my $suppress = False;
                    if %awaiting-rehydration{$query-id}:delete {
                        my $previous = %last-delivered{$query-id};
                        $suppress = $previous.defined
                            && $previous[0]
                            && $previous[1] eq to-json($update.value, :!pretty);
                    }
                    %changed{$query-id} = $update unless $suppress;
                }
                elsif $type eq 'QueryFailed' {
                    %active{$query-id}:exists
                        or die X::Convex::Protocol.new(
                            detail => "QueryFailed named unknown queryId $query-id"
                        );
                    %awaiting-rehydration{$query-id}:delete;
                    my $error-message = $modification<errorMessage>;
                    $error-message ~~ Str
                        or die X::Convex::Protocol.new(detail => 'QueryFailed omitted errorMessage');
                    %changed{$query-id} = Update.new(
                        kind => 'error',
                        error-kind => 'FunctionError',
                        error-message => $error-message,
                        error-data => $modification<errorData>,
                        logs => $modification<logLines>:exists
                            ?? optional-log-lines($modification<logLines>)
                            !! [],
                        timestamp => $end-version.timestamp
                    );
                }
                elsif $type eq 'QueryRemoved' {
                    %active{$query-id}:exists
                        and die X::Convex::Protocol.new(
                            detail => "QueryRemoved named active queryId $query-id"
                        );
                    %last-delivered{$query-id}:delete;
                    %awaiting-rehydration{$query-id}:delete;
                }
                else {
                    die X::Convex::Protocol.new(
                        detail => "unknown Transition modification '$type'"
                    );
                }
            }

            # Commit the whole transition before notifying any subscriber, so a
            # subscriber can never observe a half-applied version.
            $remote-version = $end-version;
            if $max-observed-timestamp eq ''
                || timestamp-value($end-version.timestamp) > timestamp-value($max-observed-timestamp) {
                $max-observed-timestamp = $end-version.timestamp;
            }
            publish-stats();

            for %changed.keys.map(*.Int).sort -> $query-id {
                next unless %active{$query-id}:exists;
                my $update = %changed{$query-id};
                publish($query-id, $update);
                %last-delivered{$query-id} = $update.failed
                    ?? [False, '']
                    !! [True, to-json($update.value, :!pretty)];
            }
            Nil
        }

        my sub handle-server-text(Str:D $text --> Nil) {
            $text.encode('utf8').bytes <= MAX-MESSAGE-BYTES
                or die X::Convex::Protocol.new(detail => 'Live message exceeds byte limit');
            my $decoded = try from-json($text);
            $decoded.defined
                or die X::Convex::Protocol.new(detail => 'Live message is not valid JSON');
            $decoded ~~ Hash
                or die X::Convex::Protocol.new(detail => 'Live message must be a JSON object');
            my $type = $decoded<type>;
            $type ~~ Str
                or die X::Convex::Protocol.new(detail => 'Live message omitted type');

            if $type eq 'Transition' {
                handle-transition($decoded);
                # A completed transition proves this connection is healthy, so a
                # later reconnect must not inherit an old maximum delay.
                $backoff = INITIAL-BACKOFF-SECONDS;
            }
            elsif $type eq 'Ping' | 'MutationResponse' | 'ActionResponse' {
                # This profile drives mutations and actions over HTTP.
                $backoff = INITIAL-BACKOFF-SECONDS;
            }
            elsif $type eq 'FatalError' | 'AuthError' {
                my $detail = $decoded<error> ~~ Str ?? $decoded<error> !! $type;
                die X::Convex::Protocol.new(detail => "$type: $detail");
            }
            elsif $type eq 'TransitionChunk' {
                die X::Convex::Protocol.new(
                    detail => 'TransitionChunk assembly is not implemented by this profile'
                );
            }
            else {
                die X::Convex::Protocol.new(detail => "unknown server message '$type'");
            }
            Nil
        }

        loop {
            my %item = $inbox.receive;
            my $kind = %item<kind> // '';
            my $vow = %item<vow>;

            # A generation-tagged event from a retired connection is dropped.
            # Acting on it would resurrect a socket the owner has abandoned.
            next if %item<generation>:exists && %item<generation> != $generation;

            my $failure;

            if $kind eq 'subscribe' {
                my $query-id = $next-query-id++;
                my $subscription = Subscription.new(
                    query-id => $query-id,
                    path => %item<path>,
                    args => %item<args>,
                    relay => Relay.new(budget => $budget)
                );
                %active{$query-id} = ActiveQuery.new(
                    query-id => $query-id,
                    path => %item<path>,
                    args => %item<args>,
                    subscription => $subscription
                );
                # The relay exists before the Add goes out, so an initial
                # QueryUpdated can never overtake the returned subscription.
                if $socket.defined {
                    if write-message({
                        type => 'ModifyQuerySet',
                        baseVersion => $query-set-version,
                        newVersion => $query-set-version + 1,
                        # Trailing comma: see add-modification's own comment --
                        # a bare one-element array around a single Hash-typed
                        # call result flattens into that Hash's pairs.
                        modifications => [ add-modification(%active{$query-id}), ]
                    }) {
                        $query-set-version++;
                    }
                    else {
                        retire-connection('Add write failed', reconnect => True);
                    }
                }
                else {
                    begin-connect();
                }
                $vow.keep($subscription) if $vow.defined;
            }
            elsif $kind eq 'unsubscribe' {
                my $query-id = %item<query-id>;
                my $query = %active{$query-id}:delete;
                if $query.defined {
                    # Invalidate before acknowledging. An update already dequeued
                    # by a relay consumer cannot be published after this returns,
                    # so no stale event can cross the acknowledgement.
                    $query.subscription.relay.invalidate;
                    %last-delivered{$query-id}:delete;
                    %awaiting-rehydration{$query-id}:delete;
                    if $socket.defined {
                        if write-message({
                            type => 'ModifyQuerySet',
                            baseVersion => $query-set-version,
                            newVersion => $query-set-version + 1,
                            # Trailing comma, same reason as the Add case above.
                            modifications => [ { type => 'Remove', queryId => $query-id }, ]
                        }) {
                            $query-set-version++;
                        }
                        else {
                            retire-connection('Remove write failed', reconnect => True);
                        }
                    }
                }
                $vow.keep(True) if $vow.defined;
            }
            elsif $kind eq 'debug-disconnect' {
                if $socket.defined || $connecting {
                    retire-connection('DebugDisconnect', reconnect => True);
                    # Every query that has already delivered a value must
                    # rehydrate silently on the next connection.
                    for %active.keys.map(*.Int) -> $query-id {
                        %awaiting-rehydration{$query-id} = True
                            if %last-delivered{$query-id}:exists;
                    }
                    $vow.keep(True) if $vow.defined;
                }
                elsif $vow.defined {
                    $vow.break(X::Convex::Transport.new(
                        detail => 'Live WebSocket is not connected',
                        operation => 'live'
                    ));
                }
            }
            elsif $kind eq 'close' {
                if $socket.defined {
                    $socket-tap.close if $socket-tap.defined;
                    $socket-tap = Nil;
                    $socket.close;
                    $socket = Nil;
                }
                .subscription.relay.invalidate for %active.values;
                %active = ();
                $last-close-reason = 'ClientClosed';
                publish-stats();
                $lock.protect({ $!finished = True });
                $vow.keep(True) if $vow.defined;
                last;
            }
            elsif $kind eq 'connected' {
                start-connection(%item<socket>, %item<generation>);
            }
            elsif $kind eq 'connect-failed' {
                $connecting = False;
                $connection-count++;
                $last-close-reason = %item<detail> // 'connect failed';
                publish-stats();
                arm-reconnect();
            }
            elsif $kind eq 'reconnect' {
                $reconnect-armed = False;
                begin-connect() if !$socket.defined && %active.elems > 0;
            }
            elsif $kind eq 'message' {
                $last-server-response = now;
                try {
                    handle-server-text(%item<text>);
                    CATCH { default { $failure = $_ } }
                }
            }
            elsif $kind eq 'socket-done' {
                fail-connection('TransportError', %item<detail> // 'connection ended');
            }
            elsif $kind eq 'idle-check' {
                if $socket.defined {
                    if now - $last-server-response > IDLE-DEADLINE-SECONDS {
                        fail-connection('TransportError', 'InactiveServer');
                    }
                    else {
                        schedule(IDLE-CHECK-SECONDS, 'idle-check', $generation);
                    }
                }
            }
            else {
                $vow.break(X::Convex::Protocol.new(
                    detail => "unknown Live owner command '$kind'"
                )) if $vow.defined;
            }

            if $failure.defined {
                fail-connection(
                    $failure ~~ X::Convex::Protocol ?? 'ProtocolError' !! 'TransportError',
                    $failure.message
                );
            }
        }
        Nil
    }
}

our sub optional-log-lines($value --> Array) is export {
    $value ~~ Positional
        or die X::Convex::Protocol.new(detail => 'Live logLines must be an array');
    my @lines;
    for @$value -> $line {
        $line ~~ Str
            or die X::Convex::Protocol.new(
                detail => 'Live logLines must contain only strings'
            );
        @lines.push: $line;
    }
    @lines
}

# The pinned profile wants a per-connection session identifier. It is only used
# by the deployment to correlate connections, so a 128-bit random hex string is
# sufficient and avoids adding a UUID dependency to the runtime closure.
our sub new-session-id(--> Str) is export {
    (^16).map({ (^256).pick.fmt('%02x') }).join
}
