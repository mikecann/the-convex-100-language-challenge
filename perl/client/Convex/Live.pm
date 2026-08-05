package Convex::Live;

use strict;
use warnings;

use threads;
use IO::Select;
use JSON::PP;
use Thread::Queue;
use Time::HiRes qw(sleep time);

use Convex::Errors;
use Convex::Subscription;
use Convex::WebSocket;

use constant INITIAL_BACKOFF_SECONDS => 0.1;
use constant MAX_BACKOFF_SECONDS     => 15;
use constant INACTIVITY_SECONDS      => 30;

my $CANONICAL_JSON = JSON::PP->new->canonical->allow_nonref;

sub new {
    my ( $class, $deployment_url, $client_version ) = @_;
    my $self = bless {
        url            => _live_url($deployment_url),
        client_version => $client_version,
        commands       => Thread::Queue->new,
        next_id        => 0,
        stopped        => 0,
    }, $class;
    $self->{worker} = threads->create( sub { $self->_run } );
    return $self;
}

sub request {
    my ( $self, $type, $data ) = @_;
    die Convex::Errors::closed_error('Convex Live manager is closed')
      if $self->{stopped};
    my $reply = Thread::Queue->new;
    $self->{commands}->enqueue(
        {
            type  => $type,
            data  => $data // {},
            reply => $reply,
        }
    );
    my $out = $reply->dequeue;
    die $out->{error} if $out->{error};
    return $out->{value};
}

sub subscribe {
    my ( $self, $path, $args ) = @_;
    die Convex::Errors::closed_error('Convex Live manager is closed')
      if $self->{stopped};
    my $id           = $self->{next_id}++;
    my $subscription = Convex::Subscription->new( $self, $id );
    $self->request(
        'subscribe',
        {
            query_id => $id,
            path     => $path,
            args     => $args,
            queue    => $subscription->{queue},
        }
    );
    return $subscription;
}

sub debug_disconnect {
    my ($self) = @_;
    return $self->request('debug_disconnect');
}

sub close {
    my ($self) = @_;
    return if $self->{stopped};

    # Queue shutdown while requests are still accepted. Marking stopped first
    # would reject our own command and leave the sole worker running forever.
    my $reply = Thread::Queue->new;
    $self->{commands}
      ->enqueue( { type => 'close', data => {}, reply => $reply } );
    my $out = $reply->dequeue;
    $self->{stopped} = 1;
    $self->{worker}->join if $self->{worker};
    die $out->{error}     if $out->{error};
    return;
}

sub _run {
    my ($self) = @_;
    my %subscriptions;
    my %last_results;
    my $socket;
    my $query_version     = 0;
    my $remote_version    = _zero_version();
    my $connection_count  = 0;
    my $last_close_reason = 'InitialConnect';
    my $max_observed_ts;
    my $backoff              = INITIAL_BACKOFF_SECONDS;
    my $retry_at             = 0;
    my $last_server_response = time;
    my $closed               = 0;

    while ( !$closed ) {
        while ( my $command = $self->{commands}->dequeue_nb ) {
            my ( $type, $data, $reply ) =
              @{$command}{qw(type data reply)};
            my $ok = eval {
                if ( $type eq 'subscribe' ) {
                    my $id = $data->{query_id};
                    $subscriptions{$id} = { %{$data}, finished => 0, };
                    $reply->enqueue( { value => undef } );
                    if ($socket) {
                        _modify_query_set( $socket, \$query_version,
                            [ _add_modification( $id, $subscriptions{$id} ) ],
                        );
                    }
                    else {
                        $retry_at = time;
                    }
                }
                elsif ( $type eq 'unsubscribe' ) {
                    my $id    = $data->{query_id};
                    my $state = delete $subscriptions{$id};
                    delete $last_results{$id};
                    if ($state) {

                        # Invalidate and wake the relay before publishing the
                        # acknowledgement through the adapter.
                        _finish_state($state);
                        _modify_query_set( $socket, \$query_version,
                            [ { type => 'Remove', queryId => 0 + $id } ],
                        ) if $socket;
                    }
                    $retry_at = 0 unless %subscriptions;
                    $reply->enqueue( { value => undef } );
                }
                elsif ( $type eq 'debug_disconnect' ) {
                    die Convex::Errors::transport_error(
                        'Live WebSocket is not connected', 'live' )
                      unless $socket;
                    $socket->close_now;
                    $socket = undef;
                    $connection_count += 1;
                    $last_close_reason = 'DebugDisconnect';
                    $query_version     = 0;
                    $remote_version    = _zero_version();
                    $retry_at          = time;

                    # The old connection is gone and reconnect work is now
                    # scheduled, so the adapter may safely publish its ACK.
                    $reply->enqueue( { value => undef } );
                }
                elsif ( $type eq 'close' ) {
                    $closed = 1;
                    $socket->close_now if $socket;
                    $socket = undef;
                    $reply->enqueue( { value => undef } );
                }
                else {
                    die Convex::Errors::protocol_error(
                        "unknown Live command $type");
                }
                1;
            };
            $reply->enqueue( { error => $@ } ) unless $ok;
        }
        last if $closed;

        if ( !$socket && %subscriptions && time >= $retry_at ) {
            my $connected = eval {
                $socket = Convex::WebSocket->connect( $self->{url},
                    $self->{client_version} );
                $query_version        = 0;
                $remote_version       = _zero_version();
                $last_server_response = time;
                my $connect = {
                    type            => 'Connect',
                    sessionId       => _uuid(),
                    connectionCount => $connection_count,
                    lastCloseReason => $last_close_reason,
                    clientTs        => 0,
                };
                $connect->{maxObservedTimestamp} = $max_observed_ts
                  if defined $max_observed_ts;
                $socket->write_json($connect);
                _modify_query_set(
                    $socket,
                    \$query_version,
                    [
                        map  { _add_modification( $_, $subscriptions{$_} ) }
                        sort { $a <=> $b } keys %subscriptions
                    ],
                );

                # A successful handshake resets transport backoff.
                $backoff = INITIAL_BACKOFF_SECONDS;
                1;
            };
            if ( !$connected ) {
                _publish_error( \%subscriptions, $@ );
                $socket->close_now if $socket;
                $socket            = undef;
                $last_close_reason = "$@";
                $connection_count += 1;
                $retry_at = time + $backoff;
                $backoff  = _next_backoff($backoff);
            }
        }

        if ($socket) {
            my @ready = IO::Select->new( $socket->io )->can_read(0.05);
            if ( @ready || $socket->pending ) {
                my $read_ok = eval {
                    my $raw = $socket->read_message;
                    die Convex::Errors::transport_error( 'server closed',
                        'live' )
                      unless defined $raw;
                    $last_server_response = time;
                    my $message = _decode_server_message($raw);
                    if ( ( $message->{type} // q{} ) eq 'Transition' ) {
                        _handle_transition(
                            $message,          \$remote_version,
                            \$max_observed_ts, \%last_results,
                            \%subscriptions,
                        );

                        # A valid transition proves a healthy connection too.
                        $backoff = INITIAL_BACKOFF_SECONDS;
                    }
                    elsif ( ( $message->{type} // q{} ) =~
                        /\A(?:Ping|MutationResponse|ActionResponse)\z/ )
                    {
                        $backoff = INITIAL_BACKOFF_SECONDS;
                    }
                    elsif ( ( $message->{type} // q{} ) eq 'TransitionChunk' ) {
                        die Convex::Errors::protocol_error(
                            'TransitionChunk assembly is not implemented');
                    }
                    else {
                        die Convex::Errors::protocol_error(
                            'unknown Live message');
                    }
                    1;
                };
                if ( !$read_ok ) {
                    _publish_error( \%subscriptions, $@ );
                    $socket->close_now if $socket;
                    $socket = undef;
                    $connection_count += 1;
                    $last_close_reason = "$@";
                    $query_version     = 0;
                    $remote_version    = _zero_version();
                    $retry_at          = time + $backoff;
                    $backoff           = _next_backoff($backoff);
                }
            }
            elsif ( time - $last_server_response > INACTIVITY_SECONDS ) {
                my $error =
                  Convex::Errors::transport_error( 'InactiveServer', 'live' );
                _publish_error( \%subscriptions, $error );
                $socket->close_now;
                $socket = undef;
                $connection_count += 1;
                $last_close_reason = 'InactiveServer';
                $query_version     = 0;
                $remote_version    = _zero_version();
                $retry_at          = time + $backoff;
                $backoff           = _next_backoff($backoff);
            }
        }
        else {
            sleep 0.02;
        }
    }

    _finish_state($_) for values %subscriptions;
    return;
}

sub _handle_transition {
    my ( $message, $remote_ref, $max_ts_ref,
        $last_results_ref, $subscriptions_ref )
      = @_;
    die Convex::Errors::protocol_error('Transition has malformed versions')
      unless _valid_version( $message->{startVersion} )
      && _valid_version( $message->{endVersion} );
    die Convex::Errors::protocol_error(
        'Transition modifications must be an array')
      unless ref( $message->{modifications} ) eq 'ARRAY';
    die Convex::Errors::protocol_error('Transition version mismatch')
      unless _versions_equal( $message->{startVersion}, ${$remote_ref} );

    my %changed;
    for my $modification ( @{ $message->{modifications} // [] } ) {
        die Convex::Errors::protocol_error(
            'Transition modification must be an object')
          unless ref($modification) eq 'HASH';
        my $id = $modification->{queryId};
        die Convex::Errors::protocol_error(
            'Transition modification requires queryId')
          unless defined $id && !ref($id);
        if ( ( $modification->{type} // q{} ) eq 'QueryUpdated' ) {
            my $update = {
                value => $modification->{value},
                logs  => $modification->{logLines} // [],
            };
            my $previous = $last_results_ref->{$id};

            # Reconnect hydration is not a new application value. Keep the
            # previous result through disconnect and suppress only equality.
            if (  !$previous
                || $previous->{error}
                || !_json_equal( $previous->{value}, $update->{value} ) )
            {
                $changed{$id} = $update;
            }
            $last_results_ref->{$id} = $update;
        }
        elsif ( ( $modification->{type} // q{} ) eq 'QueryFailed' ) {
            my $error = Convex::Errors::function_error(
                $modification->{errorMessage} // 'query failed',
                $modification->{errorData},
                $modification->{logLines} // [],
            );
            my $update = { error => $error };
            $last_results_ref->{$id} = $update;
            $changed{$id} = $update;
        }
        elsif ( ( $modification->{type} // q{} ) eq 'QueryRemoved' ) {
            delete $last_results_ref->{$id};
        }
        else {
            die Convex::Errors::protocol_error(
                'unknown Transition modification');
        }
    }

    # Commit the complete transition before any subscriber observes it.
    ${$remote_ref} = $message->{endVersion};
    ${$max_ts_ref} = ${$remote_ref}->{ts};
    for my $id ( sort { $a <=> $b } keys %changed ) {
        _deliver_state( $subscriptions_ref->{$id}, $changed{$id} )
          if $subscriptions_ref->{$id};
    }
    return;
}

sub _decode_server_message {
    my ($raw)        = @_;
    my $message      = eval { JSON::PP::decode_json($raw) };
    my $decode_error = $@;
    die Convex::Errors::protocol_error("decode Live message: $decode_error")
      if $decode_error;
    die Convex::Errors::protocol_error('Live message must be an object')
      unless ref($message) eq 'HASH';
    return $message;
}

sub _publish_error {
    my ( $subscriptions, $error ) = @_;
    _deliver_state( $_, { error => $error } )
      for values %{$subscriptions};
    return;
}

sub _modify_query_set {
    my ( $socket, $version_ref, $modifications ) = @_;
    return unless @{$modifications};
    $socket->write_json(
        {
            type          => 'ModifyQuerySet',
            baseVersion   => ${$version_ref},
            newVersion    => ${$version_ref} + 1,
            modifications => $modifications,
        }
    );
    ${$version_ref} += 1;
    return;
}

sub _deliver_state {
    my ( $state, $update ) = @_;
    return if $state->{finished};
    $state->{queue}->dequeue_nb
      while $state->{queue}->pending >=
      Convex::Subscription::MAX_BUFFERED_UPDATES();
    $state->{queue}->enqueue( Convex::Subscription::_encode_update($update) );
    return;
}

sub _finish_state {
    my ($state) = @_;
    return if $state->{finished}++;
    $state->{queue}->dequeue_nb while $state->{queue}->pending;
    $state->{queue}->enqueue( JSON::PP::encode_json( { kind => 'closed' } ) );
    return;
}

sub _add_modification {
    my ( $id, $state ) = @_;
    return {
        type    => 'Add',
        queryId => 0 + $id,
        udfPath => $state->{path},
        args    => [ $state->{args} ],
    };
}

sub _versions_equal {
    my ( $left, $right ) = @_;
    return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH';
    return
         ( $left->{querySet} // -1 ) == ( $right->{querySet} // -2 )
      && ( $left->{identity} // -1 ) == ( $right->{identity} // -2 )
      && ( $left->{ts} // q{} ) eq ( $right->{ts} // q{missing} );
}

sub _valid_version {
    my ($version) = @_;
    return 0 unless ref($version) eq 'HASH';
    return 0
      unless defined $version->{querySet}
      && defined $version->{identity}
      && defined $version->{ts};
    return 0
      if ref( $version->{querySet} )
      || ref( $version->{identity} )
      || ref( $version->{ts} );
    return 1;
}

sub _json_equal {
    my ( $left, $right ) = @_;
    return $CANONICAL_JSON->encode($left) eq $CANONICAL_JSON->encode($right);
}

sub _zero_version {
    return { querySet => 0, identity => 0, ts => 'AAAAAAAAAAA=' };
}

sub _next_backoff {
    my ($current) = @_;
    return $current * 2 > MAX_BACKOFF_SECONDS
      ? MAX_BACKOFF_SECONDS
      : $current * 2;
}

sub _live_url {
    my ($url) = @_;
    die Convex::Errors::protocol_error('invalid deployment URL for Live')
      unless $url =~ m{\A(https?)://([^/?#]+)(/[^?#]*)?\z};
    my ( $scheme, $authority, $path ) = ( $1, $2, $3 // q{} );
    $scheme = $scheme eq 'https' ? 'wss' : 'ws';
    $path =~ s{/+\z}{};
    return "$scheme://$authority$path/api/sync";
}

sub _uuid {
    return sprintf '%08x-%04x-%04x-%04x-%012x',
      rand( 2**32 ), rand( 2**16 ), rand( 2**16 ),
      rand( 2**16 ), rand( 2**48 );
}

1;
