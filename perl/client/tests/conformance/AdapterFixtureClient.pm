package AdapterFixtureClient;

use strict;
use warnings;

use Convex::Errors;
use AdapterFixtureSubscription;

sub new {
    my ( $class, $subscription_queues ) = @_;
    return bless { subscription_queues => $subscription_queues }, $class;
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
    return AdapterFixtureSubscription->new($queue);
}

sub set_auth {
    return;
}

sub close {
    return;
}

1;
