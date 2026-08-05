use strict;
use warnings;
use threads;
use Thread::Queue;

use FindBin;
use lib $FindBin::Bin;
use Test::More;

use RelayGuard;

sub stale_relay_case {
    my ($label)    = @_;
    my $guard      = RelayGuard->new;
    my $ready      = Thread::Queue->new;
    my $release    = Thread::Queue->new;
    my $written    = Thread::Queue->new;
    my $generation = $guard->advance('same-id');

    my $relay = threads->create(
        sub {
            # This models a relay paused after dequeue but before publication.
            $ready->enqueue(1);
            $release->dequeue;
            $guard->publish_if_current( 'same-id', $generation,
                sub { $written->enqueue('stale') } );
            return;
        }
    );
    $ready->dequeue;
    $guard->advance('same-id');
    $release->enqueue(1);
    $relay->join;
    is( $written->pending, 0, "$label suppresses a paused stale relay" );
}

stale_relay_case('same-ID replacement');
stale_relay_case('unsubscribe');
done_testing;
