use strict;
use warnings;
use threads;
use Thread::Queue;

use FindBin;
use IO::Socket::INET;
use JSON::PP qw(decode_json encode_json);
use Test::More;
use Time::HiRes qw(time);

use lib "$FindBin::Bin";
use Convex;

ok( Convex->can('new'), 'native Perl client loads' );

my $client = Convex->new('http://example.test');
eval { $client->query( 'demo:echo', [] ); };
like( "$@", qr/named JSON object/, 'rejects positional Convex arguments' );
$client->close;
eval { $client->query( 'demo:state', {} ); };
like( "$@", qr/closed/, 'rejects calls after close' );

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
    ReuseAddr => 1,
) or die "listen: $!";
my $port          = $server->sockport;
my $request_seen  = Thread::Queue->new;
my $server_thread = threads->create(
    sub {
        my $socket       = $server->accept;
        my $request_line = <$socket>;
        my %headers;
        while ( my $line = <$socket> ) {
            $line =~ s/\r?\n\z//;
            last unless length $line;
            my ( $name, $value ) = split /:\s*/, $line, 2;
            $headers{ lc $name } = $value;
        }
        my $body = q{};
        read $socket, $body, $headers{'content-length'};
        $request_seen->enqueue( decode_json($body) );
        my $response = encode_json(
            {
                status       => 'error',
                errorMessage => 'expected failure',
                errorData    => { code => 'EXPECTED_560' },
                logLines     => ['before failure'],
            }
        );
        print {$socket} "HTTP/1.1 560 Convex Function Error\r\n";
        print {$socket} "Content-Type: application/json\r\n";
        print {$socket} 'Content-Length: ' . length($response) . "\r\n";
        print {$socket} "Connection: close\r\n\r\n$response";
        close $socket;
        return;
    }
);

local $ENV{no_proxy} = '127.0.0.1';
my $fixture_client = Convex->new("http://127.0.0.1:$port");
eval { $fixture_client->query( 'demo:fail', { code => 'EXPECTED_560' } ); };
my $error = $@;
is( ref($error), 'Convex::FunctionError', 'HTTP 560 remains a function error' );
is( $error->{data}{code}, 'EXPECTED_560', 'HTTP 560 preserves errorData' );
is_deeply( $error->{logs}, ['before failure'], 'HTTP 560 preserves logs' );
my $observed_request = $request_seen->dequeue_timed( time + 2 );
is( $observed_request ? $observed_request->{path} : undef,
    'demo:fail', 'fixture received real HTTP call' );
$fixture_client->close;
$server_thread->join;
close $server;

done_testing;
