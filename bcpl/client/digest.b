// digest.b -- SHA-1, base64 and UTF-8 validation, in BCPL.
//
// These are Convex and RFC 6455 protocol behaviour, not transport, so they are
// implemented here rather than borrowed from the C boundary: the WebSocket
// handshake proof, the base64 sync timestamps and the rejection of malformed
// UTF-8 text frames are all things the client must be seen to do itself.

// BCPL's >> is defined as a logical shift, but masking makes the result
// correct whichever way the host compiler realises it, which matters because
// SHA-1 treats every word as unsigned.
LET shr32(value, count) = VALOF
{ IF count <= 0 RESULTIS value
  IF count >= 32 RESULTIS 0
  RESULTIS (value >> count) & (#x7FFFFFFF >> (count - 1))
}

AND rotl32(value, count) = (value << count) | shr32(value, 32 - count)

// SHA-1 of count bytes at source%offset, appending 20 raw bytes to `out`.
AND sha1Into(source, offset, count, out) BE
{ LET padded = bbNew(count + 72)
  LET w = VEC 79
  LET h0 = #x67452301
  LET h1 = #xEFCDAB89
  LET h2 = #x98BADCFE
  LET h3 = #x10325476
  LET h4 = #xC3D2E1F0
  LET blocks = 0
  UNLESS padded RETURN

  bbPushBytes(padded, source, offset, count)
  bbPush(padded, #x80)
  FOR filler = 1 TO (56 - ((count + 1) REM 64) + 64) REM 64 DO
    bbPush(padded, 0)
  // The 64-bit big-endian bit length. Inputs here are handshake-sized, so the
  // high word is derived from the byte count rather than tracked separately.
  bbPush(padded, 0)
  bbPush(padded, 0)
  bbPush(padded, 0)
  bbPush(padded, shr32(count, 29) & 255)
  bbPush(padded, shr32(count, 21) & 255)
  bbPush(padded, shr32(count, 13) & 255)
  bbPush(padded, shr32(count, 5) & 255)
  bbPush(padded, (count << 3) & 255)

  // A refused append would leave a short buffer and silently wrong digest, so
  // give up loudly instead of hashing a truncated message.
  UNLESS (padded!Bb_len REM 64) = 0 DO { bbFree(padded); RETURN }
  blocks := padded!Bb_len / 64

  FOR block = 0 TO blocks - 1 DO
  { LET base = block * 64
    LET a, b, c, d = h0, h1, h2, h3
    LET e = h4
    FOR index = 0 TO 15 DO
      w!index := (bbGet(padded, base + index * 4) << 24) |
                 (bbGet(padded, base + index * 4 + 1) << 16) |
                 (bbGet(padded, base + index * 4 + 2) << 8) |
                 bbGet(padded, base + index * 4 + 3)
    FOR index = 16 TO 79 DO
      w!index := rotl32(w!(index - 3) NEQV w!(index - 8) NEQV
                        w!(index - 14) NEQV w!(index - 16), 1)
    FOR index = 0 TO 79 DO
    { LET f = 0
      LET k = 0
      LET temp = 0
      TEST index < 20
      THEN { f := (b & c) | ((~b) & d); k := #x5A827999 }
      ELSE TEST index < 40
      THEN { f := b NEQV c NEQV d; k := #x6ED9EBA1 }
      ELSE TEST index < 60
      THEN { f := (b & c) | (b & d) | (c & d); k := #x8F1BBCDC }
      ELSE { f := b NEQV c NEQV d; k := #xCA62C1D6 }
      temp := rotl32(a, 5) + f + e + k + w!index
      e := d
      d := c
      c := rotl32(b, 30)
      b := a
      a := temp
    }
    h0 := h0 + a
    h1 := h1 + b
    h2 := h2 + c
    h3 := h3 + d
    h4 := h4 + e
  }

  bbFree(padded)

  FOR shift = 24 TO 0 BY -8 DO bbPush(out, shr32(h0, shift) & 255)
  FOR shift = 24 TO 0 BY -8 DO bbPush(out, shr32(h1, shift) & 255)
  FOR shift = 24 TO 0 BY -8 DO bbPush(out, shr32(h2, shift) & 255)
  FOR shift = 24 TO 0 BY -8 DO bbPush(out, shr32(h3, shift) & 255)
  FOR shift = 24 TO 0 BY -8 DO bbPush(out, shr32(h4, shift) & 255)
}

AND base64Into(source, offset, count, out) BE
{ LET alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  LET position = 0
  UNTIL position >= count DO
  { LET remaining = count - position
    LET first = source%(offset + position)
    LET second = 0
    LET third = 0
    IF remaining > 1 DO second := source%(offset + position + 1)
    IF remaining > 2 DO third := source%(offset + position + 2)
    bbPush(out, alphabet%(1 + shr32(first, 2)))
    bbPush(out, alphabet%(1 + (((first & 3) << 4) | shr32(second, 4))))
    TEST remaining > 1
    THEN bbPush(out, alphabet%(1 + (((second & 15) << 2) | shr32(third, 6))))
    ELSE bbPush(out, '=')
    TEST remaining > 2
    THEN bbPush(out, alphabet%(1 + (third & 63)))
    ELSE bbPush(out, '=')
    position := position + 3
  }
}

// Decode `count` base64 bytes, appending the raw bytes to `out`. Returns FALSE
// on any character outside the alphabet, so a peer cannot smuggle an
// unexpected sync timestamp past the parser.
AND base64Decode(source, offset, count, out) = VALOF
{ LET accumulator = 0
  LET bits = 0
  FOR index = 0 TO count - 1 DO
  { LET character = source%(offset + index)
    LET value = -1
    IF character = '=' DO BREAK
    IF 'A' <= character <= 'Z' DO value := character - 'A'
    IF 'a' <= character <= 'z' DO value := character - 'a' + 26
    IF '0' <= character <= '9' DO value := character - '0' + 52
    IF character = '+' DO value := 62
    IF character = '/' DO value := 63
    IF value < 0 RESULTIS FALSE
    accumulator := (accumulator << 6) | value
    bits := bits + 6
    IF bits >= 8 DO
    { bits := bits - 8
      bbPush(out, shr32(accumulator, bits) & 255)
    }
  }
  RESULTIS TRUE
}

// Strict UTF-8 validation, rejecting over-long encodings, surrogates and
// values above U+10FFFF. RFC 6455 requires a text frame that is not valid
// UTF-8 to fail the connection rather than be delivered.
AND utf8Valid(source, offset, count) = VALOF
{ LET index = 0
  UNTIL index >= count DO
  { LET lead = source%(offset + index)
    LET extra = 0
    LET point = 0
    LET lowest = 0
    TEST lead < #x80
    THEN { index := index + 1; LOOP }
    ELSE TEST (lead & #xE0) = #xC0
    THEN { extra := 1; point := lead & #x1F; lowest := #x80 }
    ELSE TEST (lead & #xF0) = #xE0
    THEN { extra := 2; point := lead & #x0F; lowest := #x800 }
    ELSE TEST (lead & #xF8) = #xF0
    THEN { extra := 3; point := lead & #x07; lowest := #x10000 }
    ELSE RESULTIS FALSE
    IF index + extra >= count RESULTIS FALSE
    FOR step = 1 TO extra DO
    { LET continuation = source%(offset + index + step)
      UNLESS (continuation & #xC0) = #x80 RESULTIS FALSE
      point := (point << 6) | (continuation & #x3F)
    }
    IF point < lowest RESULTIS FALSE
    IF point > #x10FFFF RESULTIS FALSE
    IF #xD800 <= point <= #xDFFF RESULTIS FALSE
    index := index + extra + 1
  }
  RESULTIS TRUE
}
