import haxe.io.Bytes;

/** Strict UTF-8 decoding.
 *
 * Neko strings are raw byte sequences, so the standard library's length and
 * validation helpers are byte-oriented and lenient. RFC 6455 requires text
 * frames to be rejected when they carry overlong encodings, surrogate halves,
 * or scalar values above U+10FFFF, and the adapter's JSON Schema boundary is
 * expressed in Unicode code points rather than bytes. Both needs are met here
 * with one explicit decoder rather than a permissive runtime primitive. */
class Utf8Text {
  /** Number of Unicode scalar values, or -1 when the bytes are not valid
   * UTF-8. Callers that only need validity ignore the count. */
  public static function scalarCount(bytes:Bytes):Int {
    var index = 0;
    var count = 0;
    while (index < bytes.length) {
      var lead = bytes.get(index);
      var following = 0;
      var scalar = 0;
      var lowest = 0;
      if (lead < 0x80) {
        index++;
        count++;
        continue;
      } else if (lead >= 0xC2 && lead <= 0xDF) {
        // 0xC0 and 0xC1 can only ever start an overlong two-byte sequence.
        following = 1;
        scalar = lead & 0x1F;
        lowest = 0x80;
      } else if (lead >= 0xE0 && lead <= 0xEF) {
        following = 2;
        scalar = lead & 0x0F;
        lowest = 0x800;
      } else if (lead >= 0xF0 && lead <= 0xF4) {
        following = 3;
        scalar = lead & 0x07;
        lowest = 0x10000;
      } else {
        return -1;
      }
      // A truncated tail is invalid rather than a partial success.
      if (index + following >= bytes.length) return -1;
      for (offset in 1...following + 1) {
        var continuation = bytes.get(index + offset);
        if (continuation < 0x80 || continuation > 0xBF) return -1;
        scalar = (scalar << 6) | (continuation & 0x3F);
      }
      // Reject overlong forms, UTF-16 surrogate halves, and out-of-range
      // scalars after reassembling the value.
      if (scalar < lowest) return -1;
      if (scalar >= 0xD800 && scalar <= 0xDFFF) return -1;
      if (scalar > 0x10FFFF) return -1;
      index += following + 1;
      count++;
    }
    return count;
  }

  public static function isValid(bytes:Bytes):Bool {
    return scalarCount(bytes) >= 0;
  }

  /** Code-point length of a Neko string, rejecting invalid UTF-8 so a byte
   * count can never be mistaken for a Unicode length. */
  public static function codePoints(value:String):Int {
    var count = scalarCount(Bytes.ofString(value));
    if (count < 0) throw ConvexError.protocol("string was not valid UTF-8");
    return count;
  }

  /** UTF-8 encoding of one scalar value, used by tests and by any caller that
   * needs an exact astral character without a deprecated helper. */
  public static function encodeScalar(scalar:Int):Bytes {
    if (scalar < 0 || scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
      throw ConvexError.protocol("scalar value is not encodable as UTF-8");
    }
    if (scalar < 0x80) {
      var one = Bytes.alloc(1);
      one.set(0, scalar);
      return one;
    }
    if (scalar < 0x800) {
      var two = Bytes.alloc(2);
      two.set(0, 0xC0 | (scalar >> 6));
      two.set(1, 0x80 | (scalar & 0x3F));
      return two;
    }
    if (scalar < 0x10000) {
      var three = Bytes.alloc(3);
      three.set(0, 0xE0 | (scalar >> 12));
      three.set(1, 0x80 | ((scalar >> 6) & 0x3F));
      three.set(2, 0x80 | (scalar & 0x3F));
      return three;
    }
    var four = Bytes.alloc(4);
    four.set(0, 0xF0 | (scalar >> 18));
    four.set(1, 0x80 | ((scalar >> 12) & 0x3F));
    four.set(2, 0x80 | ((scalar >> 6) & 0x3F));
    four.set(3, 0x80 | (scalar & 0x3F));
    return four;
  }
}
