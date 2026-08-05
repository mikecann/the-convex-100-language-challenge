use strict;
use warnings;
use utf8;
use threads;
use Thread::Queue;

use FindBin;
use JSON::PP qw(decode_json encode_json);
use Socket   qw(AF_UNIX PF_UNSPEC SOCK_STREAM SOL_SOCKET SO_SNDBUF);
use Test::More;
use Time::HiRes qw(time);

use lib "$FindBin::Bin";
use Convex::WebSocket;

sub server_frame {
    my ( $opcode, $payload, $final ) = @_;
    $final = 1 unless defined $final;
    my $first  = ( $final ? 128 : 0 ) | $opcode;
    my $length = length $payload;
    my $header = pack 'C', $first;
    $header .=
      $length < 126
      ? pack( 'C', $length )
      : pack( 'Cn', 126, $length );
    return $header . $payload;
}

socketpair( my $client_io, my $server_io, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
  or die "socketpair: $!";
$server_io->autoflush(1);
my $websocket = Convex::WebSocket->from_io_for_test($client_io);
my $payload   = encode_json( { value => "Hello, 世界 👋" } );
my $emoji     = index $payload, "\xF0";
my $split     = $emoji + 2;
print {$server_io} server_frame( 1, substr( $payload, 0, $split ), 0 );
print {$server_io} server_frame( 9, 'ping',                        1 );
print {$server_io} server_frame( 0, substr( $payload, $split ),    1 );
is_deeply(
    decode_json( $websocket->read_message ),
    { value => "Hello, 世界 👋" },
    'fragmented UTF-8 with an interleaved control frame decodes correctly',
);
$websocket->close_now;
close $server_io;

socketpair( $client_io, $server_io, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
  or die "socketpair: $!";
$server_io->autoflush(1);
$websocket = Convex::WebSocket->from_io_for_test($client_io);
print {$server_io} pack 'C', 0x81;
my $started = time;
eval { $websocket->read_message };
is( ref($@), 'Convex::TransportError', 'partial frame raises transport error' );
cmp_ok( time - $started, '<', 2.5, 'partial frame read has a hard deadline' );
$websocket->close_now;
close $server_io;

socketpair( $client_io, $server_io, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
  or die "partial write socketpair: $!";
setsockopt $client_io, SOL_SOCKET, SO_SNDBUF, pack( 'i', 4_096 )
  or die "partial write send buffer: $!";
my $partial_bytes = Thread::Queue->new;
my $partial_peer  = threads->create(
    sub {
        my $read = sysread $server_io, my $chunk, 4_096;
        $partial_bytes->enqueue( $read // 0 );
        close $server_io;
        return;
    }
);
$websocket = Convex::WebSocket->from_io_for_test($client_io);
my $large_payload = 'x' x ( 512 * 1_024 );
eval { $websocket->_write_frame( 1, $large_payload ) };
is( ref($@), 'Convex::TransportError',
    'partial frame write raises transport error' );
cmp_ok( $partial_bytes->dequeue, '>', 0,
    'partial peer receives a real frame prefix' );
ok( !defined $websocket->io,
    'partial frame write retires the uncertain connection' );
eval { $websocket->write_json( { later => 1 } ) };
is( ref($@), 'Convex::ClosedError',
    'later traffic cannot reuse a partially written connection' );
$partial_peer->join;
close $server_io;

socketpair( $client_io, $server_io, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
  or die "blocked write socketpair: $!";
setsockopt $client_io, SOL_SOCKET, SO_SNDBUF, pack( 'i', 4_096 )
  or die "blocked write send buffer: $!";
$websocket = Convex::WebSocket->from_io_for_test($client_io);
$started   = time;
eval { $websocket->_write_frame( 1, $large_payload ) };
is( ref($@), 'Convex::TransportError',
    'blocked frame write raises transport error' );
cmp_ok( time - $started,
    '<', 2.5, 'blocked frame write has a complete-frame deadline' );
ok( !defined $websocket->io,
    'blocked frame write force-retires the connection' );
close $server_io;

done_testing;
