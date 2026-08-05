package AdapterFixtureClient;

use strict;
use warnings;

use Convex::Errors;
use AdapterFixtureSubscription;

sub new {
    my ( $class, $subscription_queues, $events ) = @_;
    return bless {
        subscription_queues => $subscription_queues,
        events              => $events // {},
    }, $class;
}

sub query {
    my ( $self, $path ) = @_;
    if ( $path eq 'fixture:failure' ) {
        die Convex::Errors::function_error(
            'expected fixture failure',
            { code => 'EXPECTED_HTTP' },
            ['http log'],
        );
    }
    return { value => { answer => 42 }, logs => ['success log'] };
}

sub subscribe {
    my ($self) = @_;
    my $queue = shift @{ $self->{subscription_queues} };
    die 'fixture ran out of subscription queues' unless $queue;
    return AdapterFixtureSubscription->new( $queue,
        $self->{events}{subscription_closed} );
}

sub set_auth {
    return;
}

sub close {
    my ($self) = @_;
    $self->{events}{client_closed}->enqueue(1)
      if $self->{events}{client_closed};
    return;
}

1;
