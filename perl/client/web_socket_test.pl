use strict;
use warnings;
use utf8;

use FindBin;
use JSON::PP qw(decode_json encode_json);
use Socket   qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
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

done_testing;
