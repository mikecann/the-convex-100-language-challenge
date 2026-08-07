unit module Convex::CroTransport;

use Cro::HTTP::Client;
use Convex::Errors;
use Convex::HTTP;

# Production ordinary HTTP/TLS transport. Cro is responsible only for the
# socket, TLS, and HTTP/1.1 mechanics. Convex response status and JSON
# envelopes are validated by Convex::HTTP after this boundary returns.
#
# Call sites marked `DOCKER-CHECK` are the ones the first Docker pass must
# confirm against the pinned Cro version.
class CroHTTP does Convex::HTTP::HttpTransport {
    has Real $.deadline = Convex::HTTP::HTTP-DEADLINE-SECONDS;
    method post-json(
        Str:D $url,
        Str:D $body,
        %headers,
        Int:D :$header-limit = Convex::HTTP::MAX-HTTP-HEADER-BYTES,
        Int:D :$body-limit = Convex::HTTP::MAX-HTTP-BODY-BYTES
        --> Convex::HTTP::Response
    ) {
        my $expires = now + $!deadline;
        my $encoded = $body.encode('utf8');
        $encoded.bytes <= $body-limit
            or die X::Convex::Protocol.new(detail => 'request exceeds HTTP byte limit');

        my $response;
        try {
            # The body is passed as a Blob so Cro sends the exact bytes this
            # client encoded. Handing it a Hash would let a body serializer
            # decide the wire format, which is Convex's decision, not Cro's.
            $response = await Cro::HTTP::Client.post(
                $url,
                headers => %headers,
                body => $encoded,
                # Cro applies this as one total request deadline across
                # connection, response headers, and the complete body. A peer
                # that continuously dribbles bytes cannot reset it.
                timeout => $!deadline,
                # A Convex deployment endpoint is final. Following an
                # attacker-controlled redirect would change the authenticated
                # origin and make the deadline/recovery proof ambiguous.
                follow => 0
            );
            CATCH {
                # DOCKER-CHECK: Cro throws X::Cro::HTTP::Error for 4xx and 5xx
                # responses and exposes the response on `.response`. Convex puts
                # a structured function error in the body of an ordinary error
                # response, so that response must survive rather than collapse
                # into a transport failure.
                when X::Cro::HTTP::Error {
                    $response = .response;
                }
                default {
                    die X::Convex::Transport.new(detail => .message, operation => 'http');
                }
            }
        }

        # A declared length over the limit is refused before the body is read,
        # and the decoded body is checked again afterwards so a lying or absent
        # Content-Length cannot bypass the budget.
        my $declared-length = $response.header('content-length');
        if $declared-length.defined {
            $declared-length ~~ / ^ \d+ $ /
                or die X::Convex::Protocol.new(detail => 'HTTP Content-Length is not decimal');
            $declared-length.Int <= $body-limit
                or die X::Convex::Transport.new(
                    detail => 'HTTP response declared over byte limit',
                    operation => 'http'
                );
        }

        my %response-headers;
        my $header-bytes = 0;
        # DOCKER-CHECK: `$response.headers` is a list of Cro::HTTP::Header with
        # `.name` and `.value`.
        for $response.headers -> $header {
            $header-bytes += $header.name.encode('utf8').bytes
                + $header.value.encode('utf8').bytes
                + 4;
            %response-headers{$header.name.lc} = $header.value;
        }
        $header-bytes <= $header-limit
            or die X::Convex::Transport.new(
                detail => 'HTTP response headers exceed byte limit',
                operation => 'http'
            );

        # Cro exposes response bytes as a Supply. Count each chunk before it is
        # appended so an absent or dishonest Content-Length cannot make
        # `body-text` allocate an unbounded response first.
        my $buffer = Buf.new;
        my $too-large = False;
        my $too-slow = False;
        try {
            react {
                whenever $response.body-byte-stream -> $chunk {
                    unless $chunk ~~ Blob {
                        die X::Convex::Protocol.new(
                            detail => 'HTTP body stream emitted a non-byte chunk'
                        );
                    }
                    if $buffer.bytes + $chunk.bytes > $body-limit {
                        $too-large = True;
                        done;
                    }
                    $buffer.append($chunk);
                    LAST done;
                }
                whenever Promise.at($expires) {
                    $too-slow = True;
                    done;
                }
            }
            CATCH {
                when X::Convex::Protocol { .rethrow }
                default {
                    die X::Convex::Transport.new(
                        detail => .message,
                        operation => 'http'
                    );
                }
            }
        }
        $too-large
            and die X::Convex::Transport.new(
                detail => 'HTTP response exceeds byte limit',
                operation => 'http'
            );
        $too-slow
            and die X::Convex::Transport.new(
                detail => 'HTTP response exceeded its absolute deadline',
                operation => 'http'
            );

        my $text;
        try {
            $text = $buffer.decode('utf8');
            CATCH {
                default {
                    die X::Convex::Protocol.new(
                        detail => 'HTTP response body is not valid UTF-8'
                    );
                }
            }
        }

        Convex::HTTP::Response.new(
            status => $response.status.Int,
            body => $text,
            headers => %response-headers
        )
    }
}
