package Convex::WebSocket;

use strict;
use warnings;

use Digest::SHA qw(sha1);
use IO::Select;
use IO::Socket::INET;
use IO::Socket::SSL;
use JSON::PP     qw(encode_json);
use MIME::Base64 qw(encode_base64);
use Time::HiRes  qw(time);

use Convex::Errors;

use constant GUID              => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
use constant MAX_MESSAGE_BYTES => 2 * 1024 * 1024;
use constant FRAME_READ_DEADLINE_SECONDS => 2;
use constant UPGRADE_DEADLINE_SECONDS    => 2;

sub connect {
    my ( $class, $url, $client_version ) = @_;
    my $target = _parse_websocket_url($url);
    my $tcp    = IO::Socket::INET->new(
        PeerHost => $target->{host},
        PeerPort => $target->{port},
        Proto    => 'tcp',
        Timeout  => 2,
      )
      or die Convex::Errors::transport_error( "WebSocket connect: $!", 'live' );
    $tcp->autoflush(1);

    my $io = $tcp;
    if ( $target->{scheme} eq 'wss' ) {
        $io = IO::Socket::SSL->start_SSL(
            $tcp,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER(),
            SSL_hostname    => $target->{host},
            Timeout         => 2,
          )
          or die Convex::Errors::transport_error(
            'TLS handshake: ' . IO::Socket::SSL::errstr(), 'live' );
    }

    my $key = encode_base64( _random_bytes(16), q{} );
    print {$io} join( "\r\n",
        "GET $target->{path} HTTP/1.1",
        "Host: $target->{authority}",
        'Upgrade: websocket',
        'Connection: Upgrade',
        "Sec-WebSocket-Key: $key",
        'Sec-WebSocket-Version: 13',
        "Convex-Client: $client_version",
        q{},
        q{},
      )
      or die Convex::Errors::transport_error( "WebSocket upgrade write: $!",
        'live' );

    my $headers = _read_headers( $io, time + UPGRADE_DEADLINE_SECONDS );
    die Convex::Errors::protocol_error('WebSocket upgrade was rejected')
      unless $headers->{_status} =~ m{\AHTTP/1\.[01] 101\b};
    my $expected = encode_base64( sha1( $key . GUID ), q{} );
    die Convex::Errors::protocol_error(
        'WebSocket upgrade returned an invalid accept key')
      unless ( $headers->{'sec-websocket-accept'} // q{} ) eq $expected;

    return bless { io => $io, tcp => $tcp }, $class;
}

sub from_io_for_test {
    my ( $class, $io ) = @_;
    return bless { io => $io }, $class;
}

sub io {
    return $_[0]{io};
}

sub pending {
    my ($self) = @_;
    return
         $self->{io}
      && $self->{io}->can('pending')
      && $self->{io}->pending > 0;
}

sub write_json {
    my ( $self, $value ) = @_;
    return $self->_write_frame( 1, encode_json($value) );
}

sub close_now {
    my ($self) = @_;
    eval { close $self->{io} if $self->{io}; };
    $self->{io} = undef;
    return;
}

sub close {
    my ($self) = @_;
    eval {
        $self->_write_frame( 8, pack( 'n', 1000 ) . 'client closed' )
          if $self->{io};
    };
    $self->close_now;
    return;
}

sub read_message {
    my ($self)   = @_;
    my $deadline = time + FRAME_READ_DEADLINE_SECONDS;
    my $message  = q{};
    my $opcode;

    while (1) {
        my ( $final, $kind, $payload ) = $self->_read_frame($deadline);
        if ( $kind == 0 ) {
            die Convex::Errors::protocol_error(
                'unexpected WebSocket continuation')
              unless defined $opcode;
            $message .= $payload;
        }
        elsif ( $kind == 1 ) {
            die Convex::Errors::protocol_error(
                'interleaved WebSocket text messages')
              if defined $opcode;
            $opcode = $kind;
            $message .= $payload;
        }
        elsif ( $kind == 8 ) {
            eval { $self->_write_frame( 8, $payload ) };
            return;
        }
        elsif ( $kind == 9 ) {
            $self->_write_frame( 10, $payload );
            next;
        }
        elsif ( $kind == 10 ) {
            next;
        }
        else {
            die Convex::Errors::protocol_error(
                "unsupported WebSocket opcode $kind");
        }

        die Convex::Errors::protocol_error('WebSocket message exceeds limit')
          if length($message) > MAX_MESSAGE_BYTES;
        return $message if $final;
    }
}

sub _read_headers {
    my ( $io, $deadline ) = @_;
    my $raw = q{};
    while ( $raw !~ /\r\n\r\n\z/ ) {
        $raw .= _read_exact_from( $io, 1, $deadline, 'WebSocket upgrade' );
        die Convex::Errors::protocol_error('WebSocket headers too large')
          if length($raw) > 32 * 1024;
    }

    my @lines   = split /\r\n/, $raw;
    my %headers = ( _status => shift @lines );
    for my $line (@lines) {
        next unless $line =~ /:/;
        my ( $key, $value ) = split /:\s*/, $line, 2;
        $headers{ lc $key } = $value;
    }
    return \%headers;
}

sub _read_exact {
    my ( $self, $length, $deadline ) = @_;
    return _read_exact_from( $self->{io}, $length, $deadline,
        'WebSocket frame' );
}

# Once a frame read begins it has one absolute deadline. A timeout abandons
# that connection, so no consumed byte is ever reinterpreted as a new header.
sub _read_exact_from {
    my ( $io, $length, $deadline, $context ) = @_;
    my $out = q{};
    while ( length($out) < $length ) {
        my $remaining = $deadline - time;
        die Convex::Errors::transport_error(
            "$context timed out during partial read", 'live' )
          if $remaining <= 0;

        # TLS can already hold decrypted bytes even when the underlying file
        # descriptor is no longer readable. Consume that buffer before asking
        # select(2), otherwise a length field or payload can falsely time out.
        my @ready =
          $io->can('pending') && $io->pending > 0
          ? ($io)
          : IO::Select->new($io)->can_read($remaining);
        die Convex::Errors::transport_error(
            "$context timed out during partial read", 'live' )
          unless @ready;
        my $read = sysread( $io, my $chunk, $length - length($out) );
        die Convex::Errors::transport_error(
            "$context closed during partial read", 'live' )
          unless $read;
        $out .= $chunk;
    }
    return $out;
}

sub _read_frame {
    my ( $self, $deadline ) = @_;
    my ( $first, $second ) = unpack 'CC', $self->_read_exact( 2, $deadline );
    my $final = $first & 128;
    my $kind  = $first & 15;
    die Convex::Errors::protocol_error('server frame was masked')
      if $second & 128;

    my $length = $second & 127;
    $length = unpack 'n', $self->_read_exact( 2, $deadline )
      if $length == 126;
    $length = unpack 'Q>', $self->_read_exact( 8, $deadline )
      if $length == 127;
    die Convex::Errors::protocol_error('WebSocket frame exceeds limit')
      if $length > MAX_MESSAGE_BYTES;
    die Convex::Errors::protocol_error('fragmented or oversized control frame')
      if $kind >= 8 && ( !$final || $length > 125 );

    return ( $final, $kind, $self->_read_exact( $length, $deadline ) );
}

sub _write_frame {
    my ( $self, $kind, $payload ) = @_;
    die Convex::Errors::closed_error() unless $self->{io};
    my $length = length $payload;
    my $mask   = _random_bytes(4);
    my $header = pack 'C', 128 | $kind;
    if ( $length < 126 ) {
        $header .= pack 'C', 128 | $length;
    }
    elsif ( $length <= 65_535 ) {
        $header .= pack 'Cn', 254, $length;
    }
    else {
        $header .= pack 'CQ>', 255, $length;
    }
    my $masked = join q{}, map {
        chr( ord( substr $payload, $_, 1 ) ^ ord( substr $mask, $_ % 4, 1 ) )
    } 0 .. $length - 1;
    print { $self->{io} } $header . $mask . $masked
      or die Convex::Errors::transport_error( "WebSocket write: $!", 'live' );
    return;
}

sub _parse_websocket_url {
    my ($url) = @_;
    die Convex::Errors::protocol_error('Live URL must use ws or wss')
      unless $url =~ m{\A(wss?)://([^/?#]+)(/[^?#]*)?\z};
    my ( $scheme, $authority, $path ) = ( $1, $2, $3 // '/' );
    my ( $host, $port );
    if ( $authority =~ /\A\[([^]]+)\](?::(\d+))?\z/ ) {
        ( $host, $port ) = ( $1, $2 );
    }
    elsif ( $authority =~ /\A([^:]+)(?::(\d+))?\z/ ) {
        ( $host, $port ) = ( $1, $2 );
    }
    else {
        die Convex::Errors::protocol_error('invalid Live authority');
    }
    $port //= $scheme eq 'wss' ? 443 : 80;
    return {
        scheme    => $scheme,
        authority => $authority,
        host      => $host,
        port      => $port,
        path      => $path,
    };
}

sub _random_bytes {
    my ($length) = @_;
    return join q{}, map { chr int rand 256 } 1 .. $length;
}

1;
