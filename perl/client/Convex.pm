package Convex;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(encode_json decode_json);
use URI;
use Convex::Errors;
use Convex::Live;

our $VERSION = '0.1.0';

# A compact native Perl client for Convex's documented JSON HTTP API and the
# explicitly pinned, unversioned /api/sync protocol profile.
sub new {
  my ($class, $deployment_url, %options) = @_;
  my $uri = URI->new($deployment_url);
  die Convex::Errors::protocol_error('Convex deployment URL must use http or https') unless $uri->scheme =~ /^https?$/ && $uri->host;
  die Convex::Errors::protocol_error('Convex deployment URL must not contain user information') if defined $uri->userinfo;
  $uri->query(undef); $uri->fragment(undef); $uri->path($uri->path =~ s{/$}{}r);
  return bless { deployment_url => $uri->as_string =~ s{/$}{}r, token => $options{bearer_token} || '', version => $options{client_version} || 'perl-0.1.0', closed => 0 }, $class;
}
sub query { shift->_call('query', @_) }
sub mutation { shift->_call('mutation', @_) }
sub action { shift->_call('action', @_) }
sub set_auth { die Convex::Errors::closed_error() if $_[0]{closed}; $_[0]{token} = $_[1] || ''; }
sub subscribe {
  my ($self, $path, $args) = @_; $self->_validate($path, $args); die Convex::Errors::closed_error() if $self->{closed};
  $self->{live} ||= Convex::Live->new($self->{deployment_url}, $self->{version}); return $self->{live}->subscribe($path, $args);
}
sub debug_disconnect_for_adapter { die Convex::Errors::closed_error() if $_[0]{closed}; die Convex::Errors::transport_error('Live WebSocket is not connected', 'live') unless $_[0]{live}; $_[0]{live}->debug_disconnect; }
sub close { my ($self) = @_; return if $self->{closed}++; $self->{live}->close if $self->{live}; }
sub _call {
  my ($self, $operation, $path, $args) = @_; $self->_validate($path, $args); die Convex::Errors::closed_error() if $self->{closed};
  my %headers = ('content-type' => 'application/json', accept => 'application/json', 'convex-client' => $self->{version}); $headers{authorization} = "Bearer $self->{token}" if length $self->{token};
  my $response = eval { HTTP::Tiny->new(timeout => 30, verify_SSL => 1)->post("$self->{deployment_url}/api/$operation", { headers => \%headers, content => encode_json({ path => $path, args => $args, format => 'json' }) }) };
  die Convex::Errors::transport_error("HTTP $operation: $@", $operation) if $@;
  die Convex::Errors::transport_error("HTTP $operation returned $response->{status}", $operation) unless $response->{success};
  my $body = eval { decode_json($response->{content}) }; die Convex::Errors::transport_error("decode HTTP response: $@", $operation) if $@;
  return { value => $body->{value}, logs => $body->{logLines} || [] } if ($body->{status} || '') eq 'success' && exists $body->{value};
  die Convex::Errors::function_error($body->{errorMessage} || 'function failed', $body->{errorData}, $body->{logLines} || []) if ($body->{status} || '') eq 'error';
  die Convex::Errors::protocol_error('HTTP response has an unknown Convex status');
}
sub _validate { my ($self, $path, $args) = @_; die Convex::Errors::protocol_error('Convex function path is required') unless defined $path && length $path; die Convex::Errors::protocol_error('Convex arguments must be a named JSON object') unless ref($args) eq 'HASH'; eval { encode_json($args); 1 } or die Convex::Errors::protocol_error("encode Convex arguments: $@"); }
1;
