"""Unit tests for the hand-written JSON reader and writer."""

from json import J_ARRAY, J_NUMBER, J_OBJECT, J_STRING, Json, parse, quote


fn check(condition: Bool, label: String) raises:
    if not condition:
        raise Error("FAIL " + label)


fn expect_reject(text: String, label: String) raises:
    var rejected = False
    try:
        _ = parse(text)
    except:
        rejected = True
    check(rejected, label)


fn main() raises:
    var doc = parse('{"a":1,"b":[true,null,"x"],"c":{"d":-2.5e3}}')
    check(doc.kind(doc.root) == J_OBJECT, "root is an object")
    check(doc.as_int(doc.member(doc.root, "a")) == 1, "integer member")
    var array = doc.member(doc.root, "b")
    check(doc.kind(array) == J_ARRAY, "array member")
    check(doc.count(array) == 3, "array length")
    check(doc.truth(doc.item(array, 0)), "array boolean")
    check(doc.text(doc.item(array, 2)) == "x", "array string")
    var nested = doc.member(doc.member(doc.root, "c"), "d")
    check(doc.number(nested) == -2500.0, "exponent number")
    check(doc.member(doc.root, "missing") == -1, "absent member is -1")

    # Convex sends a whole count as either `0` or `0.0`; both decode, and a
    # genuinely fractional value must not be silently truncated.
    var integral = parse('{"count":1.0,"half":0.5}')
    check(
        integral.as_int(integral.member(integral.root, "count")) == 1,
        "1.0 is whole",
    )
    check(
        not integral.is_integral(integral.member(integral.root, "half")),
        "0.5 is not whole",
    )

    # Number tokens survive verbatim so an echoed value is unchanged.
    var numbers = parse('{"a":0.0,"b":42.5,"c":1e3}')
    check(
        numbers.dump(numbers.root) == '{"a":0.0,"b":42.5,"c":1e3}',
        "verbatim numbers",
    )

    # Text above U+007F round-trips as its own UTF-8 bytes.
    var unicode = parse('{"greeting":"Hello, 世界 👋"}')
    check(
        unicode.text(unicode.member(unicode.root, "greeting")) == "Hello, 世界 👋",
        "utf-8 passthrough",
    )
    check(
        unicode.dump(unicode.root) == '{"greeting":"Hello, 世界 👋"}', "utf-8 dump"
    )

    # Escapes, including a surrogate pair, decode to real codepoints.
    var escaped = parse('"a\\u0041\\ud83d\\ude00\\n"')
    check(escaped.text(escaped.root) == "aA😀\n", "escape decoding")
    check(quote(String('a\nb\\c"d')) == '"a\\nb\\\\c\\"d"', "escape encoding")

    # Document IDs arrive as plain strings and must stay strings.
    var identifier = parse('"jd7abc123"')
    check(identifier.kind(identifier.root) == J_STRING, "string document")

    expect_reject("{", "unterminated object")
    expect_reject('{"a":}', "missing value")
    expect_reject("[1,]", "trailing comma")
    expect_reject("01", "leading zero is still one token then junk")
    expect_reject('"\\ud800"', "unpaired surrogate")
    expect_reject("1 2", "trailing document")
    expect_reject("nul", "truncated literal")
    expect_reject('{"a":1}x', "trailing bytes")

    print("PASS mojo json")
