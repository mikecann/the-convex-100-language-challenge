module c3_values;

import std::collections::object;
import std::encoding::json;

faultdef EXPECTED_INTEGRAL_NUMBER, OUT_OF_RANGE;

// Convex may serialise counter values as 1.0. This deliberately accepts only
// mathematically integral JSON numbers, never strings or fractional values.
fn int? parse_counter(String encoded)
{
    Object* value = json::tparse(encoded, JSON)!;
    if (value.type != double) return EXPECTED_INTEGRAL_NUMBER~;
    double number = value.f;
    if (number != (double)(int)number) return EXPECTED_INTEGRAL_NUMBER~;
    if (number > 2147483647.0 || number < -2147483648.0) return OUT_OF_RANGE~;
    return (int)number;
}
