use Test;
use lib $?FILE.IO.parent.parent.absolute;
use Convex::CroTransport;
use Convex::Errors;
use Convex::HTTP;

# Real loopback HTTP coverage for the production Cro boundary. The fixture
# writes raw response bytes so Content-Length, chunked, EOF, invalid UTF-8, and
# slow-body behavior cannot be normalized by another HTTP framework first.

plan 14;

sub read-request(IO::Socket::INET:D $socket --> Nil) {
    my $request = '';
    until $request.contains("\r\n\r\n") {
        my $part = $socket.recv(4096);
        last unless $part.defined && $part.chars;
        $request ~= $part;
    }
    my ($headers, $body) = $request.split("\r\n\r\n", 2);
    my $length = 0;
    for $headers.lines -> $line {
        $length = $0.Int if $line ~~ /:i ^ 'Content-Length:' \s* (\d+) /;
    }
    while $body.encode('utf8').bytes < $length {
        my $part = $socket.recv($length - $body.encode('utf8').bytes);
        last unless $part.defined && $part.chars;
        $body ~= $part;
    }
    Nil
}

# Each item is [bytes-or-text, delay-before-write]. A fresh listener per case
# proves a failed response does not poison a later request through connection
# reuse or fixture state.
sub raw-response(@parts --> Str) {
    my $listener = IO::Socket::INET.new(
        localhost => '127.0.0.1',
        localport => 0,
        listen => True
    );
    my $port = $listener.localport;
    start {
        my $socket = $listener.accept;
        $listener.close;
        read-request($socket);
        for @parts -> $part {
            sleep $part[1] if $part[1] > 0;
            my $bytes = $part[0] ~~ Blob ?? $part[0] !! $part[0].encode('utf8');
            # IO::Socket::INET.write is already a blocking, unbuffered
            # syscall; there is no .flush to pair it with.
            try $socket.write($bytes);
        }
        try $socket.close;
    }
    "http://127.0.0.1:$port/api/query"
}

sub call(Str:D $url, Real:D :$deadline = 2 --> Convex::HTTP::Response) {
    Convex::CroTransport::CroHTTP.new(:$deadline).post-json(
        $url,
        '{}',
        { content-type => 'application/json' }
    )
}

my $content-length-body = '{"status":"success","value":1}';
my $content-length = call(raw-response([
    ["HTTP/1.1 200 OK\r\nContent-Length: {$content-length-body.encode('utf8').bytes}\r\nConnection: close\r\n\r\n", 0],
    [$content-length-body.substr(0, 9), 0],
    [$content-length-body.substr(9), 0.02]
]));
is $content-length.status, 200, 'Content-Length response keeps its status';
is decode-envelope($content-length, 'query')<value>, 1,
    'Content-Length body is assembled incrementally';

my $chunked = call(raw-response([
    ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", 0],
    ["10\r\n\{\"status\":\"succe\r\n", 0],
    ["e\r\nss\",\"value\":2}\r\n", 0.02],
    ["0\r\n\r\n", 0]
]));
is decode-envelope($chunked, 'query')<value>, 2,
    'chunked body split across writes is decoded';

my $eof = call(raw-response([
    # The trailing comma matters: without it, Raku's single-argument
    # flattening rule collapses this one-element outer array into the inner
    # [text, delay] pair itself, so `raw-response` receives a flat 2-item
    # list instead of a list of one 2-item part.
    ["HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n\{\"status\":\"success\",\"value\":3\}", 0],
]));
is decode-envelope($eof, 'query')<value>, 3, 'EOF-delimited response is decoded';

throws-like {
    call(raw-response([
        ["HTTP/1.1 200 OK\r\nContent-Length: 2097153\r\nConnection: close\r\n\r\n", 0],
    ]))
}, X::Convex::Transport, 'declared over-limit response is rejected before accumulation';

my $large = 'x' x 1_048_576;
throws-like {
    call(raw-response([
        ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", 0],
        ["100000\r\n$large\r\n", 0],
        ["100000\r\n$large\r\n", 0],
        ["1\r\nx\r\n0\r\n\r\n", 0]
    ]))
}, X::Convex::Transport, 'chunked response cannot cross the running byte bound';

my $started = now;
throws-like {
    call(
        raw-response([
            ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", 0],
            ["1\r\nx\r\n", 0.15],
            ["1\r\ny\r\n", 0.15],
            ["0\r\n\r\n", 0.15]
        ]),
        deadline => 0.2
    )
}, X::Convex::Transport, 'slow chunked body obeys one absolute deadline';
ok now - $started < 1, 'slow-body failure is bounded rather than per-chunk refreshed';

throws-like {
    call(raw-response([
        ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n", 0],
        [Blob.new(0xC3, 0x28), 0]
    ]))
}, X::Convex::Protocol, 'invalid UTF-8 is a protocol error';

my $error-body = '{"status":"error","errorMessage":"fixture boom","errorData":{"code":"E560"},"logLines":["fixture log"]}';
my $function-error;
try {
    decode-envelope(call(raw-response([
        ["HTTP/1.1 560 Fixture\r\nContent-Length: {$error-body.encode('utf8').bytes}\r\nConnection: close\r\n\r\n$error-body", 0],
    ])), 'query');
    CATCH { when X::Convex::Function { $function-error = $_ } }
}
ok $function-error.defined, 'HTTP 560 structured envelope remains a FunctionError';
is $function-error.data<code>, 'E560', 'HTTP 560 preserves structured error data';
is $function-error.logs[0], 'fixture log', 'HTTP 560 preserves deployment logs';

throws-like {
    decode-envelope(call(raw-response([
        ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]", 0],
    ])), 'query')
}, X::Convex::Protocol, 'real transport rejects a non-object envelope';

my $recovered = call(raw-response([
    ["HTTP/1.1 200 OK\r\nContent-Length: {$content-length-body.encode('utf8').bytes}\r\nConnection: close\r\n\r\n$content-length-body", 0],
]));
is decode-envelope($recovered, 'query')<value>, 1,
    'a clean request succeeds after every failing fixture';
