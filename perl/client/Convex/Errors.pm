package Convex::Errors;

use strict;
use warnings;

# Typed errors let the conformance adapter preserve the distinction between a
# Convex function failure, malformed protocol data, and a broken transport.
sub function_error {
    bless {
        kind    => 'FunctionError',
        message => $_[0],
        data    => $_[1],
        logs    => $_[2] || []
      },
      'Convex::FunctionError';
}

sub protocol_error {
    bless { kind => 'ProtocolError', message => $_[0] },
      'Convex::ProtocolError';
}

sub transport_error {
    bless {
        kind      => 'TransportError',
        message   => $_[0],
        operation => $_[1] || 'live'
      },
      'Convex::TransportError';
}

sub closed_error {
    bless {
        kind    => 'ClosedError',
        message => $_[0] || 'Convex client is closed'
      },
      'Convex::ClosedError';
}

package Convex::Error;
use overload '""' => sub { $_[0]{message} }, fallback => 1;

package Convex::FunctionError;
our @ISA = ('Convex::Error');

package Convex::ProtocolError;
our @ISA = ('Convex::Error');

package Convex::TransportError;
our @ISA = ('Convex::Error');

package Convex::ClosedError;
our @ISA = ('Convex::Error');
1;
