unit module Convex::HTTP;

use JSON::Fast;
use Convex::Errors;

# Every limit below is a hard budget rather than a hint. The shared conformance
# container runs the client with 128 MiB of memory and a read-only filesystem,
# so a deployment (or a man in the middle) must never be able to make the
# client allocate an unbounded response.
our constant MAX-HTTP-BODY-BYTES = 2 * 1024 * 1024;
our constant MAX-HTTP-HEADER-BYTES = 16 * 1024;
our constant MAX-HTTP-STATUS = 599;
our constant MIN-HTTP-STATUS = 100;
our constant HTTP-DEADLINE-SECONDS = 10;

# Ordinary Raku HTTP/TLS libraries sit behind this tiny boundary. The client
# owns Convex envelope validation so no library-specific response object leaks
# into public behaviour or the conformance adapter.
class Response {
    has Int $.status is required;
    has Str $.body is required;
    has %.headers;
}

# Named HttpTransport rather than the shorter Transport: `use Convex::Errors`
# above pulls in `X::Convex::Transport`, and Raku's export of a deeply
# namespaced symbol like that also binds its bare leaf name (`Transport`) in
# this file's lexical scope. A role literally named `Transport` here would
# collide with that alias and fail to compile with a misleading "expecting
# any of: generic role" parse error.
role HttpTransport {
    # Implementations must make a POST using TLS when the endpoint is https,
    # cap headers and body before accumulating them, and return the raw
    # response even for non-2xx statuses. Convex puts a structured function
    # error in an ordinary response body, so the status code alone is never a
    # success/failure decision.
    #
    # The parameter is a plain `%headers`, not the attributive `%.headers`: an
    # attributive parameter would try to bind to an attribute of the role,
    # which does not exist here.
    method post-json(
        Str:D $url,
        Str:D $body,
        %headers,
        Int:D :$header-limit = MAX-HTTP-HEADER-BYTES,
        Int:D :$body-limit = MAX-HTTP-BODY-BYTES
        --> Response
    ) { ... }
}

# Check a value is a JSON object without accepting Raku associative lookalikes.
sub require-object($value, Str:D $where --> Hash) is export {
    $value ~~ Hash
        or die X::Convex::Protocol.new(detail => "$where must be a JSON object");
    $value
}

sub require-string($value, Str:D $where --> Str) is export {
    $value ~~ Str
        or die X::Convex::Protocol.new(detail => "$where must be a string");
    $value
}

sub optional-string-list($value, Str:D $where --> Array) is export {
    # Callers decide whether an omitted field means an empty list. Once the
    # field exists, JSON null is a value and must not be mistaken for omission.
    $value ~~ Positional
        or die X::Convex::Protocol.new(detail => "$where must be an array");
    for @$value -> $entry {
        $entry ~~ Str
            or die X::Convex::Protocol.new(detail => "$where must contain only strings");
    }
    [ @$value ]
}

# A transport may only report a status inside the HTTP range. Anything else
# means the transport itself mis-parsed the response line, and treating it as a
# Convex answer would hide the real failure.
sub require-http-status(Int:D $status --> Int) is export {
    MIN-HTTP-STATUS <= $status <= MAX-HTTP-STATUS
        or die X::Convex::Protocol.new(detail => "HTTP status $status is outside the protocol range");
    $status
}

# Parse the documented HTTP envelope before interpreting the status code. This
# preserves a structured FunctionError from a non-2xx response while still
# rejecting a non-2xx response that merely happens to contain a fake success.
sub decode-envelope(Response:D $response, Str:D $operation --> Hash) is export {
    require-http-status($response.status);
    $response.body.encode('utf8').bytes <= MAX-HTTP-BODY-BYTES
        or die X::Convex::Transport.new(
            detail => 'HTTP response exceeds byte limit',
            operation => $operation
        );

    my $decoded;
    try {
        $decoded = from-json($response.body);
        CATCH {
            default {
                die X::Convex::Protocol.new(
                    detail => "HTTP {$response.status} response is not valid JSON: {.message}"
                );
            }
        }
    }
    my %envelope = require-object($decoded, 'HTTP response');
    my $status = require-string(%envelope<status>, 'HTTP response status');

    if $status eq 'success' {
        %envelope<value>:exists
            or die X::Convex::Protocol.new(detail => 'success response omitted value');
        $response.status ~~ 200..299
            or die X::Convex::Protocol.new(
                detail => "HTTP {$response.status} cannot carry a successful Convex result"
            );
        return {
            value => %envelope<value>,
            logs => %envelope<logLines>:exists
                ?? optional-string-list(%envelope<logLines>, 'HTTP response logLines')
                !! []
        };
    }

    if $status eq 'error' {
        my $message = require-string(%envelope<errorMessage>, 'error response errorMessage');
        die X::Convex::Function.new(
            message-text => $message,
            operation => $operation,
            data => %envelope<errorData>,
            logs => %envelope<logLines>:exists
                ?? optional-string-list(%envelope<logLines>, 'error response logLines')
                !! []
        );
    }

    die X::Convex::Protocol.new(detail => "unknown HTTP response status '$status'");
}
