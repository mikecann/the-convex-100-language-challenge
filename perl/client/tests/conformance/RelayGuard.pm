package RelayGuard;

use strict;
use warnings;

use threads;
use threads::shared;

sub new {
    my ($class) = @_;
    my $lock        : shared;
    my %generations : shared;
    return bless {
        lock        => \$lock,
        generations => \%generations,
    }, $class;
}

sub lock_ref {
    return $_[0]{lock};
}

sub advance {
    my ( $self, $subscription_id ) = @_;
    lock( ${ $self->{lock} } );
    $self->{generations}{$subscription_id} =
      ( $self->{generations}{$subscription_id} // 0 ) + 1;
    return $self->{generations}{$subscription_id};
}

# Generation validation and publication share one lock. Replacement and
# unsubscribe advance the generation before ACK, so an old relay paused after
# dequeue cannot publish when it resumes.
sub publish_if_current {
    my ( $self, $subscription_id, $generation, $callback ) = @_;
    lock( ${ $self->{lock} } );
    return 0
      unless ( $self->{generations}{$subscription_id} // 0 ) == $generation;
    $callback->();
    return 1;
}

sub synchronized {
    my ( $self, $callback ) = @_;
    lock( ${ $self->{lock} } );
    return $callback->();
}

1;
