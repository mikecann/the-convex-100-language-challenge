package AdapterFixtureSubscription;

use strict;
use warnings;

use JSON::PP qw(decode_json encode_json);

use Convex::Errors;

sub new {
    my ( $class, $queue, $closed_event ) = @_;
    return bless {
        queue        => $queue,
        closed       => 0,
        closed_event => $closed_event,
    }, $class;
}

sub next_update {
    my ($self) = @_;
    my $item = decode_json( $self->{queue}->dequeue );
    die Convex::Errors::closed_error('fixture subscription closed')
      if $item->{kind} eq 'closed';
    if ( $item->{kind} eq 'error' ) {
        return {
            error => Convex::Errors::function_error(
                $item->{message}, $item->{data}, $item->{logs}
            )
        };
    }
    return { value => $item->{value}, logs => $item->{logs} // [] };
}

sub close {
    my ($self) = @_;
    return if $self->{closed}++;
    $self->{queue}->enqueue( encode_json( { kind => 'closed' } ) );
    $self->{closed_event}->enqueue(1) if $self->{closed_event};
    return;
}

1;
