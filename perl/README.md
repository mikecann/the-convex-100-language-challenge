<img src="logo.png" alt="Perl camel logo" width="160">
<!-- Logo source: https://raw.githubusercontent.com/metacpan/perl-assets/main/blessed/exports/perl-010-300.png -->

# Perl

Perl is a high-level, dynamically typed language created by Larry Wall and
first released in 1987. It draws on C, `sed`, `awk`, and the Unix shell, and is
especially at home in text processing, system administration, web applications,
and quick automation. Perl is still actively maintained, while its enormous
CPAN module archive gives established codebases a long practical life. You can
learn more at [perl.org](https://www.perl.org/).

This repository contains an educational, unofficial Convex client
demonstration. It is not a production SDK and is not a package to install from
CPAN.

## Getting Started

Start with [`examples/basics/main.pl`](examples/basics/main.pl). It queries a
fresh counter room, starts a Live subscription, applies an idempotent mutation,
and receives the resulting update.

From the repository root, run the exact canonical example in its minimal Docker image:

```sh
./run verify-example perl
```

Docker supplies the pinned Perl runtime and dependencies, so you do not need to
install Perl or CPAN packages on your host.

## Interesting Parts

### `//=` builds the Live worker only once

Perl 5.10 (2007) added the defined-or operator to fix a long-standing footgun
in `||`: a count of `0` or an empty string is a perfectly good value, but
`||` would treat it as false and clobber it anyway. Its assignment form,
`//=`, only ever acts on `undef`, which makes it a natural fit for
lazily creating a singleton — `subscribe` builds the shared WebSocket worker
the first time anyone asks for Live updates, and every call after that reuses
it.

```perl
sub subscribe {
    my ( $self, $path, $args ) = @_;
    ...
    # Create the shared Live worker only the first time it's needed.
    $self->{live} //= Convex::Live->new( $self->{deployment_url}, $self->{version} );
    # TypeScript: this.live ??= new LiveWorker(url, version);
    return $self->{live}->subscribe( $path, $args );
}
```

### Arrows between neighbouring braces are optional

Every call returns a `{ value, logs }` envelope decoded straight out of JSON,
and `value` is itself hashes nested inside hashes. Perl dereferences each
level with `->`, but between two adjacent subscripts the arrow can simply be
dropped, so a deeply nested lookup reads almost like a property chain — minus
any compile-time guarantee that the shape is actually there.

```perl
my $response = $client->query( 'demo:state', { room => $room } );

# Perl elides the arrow between adjacent {..}{..} pairs.
my $count = $response->{value}{count};   # TypeScript: response.value.count, type-checked
print "Count: $count\n";
```

### A Live subscription is a blocking pull, not a rerender

React's `useQuery` subscribes once and quietly rerenders your component on
every server push. A script has no render loop to hook into, so this client
makes that relationship explicit: `subscribe` opens a mailbox on the shared
Live worker, and `next_update` blocks until a message lands or the timeout
elapses.

```perl
my $subscription = $client->subscribe( 'demo:state', { room => $room } );
my $initial = $subscription->next_update(10);   # blocks up to 10s for the first push
die $initial->{error} if $initial->{error};
print "count: $initial->{value}{count}\n";

# ...mutate elsewhere, then pull whatever the Live worker pushed next...
my $updated = $subscription->next_update(10);
$subscription->close;   # TypeScript: the cleanup effect unsubscribes for you
```

### `eval` is Perl's `try`, `$@` is the `catch`

Perl's real `try`/`catch` keywords only arrived as an experiment in 5.34
(2022) — for the three decades before that, `eval { }` was the exception
handler. A block ending in a true value signals success; anything that dies
inside it lands in the global `$@` for the code right after to inspect.

```perl
eval {
    my $mutation = $client->mutation( 'demo:increment',
        { room => $room, runId => $run_id } );
    die 'mutation was not applied' unless $mutation->{value}{applied};
    1;
} or do {
    my $error = $@ || 'unknown example failure';   # TypeScript: catch (error) { ... }
    $client->close;
    die $error;
};
```

## Status

| Behaviour | Status |
| --- | --- |
| Documented JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Pinned `/api/sync` Live query profile | Verified by shared local and hosted conformance |
| Capability badges | HTTP and Live earned |

## Example

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

## Implementation Notes

```sh
./run test perl
./run build perl
```

`./run test perl` checks formatting with Perl::Tidy 20260705, runs Perl::Critic
1.156, performs syntax checks, and executes the language-local fixture suite.
`./run build perl` builds the minimal `linux/amd64` adapter runtime. The
formatter and linter dependencies are build-only and locked in
[`client/tooling-cpan.lock`](client/tooling-cpan.lock).

The client is native Perl. [`client/Convex.pm`](client/Convex.pm) implements the
documented JSON HTTP calls with `HTTP::Tiny` and `JSON::PP`; it does not delegate
Convex behavior to another language's SDK. HTTP calls return a small envelope
containing the decoded `value` and any server `logs`, which is why the examples
read `$response->{value}` rather than the value directly.

For Live queries, one worker owns WebSocket I/O, reconnects, and the active
query set. Each subscription has a bounded mailbox that keeps the newest 16
updates, so a slow consumer cannot grow memory without limit. The explicit
`next_update` method fits a terminal example and makes timeout handling clear,
even though Perl also supports event-loop and callback-based designs.

The final images use a digest-pinned Perl 5.42.0 build and an amd64 distroless
Debian 12 nonroot base. They retain only the traced Perl and TLS runtime closure,
the client, and the small shell surface required by the shared verifier. CPAN,
compilers, linkers, formatters, and linters are not present in the runtime.

## Known Issues

1. Live authentication, WebSocket mutations and actions, transition-chunk
   assembly, and full Convex value support are deferred. Mutations and actions
   currently use the documented HTTP API.
2. Live compatibility targets a pinned, undocumented `/api/sync` profile. It
   is experimental compatibility work, not a stable public SDK contract.
3. The Live mailbox retains only the newest 16 updates per subscription. A slow
   consumer can miss older intermediate values.
