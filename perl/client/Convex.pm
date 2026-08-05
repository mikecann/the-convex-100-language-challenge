package Convex;

use strict;
use warnings;

use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);

use Convex::Errors;
use Convex::Live;

our $VERSION = '0.1.0';

# A compact native Perl client for Convex's documented JSON HTTP API and the
# explicitly pinned, unversioned /api/sync protocol profile.
sub new {
    my ( $class, $deployment_url, %options ) = @_;
    my $parsed = _parse_deployment_url($deployment_url);

    return bless {
        deployment_url => $parsed->{base_url},
        token          => $options{bearer_token}   // q{},
        version        => $options{client_version} // 'perl-0.1.0',
        closed         => 0,
    }, $class;
}

sub query {
    my $self = shift;
    return $self->_call( 'query', @_ );
}

sub mutation {
    my $self = shift;
    return $self->_call( 'mutation', @_ );
}

sub action {
    my $self = shift;
    return $self->_call( 'action', @_ );
}

sub set_auth {
    my ( $self, $token ) = @_;
    die Convex::Errors::closed_error() if $self->{closed};
    $self->{token} = $token // q{};
    return;
}

sub subscribe {
    my ( $self, $path, $args ) = @_;
    $self->_validate( $path, $args );
    die Convex::Errors::closed_error() if $self->{closed};

    $self->{live} //=
      Convex::Live->new( $self->{deployment_url}, $self->{version} );
    return $self->{live}->subscribe( $path, $args );
}

# This hook is deliberately adapter-only. Application code should not need to
# break a healthy transport to test reconnect behaviour.
sub debug_disconnect_for_adapter {
    my ($self) = @_;
    die Convex::Errors::closed_error() if $self->{closed};
    die Convex::Errors::transport_error( 'Live WebSocket is not connected',
        'live' )
      unless $self->{live};
    return $self->{live}->debug_disconnect;
}

sub close {
    my ($self) = @_;
    return               if $self->{closed}++;
    $self->{live}->close if $self->{live};
    return;
}

sub _call {
    my ( $self, $operation, $path, $args ) = @_;
    $self->_validate( $path, $args );
    die Convex::Errors::closed_error() if $self->{closed};

    my %headers = (
        'content-type'  => 'application/json',
        'accept'        => 'application/json',
        'convex-client' => $self->{version},
    );
    $headers{authorization} = "Bearer $self->{token}"
      if length $self->{token};

    my $response = eval {
        HTTP::Tiny->new( timeout => 30, verify_SSL => 1 )->post(
            "$self->{deployment_url}/api/$operation",
            {
                headers => \%headers,
                content => encode_json(
                    {
                        path   => $path,
                        args   => $args,
                        format => 'json',
                    }
                ),
            }
        );
    };
    die Convex::Errors::transport_error( "HTTP $operation: $@", $operation )
      if $@;

    # Convex function failures use HTTP 560. Decode the Convex envelope before
    # classifying the HTTP status so errorData and logs survive intact.
    my $body = eval { decode_json( $response->{content} ) };
    if ( !$@ && ref($body) eq 'HASH' ) {
        if ( ( $body->{status} // q{} ) eq 'error' ) {
            die Convex::Errors::function_error(
                $body->{errorMessage} // 'function failed',
                $body->{errorData}, $body->{logLines} // [],
            );
        }
        if ( ( $body->{status} // q{} ) eq 'success'
            && exists $body->{value} )
        {
            return {
                value => $body->{value},
                logs  => $body->{logLines} // [],
            };
        }
    }

    die Convex::Errors::transport_error(
        "HTTP $operation returned $response->{status}", $operation )
      unless $response->{success};
    die Convex::Errors::transport_error( "decode HTTP response: $@",
        $operation )
      if $@;
    die Convex::Errors::protocol_error(
        'HTTP response has an unknown Convex status');
}

sub _validate {
    my ( $self, $path, $args ) = @_;
    die Convex::Errors::protocol_error('Convex function path is required')
      unless defined $path && length $path;
    die Convex::Errors::protocol_error(
        'Convex arguments must be a named JSON object')
      unless ref($args) eq 'HASH';
    eval { encode_json($args); 1 }
      or die Convex::Errors::protocol_error("encode Convex arguments: $@");
    return;
}

sub _parse_deployment_url {
    my ($url) = @_;
    die Convex::Errors::protocol_error(
        'Convex deployment URL must use http or https')
      unless defined $url
      && $url =~ m{\A(https?)://([^/?#]+)(/[^?#]*)?\z};

    my ( $scheme, $authority, $path ) = ( $1, $2, $3 // q{} );
    die Convex::Errors::protocol_error(
        'Convex deployment URL must not contain user information')
      if $authority =~ /@/;
    $path =~ s{/+\z}{};
    return {
        scheme    => $scheme,
        authority => $authority,
        base_url  => "$scheme://$authority$path",
    };
}

1;
