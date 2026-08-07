# Codec regressions.
#
# These are the primitives every protocol boundary depends on, so they are
# tested against known vectors rather than against themselves.

(import ./check :as check)
(import ../codec :as codec)
(import transport :as transport)

# UTF-8 validation must reject exactly the encodings a permissive decoder would
# accept, because that disagreement is what lets one peer see a different
# string from the other.
(check/check= (codec/utf8-count "hello") 5 "ASCII counts one point per byte")
(check/check= (codec/utf8-count "Καλημέρα") 8 "Greek counts code points, not bytes")
(check/check= (codec/utf8-count "🟨🟩🟦") 3 "astral planes count as one point each")
(check/check= (codec/utf8-count (string/from-bytes 0xC0 0x80)) nil "overlong NUL is invalid")
(check/check= (codec/utf8-count (string/from-bytes 0xC1 0xBF)) nil "overlong ASCII is invalid")
(check/check= (codec/utf8-count (string/from-bytes 0xE0 0x80 0x80)) nil
              "overlong 3-byte is invalid")
(check/check= (codec/utf8-count (string/from-bytes 0xED 0xA0 0x80)) nil
              "surrogates are invalid")
(check/check= (codec/utf8-count (string/from-bytes 0xF4 0x90 0x80 0x80)) nil
              "above U+10FFFF is invalid")
(check/check= (codec/utf8-count (string/from-bytes 0xE2 0x82)) nil
              "a truncated sequence is invalid")
(check/check= (codec/utf8-count (string/from-bytes 0xF4 0x8F 0xBF 0xBF)) 1
              "U+10FFFF itself is valid")

# RFC 4648 test vectors.
(check/check= (codec/base64-encode "") "" "empty input encodes to empty text")
(check/check= (codec/base64-encode "f") "Zg==" "one byte pads twice")
(check/check= (codec/base64-encode "fo") "Zm8=" "two bytes pad once")
(check/check= (codec/base64-encode "foo") "Zm9v" "three bytes need no padding")
(check/check= (codec/base64-encode "foobar") "Zm9vYmFy" "six bytes encode in two groups")
(check/check= (codec/base64-decode "Zm9vYmFy") "foobar" "decoding reverses encoding")
(check/check= (codec/base64-decode "Zg==") "f" "double padding decodes one byte")
(check/check= (codec/base64-decode "Zm8=") "fo" "single padding decodes two bytes")
(check/check= (codec/base64-decode "Zm9") nil "an unpadded remainder is refused")
(check/check= (codec/base64-decode "Zm9v=") nil "a misaligned pad is refused")
(check/check= (codec/base64-decode "Zg=A") nil "padding in the middle is refused")
(check/check= (codec/base64-decode "Z*9v") nil "a non-alphabet character is refused")
# Zh== would decode to the same byte as Zg== if the ignored bits were not zero.
(check/check= (codec/base64-decode "Zh==") nil "non-canonical trailing bits are refused")

(def round-trip (codec/base64-encode (string/from-bytes 0x00 0xFF 0x10 0x80 0x7F)))
(check/check= (codec/base64-decode round-trip) (string/from-bytes 0x00 0xFF 0x10 0x80 0x7F)
              "arbitrary bytes survive a round trip")

(check/check= (codec/hex-encode (string/from-bytes 0x00 0x0F 0xF0 0xFF)) "000ff0ff"
              "hex encodes low nibbles after high nibbles")

# The RFC 3174 vector, used by the RFC 6455 handshake.
(check/check= (codec/hex-encode (transport/sha1 "abc"))
              "a9993e364706816aba3e25717850c26c9cd0d89d"
              "SHA-1 matches its published vector")
(check/check= (codec/base64-encode (transport/sha1 (string "dGhlIHNhbXBsZSBub25jZQ=="
                                                           "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
              "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
              "the RFC 6455 handshake example produces its published accept value")

# Sync timestamps are little-endian, so the ordering cannot be read off the
# encoded text or off the bytes in the order they appear.
(check/check (> (codec/compare-timestamps "AAEAAAAAAAA=" "/wAAAAAAAAA=") 0)
             "256 sorts above 255 despite a smaller low byte")
(check/check (< (codec/compare-timestamps "AAAAAAAAAAA=" "AQAAAAAAAAA=") 0)
             "zero sorts below one")
(check/check= (codec/compare-timestamps "AQAAAAAAAAA=" "AQAAAAAAAAA=") 0
              "equal timestamps compare equal")
(check/check-raises "ProtocolError"
                    (fn [] (codec/compare-timestamps "AQAAAAAAAAA=" "short"))
                    "a malformed timestamp is refused rather than ordered")
(check/check (codec/valid-timestamp? "AAAAAAAAAAA=") "the initial timestamp is well formed")
(check/check (not (codec/valid-timestamp? "AAAA")) "a four byte timestamp is not well formed")

(check/report "janet codec")
