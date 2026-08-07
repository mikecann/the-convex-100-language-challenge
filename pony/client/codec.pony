// Byte level helpers shared by the JSON codec, the HTTP client, and the
// WebSocket framing layer.
//
// They live in one file so the Convex specific code below stays about Convex.
// Everything here is a primitive, which means it is a `val` reference and can
// therefore be called from inside a `recover` block while a builder string is
// still mutable. That is the pattern this package uses to produce immutable
// wire buffers without copying them a second time.

primitive Bytes
  """
  Conversions between Pony strings and the immutable byte arrays that the
  socket layer moves around.
  """

  fun of_string(text: String): Array[U8] val =>
    var out: Array[U8] iso = Array[U8](text.size())
    var index: USize = 0
    while index < text.size() do
      out.push(try text(index)? else 0 end)
      index = index + 1
    end
    consume out

  fun to_string(data: Array[U8] val): String =>
    var out: String iso = String(data.size())
    var index: USize = 0
    while index < data.size() do
      out.push(try data(index)? else 0 end)
      index = index + 1
    end
    consume out

  fun slice(data: Array[U8] val, from: USize, upto: USize): Array[U8] val ? =>
    if (upto < from) or (upto > data.size()) then error end
    var out: Array[U8] iso = Array[U8](upto - from)
    var index: USize = from
    while index < upto do
      out.push(data(index)?)
      index = index + 1
    end
    consume out

  fun same(left: Array[U8] val, right: Array[U8] val): Bool =>
    if left.size() != right.size() then return false end
    var index: USize = 0
    while index < left.size() do
      let a = try left(index)? else return false end
      let b = try right(index)? else return false end
      if a != b then return false end
      index = index + 1
    end
    true

  fun append_all(target: Array[U8] ref, source: Array[U8] val) =>
    var index: USize = 0
    while index < source.size() do
      target.push(try source(index)? else 0 end)
      index = index + 1
    end

  fun append_string(target: Array[U8] ref, source: String) =>
    var index: USize = 0
    while index < source.size() do
      target.push(try source(index)? else 0 end)
      index = index + 1
    end

  fun freeze(source: Array[U8] box, from: USize, upto: USize): Array[U8] val =>
    let limit = if upto > source.size() then source.size() else upto end
    let reserve = if limit > from then limit - from else USize(0) end
    var out: Array[U8] iso = Array[U8](reserve)
    var index: USize = from
    while index < limit do
      out.push(try source(index)? else 0 end)
      index = index + 1
    end
    consume out

  fun starts_with(text: String, marker: String): Bool =>
    if text.size() < marker.size() then return false end
    var index: USize = 0
    while index < marker.size() do
      let left = try text(index)? else return false end
      let right = try marker(index)? else return false end
      if left != right then return false end
      index = index + 1
    end
    true

  fun lower(text: String): String =>
    var out: String iso = String(text.size())
    var index: USize = 0
    while index < text.size() do
      let byte = try text(index)? else 0 end
      if (byte >= 'A') and (byte <= 'Z') then
        out.push(byte + 32)
      else
        out.push(byte)
      end
      index = index + 1
    end
    consume out

primitive Hex
  """
  Lower case hexadecimal, used for WebSocket masking diagnostics and for the
  session identifier the Convex sync protocol expects.
  """

  fun digit(value: U8): U8 =>
    if value < 10 then '0' + value else ('a' + value) - 10 end

  fun encode(data: Array[U8] val): String =>
    var out: String iso = String(data.size() * 2)
    var index: USize = 0
    while index < data.size() do
      let byte = try data(index)? else 0 end
      out.push(Hex.digit(byte >> 4))
      out.push(Hex.digit(byte and 0x0f))
      index = index + 1
    end
    consume out

primitive Base64Codec
  """
  Standard base64 with padding. Convex encodes sync protocol timestamps this
  way, and RFC 6455 uses it for the WebSocket key and accept headers, so the
  decoder is deliberately strict: a malformed timestamp must fail the
  connection rather than silently compare as an older value.
  """

  fun _alphabet(): String =>
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  fun encode(data: Array[U8] val): String =>
    let alphabet = Base64Codec._alphabet()
    var out: String iso = String(((data.size() + 2) / 3) * 4)
    var index: USize = 0
    while index < data.size() do
      let remaining = data.size() - index
      let byte0 = try data(index)? else 0 end
      let byte1 =
        if remaining > 1 then try data(index + 1)? else 0 end else U8(0) end
      let byte2 =
        if remaining > 2 then try data(index + 2)? else 0 end else U8(0) end
      let group = (byte0.u32() << 16) or (byte1.u32() << 8) or byte2.u32()
      out.push(try alphabet(((group >> 18) and 0x3f).usize())? else '=' end)
      out.push(try alphabet(((group >> 12) and 0x3f).usize())? else '=' end)
      if remaining > 1 then
        out.push(try alphabet(((group >> 6) and 0x3f).usize())? else '=' end)
      else
        out.push('=')
      end
      if remaining > 2 then
        out.push(try alphabet((group and 0x3f).usize())? else '=' end)
      else
        out.push('=')
      end
      index = index + 3
    end
    consume out

  fun _value(character: U8): U8 ? =>
    if (character >= 'A') and (character <= 'Z') then
      character - 'A'
    elseif (character >= 'a') and (character <= 'z') then
      (character - 'a') + 26
    elseif (character >= '0') and (character <= '9') then
      (character - '0') + 52
    elseif character == '+' then
      62
    elseif character == '/' then
      63
    else
      error
    end

  fun decode(text: String): Array[U8] val ? =>
    if (text.size() == 0) or ((text.size() % 4) != 0) then error end
    var out: Array[U8] iso = Array[U8]((text.size() / 4) * 3)
    var index: USize = 0
    while index < text.size() do
      let character2 = text(index + 2)?
      let character3 = text(index + 3)?
      // Padding is only ever legal in the final quad, and `=` may not appear
      // in the third position unless it also appears in the fourth.
      let padding =
        if character3 == '=' then
          if character2 == '=' then USize(2) else USize(1) end
        else
          USize(0)
        end
      if (padding > 0) and ((index + 4) != text.size()) then error end
      let value0 = Base64Codec._value(text(index)?)?
      let value1 = Base64Codec._value(text(index + 1)?)?
      let value2 =
        if padding > 1 then U8(0) else Base64Codec._value(character2)? end
      let value3 =
        if padding > 0 then U8(0) else Base64Codec._value(character3)? end
      let group = (value0.u32() << 18) or (value1.u32() << 12) or
        (value2.u32() << 6) or value3.u32()
      out.push(((group >> 16) and 0xff).u8())
      if padding < 2 then out.push(((group >> 8) and 0xff).u8()) end
      if padding < 1 then out.push((group and 0xff).u8()) end
      index = index + 4
    end
    consume out

primitive Utf8
  """
  Strict UTF-8 validation.

  The conformance suite round-trips emoji and multi-byte scripts through
  Convex, and RFC 6455 requires a text frame's payload to be valid UTF-8 once
  all of its fragments are joined. Validating after reassembly, rather than per
  fragment, is what makes a code point split across two frames legal.
  """

  fun valid(data: Array[U8] val): Bool =>
    try
      var index: USize = 0
      while index < data.size() do
        let lead = data(index)?
        let width =
          if lead < 0x80 then
            USize(1)
          elseif (lead >= 0xc2) and (lead <= 0xdf) then
            USize(2)
          elseif (lead >= 0xe0) and (lead <= 0xef) then
            USize(3)
          elseif (lead >= 0xf0) and (lead <= 0xf4) then
            USize(4)
          else
            return false
          end
        if (index + width) > data.size() then return false end
        var offset: USize = 1
        while offset < width do
          let continuation = data(index + offset)?
          if (continuation and 0xc0) != 0x80 then return false end
          offset = offset + 1
        end
        // Reject over-long encodings and surrogate halves, which are the two
        // shapes a lenient decoder would otherwise accept.
        if width == 3 then
          let second = data(index + 1)?
          if (lead == 0xe0) and (second < 0xa0) then return false end
          if (lead == 0xed) and (second > 0x9f) then return false end
        elseif width == 4 then
          let second = data(index + 1)?
          if (lead == 0xf0) and (second < 0x90) then return false end
          if (lead == 0xf4) and (second > 0x8f) then return false end
        end
        index = index + width
      end
      true
    else
      false
    end

  fun valid_string(text: String): Bool =>
    Utf8.valid(Bytes.of_string(text))

  fun scalar_count(text: String): USize ? =>
    """
    Counts Unicode scalar values, not UTF-8 bytes. The adapter protocol's
    128-character identifier limit is defined in JSON characters, so an emoji
    is one character even though it occupies four bytes on the wire.
    """
    let data = Bytes.of_string(text)
    var index: USize = 0
    var count: USize = 0
    while index < data.size() do
      let lead = data(index)?
      let width =
        if lead < 0x80 then USize(1)
        elseif (lead >= 0xc2) and (lead <= 0xdf) then USize(2)
        elseif (lead >= 0xe0) and (lead <= 0xef) then USize(3)
        elseif (lead >= 0xf0) and (lead <= 0xf4) then USize(4)
        else error
        end
      if (index + width) > data.size() then error end
      var offset: USize = 1
      while offset < width do
        if (data(index + offset)? and 0xc0) != 0x80 then error end
        offset = offset + 1
      end
      if width == 3 then
        let second = data(index + 1)?
        if (lead == 0xe0) and (second < 0xa0) then error end
        if (lead == 0xed) and (second > 0x9f) then error end
      elseif width == 4 then
        let second = data(index + 1)?
        if (lead == 0xf0) and (second < 0x90) then error end
        if (lead == 0xf4) and (second > 0x8f) then error end
      end
      index = index + width
      count = count + 1
    end
    count

  fun write_point(code: U32): Array[U8] val =>
    """
    Returns the UTF-8 bytes for one Unicode scalar value, so a caller building
    a `String iso` can push them in without handing that builder to another
    function as a `ref` alias.
    """
    recover val
      let out = Array[U8](4)
      if code < 0x80 then
        out.push(code.u8())
      elseif code < 0x800 then
        out.push((0xc0 or (code >> 6)).u8())
        out.push((0x80 or (code and 0x3f)).u8())
      elseif code < 0x10000 then
        out.push((0xe0 or (code >> 12)).u8())
        out.push((0x80 or ((code >> 6) and 0x3f)).u8())
        out.push((0x80 or (code and 0x3f)).u8())
      else
        out.push((0xf0 or (code >> 18)).u8())
        out.push((0x80 or ((code >> 12) and 0x3f)).u8())
        out.push((0x80 or ((code >> 6) and 0x3f)).u8())
        out.push((0x80 or (code and 0x3f)).u8())
      end
      out
    end

primitive Sha1
  """
  SHA-1 is only used to verify the `Sec-WebSocket-Accept` header of the
  WebSocket handshake, which is the one place RFC 6455 mandates it. Doing it
  here keeps the Live upgrade a real handshake check rather than a header that
  is read and ignored.
  """

  fun _rotate(value: U32, places: U32): U32 =>
    (value << places) or (value >> (U32(32) - places))

  fun apply(data: Array[U8] val): Array[U8] val =>
    var h0: U32 = 0x67452301
    var h1: U32 = 0xefcdab89
    var h2: U32 = 0x98badcfe
    var h3: U32 = 0x10325476
    var h4: U32 = 0xc3d2e1f0

    // Message, 0x80 terminator, zero padding to a 64 byte boundary, then the
    // original bit length as a big endian 64 bit integer.
    let bit_length = data.size().u64() * 8
    var padded: Array[U8] iso = Array[U8](data.size() + 72)
    var index: USize = 0
    while index < data.size() do
      padded.push(try data(index)? else 0 end)
      index = index + 1
    end
    padded.push(0x80)
    while ((padded.size() + 8) % 64) != 0 do
      padded.push(0)
    end
    var shift: I32 = 56
    while shift >= 0 do
      padded.push(((bit_length >> shift.u64()) and 0xff).u8())
      shift = shift - 8
    end
    let message: Array[U8] val = consume padded

    try
      var block: USize = 0
      while block < message.size() do
        let words = Array[U32](80)
        var word_index: USize = 0
        while word_index < 16 do
          let base = block + (word_index * 4)
          words.push(
            (message(base)?.u32() << 24) or
            (message(base + 1)?.u32() << 16) or
            (message(base + 2)?.u32() << 8) or
            message(base + 3)?.u32())
          word_index = word_index + 1
        end
        while word_index < 80 do
          let mixed = words(word_index - 3)? xor words(word_index - 8)? xor
            words(word_index - 14)? xor words(word_index - 16)?
          words.push(Sha1._rotate(mixed, 1))
          word_index = word_index + 1
        end

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var round: USize = 0
        while round < 80 do
          (let f: U32, let k: U32) =
            if round < 20 then
              (((b and c) or ((not b) and d)), U32(0x5a827999))
            elseif round < 40 then
              ((b xor c xor d), U32(0x6ed9eba1))
            elseif round < 60 then
              (((b and c) or (b and d) or (c and d)), U32(0x8f1bbcdc))
            else
              ((b xor c xor d), U32(0xca62c1d6))
            end
          let temp = Sha1._rotate(a, 5) + f + e + k + words(round)?
          e = d
          d = c
          c = Sha1._rotate(b, 30)
          b = a
          a = temp
          round = round + 1
        end

        h0 = h0 + a
        h1 = h1 + b
        h2 = h2 + c
        h3 = h3 + d
        h4 = h4 + e
        block = block + 64
      end
    end

    var digest: Array[U8] iso = Array[U8](20)
    for word in [h0; h1; h2; h3; h4].values() do
      digest.push(((word >> 24) and 0xff).u8())
      digest.push(((word >> 16) and 0xff).u8())
      digest.push(((word >> 8) and 0xff).u8())
      digest.push((word and 0xff).u8())
    end
    consume digest
