package Convex::WebSocket;

use strict;
use warnings;
use Digest::SHA qw(sha1);
use IO::Socket::INET;
use IO::Socket::SSL;
use MIME::Base64 qw(encode_base64);
use URI;
use JSON::PP qw(encode_json);
use Convex::Errors;

use constant MAX_MESSAGE_BYTES => 2 * 1024 * 1024;
use constant GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

sub connect {
  my ($class, $url, $client_version) = @_;
  my $uri = URI->new($url);
  die Convex::Errors::protocol_error('Live URL must use ws or wss') unless $uri->scheme =~ /^wss?$/;
  my $port = $uri->port || ($uri->scheme eq 'wss' ? 443 : 80);
  my $tcp = IO::Socket::INET->new(PeerHost => $uri->host, PeerPort => $port, Proto => 'tcp', Timeout => 10)
    or die Convex::Errors::transport_error("WebSocket connect: $!", 'live');
  $tcp->autoflush(1);
  my $io = $tcp;
  if ($uri->scheme eq 'wss') {
    $io = IO::Socket::SSL->start_SSL($tcp, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER(), SSL_hostname => $uri->host, Timeout => 10)
      or die Convex::Errors::transport_error('TLS handshake: ' . IO::Socket::SSL::errstr(), 'live');
  }
  my $key = encode_base64(join('', map { chr int rand 256 } 1..16), '');
  my $host = $uri->host . (($port == 80 || $port == 443) ? '' : ":$port");
  my $path = $uri->path_query || '/';
  print {$io} "GET $path HTTP/1.1\r\nHost: $host\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nConvex-Client: $client_version\r\n\r\n";
  my $headers = _headers($io);
  die Convex::Errors::protocol_error('WebSocket upgrade was rejected') unless $headers->{_status} =~ m{^HTTP/1\.[01] 101\b};
  my $expected = encode_base64(sha1($key . GUID), '');
  die Convex::Errors::protocol_error('WebSocket upgrade returned an invalid accept key') unless ($headers->{'sec-websocket-accept'} || '') eq $expected;
  return bless { io => $io, tcp => $tcp, partial => '' }, $class;
}

sub io { $_[0]{io} }
sub pending { $_[0]{io} && $_[0]{io}->can('pending') && $_[0]{io}->pending > 0 }
sub write_json { $_[0]->_write_frame(1, encode_json($_[1])); }
sub close_now { my ($self) = @_; eval { close $self->{io} if $self->{io}; }; $self->{io} = undef; }
sub close { my ($self) = @_; eval { $self->_write_frame(8, pack('n', 1000) . 'client closed') if $self->{io}; }; $self->close_now; }

sub read_message {
  my ($self) = @_;
  my ($message, $opcode) = ('', undef);
  while (1) {
    my ($fin, $kind, $payload) = $self->_read_frame;
    if ($kind == 0) { die Convex::Errors::protocol_error('unexpected WebSocket continuation') unless defined $opcode; $message .= $payload; }
    elsif ($kind == 1) { die Convex::Errors::protocol_error('interleaved WebSocket text messages') if defined $opcode; $opcode = $kind; $message .= $payload; }
    elsif ($kind == 8) { eval { $self->_write_frame(8, $payload) }; return undef; }
    elsif ($kind == 9) { $self->_write_frame(10, $payload); next; }
    elsif ($kind == 10) { next; }
    else { die Convex::Errors::protocol_error("unsupported WebSocket opcode $kind"); }
    die Convex::Errors::protocol_error('WebSocket message exceeds limit') if length($message) > MAX_MESSAGE_BYTES;
    return $message if $fin;
  }
}

sub _headers {
  my ($io) = @_; my ($raw, $limit) = ('', 32 * 1024);
  while ($raw !~ /\r\n\r\n\z/) { my $n = sysread($io, my $c, 1); die Convex::Errors::transport_error('WebSocket closed during upgrade', 'live') unless $n; $raw .= $c; die Convex::Errors::protocol_error('WebSocket headers too large') if length($raw) > $limit; }
  my @lines = split /\r\n/, $raw; my %headers = (_status => shift @lines);
  for (@lines) { next unless /:/; my ($k, $v) = split /:\s*/, $_, 2; $headers{lc $k} = $v; } return \%headers;
}
sub _read_exact { my ($self, $length) = @_; my $out = ''; while (length($out) < $length) { my $n = sysread($self->{io}, my $chunk, $length - length($out)); die Convex::Errors::transport_error('WebSocket closed while reading frame', 'live') unless $n; $out .= $chunk; } return $out; }
sub _read_frame {
  my ($self) = @_; my ($a, $b) = unpack('CC', $self->_read_exact(2)); my $fin = $a & 128; my $kind = $a & 15;
  die Convex::Errors::protocol_error('server frame was masked') if $b & 128;
  my $len = $b & 127; $len = unpack('n', $self->_read_exact(2)) if $len == 126; $len = unpack('Q>', $self->_read_exact(8)) if $len == 127;
  die Convex::Errors::protocol_error('WebSocket frame exceeds limit') if $len > MAX_MESSAGE_BYTES;
  die Convex::Errors::protocol_error('fragmented or oversized control frame') if $kind >= 8 && (!$fin || $len > 125);
  return ($fin, $kind, $self->_read_exact($len));
}
sub _write_frame {
  my ($self, $kind, $payload) = @_; die Convex::Errors::closed_error() unless $self->{io}; my $len = length $payload; my $mask = join('', map { chr int rand 256 } 1..4); my $header = pack('C', 128 | $kind);
  $header .= $len < 126 ? pack('C', 128 | $len) : $len <= 65535 ? pack('Cn', 254, $len) : pack('CQ>', 255, $len);
  my $masked = join('', map { chr(ord(substr($payload, $_, 1)) ^ ord(substr($mask, $_ % 4, 1))) } 0 .. $len - 1);
  print {$self->{io}} $header . $mask . $masked or die Convex::Errors::transport_error("WebSocket write: $!", 'live');
}
1;
