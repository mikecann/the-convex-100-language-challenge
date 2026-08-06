import std/[base64, json, unittest]
import ../protocol

suite "Nim Convex decoding":
  test "accepts mathematically integral JSON floats":
    check integralCount(parseJson("0.0")) == 0.0
    check integralCount(parseJson("1")) == 1.0
  test "rejects fractional, quoted, and non-finite values":
    expect ValueError: discard integralCount(parseJson("1.5"))
    expect ValueError: discard integralCount(parseJson("\"1\""))
    expect ValueError: discard integralCount(parseJson("1e400"))
  test "orders protocol timestamps numerically across 255 to 256":
    var before = newString(8)
    before[0] = char(255)
    var after = newString(8)
    after[0] = char(0)
    after[1] = char(1)
    check compareTimestamps(encode(before), encode(after)) < 0
    check compareTimestamps(encode(after), encode(before)) > 0
