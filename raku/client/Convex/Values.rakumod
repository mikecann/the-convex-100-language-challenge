unit module Convex::Values;

use Convex::Errors;

# Convex encodes JSON numbers, and an integral count can legitimately arrive as
# `0`, `0.0`, or `0e0`. A demonstration that only accepted Raku `Int` would
# fail against a real deployment; one that called `.Int` on anything numeric
# would silently round a broken response into a plausible one.
#
# This helper accepts a value that is mathematically an integer and inside the
# signed 64-bit range, and rejects everything else: quoted numbers, booleans,
# fractions, NaN, the infinities, and out-of-range magnitudes.

our constant MIN-SAFE-INTEGER = -9_223_372_036_854_775_808;
our constant MAX-SAFE-INTEGER = 9_223_372_036_854_775_807;

our sub integral-int($value, Str:D $where --> Int) is export {
    # Bool is an Int in Raku, so JSON `true` would otherwise decode to 1.
    $value ~~ Bool
        and die X::Convex::Protocol.new(detail => "$where must be a number, not a boolean");
    $value ~~ Real
        or die X::Convex::Protocol.new(detail => "$where must be a JSON number");

    if $value ~~ Num {
        # NaN is the only value not equal to itself.
        $value == $value
            or die X::Convex::Protocol.new(detail => "$where must be a finite number");
        $value != Inf && $value != -Inf
            or die X::Convex::Protocol.new(detail => "$where must be a finite number");
    }

    $value == $value.Int
        or die X::Convex::Protocol.new(detail => "$where must be an integral number");
    my $integer = $value.Int;
    MIN-SAFE-INTEGER <= $integer <= MAX-SAFE-INTEGER
        or die X::Convex::Protocol.new(detail => "$where is outside the signed 64-bit range");
    $integer
}
