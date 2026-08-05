package Adapter;

use strict;
use warnings;

use FindBin;
use lib $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../..";
use lib join '/', ( $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../.." ),
  'tests', 'conformance';

use Errno qw(EAGAIN EINTR EWOULDBLOCK);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use JSON::PP    qw(decode_json encode_json);
use Socket      qw(MSG_DONTWAIT SHUT_RDWR SOL_SOCKET SO_TYPE);
use Time::HiRes qw(sleep time);
use threads;

use Convex;
use RelayGuard;

use constant OUTPUT_WRITE_DEADLINE_SECONDS => 1;

sub retire_output {
    my ($output) = @_;
    return unless defined fileno $output;
    eval { shutdown $output, SHUT_RDWR; };
    eval { close $output; };
    return;
}

sub set_output_nonblocking {
    my ($output) = @_;

    # MSG_DONTWAIT keeps a duplex TCP controller input blocking while writes
    # remain bounded. Pipes such as stdout need O_NONBLOCK on their own fd.
    return if defined getsockopt $output, SOL_SOCKET, SO_TYPE;
    my $flags = fcntl $output, F_GETFL, 0;
    die Convex::Errors::transport_error( "inspect adapter output flags: $!",
        'adapter-output' )
      unless defined $flags;
    my $changed = fcntl $output, F_SETFL, $flags | O_NONBLOCK;
    die Convex::Errors::transport_error( "make adapter output nonblocking: $!",
        'adapter-output' )
      unless defined $changed;
    return;
}

sub write_complete {
    my ( $output, $bytes ) = @_;
    my $deadline  = time + OUTPUT_WRITE_DEADLINE_SECONDS;
    my $length    = length $bytes;
    my $offset    = 0;
    my $is_socket = defined getsockopt $output, SOL_SOCKET, SO_TYPE;
    local $SIG{PIPE} = 'IGNORE';

    my $complete = eval {
        while ( $offset < $length ) {
            my $remaining = $deadline - time;
            die Convex::Errors::transport_error(
                "adapter output timed out after $offset of $length bytes",
                'adapter-output', )
              if $remaining <= 0;
            my @ready = IO::Select->new($output)->can_write($remaining);
            die Convex::Errors::transport_error(
                "adapter output timed out after $offset of $length bytes",
                'adapter-output', )
              unless @ready;
            my $count =
              $is_socket
              ? send( $output, substr( $bytes, $offset ), MSG_DONTWAIT )
              : syswrite $output, $bytes, $length - $offset, $offset;
            if ( !defined $count ) {
                next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
                die Convex::Errors::transport_error(
                    "adapter output failed after $offset of $length bytes: $!",
                    'adapter-output',
                );
            }
            die Convex::Errors::transport_error(
                "adapter output closed after $offset of $length bytes",
                'adapter-output', )
              if $count == 0;
            $offset += $count;
        }
        1;
    };
    if ( !$complete ) {
        my $error = $@;

        # A partial NDJSON line cannot be repaired. Force-retire the controller
        # stream so no later event can append to corrupted output.
        retire_output($output);
        die $error;
    }
    return;
}

sub write_event {
    my ( $output, $guard, $event ) = @_;
    $guard->synchronized(
        sub {
            write_complete( $output, encode_json($event) . "\n" );
            return;
        }
    );
    return;
}

sub write_subscription_event {
    my ( $output, $guard, $subscription_id, $generation, $event ) = @_;
    return $guard->publish_if_current(
        $subscription_id,
        $generation,
        sub {
            write_complete( $output, encode_json($event) . "\n" );
            return;
        }
    );
}

sub error_details {
    my ($error) = @_;
    my $kind    = ref($error) || 'TransportError';
    my %details = (
        name    => $kind =~ /([^:]+)\z/ ? $1 : $kind,
        message => "$error",
    );
    $details{data} = $error->{data}
      if ref($error) && exists $error->{data};
    return \%details;
}

sub invalidate_relay {
    my ( $subscription_id, $guard, $subscriptions, $relays, $retired_relays ) =
      @_;

    # Invalidation happens before the ACK and shares the publication lock.
    # A relay paused after dequeue can resume later, but it cannot publish.
    $guard->advance($subscription_id);
    my $subscription = delete $subscriptions->{$subscription_id};
    my $relay        = delete $relays->{$subscription_id};
    push @{$retired_relays}, $relay if $relay;
    $subscription->close if $subscription;
    return;
}

sub reap_relays {
    my ( $retired_relays, $wait_seconds ) = @_;
    my $deadline = time + $wait_seconds;
    while ( @{$retired_relays} ) {
        my @still_running;
        for my $relay ( @{$retired_relays} ) {
            if ( $relay->is_joinable ) {
                $relay->join;
            }
            else {
                push @still_running, $relay;
            }
        }
        @{$retired_relays} = @still_running;
        last if !@still_running || time >= $deadline;
        sleep 0.01;
    }
    return;
}

sub stop_adapter_lifecycle {
    my ( $guard, $subscriptions, $relays, $retired_relays, $client_ref ) = @_;
    my @errors;

    # EOF and controller disconnects do not carry a close command, but they
    # still own the same local lifecycle. Invalidate every relay first so none
    # can publish while the controller stream is already gone.
    for my $subscription_id ( keys %{$subscriptions} ) {
        eval {
            invalidate_relay(
                $subscription_id, $guard, $subscriptions,
                $relays,          $retired_relays,
            );
            1;
        } or push @errors, "$@";
    }

    if ( ${$client_ref} ) {
        eval { ${$client_ref}->close; 1 } or push @errors, "$@";
        ${$client_ref} = undef;
    }

    # Closing each subscription wakes a relay blocked in next_update. Await
    # every tracked relay so Perl exits with no running or unjoined threads.
    reap_relays( $retired_relays, 2 );
    push @errors, 'adapter relay did not stop within two seconds'
      if @{$retired_relays};
    return join q{}, @errors;
}

sub run_adapter {
    my ( $input, $output, $options ) = @_;
    $options //= {};
    $output->autoflush(1);
    set_output_nonblocking($output);
    my $guard  = RelayGuard->new;
    my $client = $options->{client};
    my %subscriptions;
    my %relays;
    my @retired_relays;
    my $done         = 0;
    my $stop_reading = 0;

    while ( my $line = <$input> ) {
        my $command      = eval { decode_json($line) };
        my $decode_error = $@;
        if ($decode_error) {
            my $wrote = eval {
                write_event(
                    $output, $guard,
                    {
                        type  => 'error',
                        error => {
                            name    => 'ProtocolError',
                            message => "decode command: $decode_error",
                        },
                    }
                );
                1;
            };
            $stop_reading = 1 unless $wrote;
            last if $stop_reading;
            next;
        }

        my $id = $command->{id};
        my $ok = eval {
            if ( $command->{op} eq 'hello' ) {
                die 'unsupported adapter protocol version'
                  unless $command->{protocolVersion} == 1;
                write_event(
                    $output, $guard,
                    {
                        protocolVersion => 1,
                        id              => $id,
                        type            => 'ready',
                        language        => 'perl',
                        implementation  => "native-perl-$]",
                        runtime         => "perl-$]",
                    }
                );
            }
            elsif ( $command->{op} =~ /\A(query|mutation|action)\z/ ) {
                my $operation = $1;
                $client //= Convex->new( $ENV{CONVEX_URL},
                    bearer_token => $ENV{CONVEX_AUTH_TOKEN}, );
                my $result = $client->$operation( $command->{path},
                    $command->{args} || {} );
                write_event(
                    $output, $guard,
                    {
                        id    => $id,
                        type  => 'result',
                        value => $result->{value},
                        logs  => $result->{logs},
                    }
                );
            }
            elsif ( $command->{op} eq 'setAuth' ) {
                $client //= Convex->new( $ENV{CONVEX_URL} );
                $client->set_auth( $command->{token} );
                write_event( $output, $guard, { id => $id, type => 'ack' } );
            }
            elsif ( $command->{op} eq 'subscribe' ) {
                $client //= Convex->new( $ENV{CONVEX_URL} );
                my $subscription_id = $command->{subscriptionId};
                invalidate_relay(
                    $subscription_id, $guard, \%subscriptions,
                    \%relays,         \@retired_relays,
                );
                my $generation   = $guard->advance($subscription_id);
                my $subscription = $client->subscribe( $command->{path},
                    $command->{args} || {} );
                $subscriptions{$subscription_id} = $subscription;
                write_event( $output, $guard, { id => $id, type => 'ack' } );

                $relays{$subscription_id} = threads->create(
                    sub {
                        while (1) {
                            my $update = eval { $subscription->next_update };
                            my $error  = $@;
                            last
                              if $error
                              && ref($error) eq 'Convex::ClosedError';
                            $options->{relay_after_dequeue}->(
                                $subscription_id, $generation, $update, $error,
                            ) if $options->{relay_after_dequeue};
                            my $event;
                            if ( $error || $update->{error} ) {
                                my $reported_error = $error || $update->{error};
                                $event = {
                                    type           => 'subscription',
                                    subscriptionId => $subscription_id,
                                    error => error_details($reported_error),
                                };
                                $event->{logs} = $reported_error->{logs}
                                  if ref($reported_error) eq
                                  'Convex::FunctionError';
                            }
                            else {
                                $event = {
                                    type           => 'subscription',
                                    subscriptionId => $subscription_id,
                                    value          => $update->{value},
                                    logs           => $update->{logs} || [],
                                };
                            }
                            my $wrote = eval {
                                write_subscription_event( $output, $guard,
                                    $subscription_id, $generation, $event, );
                                1;
                            };
                            last unless $wrote;
                        }
                        return;
                    }
                );
            }
            elsif ( $command->{op} eq 'unsubscribe' ) {
                invalidate_relay( $command->{subscriptionId},
                    $guard, \%subscriptions, \%relays, \@retired_relays, );
                write_event( $output, $guard, { id => $id, type => 'ack' } );
            }
            elsif ( $command->{op} eq 'debugDisconnect' ) {
                $client->debug_disconnect_for_adapter;
                write_event( $output, $guard, { id => $id, type => 'ack' } );
            }
            elsif ( $command->{op} eq 'close' ) {
                my $cleanup_error = stop_adapter_lifecycle(
                    $guard, \%subscriptions, \%relays,
                    \@retired_relays, \$client,
                );
                die $cleanup_error if length $cleanup_error;
                $done = 1;
                write_event( $output, $guard, { id => $id, type => 'closed' } );
            }
            else {
                die 'unknown adapter operation';
            }
            1;
        };
        if ( !$ok ) {
            my $error = $@;
            if ( ref($error) eq 'Convex::TransportError'
                && ( $error->{operation} // q{} ) eq 'adapter-output' )
            {
                $stop_reading = 1;
            }
            else {
                my $event = {
                    id    => $id,
                    type  => 'error',
                    error => error_details($error),
                };
                $event->{logs} = $error->{logs}
                  if ref($error) eq 'Convex::FunctionError';
                my $wrote = eval { write_event( $output, $guard, $event ); 1 };
                $stop_reading = 1 unless $wrote;
            }
        }
        reap_relays( \@retired_relays, 0 );
        last if $done || $stop_reading;
    }

    # EOF has no command id and the output may already be closed. Perform the
    # close-equivalent lifecycle without trying to emit a final protocol event.
    if ( !$done ) {
        my $cleanup_error =
          stop_adapter_lifecycle( $guard, \%subscriptions, \%relays,
            \@retired_relays, \$client, );
        die $cleanup_error if length $cleanup_error;
    }
    return;
}

sub main {
    if ( $ENV{ADAPTER_LISTEN} ) {
        my ( $host, $port ) = split /:/, $ENV{ADAPTER_LISTEN}, 2;
        my $server = IO::Socket::INET->new(
            LocalAddr => $host,
            LocalPort => $port,
            Listen    => 1,
            ReuseAddr => 1,
        ) or die "listen: $!";
        my $socket = $server->accept;
        run_adapter( $socket, $socket );
        close $socket
          or die "close controller socket: $!"
          if defined fileno $socket;
        close $server or die "close adapter listener: $!";
    }
    else {
        run_adapter( *STDIN, *STDOUT );
    }
    return;
}

1;
