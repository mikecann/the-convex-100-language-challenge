#!/usr/local/bin/perl
use strict;
use warnings;
use FindBin;
use lib $ENV{CONVEX_CLIENT_PATH} || "$FindBin::Bin/../../client";
use Convex;

# Convex JSON numbers are decoded as scalars. This helper rejects a surprising
# value before the example compares counts or prints a misleading success.
sub whole_count {
    my ( $value, $operation ) = @_;
    die "$operation count was not a whole number"
      unless defined $value && $value =~ /^-?\d+$/;
    return 0 + $value;
}

# Create a Convex client using the deployment selected by the verifier.
my $client = Convex->new( $ENV{CONVEX_URL} );

# A unique room lets concurrent example runs prove the same isolated
# 0 -> 1 journey.
my $room = $ARGV[0] || 'perl-example';
eval {
    # Query the current room state through Convex's documented HTTP API.
    my $current = $client->query( 'demo:state', { room => $room } );
    my $current_count =
      whole_count( $current->{value}{count}, 'current query' );
    print "current count: $current_count\n";

    # Start Live before changing state, so the reactive query cannot miss the
    # mutation.
    my $subscription = $client->subscribe( 'demo:state', { room => $room } );
    my $initial      = $subscription->next_update(10);
    die $initial->{error} if $initial->{error};
    my $initial_count =
      whole_count( $initial->{value}{count}, 'initial Live value' );
    die "initial Live count disagreed" unless $initial_count == $current_count;
    print "live initial count: $initial_count\n";

    # The runId is an idempotency key, so retrying this logical mutation is
    # safe.
    my $mutation = $client->mutation(
        'demo:increment',
        {
            room     => $room,
            language => 'perl',
            runId    => join( '-', 'perl', time, int( rand(1_000_000) ) )
        }
    );
    die 'mutation was not applied' unless $mutation->{value}{applied};
    print "mutation applied: true\n";
    my $mutation_count =
      whole_count( $mutation->{value}{state}{count}, 'mutation' );
    die 'mutation count disagreed' unless $mutation_count == $current_count + 1;
    print "mutation count: $mutation_count\n";

    # Receive the changed state from the existing Live query rather than
    # polling HTTP.
    my $changed = $subscription->next_update(10);
    die $changed->{error} if $changed->{error};
    my $changed_count =
      whole_count( $changed->{value}{count}, 'updated Live value' );
    die 'updated Live count disagreed' unless $changed_count == $mutation_count;
    print "live updated count: $changed_count\n";
    print "verified count: $current_count -> $changed_count\n";

    # Unsubscribe explicitly so the Live worker removes this query before exit.
    $subscription->close;
    1;
} or do {
    my $error = $@ || 'unknown example failure';

    # Failure cleanup must also stop the Live worker instead of hiding it behind
    # the original operation error or leaving the process running.
    $client->close;
    die $error;
};

# Close the shared client after the demonstrated HTTP and Live work is complete.
$client->close;
