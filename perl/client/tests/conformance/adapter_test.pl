use strict;
use warnings;
use threads;
use Thread::Queue;

use FindBin;
use IO::Handle;
use IO::Select;
use JSON::PP qw(decode_json encode_json);
use Socket   qw(AF_UNIX PF_UNSPEC SHUT_WR SOCK_STREAM);
use Test::More;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../..";
use lib $FindBin::Bin;

use Adapter;
use AdapterFixtureClient;

my $CANONICAL_JSON = JSON::PP->new->canonical;

sub send_command {
    my ( $socket, $command ) = @_;
    print {$socket} encode_json($command) . "\n";
    return;
}

sub read_event {
    my ( $socket, $timeout ) = @_;
    my @ready = IO::Select->new($socket)->can_read($timeout);
    die 'timed out waiting for adapter event' unless @ready;
    my $line = <$socket>;
    die 'adapter closed before event' unless defined $line;
    return decode_json($line);
}

sub is_event {
    my ( $actual, $expected, $label ) = @_;
    is( $CANONICAL_JSON->encode($actual),
        $CANONICAL_JSON->encode($expected), $label );
    return;
}

my @subscription_queues = map { Thread::Queue->new } 1 .. 4;
my $client              = AdapterFixtureClient->new( \@subscription_queues );
my $pause_tokens        = Thread::Queue->new;
my $paused              = Thread::Queue->new;
my $release             = Thread::Queue->new;

my $relay_after_dequeue = sub {
    my ($subscription_id) = @_;
    return unless $subscription_id =~ /\A(?:replace|unsubscribe)-id\z/;
    return unless defined $pause_tokens->dequeue_nb;
    $paused->enqueue($subscription_id);
    $release->dequeue;
    return;
};

socketpair( my $controller, my $adapter, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
  or die "socketpair: $!";
$controller->autoflush(1);
my $adapter_thread = threads->create(
    sub {
        Adapter::run_adapter(
            $adapter, $adapter,
            {
                client              => $client,
                relay_after_dequeue => $relay_after_dequeue,
            }
        );
        return;
    }
);

# Keep stdin open while checking this event so the test proves interactive
# stdio/TCP output is flushed, not merely written during process shutdown.
send_command( $controller,
    { protocolVersion => 1, id => 'hello', op => 'hello' } );
is_event(
    read_event( $controller, 0.5 ),
    {
        protocolVersion => 1,
        id              => 'hello',
        type            => 'ready',
        language        => 'perl',
        implementation  => "native-perl-$]",
        runtime         => "perl-$]",
    },
    'hello flushes before the next command'
);

send_command( $controller,
    { id => 'success', op => 'query', path => 'fixture:success', args => {} } );
is_event(
    read_event( $controller, 0.5 ),
    {
        id    => 'success',
        type  => 'result',
        value => { answer => 42 },
        logs  => ['success log'],
    },
    'successful result has the exact adapter shape'
);

send_command( $controller,
    { id => 'failure', op => 'query', path => 'fixture:failure', args => {} } );
is_event(
    read_event( $controller, 0.5 ),
    {
        id    => 'failure',
        type  => 'error',
        error => {
            name    => 'FunctionError',
            message => 'expected fixture failure',
            data    => { code => 'EXPECTED_HTTP' },
        },
        logs => ['http log'],
    },
    'HTTP FunctionError keeps the exact data and logs shape'
);

send_command(
    $controller,
    {
        id             => 'subscribe-error',
        op             => 'subscribe',
        subscriptionId => 'error-id',
        path           => 'fixture:subscription',
        args           => {},
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'subscribe-error', type => 'ack' },
    'subscribe ACK shape'
);
$subscription_queues[0]->enqueue(
    encode_json(
        {
            kind    => 'error',
            message => 'subscription failed',
            data    => { code => 'EXPECTED_SUBSCRIPTION' },
            logs    => ['subscription log'],
        }
    )
);
is_event(
    read_event( $controller, 0.5 ),
    {
        type           => 'subscription',
        subscriptionId => 'error-id',
        error          => {
            name    => 'FunctionError',
            message => 'subscription failed',
            data    => { code => 'EXPECTED_SUBSCRIPTION' },
        },
        logs => ['subscription log'],
    },
    'subscription error has the exact structured shape'
);
send_command(
    $controller,
    {
        id             => 'unsubscribe-error',
        op             => 'unsubscribe',
        subscriptionId => 'error-id'
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'unsubscribe-error', type => 'ack' },
    'unsubscribe ACK shape'
);

send_command(
    $controller,
    {
        id             => 'replace-old',
        op             => 'subscribe',
        subscriptionId => 'replace-id',
        path           => 'fixture:old',
        args           => {},
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'replace-old', type => 'ack' },
    'old replacement ACK'
);
$pause_tokens->enqueue(1);
$subscription_queues[1]->enqueue(
    encode_json( { kind => 'value', value => { source => 'stale' } } ) );
is( $paused->dequeue, 'replace-id',
    'old replacement relay paused after dequeue' );
send_command(
    $controller,
    {
        id             => 'replace-new',
        op             => 'subscribe',
        subscriptionId => 'replace-id',
        path           => 'fixture:new',
        args           => {},
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'replace-new', type => 'ack' },
    'replacement ACK is not join-blocked'
);
$release->enqueue(1);
$subscription_queues[2]->enqueue(
    encode_json( { kind => 'value', value => { source => 'fresh' } } ) );
is_event(
    read_event( $controller, 0.5 ),
    {
        type           => 'subscription',
        subscriptionId => 'replace-id',
        value          => { source => 'fresh' },
        logs           => [],
    },
    'stale replacement value cannot cross the ACK'
);
send_command(
    $controller,
    {
        id             => 'replace-done',
        op             => 'unsubscribe',
        subscriptionId => 'replace-id'
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'replace-done', type => 'ack' },
    'replacement cleanup ACK'
);

send_command(
    $controller,
    {
        id             => 'unsubscribe-old',
        op             => 'subscribe',
        subscriptionId => 'unsubscribe-id',
        path           => 'fixture:unsubscribe',
        args           => {},
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'unsubscribe-old', type => 'ack' },
    'unsubscribe fixture ACK'
);
$pause_tokens->enqueue(1);
$subscription_queues[3]->enqueue(
    encode_json( { kind => 'value', value => { source => 'stale' } } ) );
is( $paused->dequeue,
    'unsubscribe-id', 'unsubscribe relay paused after dequeue' );
send_command(
    $controller,
    {
        id             => 'unsubscribe-now',
        op             => 'unsubscribe',
        subscriptionId => 'unsubscribe-id',
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'unsubscribe-now', type => 'ack' },
    'unsubscribe ACK is not join-blocked'
);
$release->enqueue(1);
ok(
    !IO::Select->new($controller)->can_read(0.2),
    'no stale unsubscribe event appears after ACK'
);

send_command( $controller, { id => 'close', op => 'close' } );
is_event(
    read_event( $controller, 0.5 ),
    { id => 'close', type => 'closed' },
    'close has the exact adapter shape'
);
$adapter_thread->join;

my $subscription_closed = Thread::Queue->new;
my $client_closed       = Thread::Queue->new;
my @eof_queues          = ( Thread::Queue->new );
my $eof_client          = AdapterFixtureClient->new(
    \@eof_queues,
    {
        subscription_closed => $subscription_closed,
        client_closed       => $client_closed,
    }
);
socketpair( $controller, $adapter, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
  or die "EOF socketpair: $!";
$controller->autoflush(1);
$adapter_thread = threads->create(
    sub {
        Adapter::run_adapter( $adapter, $adapter, { client => $eof_client } );
        return;
    }
);
send_command(
    $controller,
    {
        id             => 'eof-subscribe',
        op             => 'subscribe',
        subscriptionId => 'eof-id',
        path           => 'fixture:eof',
        args           => {},
    }
);
is_event(
    read_event( $controller, 0.5 ),
    { id => 'eof-subscribe', type => 'ack' },
    'active EOF fixture subscribes'
);
shutdown $controller, SHUT_WR or die "shutdown controller writes: $!";
my $eof_deadline = time + 1;
sleep 0.01 while !$adapter_thread->is_joinable && time < $eof_deadline;
ok( $adapter_thread->is_joinable, 'EOF cleanup stops the adapter promptly' );
$adapter_thread->join;
is( $subscription_closed->pending,
    1, 'EOF cleanup closes the active subscription' );
is( $client_closed->pending, 1, 'EOF cleanup closes the client' );
is( scalar threads->list(threads::running),
    0, 'EOF cleanup leaves no running or unjoined threads' );
close $controller;
close $adapter;

done_testing;
