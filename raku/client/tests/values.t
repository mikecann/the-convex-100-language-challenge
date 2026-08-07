use Test;
use JSON::Fast;
use lib $?FILE.IO.parent.parent.absolute;
use Convex::Errors;
use Convex::Values;

# The counter demonstration reads an integer out of JSON, and Convex may encode
# that integer as `0`, `0.0`, or `0e0`. These cases are decoded from real JSON
# text rather than from hand-built Raku numbers, so the test exercises what the
# deployment can actually send.

plan 12;

sub decoded(Str:D $json) { from-json("\{\"count\":$json\}")<count> }

is integral-int(decoded('0'), 'count'), 0, 'a JSON integer decodes to an Int';
is integral-int(decoded('0.0'), 'count'), 0, 'an integral decimal decodes to an Int';
is integral-int(decoded('1.0'), 'count'), 1, 'one encoded as 1.0 decodes to 1';
is integral-int(decoded('0e0'), 'count'), 0, 'an exponent form decodes to an Int';
is integral-int(decoded('-3'), 'count'), -3, 'a negative integer is accepted';
is integral-int(decoded('9223372036854775807'), 'count'), 9223372036854775807,
    'the largest signed 64-bit value is accepted';

throws-like { integral-int(decoded('0.5'), 'count') }, X::Convex::Protocol,
    'a fractional value is rejected instead of being rounded';
throws-like { integral-int(decoded('"1"'), 'count') }, X::Convex::Protocol,
    'a quoted number is rejected';
throws-like { integral-int(decoded('true'), 'count') }, X::Convex::Protocol,
    'a boolean is rejected even though Bool is an Int in Raku';
throws-like { integral-int(decoded('null'), 'count') }, X::Convex::Protocol,
    'a null is rejected';
throws-like { integral-int(Inf, 'count') }, X::Convex::Protocol,
    'an infinite value is rejected';
throws-like { integral-int(decoded('9223372036854775808'), 'count') }, X::Convex::Protocol,
    'a value past the signed 64-bit range is rejected';
