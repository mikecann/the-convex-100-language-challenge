use strict;
use warnings;
use threads;
use Thread::Queue;

use Digest::SHA qw(sha1);
use FindBin;
use IO::Socket::INET;
use JSON::PP     qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use Socket       qw(SOL_SOCKET SO_SNDBUF);
use Test::More;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin";
use Convex;
use Convex::Live;

use constant GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

$SIG{PIPE} = 'IGNORE';

sub read_exact {
    my ( $socket, $length ) = @_;
    my $out = q{};
    while ( length($out) < $length ) {
        my $read = sysread $socket, my $chunk, $length - length($out);
        return unless $read;
        $out .= $chunk;
    }
    return $out;
}

sub accept_websocket {
    my ($server) = @_;
    my $socket   = $server->accept;
    my $request  = <$socket>;
    my %headers;
    while ( my $line = <$socket> ) {
        $line =~ s/\r?\n\z//;
        last unless length $line;
        my ( $name, $value ) = split /:\s*/, $line, 2;
        $headers{ lc $name } = $value;
    }
    my $accept =
      encode_base64( sha1( $headers{'sec-websocket-key'} . GUID ), q{} );
    print {$socket} "HTTP/1.1 101 Switching Protocols\r\n";
    print {$socket} "Upgrade: websocket\r\nConnection: Upgrade\r\n";
    print {$socket} "Sec-WebSocket-Accept: $accept\r\n\r\n";
    return $socket;
}

sub read_client_json {
    my ($socket) = @_;
    my $header = read_exact( $socket, 2 );
    return unless defined $header;
    my ( $first, $second ) = unpack 'CC', $header;
    my $length = $second & 127;
    $length = unpack 'n',  read_exact( $socket, 2 ) if $length == 126;
    $length = unpack 'Q>', read_exact( $socket, 8 ) if $length == 127;
    my $mask    = read_exact( $socket, 4 );
    my $payload = read_exact( $socket, $length );
    my $decoded = join q{}, map {
        chr( ord( substr $payload, $_, 1 ) ^ ord( substr $mask, $_ % 4, 1 ) )
    } 0 .. $length - 1;
    return decode_json($decoded);
}

sub write_server_text {
    my ( $socket, $payload ) = @_;
    my $length = length $payload;
    my $header = pack 'C', 0x81;
    $header .=
      $length < 126
      ? pack( 'C', $length )
      : pack( 'Cn', 126, $length );
    print {$socket} $header . $payload;
    return;
}

sub write_server_json {
    my ( $socket, $value ) = @_;
    write_server_text( $socket, encode_json($value) );
    return;
}

sub version {
    my ( $query_set, $timestamp ) = @_;
    return { querySet => $query_set, identity => 0, ts => $timestamp };
}

sub transition {
    my ( $start, $end, @modifications ) = @_;
    return {
        type          => 'Transition',
        startVersion  => $start,
        endVersion    => $end,
        modifications => \@modifications,
    };
}

sub updated {
    my ( $id, $count ) = @_;
    return {
        type     => 'QueryUpdated',
        queryId  => $id,
        value    => { count => $count },
        logLines => [],
    };
}

sub test_server {
    my ($handler) = @_;
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 8,
        ReuseAddr => 1,
    ) or die "listen: $!";
    my $url    = 'http://127.0.0.1:' . $server->sockport;
    my $errors = Thread::Queue->new;
    my $thread = threads->create(
        sub {
            eval { $handler->($server); 1 }
              or $errors->enqueue("$@");
            return;
        }
    );
    return ( $server, $url, $thread, $errors );
}

sub finish_server {
    my ( $server, $thread, $errors ) = @_;
    close $server;
    $thread->join;
    fail( 'fixture server failed: ' . $errors->dequeue ) if $errors->pending;
    return;
}

sub constrained_connector {
    return sub {
        my ( $url, $client_version ) = @_;
        my $socket = Convex::WebSocket->connect( $url, $client_version );
        setsockopt $socket->io, SOL_SOCKET, SO_SNDBUF, pack( 'i', 4_096 )
          or die "set fixture send buffer: $!";
        return $socket;
    };
}

{
    ok(
        Convex::Live::_versions_equal(
            {
                ts       => 'same',
                identity => 3,
                querySet => 7,
            },
            {
                querySet => 7,
                ts       => 'same',
                identity => 3,
            }
        ),
        'transition versions compare fields, not JSON key order'
    );
}

{
    my $manager      = bless {}, 'FakeManager';
    my $subscription = Convex::Subscription->new( $manager, 7 );
    $subscription->deliver( { value => { count => $_ } } ) for 0 .. 16;
    my @observed =
      map { $subscription->next_update(0.1)->{value}{count} } 1 .. 16;
    is_deeply(
        \@observed,
        [ 1 .. 16 ],
        'slow consumers retain only the newest sixteen Live values'
    );
    $subscription->finish;
}

{
    my $advance  = Thread::Queue->new;
    my $observed = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $socket     = accept_websocket($listener);
            my $connect    = read_client_json($socket);
            my $add        = read_client_json($socket);
            my $id         = $add->{modifications}[0]{queryId};
            $observed->enqueue( $connect->{type},
                $add->{modifications}[0]{type},
            );
            write_server_json(
                $socket,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'AQAAAAAAAAA=' ),
                    updated( $id, 0 ),
                )
            );
            $advance->dequeue;
            write_server_json(
                $socket,
                transition(
                    version( 1, 'AQAAAAAAAAA=' ),
                    version( 1, 'AgAAAAAAAAA=' ),
                    updated( $id, 1 ),
                )
            );
            $advance->dequeue;
            write_server_json(
                $socket,
                transition(
                    version( 1, 'AgAAAAAAAAA=' ),
                    version( 1, 'AwAAAAAAAAA=' ),
                    {
                        type         => 'QueryFailed',
                        queryId      => $id,
                        errorMessage => 'room empty',
                        errorData    => { code => 'ROOM_EMPTY' },
                        logLines     => [],
                    },
                )
            );
            $advance->dequeue;
            write_server_json(
                $socket,
                transition(
                    version( 1, 'AwAAAAAAAAA=' ),
                    version( 1, 'BAAAAAAAAAA=' ),
                    updated( $id, 2 ),
                )
            );
            my $remove = read_client_json($socket);
            $observed->enqueue( $remove->{modifications}[0]{type} );
            close $socket;
            return;
        }
    );
    my $client       = Convex->new($url);
    my $subscription = $client->subscribe( 'demo:state', { room => 'matrix' } );
    is( $observed->dequeue, 'Connect', 'Live sends Connect first' );
    is( $observed->dequeue, 'Add',     'Live sends Add' );
    my $initial_update = $subscription->next_update(2);
    die $initial_update->{error} if $initial_update->{error};
    my $initial_count = 0 + $initial_update->{value}{count};
    is( $initial_count, 0, 'initial QueryUpdated' );
    $advance->enqueue(1);
    is( $subscription->next_update(2)->{value}{count},
        1, 'external QueryUpdated' );
    $advance->enqueue(1);
    my $failed = $subscription->next_update(2);
    is(
        ref( $failed->{error} ),
        'Convex::FunctionError',
        'QueryFailed is typed'
    );
    is( $failed->{error}{data}{code},
        'ROOM_EMPTY', 'QueryFailed keeps error data' );
    $advance->enqueue(1);
    is( $subscription->next_update(2)->{value}{count},
        2, 'QueryFailed recovers' );
    $subscription->close;
    is( $observed->dequeue, 'Remove', 'unsubscribe sends Remove' );
    $client->close;
    finish_server( $server, $thread, $errors );
}

{
    my $connected = Thread::Queue->new;
    my $change    = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $count = 0;
            for my $connection_index ( 0 .. 5 ) {
                my $socket  = accept_websocket($listener);
                my $connect = read_client_json($socket);
                my $add     = read_client_json($socket);
                my $id      = $add->{modifications}[0]{queryId};
                $connected->enqueue($connect);
                my $hydration_ts = "hydrate-$connection_index";
                write_server_json(
                    $socket,
                    transition(
                        version( 0, 'AAAAAAAAAAA=' ),
                        version( 1, $hydration_ts ),
                        updated( $id, $count ),
                    )
                );
                if ( $connection_index > 0 ) {
                    $change->dequeue;
                    $count += 1;
                    write_server_json(
                        $socket,
                        transition(
                            version( 1, $hydration_ts ),
                            version( 1, "changed-$connection_index" ),
                            updated( $id, $count ),
                        )
                    );
                }
                read_exact( $socket, 1 ) if $connection_index < 5;
                close $socket;
            }
            return;
        }
    );
    my $client = Convex->new($url);
    my $subscription =
      $client->subscribe( 'demo:state', { room => 'reconnect' } );
    my $first_connect = $connected->dequeue;
    is( $first_connect->{connectionCount},
        0, 'initial connectionCount is zero' );
    is( $subscription->next_update(2)->{value}{count},
        0, 'initial reconnect value' );
    for my $attempt ( 1 .. 5 ) {
        $client->debug_disconnect_for_adapter;
        my $connect = $connected->dequeue_timed( time + 2 );
        is( $connect->{connectionCount}, $attempt, "reconnect $attempt count" );
        is( $connect->{lastCloseReason},
            'DebugDisconnect', "reconnect $attempt reason" );
        ok(
            defined $connect->{maxObservedTimestamp},
            "reconnect $attempt keeps timestamp"
        );
        eval { $subscription->next_update(0.15) };
        like( "$@", qr/timed out/,
            "reconnect $attempt suppresses unchanged hydration" );
        $change->enqueue(1);
        is( $subscription->next_update(2)->{value}{count},
            $attempt, "reconnect $attempt delivers change" );
    }
    $subscription->close;
    $client->close;
    finish_server( $server, $thread, $errors );
}

{
    my $continue = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $first = accept_websocket($listener);
            read_client_json($first);
            my $add = read_client_json($first);
            my $id  = $add->{modifications}[0]{queryId};
            write_server_json(
                $first,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'initial' ),
                    updated( $id, 0 ),
                )
            );
            $continue->dequeue;
            write_server_text( $first, '{malformed-json' );
            close $first;

            my $second = accept_websocket($listener);
            read_client_json($second);
            $add = read_client_json($second);
            $id  = $add->{modifications}[0]{queryId};
            write_server_json(
                $second,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'rehydrate-one' ),
                    updated( $id, 0 ),
                )
            );
            write_server_json(
                $second,
                {
                    type          => 'Transition',
                    startVersion  => version( 1, 'rehydrate-one' ),
                    endVersion    => version( 1, 'malformed-shape' ),
                    modifications => {},
                }
            );
            close $second;

            my $third = accept_websocket($listener);
            read_client_json($third);
            $add = read_client_json($third);
            $id  = $add->{modifications}[0]{queryId};
            write_server_json(
                $third,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'rehydrate-two' ),
                    updated( $id, 0 ),
                )
            );
            close $third;

            my $fourth = accept_websocket($listener);
            read_client_json($fourth);
            $add = read_client_json($fourth);
            $id  = $add->{modifications}[0]{queryId};
            write_server_json(
                $fourth,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'rehydrate-three' ),
                    updated( $id, 0 ),
                )
            );
            $continue->dequeue;
            write_server_json(
                $fourth,
                transition(
                    version( 1, 'rehydrate-three' ),
                    version( 1, 'recovered' ),
                    updated( $id, 1 ),
                )
            );
            read_exact( $fourth, 1 );
            close $fourth;
            return;
        }
    );
    my $client       = Convex->new($url);
    my $subscription = $client->subscribe( 'demo:state', { room => 'errors' } );
    is( $subscription->next_update(2)->{value}{count},
        0, 'error fixture initial value' );
    $continue->enqueue(1);
    is( ref( $subscription->next_update(2)->{error} ),
        'Convex::ProtocolError',
        'malformed JSON is a structured protocol error' );
    is( ref( $subscription->next_update(3)->{error} ),
        'Convex::ProtocolError', 'malformed Transition is a protocol error' );
    is( ref( $subscription->next_update(3)->{error} ),
        'Convex::TransportError', 'transport error is structured' );
    $continue->enqueue(1);
    is( $subscription->next_update(3)->{value}{count},
        1, 'valid value follows protocol and transport recovery' );
    $subscription->close;
    $client->close;
    finish_server( $server, $thread, $errors );
}

{
    my $observed = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $first = accept_websocket($listener);
            read_client_json($first);
            my $prefix = read_exact( $first, 4_096 );
            $observed->enqueue( length( $prefix // q{} ) );
            close $first;

            my $second  = accept_websocket($listener);
            my $connect = read_client_json($second);
            my $add     = read_client_json($second);
            my $id      = $add->{modifications}[0]{queryId};
            $observed->enqueue(
                $connect->{connectionCount},
                length $add->{modifications}[0]{args}[0]{blob},
            );
            write_server_json(
                $second,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'write-recovered' ),
                    updated( $id, 7 ),
                )
            );
            read_client_json($second);
            close $second;
            return;
        }
    );
    my $manager = Convex::Live->new( $url, 'perl-write-recovery',
        connector => constrained_connector(), );
    my $subscription =
      $manager->subscribe( 'demo:state',
        { room => 'partial-write', blob => 'x' x ( 512 * 1_024 ) },
      );
    is(
        ref( $subscription->next_update(3)->{error} ),
        'Convex::TransportError',
        'partial Add write reports a transport error'
    );
    is( $observed->dequeue, 4_096,
        'partial peer receives only a frame prefix' );
    is( $observed->dequeue, 1,
        'partial write recovery opens a new connection' );
    is(
        $observed->dequeue,
        512 * 1_024,
        'reconnect resends the complete active Add'
    );
    is( $subscription->next_update(3)->{value}{count},
        7, 'subscription recovers after partial write retirement' );
    $subscription->close;
    $manager->close;
    finish_server( $server, $thread, $errors );
}

{
    my $stalled = Thread::Queue->new;
    my $release = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $socket = accept_websocket($listener);
            read_client_json($socket);
            my $add = read_client_json($socket);
            my $id  = $add->{modifications}[0]{queryId};
            write_server_json(
                $socket,
                transition(
                    version( 0, 'AAAAAAAAAAA=' ),
                    version( 1, 'blocked-write-initial' ),
                    updated( $id, 0 ),
                )
            );
            my $prefix = read_exact( $socket, 4_096 );
            $stalled->enqueue( length( $prefix // q{} ) );
            $release->dequeue;
            close $socket;
            return;
        }
    );
    my $manager = Convex::Live->new( $url, 'perl-write-deadline',
        connector => constrained_connector(), );
    my $subscription =
      $manager->subscribe( 'demo:state', { room => 'blocked-write' } );
    is( $subscription->next_update(2)->{value}{count},
        0, 'blocking write fixture starts connected' );

    my $large_reply = Thread::Queue->new;
    my $large_queue = Thread::Queue->new;
    $manager->{commands}->enqueue(
        {
            type => 'subscribe',
            data => {
                query_id => 99,
                path     => 'demo:state',
                args     => {
                    room => 'blocked-large-write',
                    blob => 'x' x ( 512 * 1_024 ),
                },
                queue => $large_queue,
            },
            reply => $large_reply,
        }
    );
    is( $stalled->dequeue, 4_096,
        'blocking peer stalls a real partial Add frame' );

    my $small_unsubscribe = Thread::Queue->new;
    my $large_unsubscribe = Thread::Queue->new;
    $manager->{commands}->enqueue(
        {
            type  => 'unsubscribe',
            data  => { query_id => 0 },
            reply => $small_unsubscribe,
        },
        {
            type  => 'unsubscribe',
            data  => { query_id => 99 },
            reply => $large_unsubscribe,
        },
    );
    my $started = time;
    $manager->close;
    cmp_ok( time - $started,
        '<', 2.5,
        'stalled write cannot block unsubscribe and close past deadline' );
    ok( $large_reply->pending,
        'blocked Add command completes after retirement' );
    ok( $small_unsubscribe->pending,
        'existing unsubscribe completes after write retirement' );
    ok( $large_unsubscribe->pending,
        'partial Add unsubscribe completes after write retirement' );
    $release->enqueue(1);
    finish_server( $server, $thread, $errors );
}

{
    my $partial_sent = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $socket = accept_websocket($listener);
            read_client_json($socket);
            read_client_json($socket);
            print {$socket} pack 'C', 0x81;
            $partial_sent->enqueue(1);
            read_exact( $socket, 1 );
            close $socket;
            return;
        }
    );
    my $client = Convex->new($url);
    $client->subscribe( 'demo:state', { room => 'partial-frame' } );
    $partial_sent->dequeue;
    my $started = time;
    $client->close;
    cmp_ok( time - $started, '<', 2.5,
        'close is bounded during partial frame' );
    finish_server( $server, $thread, $errors );
}

{
    my $partial_sent = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $socket = $listener->accept;
            <$socket>;
            while ( my $line = <$socket> ) {
                last if $line eq "\r\n";
            }
            print {$socket} 'H';
            $partial_sent->enqueue(1);
            read_exact( $socket, 1 );
            close $socket;
            return;
        }
    );
    my $client = Convex->new($url);
    $client->subscribe( 'demo:state', { room => 'partial-upgrade' } );
    $partial_sent->dequeue;
    my $started = time;
    $client->close;
    cmp_ok( time - $started,
        '<', 2.5, 'close is bounded during partial upgrade' );
    finish_server( $server, $thread, $errors );
}

{
    my $ready = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $socket = accept_websocket($listener);
            read_client_json($socket);
            read_client_json($socket);
            $ready->enqueue(1);
            read_exact( $socket, 1 );
            close $socket;
            return;
        }
    );
    my $client = Convex->new($url);
    $client->subscribe( 'demo:state', { room => 'idle-peer' } );
    $ready->dequeue;
    my $started = time;
    $client->close;
    cmp_ok( time - $started, '<', 1.5, 'close is bounded for an idle peer' );
    finish_server( $server, $thread, $errors );
}

{
    my $ready = Thread::Queue->new;
    my ( $server, $url, $thread, $errors ) = test_server(
        sub {
            my ($listener) = @_;
            my $socket = accept_websocket($listener);
            read_client_json($socket);
            read_client_json($socket);
            $ready->enqueue(1);
            for ( 1 .. 500 ) {
                last unless eval {
                    write_server_json( $socket, { type => 'Ping' } );
                    1;
                };
                sleep 0.002;
            }
            close $socket;
            return;
        }
    );
    my $client = Convex->new($url);
    $client->subscribe( 'demo:state', { room => 'busy-peer' } );
    $ready->dequeue;
    my $started = time;
    $client->close;
    cmp_ok( time - $started,
        '<', 1.5, 'close is bounded for a continuously sending peer' );
    finish_server( $server, $thread, $errors );
}

done_testing;
