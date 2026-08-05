# Convex from Perl

This is a small, native Perl demonstration of Convex HTTP calls and a pinned experimental Live protocol profile.

It is educational and unofficial, not a production SDK or a package to install from CPAN.

## Start here

[`examples/basics/main.pl`](examples/basics/main.pl) queries a fresh counter room, begins Live, applies an idempotent mutation, then verifies the Live update.

## What works

| Behaviour | Status |
| --- | --- |
| Documented JSON HTTP queries, mutations, and actions | Implemented, pending shared evidence |
| Pinned `/api/sync` Live query profile | Implemented, pending shared evidence |
| Capability badges | None earned yet |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pl -->
```perl
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
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test perl
./run build perl
```

The first checks every source against Perl::Tidy 20260705, runs Perl::Critic
1.156 at severity 5, performs syntax checks, and executes the language-local
fixture matrix. All 37 build-only formatter and linter distributions are pinned
by version, CPAN author path, and SHA-256 in
[`client/tooling-cpan.lock`](client/tooling-cpan.lock); installation uses an
empty local mirror so undeclared transitive downloads fail. The second builds
the minimal linux/amd64 adapter runtime.
Coordinator-owned `verify-example`, `verify`, and `verify-hosted` are required
before either capability can be awarded.

## Conformance notes

The adapter speaks NDJSON protocol v1 over stdin/stdout or `ADAPTER_LISTEN` TCP.
Live is implemented with one worker that owns WebSocket reads, writes,
reconnects, and query-set versions; each subscriber gets a newest-16 mailbox.
Partial handshake and frame reads or writes abandon the connection after a
two-second deadline. A partial write force-retires the uncertain stream before
active Add operations are rehydrated on a new connection. Adapter EOF performs
the same subscription, relay, client, and socket cleanup as an explicit close,
without writing to the disconnected controller. Adapter NDJSON writes have a
one-second complete-write deadline and force-retire a partial controller stream
so EOF cleanup cannot wait forever behind output backpressure. Deterministic
fixtures cover Add/Remove, QueryFailed recovery, five reconnects and metadata,
unchanged hydration suppression, stale relay races, fragmented UTF-8 and
control frames, structured recovery, partial and blocked writes, EOF, and
hostile shutdown.
`debugDisconnect` is adapter-only.

Runtime transport modules are supplied by the digest-pinned Perl 5.42.0 image:
HTTP::Tiny 0.090, JSON::PP 4.16, IO::Socket::SSL 2.091, MIME::Base64 3.16_01,
and Net::SSLeay 1.94. Final images use the pinned amd64 distroless Debian 12
nonroot base, then add only the traced Perl and TLS runtime closure, the shell
and text tools required by shared policy, and the client sources. CPAN and
ExtUtils::MakeMaker modules are absent, as are compiler, linker, package
manager, formatter, and linter commands.

## Limitations

Live authentication, WebSocket mutations/actions, transition-chunk assembly, journals, optimistic updates, and full Convex value support are deliberately deferred. The sync endpoint is pinned experimental compatibility work, not a stable public protocol.
