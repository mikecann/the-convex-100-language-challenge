#!/usr/local/bin/perl

use strict;
use warnings;

use FindBin;
use lib $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../..";
use lib join '/', ( $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../.." ),
  'tests', 'conformance';

use IO::Socket::INET;
use JSON::PP qw(decode_json encode_json);
use threads;

use Convex;
use RelayGuard;

sub write_event {
    my ( $output, $guard, $event ) = @_;
    $guard->synchronized(
        sub {
            print {$output} encode_json($event) . "\n";
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
            print {$output} encode_json($event) . "\n";
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

sub retire_relay {
    my ( $subscription_id, $guard, $subscriptions, $relays ) = @_;
    $guard->advance($subscription_id);
    my $subscription = delete $subscriptions->{$subscription_id};
    $subscription->close if $subscription;
    my $relay = delete $relays->{$subscription_id};
    $relay->join if $relay;
    return;
}

sub run_adapter {
    my ( $input, $output ) = @_;
    my $guard = RelayGuard->new;
    my $client;
    my %subscriptions;
    my %relays;
    my $done = 0;

    while ( my $line = <$input> ) {
        my $command = eval { decode_json($line) };
        if ($@) {
            write_event(
                $output, $guard,
                {
                    type  => 'error',
                    error => {
                        name    => 'ProtocolError',
                        message => "decode command: $@",
                    },
                }
            );
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
                retire_relay( $subscription_id, $guard, \%subscriptions,
                    \%relays );
                my $generation   = $guard->advance($subscription_id);
                my $subscription = $client->subscribe( $command->{path},
                    $command->{args} || {} );
                $subscriptions{$subscription_id} = $subscription;
                write_event( $output, $guard, { id => $id, type => 'ack' } );

                $relays{$subscription_id} = threads->create(
                    sub {
                        while (1) {
                            my $update = eval { $subscription->next_update };
                            last
                              if $@
                              && ref($@) eq 'Convex::ClosedError';
                            my $event;
                            if ( $@ || $update->{error} ) {
                                $event = {
                                    type           => 'subscription',
                                    subscriptionId => $subscription_id,
                                    error          =>
                                      error_details( $@ || $update->{error} ),
                                };
                            }
                            else {
                                $event = {
                                    type           => 'subscription',
                                    subscriptionId => $subscription_id,
                                    value          => $update->{value},
                                    logs           => $update->{logs} || [],
                                };
                            }
                            write_subscription_event( $output, $guard,
                                $subscription_id, $generation, $event );
                        }
                        return;
                    }
                );
            }
            elsif ( $command->{op} eq 'unsubscribe' ) {
                retire_relay( $command->{subscriptionId},
                    $guard, \%subscriptions, \%relays );
                write_event( $output, $guard, { id => $id, type => 'ack' } );
            }
            elsif ( $command->{op} eq 'debugDisconnect' ) {
                $client->debug_disconnect_for_adapter;
                write_event( $output, $guard, { id => $id, type => 'ack' } );
            }
            elsif ( $command->{op} eq 'close' ) {
                retire_relay( $_, $guard, \%subscriptions, \%relays )
                  for keys %subscriptions;
                $client->close if $client;
                write_event( $output, $guard, { id => $id, type => 'closed' } );
                $done = 1;
            }
            else {
                die 'unknown adapter operation';
            }
            1;
        };
        if ( !$ok ) {
            my $error = $@;
            my $event = {
                id    => $id,
                type  => 'error',
                error => error_details($error),
            };
            $event->{logs} = $error->{logs}
              if ref($error) eq 'Convex::FunctionError';
            write_event( $output, $guard, $event );
        }
        last if $done;
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
    }
    else {
        run_adapter( *STDIN, *STDOUT );
    }
    return;
}

main() unless caller;
