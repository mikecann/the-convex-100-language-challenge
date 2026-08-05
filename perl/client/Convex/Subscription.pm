package Convex::Subscription;

use strict;
use warnings;

use threads;
use Thread::Queue;
use JSON::PP    qw(decode_json encode_json);
use Time::HiRes qw(time);

use Convex::Errors;

use constant MAX_BUFFERED_UPDATES => 16;

sub new {
    my ( $class, $manager, $id ) = @_;
    return bless {
        manager => $manager,
        id      => $id,
        queue   => Thread::Queue->new,
        closed  => 0,
    }, $class;
}

sub next_update {
    my ( $self, $timeout ) = @_;
    my $item =
      defined $timeout
      ? $self->{queue}->dequeue_timed( time + $timeout )
      : $self->{queue}->dequeue;
    die Convex::Errors::transport_error( 'timed out waiting for Live update',
        'live' )
      unless defined $item;
    my $decoded = decode_json($item);
    die Convex::Errors::closed_error('Live subscription is closed')
      if $decoded->{kind} eq 'closed';
    if ( $decoded->{kind} eq 'error' ) {
        my $error = $decoded->{error};
        my $typed;
        if ( $error->{name} eq 'FunctionError' ) {
            $typed = Convex::Errors::function_error( $error->{message},
                $error->{data}, $error->{logs} );
        }
        elsif ( $error->{name} eq 'ProtocolError' ) {
            $typed = Convex::Errors::protocol_error( $error->{message} );
        }
        else {
            $typed = Convex::Errors::transport_error( $error->{message},
                $error->{operation} // 'live' );
        }
        return { error => $typed };
    }
    return { value => $decoded->{value}, logs => $decoded->{logs} // [] };
}

sub deliver {
    my ( $self, $update ) = @_;
    return if $self->{closed};
    $self->{queue}->dequeue_nb
      while $self->{queue}->pending >= MAX_BUFFERED_UPDATES;
    $self->{queue}->enqueue( _encode_update($update) );
    return;
}

sub finish {
    my ($self) = @_;
    return if $self->{closed}++;
    $self->{queue}->dequeue_nb while $self->{queue}->pending;
    $self->{queue}->enqueue( encode_json( { kind => 'closed' } ) );
    return;
}

sub close {
    my ($self) = @_;
    return if $self->{closed};
    eval {
        $self->{manager}->request( 'unsubscribe', { query_id => $self->{id} } );
    };
    die $@ if $@ && ref($@) ne 'Convex::ClosedError';
    return;
}

sub _encode_update {
    my ($update) = @_;
    if ( $update->{error} ) {
        my $error      = $update->{error};
        my $name       = ref($error) =~ /([^:]+)\z/ ? $1     : 'TransportError';
        my $structured = ref($error)                ? $error : {};
        return encode_json(
            {
                kind  => 'error',
                error => {
                    name      => $name,
                    message   => "$error",
                    operation => $structured->{operation},
                    data      => $structured->{data},
                    logs      => $structured->{logs} // [],
                },
            }
        );
    }
    return encode_json(
        {
            kind  => 'value',
            value => $update->{value},
            logs  => $update->{logs} // [],
        }
    );
}

1;
