use Test;
use JSON::Fast;
use lib $?FILE.IO.parent.parent.absolute;
use Convex;
use Convex::Errors;
use Convex::HTTP;

# HTTP envelope and request coverage.
#
# The response taxonomy is the part of the HTTP surface that is easy to get
# subtly wrong: Convex reports a function rejection inside the body of an
# ordinary response, so neither the status code nor the body alone is enough to
# decide what happened.

plan 26;

sub response(Int:D $status, Str:D $body --> Convex::HTTP::Response) {
    Convex::HTTP::Response.new(status => $status, body => $body)
}

# --------------------------------------------------------------------------
# Success
# --------------------------------------------------------------------------

my %success = decode-envelope(
    response(200, '{"status":"success","value":{"count":0.0},"logLines":["[LOG] demo:state"]}'),
    'query'
);
ok %success<value><count> == 0,
    'an integral decimal stays a number for the example decoder to interpret';
is %success<logs>[0], '[LOG] demo:state', 'log lines are preserved for the caller';

nok decode-envelope(response(200, '{"status":"success","value":null}'), 'query')<value>.defined,
    'a JSON null value is a successful result, not a missing one';

is-deeply decode-envelope(response(200, '{"status":"success","value":[1,2]}'), 'query')<logs>,
    [], 'an absent logLines array becomes an empty list';

# --------------------------------------------------------------------------
# Structured function errors
# --------------------------------------------------------------------------

my $function-error;
try {
    decode-envelope(
        response(200, '{"status":"error","errorMessage":"boom","errorData":{"code":"X"}}'),
        'mutation'
    );
    CATCH { when X::Convex::Function { $function-error = $_ } }
}
ok $function-error.defined, 'a status of error raises a structured function error';
is $function-error.data<code>, 'X', 'the structured error data survives decoding';
is $function-error.operation, 'mutation', 'the failing operation is recorded';

# A rejection reported with a non-2xx status is still a function error, because
# Convex uses the response body to describe it.
my $error-with-status;
try {
    decode-envelope(response(400, '{"status":"error","errorMessage":"boom"}'), 'query');
    CATCH { when X::Convex::Function { $error-with-status = $_ } }
}
ok $error-with-status.defined, 'a non-2xx structured rejection is not downgraded to transport';

# --------------------------------------------------------------------------
# Envelope taxonomy
# --------------------------------------------------------------------------

throws-like { decode-envelope(response(503, '{"status":"success","value":0}'), 'query') },
    X::Convex::Protocol, 'a non-2xx response cannot masquerade as success';
throws-like { decode-envelope(response(200, '{"status":"success"}'), 'query') },
    X::Convex::Protocol, 'a success response without a value is rejected';
throws-like { decode-envelope(response(500, '{"status":"error"}'), 'query') },
    X::Convex::Protocol, 'an error without a string errorMessage is rejected';
throws-like { decode-envelope(response(200, '{"status":"weird","value":1}'), 'query') },
    X::Convex::Protocol, 'an unknown envelope status is rejected';
throws-like { decode-envelope(response(200, '[]'), 'query') },
    X::Convex::Protocol, 'a JSON array is not an HTTP envelope';
throws-like { decode-envelope(response(200, '"success"'), 'query') },
    X::Convex::Protocol, 'a JSON string is not an HTTP envelope';
throws-like { decode-envelope(response(200, 'not json'), 'query') },
    X::Convex::Protocol, 'invalid JSON is not flattened into a transport success';
throws-like { decode-envelope(response(999, '{"status":"success","value":1}'), 'query') },
    X::Convex::Protocol, 'a status outside the HTTP range is a protocol failure';
throws-like {
    decode-envelope(
        response(200, '{"status":"success","value":1,"logLines":[42]}'),
        'query'
    )
}, X::Convex::Protocol, 'non-string log lines are rejected rather than stringified';
throws-like {
    decode-envelope(
        response(200, '{"status":"success","value":1,"logLines":null}'),
        'query'
    )
}, X::Convex::Protocol, 'an explicit null logLines is not mistaken for omission';

# --------------------------------------------------------------------------
# Request shape
# --------------------------------------------------------------------------

class RecordingTransport does Convex::HTTP::HttpTransport {
    has $.url is rw;
    has $.body is rw;
    has %.headers is rw;

    method post-json(
        Str:D $url,
        Str:D $body,
        %headers,
        Int:D :$header-limit = Convex::HTTP::MAX-HTTP-HEADER-BYTES,
        Int:D :$body-limit = Convex::HTTP::MAX-HTTP-BODY-BYTES
        --> Convex::HTTP::Response
    ) {
        $!url = $url;
        $!body = $body;
        %!headers = %headers;
        Convex::HTTP::Response.new(status => 200, body => '{"status":"success","value":1}')
    }
}

my $transport = RecordingTransport.new;
my $client = Convex::Client.new(
    deployment-url => 'https://example.convex.cloud/',
    transport => $transport
);
$client.query('demo:state', { room => 'r' });
is $transport.url, 'https://example.convex.cloud/api/query',
    'the query URL is built from the normalised deployment URL';
nok $transport.body.contains("\n"),
    'the request body is a single line, never pretty printed JSON';
is from-json($transport.body)<format>, 'json', 'the request declares the json value format';

$client.set-auth('token-value');
$client.query('demo:state', { room => 'r' });
is $transport.headers<authorization>, 'Bearer token-value',
    'a bearer token is sent once authentication is set';

throws-like { Convex::Client.new(deployment-url => 'ftp://example.com', transport => $transport) },
    X::Convex::Protocol, 'a non-HTTP deployment URL is refused';
throws-like {
    Convex::Client.new(
        deployment-url => 'https://example.convex.cloud/?ignored=1',
        transport => $transport
    )
}, X::Convex::Protocol, 'a deployment URL query is rejected rather than silently discarded';
throws-like { $client.set-auth("token\r\nInjected: true") },
    X::Convex::Protocol, 'a bearer token cannot inject another HTTP header';
throws-like {
    Convex::Client.new(
        deployment-url => 'https://example.convex.cloud',
        transport => $transport,
        bearer-token => "token\nInjected: true"
    )
}, X::Convex::Protocol, 'constructor authentication applies the same header safety check';
