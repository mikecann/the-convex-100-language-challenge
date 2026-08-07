unit module Convex;

use JSON::Fast;
use Convex::Errors;
use Convex::HTTP;
use Convex::Live;

# The value and the deployment's log lines travel together so a caller can show
# what the function printed next to what it returned.
class Result {
    has $.value is required;
    has @.logs;
}

# Native Raku Convex client. The injected transport makes the protocol logic
# deterministic in tests while the production transport uses Cro for ordinary
# HTTP/TLS mechanics. Everything Convex-specific -- the request envelope, the
# response taxonomy, authentication lifetime, and the byte budgets -- is
# implemented here in Raku.
class Client {
    has Str $.deployment-url is required;
    has Convex::HTTP::HttpTransport $.transport is required;
    has Str $.client-version = 'raku-0.1.0';
    has Str $!bearer-token = '';
    has Bool $!closed = False;
    has Lock $!lock .= new;

    # TWEAK runs after ordinary attribute initialisation, so normalising the URL
    # here cannot be undone by a default initialiser. A custom BUILD would have
    # to re-implement all of that binding by hand.
    submethod TWEAK(Str :$bearer-token = '') {
        $!deployment-url = normalize-deployment-url($!deployment-url);
        validate-bearer-token($bearer-token);
        $!bearer-token = $bearer-token;
    }

    # Replacing authentication affects subsequent HTTP operations. Live auth is
    # deliberately deferred in this first profile rather than silently ignored;
    # the manifest records that limitation.
    method set-auth(Str:D $token --> Nil) {
        validate-bearer-token($token);
        $!lock.protect({
            die X::Convex::Closed.new if $!closed;
            $!bearer-token = $token;
        });
        Nil
    }

    method query(Str:D $path, %args = %() --> Result) {
        self!call('query', $path, %args)
    }

    method mutation(Str:D $path, %args = %() --> Result) {
        self!call('mutation', $path, %args)
    }

    method action(Str:D $path, %args = %() --> Result) {
        self!call('action', $path, %args)
    }

    # Live is a separate object so an HTTP-only user never starts a socket
    # worker. The client still validates the call shape so both surfaces reject
    # the same bad input.
    method subscribe(
        Str:D $path,
        %args = %(),
        Convex::Live::Owner:D :$live-owner!
        --> Convex::Live::Subscription
    ) {
        self!validate-call($path, %args);
        $!lock.protect({ die X::Convex::Closed.new if $!closed });
        $live-owner.subscribe($path, %args)
    }

    method close(--> Nil) {
        $!lock.protect({ $!closed = True });
        Nil
    }

    method !call(Str:D $operation, Str:D $path, %args --> Result) {
        self!validate-call($path, %args);
        my $token = $!lock.protect({
            die X::Convex::Closed.new if $!closed;
            $!bearer-token
        });
        my %headers = (
            'accept' => 'application/json',
            'content-type' => 'application/json',
            'convex-client' => $!client-version
        );
        %headers<authorization> = "Bearer $token" if $token.chars;
        # `:!pretty` matters: JSON::Fast pretty-prints by default, and a
        # multi-line request body would be both wasteful and, in the adapter,
        # a protocol violation.
        my $body = to-json({ path => $path, args => %args, format => 'json' }, :!pretty);
        $body.encode('utf8').bytes <= Convex::HTTP::MAX-HTTP-BODY-BYTES
            or die X::Convex::Protocol.new(detail => 'request exceeds HTTP byte limit');
        my $response = $!transport.post-json(
            "{$!deployment-url}/api/$operation",
            $body,
            %headers
        );
        my %decoded = decode-envelope($response, $operation);
        Result.new(value => %decoded<value>, logs => %decoded<logs>)
    }

    method !validate-call(Str:D $path, %args --> Nil) {
        # The shared adapter schema requires at least three characters, which is
        # the shortest possible `a:b` module/function reference.
        $path.chars >= 3
            or die X::Convex::Protocol.new(detail => 'Convex function path must be module:function');
        $path.contains(':')
            or die X::Convex::Protocol.new(detail => 'Convex function path must contain a colon');
        # Serialising first catches NaN, closures, and other values that cannot
        # faithfully cross Convex's JSON transport before any state is modified.
        try {
            to-json(%args, :!pretty);
            CATCH {
                default {
                    die X::Convex::Protocol.new(
                        detail => "arguments are not JSON encodable: {.message}"
                    );
                }
            }
        }
        Nil
    }
}

sub validate-bearer-token(Str:D $token --> Nil) {
    # Raku strings are grapheme-based: an adjacent CR+LF collapses into one
    # synthetic grapheme (Unicode's normal-form-grapheme rule for the CRLF
    # newline sequence), so `.contains("\r")` and `.contains("\n")` each miss
    # a token whose line break is exactly "\r\n" -- the string no longer has a
    # lone \r or lone \n grapheme to find. A regex character class matches
    # against the underlying codepoints instead, so it catches a lone \r, a
    # lone \n, and a fused \r\n alike.
    $token ~~ /<[\r\n]>/
        and die X::Convex::Protocol.new(
            detail => 'bearer token must not contain a line break'
        );
    Nil
}

# Accept only an absolute http/https URL with a host, then strip trailing
# slashes so `$url/api/query` is always well formed. Query and fragment text is
# rejected rather than silently discarded because it is not part of a Convex
# deployment origin.
# Credentials in the authority are rejected outright: they would end up in the
# WebSocket URL and in error messages.
our sub normalize-deployment-url(Str:D $url --> Str) is export {
    $url.comb.first({ .ord <= 32 || .ord == 127 }).defined
        and die X::Convex::Protocol.new(
            detail => 'Convex URL must not contain whitespace or control characters'
        );
    ($url.contains('?') || $url.contains('#'))
        and die X::Convex::Protocol.new(
            detail => 'Convex URL must not contain a query or fragment'
        );
    $url ~~ / ^
        $<scheme> = ( <[A..Za..z]> <[A..Za..z0..9+.\-]>* )
        '://'
        $<authority> = ( <-[/?#]>+ )
        $<path> = ( <-[?#]>* )
    /
        or die X::Convex::Protocol.new(detail => 'Convex URL must be an absolute http or https URL');

    my $scheme = ~$<scheme>;
    $scheme.lc eq 'http' | 'https'
        or die X::Convex::Protocol.new(detail => "Convex URL scheme '$scheme' must be http or https");
    my $authority = ~$<authority>;
    $authority.contains('@')
        and die X::Convex::Protocol.new(detail => 'Convex URL must not contain credentials');
    my $path = (~$<path>).subst(/ '/'+ $ /, '');
    "{$scheme.lc}://$authority$path"
}
