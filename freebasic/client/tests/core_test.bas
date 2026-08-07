' Adversarial coverage for the byte, text, and number primitives. These are
' the pieces the WebSocket handshake, the sync timestamps, and the JSON
' encoder all depend on, so they are proved directly rather than inferred from
' a live transcript.

#include once "core.bi"
#include once "net.bi"
#include once "testing.bi"

dim as string decoded
dim as ulongint parsed
dim as double number
dim as string rendered

' --- StrBuf ---------------------------------------------------------------
dim as StrBuf sink
sink.Append("hello")
sink.AppendByte(0)
sink.Append("world")
Check(sink.count = 11, "StrBuf counts an embedded NUL")
dim as string taken = sink.Take()
Check(len(taken) = 11, "FreeBASIC strings are length counted, not NUL terminated")
Check(taken[5] = 0, "the embedded NUL survives Take")
CheckEqual(sink.Slice(6, 5), "world", "Slice reads past an embedded NUL")
sink.DropFront(6)
CheckEqual(sink.Take(), "world", "DropFront keeps the residue intact")

dim as StrBuf grower
for index as integer = 1 to 5000
  grower.AppendByte(asc("x"))
next
Check(grower.count = 5000, "StrBuf grows past its initial capacity")

' --- base64 ---------------------------------------------------------------
CheckEqual(Base64Encode(""), "", "base64 of an empty string")
CheckEqual(Base64Encode("f"), "Zg==", "base64 pads a one byte group")
CheckEqual(Base64Encode("fo"), "Zm8=", "base64 pads a two byte group")
CheckEqual(Base64Encode("foo"), "Zm9v", "base64 of a full group")
CheckEqual(Base64Encode("foobar"), "Zm9vYmFy", "base64 of two groups")
Check(Base64Decode("Zm9vYmFy", decoded) andalso decoded = "foobar", "base64 round trip")
Check(Base64Decode("Zg==", decoded) andalso decoded = "f", "base64 decodes one byte")
' Strict decoding: length, padding position, alphabet, and unused bits.
Check(not Base64Decode("Zg=", decoded), "base64 rejects a short quantum")
Check(not Base64Decode("Z===", decoded), "base64 rejects three padding characters")
Check(not Base64Decode("Zg==Zg==", decoded), "base64 rejects padding before the end")
Check(not Base64Decode("Zm9v YmFy", decoded), "base64 rejects embedded whitespace")
Check(not Base64Decode("Zm9v!mFy", decoded), "base64 rejects a character outside the alphabet")
Check(not Base64Decode("Zh==", decoded), "base64 rejects unused trailing bits")

' --- SHA-1 and the WebSocket accept token ---------------------------------
CheckEqual(ToHex(Sha1("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709", _
  "SHA-1 of an empty string")
CheckEqual(ToHex(Sha1("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 of abc")
CheckEqual( _
  ToHex(Sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")), _
  "84983e441c3bd26ebaae4aa1f95129e5e54670f1", _
  "SHA-1 across a multi block message")
' The worked example from RFC 6455 section 1.3.
CheckEqual( _
  Base64Encode(Sha1("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11")), _
  "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", _
  "the RFC 6455 Sec-WebSocket-Accept example")

' --- UTF-8 ----------------------------------------------------------------
Check(IsValidUtf8("plain ascii"), "ASCII is valid UTF-8")
Check(IsValidUtf8("Hello, " & chr(228, 184, 150, 231, 149, 140)), "three byte sequences")
Check(IsValidUtf8(chr(240, 159, 145, 139)), "a four byte emoji")
Check(not IsValidUtf8(chr(192, 175)), "an overlong two byte encoding is rejected")
Check(not IsValidUtf8(chr(237, 160, 128)), "a UTF-16 surrogate half is rejected")
Check(not IsValidUtf8(chr(244, 144, 128, 128)), "a code point above U+10FFFF is rejected")
Check(not IsValidUtf8(chr(226, 130)), "a truncated sequence is rejected")
Check(not IsValidUtf8(chr(128)), "a bare continuation byte is rejected")
Check(not IsValidUtf8(chr(248, 136, 128, 128, 128)), "a five byte lead is rejected")

' --- numbers --------------------------------------------------------------
Check(DecimalToUlong("0", parsed) andalso parsed = 0, "decimal zero")
Check(DecimalToUlong("18446744073709551615", parsed), "the largest 64-bit decimal")
Check(not DecimalToUlong("18446744073709551616", parsed), "decimal overflow is rejected")
Check(not DecimalToUlong("", parsed), "an empty decimal is rejected")
Check(not DecimalToUlong("12a", parsed), "a trailing letter is rejected")
Check(not DecimalToUlong(" 12", parsed), "a leading space is rejected")
Check(not DecimalToUlong("+12", parsed), "a leading sign is rejected")

Check(FormatDouble(42.5, rendered) andalso rendered = "42.5", "42.5 keeps its short spelling")
Check(FormatDouble(0.1, rendered), "0.1 has a round trip spelling")
Check(ParseDouble(rendered, number) andalso number = 0.1, "0.1 round trips exactly")
Check(FormatDouble(1.0e300, rendered), "a large finite double is representable")
Check(ParseDouble(rendered, number) andalso number = 1.0e300, "1e300 round trips exactly")
Check(not ParseDouble("1.0x", number), "a partial number parse is rejected")
Check(not ParseDouble("", number), "an empty number is rejected")
CheckEqual(FormatInteger(-9223372036854775807ll - 1), "-9223372036854775808", _
  "the most negative 64-bit integer formats exactly")

' --- clock and randomness -------------------------------------------------
dim as longint before = MonotonicMs()
SleepMs(30)
dim as longint elapsed = MonotonicMs() - before
Check(elapsed >= 25, "SleepMs waits at least the requested interval")
Check(elapsed < 2000, "SleepMs returns promptly")
dim as string firstRandom = RandomBytes(16)
dim as string secondRandom = RandomBytes(16)
Check(len(firstRandom) = 16 andalso len(secondRandom) = 16, "the CSPRNG fills the request")
Check(firstRandom <> secondRandom, "two masking keys differ")
Check(len(SessionId()) = 36, "a session id is a UUID shaped string")

' --- ABI layouts ----------------------------------------------------------
dim as string layoutReason
Check(NetSelfTest(layoutReason), "POSIX structure layouts match the glibc ABI")
if len(layoutReason) > 0 then
  print "  detail: " & layoutReason
end if

end TestSummary("freebasic core")
