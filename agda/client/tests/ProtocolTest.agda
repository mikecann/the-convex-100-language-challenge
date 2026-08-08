{-# OPTIONS --without-K #-}

-- Deterministic coverage for the parts of the client that are pure functions
-- of their input: the JSON codec and its bounds, the integral-number view,
-- UTF-8, base64 and the canonical Live timestamp, SHA-1, RFC6455 frame
-- headers, close-frame validation, HTTP response framing, deployment URLs, and
-- the Convex envelope.
--
-- These are the checks a mocked fixture cannot make, because they are about
-- rejecting input rather than about a happy path.
module ProtocolTest where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Json
open import Convex.Error
open import Convex.Base64 using (timestampEncode; timestampDecode; initialTimestamp)
import Convex.Base64 as B64
open import Convex.Digest
open import Convex.WebSocket
open import Convex.Http
open import Check
import Convex.Utf8 as Utf8

private
  bytesOf : String → Bytes
  bytesOf = Utf8.encode

  decodedOk : Either String JSON → Bool
  decodedOk (right _) = true
  decodedOk (left _) = false

  reencode : String → String
  reencode text = onDecoded (decodeText text)
    where
      onDecoded : Either String JSON → String
      onDecoded (left m) = "<error: " <> m <> ">"
      onDecoded (right value) = encode value

  natOr : Nat → Maybe Nat → Nat
  natOr fallback nothing = fallback
  natOr _ (just n) = n

  repeatString : Nat → String → String
  repeatString zero _ = ""
  repeatString (suc n) unit = unit <> repeatString n unit

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------

jsonChecks : MVar Tally → IO ⊤
jsonChecks t =
  checkEqString t (reencode "{\"a\":1,\"b\":[true,false,null]}")
    "{\"a\":1,\"b\":[true,false,null]}" "objects and arrays round-trip"
    -- A float must survive unchanged; Convex echoes arbitrary user values.
    >> checkEqString t (reencode "{\"number\":42.5}") "{\"number\":42.5}"
         "a fractional number keeps its exact lexeme"
    >> checkEqString t (reencode "{\"e\":1e3}") "{\"e\":1e3}" "an exponent keeps its exact lexeme"
    >> check t (decodedOk (decodeText "\"Hello, \\u4e16\\u754c \\ud83d\\udc4b\""))
         "surrogate pairs decode"
    >> checkEqString t (reencode "\"\\ud83d\\udc4b\"") "\"👋\"" "a surrogate pair becomes one code point"
    >> check t (not (decodedOk (decodeText "\"\\ud83d\""))) "a lone high surrogate is rejected"
    >> check t (not (decodedOk (decodeText "\"\\udc4b\""))) "a lone low surrogate is rejected"
    >> check t (not (decodedOk (decodeText "{\"a\":1,}"))) "a trailing comma is rejected"
    >> check t (not (decodedOk (decodeText "{\"a\":01}"))) "a leading zero is rejected"
    >> check t (not (decodedOk (decodeText "{\"a\":1} trailing"))) "trailing data is rejected"
    >> check t (not (decodedOk (decodeText "{\"a\":.5}"))) "a bare decimal point is rejected"
    >> check t (not (decodedOk (decodeBytes (fromOctets (34 ∷ 255 ∷ 34 ∷ [])))))
         "an invalid UTF-8 octet inside a string is rejected"
    >> check t (not (decodedOk (decodeText "[1")))  "an unterminated array is rejected"
    -- Structural bounds are enforced before a value is built.
    >> check t (not (decodedOk (decodeText (repeatString 200 "[" <> repeatString 200 "]"))))
         "nesting past the depth limit is rejected"
    >> check t (not (decodedOk (decodeText ("[" <> repeatString 5000 "1," <> "1]"))))
         "more structural nodes than the limit is rejected"
    >> check t (decodedOk (decodeText "{}")) "an empty object decodes"
    >> check t (not (decodedOk (decodeBytes emptyBytes))) "empty input is rejected"

numberChecks : MVar Tally → IO ⊤
numberChecks t =
  checkEqNat t (natOr 99 (natOfLexeme "0")) 0 "0 is integral"
    >> checkEqNat t (natOr 99 (natOfLexeme "0.0")) 0 "0.0 is integral"
    >> checkEqNat t (natOr 99 (natOfLexeme "1.0")) 1 "1.0 is integral"
    >> checkEqNat t (natOr 99 (natOfLexeme "1e2")) 100 "1e2 is integral"
    >> checkEqNat t (natOr 99 (natOfLexeme "1500e-2")) 15 "1500e-2 is integral"
    >> check t (not (isJust (natOfLexeme "1.5"))) "1.5 is not integral"
    >> check t (not (isJust (natOfLexeme "1e-1"))) "1e-1 is not integral"
    >> check t (not (isJust (natOfLexeme "-1"))) "a negative count is rejected"
    >> check t (not (isJust (natOfLexeme "99999999999999999999")))
         "an out-of-range integer is rejected"
    >> check t (not (isJust (asNat (jstr "1")))) "a quoted number is not a count"
    >> check t (not (isJust (asNat jnull))) "null is not a count"

--------------------------------------------------------------------------------
-- UTF-8, base64, digests
--------------------------------------------------------------------------------

utf8Checks : MVar Tally → IO ⊤
utf8Checks t =
  checkEqNat t (Utf8.octetLength "Καλημέρα") 16 "octet length counts wire bytes"
    >> checkEqNat t (Utf8.octetLength "🟨🟩🟦") 12 "astral code points are four octets each"
    >> check t (Utf8.valid (bytesOf "مرحبا")) "valid UTF-8 is accepted"
    >> check t (not (Utf8.valid (fromOctets (195 ∷ [])))) "a truncated sequence is rejected"
    >> check t (not (Utf8.valid (fromOctets (192 ∷ 128 ∷ [])))) "an over-long form is rejected"
    >> check t (not (Utf8.valid (fromOctets (237 ∷ 160 ∷ 128 ∷ []))))
         "an encoded surrogate is rejected"
    >> check t (not (Utf8.valid (fromOctets (245 ∷ 128 ∷ 128 ∷ 128 ∷ []))))
         "a code point above U+10FFFF is rejected"
    -- A multi-byte sequence split across a fragment edge must not validate as
    -- a shorter prefix, which is what makes fragment assembly detectable.
    >> check t (not (Utf8.validRegion (bytesOf "世界") 0 2)) "a split sequence is rejected"
    >> check t (Utf8.validRegion (bytesOf "世界") 0 6) "the whole sequence is accepted"

base64Checks : MVar Tally → IO ⊤
base64Checks t =
  checkEqString t (b64 "Man") "TWFu" "three octets encode without padding"
    >> checkEqString t (b64 "Ma") "TWE=" "two octets encode with one pad"
    >> checkEqString t (b64 "M") "TQ==" "one octet encodes with two pads"
    >> checkEqString t initialTimestamp "AAAAAAAAAAA=" "the initial Live timestamp is canonical"
    >> checkEqNat t (natOr 99 (timestampDecode (timestampEncode 123456789))) 123456789
         "a timestamp round-trips"
    >> check t (not (isJust (timestampDecode "AAAAAAAAAAB=")))
         "a timestamp with non-zero padding bits is rejected"
    >> check t (not (isJust (timestampDecode "AAAA"))) "a short timestamp is rejected"
    >> check t (not (isJust (timestampDecode "AAAAAAAAAAAA"))) "an unpadded timestamp is rejected"
  where
    b64 : String → String
    b64 text = B64.encode (bytesOf text)

digestChecks : MVar Tally → IO ⊤
digestChecks t =
  checkEqString t (hexString (sha1 (bytesOf "abc")))
    "a9993e364706816aba3e25717850c26c9cd0d89d" "SHA-1 matches the published vector for abc"
    >> checkEqString t (hexString (sha1 emptyBytes))
         "da39a3ee5e6b4b0d3255bfef95601890afd80709" "SHA-1 matches the empty-string vector"
    -- The RFC6455 example key and its expected accept value.
    >> checkEqString t (expectedAccept "dGhlIHNhbXBsZSBub25jZQ==")
         "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" "the accept key matches the RFC6455 example"
    >> check t (not (fnv1a64 (bytesOf "a") ==ⁿ fnv1a64 (bytesOf "b")))
         "distinct inputs give distinct signatures"
    >> check t (fnv1a64 (bytesOf "same") ==ⁿ fnv1a64 (bytesOf "same"))
         "the signature is stable"

--------------------------------------------------------------------------------
-- WebSocket framing
--------------------------------------------------------------------------------

private
  scanKind : FrameScan → String
  scanKind (frameNeed _) = "need"
  scanKind (frameBad _) = "bad"
  scanKind (frameGot _ _) = "got"

  frameLength : FrameScan → Nat
  frameLength (frameGot f _) = size (framePayload f)
  frameLength _ = 0

frameChecks : MVar Tally → IO ⊤
frameChecks t =
  checkEqString t (scanKind (scanFrame (fromOctets (129 ∷ 2 ∷ 104 ∷ 105 ∷ [])))) "got"
    "a small final text frame parses"
    >> checkEqNat t (frameLength (scanFrame (fromOctets (129 ∷ 2 ∷ 104 ∷ 105 ∷ [])))) 2
         "the payload length is the declared length"
    >> checkEqString t (scanKind (scanFrame (fromOctets (129 ∷ 2 ∷ 104 ∷ [])))) "need"
         "an incomplete payload asks for more octets"
    >> checkEqString t (scanKind (scanFrame (fromOctets (129 ∷ 130 ∷ [])))) "bad"
         "a masked server frame is rejected"
    >> checkEqString t (scanKind (scanFrame (fromOctets (193 ∷ 0 ∷ [])))) "bad"
         "a reserved bit is rejected"
    -- A header claiming a huge payload is refused before any octet of that
    -- payload is buffered.
    >> checkEqString t
         (scanKind (scanFrame (fromOctets (130 ∷ 127 ∷ 127 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ []))))
         "bad" "an oversized declared length is rejected without buffering"
    >> checkEqString t
         (scanKind (scanFrame (fromOctets (130 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ 255 ∷ []))))
         "bad" "a length with the high bit set is rejected"
    >> checkEqString t (scanKind (scanFrame (fromOctets (129 ∷ 126 ∷ 0 ∷ 5 ∷ [])))) "bad"
         "a non-minimal 16-bit length is rejected"
    >> checkEqString t (scanKind (scanFrame (fromOctets (9 ∷ 0 ∷ [])))) "bad"
         "a fragmented control frame is rejected"
    >> checkEqString t (scanKind (scanFrame (fromOctets (137 ∷ 126 ∷ 0 ∷ 126 ∷ [])))) "bad"
         "an oversized control frame is rejected"
    >> check t (closeFrameValid emptyBytes) "an empty close payload is valid"
    >> check t (not (closeFrameValid (fromOctets (3 ∷ [])))) "a one-octet close payload is invalid"
    >> check t (closeFrameValid (fromOctets (3 ∷ 232 ∷ []))) "close code 1000 is valid"
    >> check t (not (closeFrameValid (fromOctets (3 ∷ 236 ∷ []))))
         "an unregistered close code is rejected"
    >> check t (not (closeFrameValid (fromOctets (3 ∷ 232 ∷ 195 ∷ []))))
         "an invalid UTF-8 close reason is rejected"

--------------------------------------------------------------------------------
-- HTTP framing and the Convex envelope
--------------------------------------------------------------------------------

private
  headKind : Either String ResponseHead → String
  headKind (left _) = "error"
  headKind (right _) = "ok"

  headStatus : Either String ResponseHead → Nat
  headStatus (right h) = statusCode h
  headStatus (left _) = 0

  headChunked : Either String ResponseHead → Bool
  headChunked (right h) = chunked h
  headChunked (left _) = false

  headLength : Either String ResponseHead → Nat
  headLength (right h) = natOr 0 (contentLength h)
  headLength (left _) = 0

  envelopeKind : Either ConvexError CallResult → String
  envelopeKind (left e) = errorName e
  envelopeKind (right _) = "success"

httpChecks : MVar Tally → IO ⊤
httpChecks t =
  checkEqNat t (headStatus (parseHead (bytesOf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))) 200
    "a status line parses"
    -- A non-2xx reply is still framed and decoded, because Convex reports
    -- function failures with a body the client must read.
    >> checkEqNat t (headStatus (parseHead (bytesOf "HTTP/1.1 560 Nope\r\nContent-Length: 0\r\n\r\n"))) 560
         "a non-2xx status parses"
    >> checkEqNat t (headLength (parseHead (bytesOf "HTTP/1.1 200 OK\r\ncontent-length:  7 \r\n\r\n"))) 7
         "Content-Length matching is case- and space-insensitive"
    >> check t (headChunked (parseHead (bytesOf "HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n")))
         "chunked framing is detected case-insensitively"
    >> checkEqString t (headKind (parseHead (bytesOf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"))) "error"
         "a response without a blank line is rejected"
    >> checkEqString t (headKind (parseHead (bytesOf "ICY 200 OK\r\n\r\n"))) "error"
         "a non-HTTP status line is rejected"
    >> checkEqString t (headKind (parseHead (bytesOf "HTTP/1.1 999 X\r\n\r\n"))) "error"
         "an out-of-range status code is rejected"
    >> checkEqString t
         (envelopeKind (interpret 200 (fromRight (decodeText "{\"status\":\"success\",\"value\":1,\"logLines\":[]}"))))
         "success" "a success envelope yields a value"
    >> checkEqString t
         (envelopeKind (interpret 200 (fromRight (decodeText "{\"status\":\"error\",\"errorMessage\":\"no\",\"errorData\":{\"code\":\"X\"}}"))))
         "FunctionError" "an error envelope becomes a structured function error"
    >> checkEqString t
         (envelopeKind (interpret 500 (fromRight (decodeText "{\"status\":\"weird\"}"))))
         "ProtocolError" "an unknown status becomes a protocol error"
    >> checkEqString t
         (envelopeKind (interpret 200 (fromRight (decodeText "{\"status\":\"success\",\"value\":1,\"logLines\":[1]}"))))
         "ProtocolError" "non-string logLines become a protocol error"
    >> checkEqString t
         (envelopeKind (interpret 200 (fromRight (decodeText "{\"status\":\"success\"}"))))
         "ProtocolError" "a success envelope without a value is a protocol error"
  where
    fromRight : Either String JSON → JSON
    fromRight (right value) = value
    fromRight (left _) = jnull

private
  urlKind : Either String Deployment → String
  urlKind (left _) = "error"
  urlKind (right _) = "ok"

  urlPort : Either String Deployment → Nat
  urlPort (right dep) = port dep
  urlPort (left _) = 0

  urlHost : Either String Deployment → String
  urlHost (right dep) = host dep
  urlHost (left _) = ""

urlChecks : MVar Tally → IO ⊤
urlChecks t =
  checkEqNat t (urlPort (parseDeployment "https://example.convex.cloud")) 443 "https defaults to 443"
    >> checkEqNat t (urlPort (parseDeployment "http://backend:3210")) 3210 "an explicit port is used"
    >> checkEqString t (urlHost (parseDeployment "http://backend:3210/")) "backend"
         "a trailing slash is trimmed"
    >> checkEqString t (urlHost (parseDeployment "http://[::1]:8080")) "::1" "an IPv6 literal parses"
    >> checkEqString t (urlKind (parseDeployment "ftp://example.com")) "error"
         "a non-HTTP scheme is rejected"
    >> checkEqString t (urlKind (parseDeployment "http://user:pass@example.com")) "error"
         "credentials are rejected"
    >> checkEqString t (urlKind (parseDeployment "http://example.com?x=1")) "error"
         "a query string is rejected"
    >> checkEqString t (urlKind (parseDeployment "http://example.com:0")) "error"
         "port zero is rejected"
    >> check t (not (safeHeaderValue "bad\r\nInjected: 1")) "a header value with CRLF is rejected"
    >> check t (not (validFunctionPath "demo")) "a path without a colon is rejected"
    >> check t (validFunctionPath "demo:state") "a module:function path is accepted"

main : IO ⊤
main =
  initStandardStreams >> newTally >>= λ t →
  jsonChecks t >> numberChecks t >> utf8Checks t >> base64Checks t >> digestChecks t
    >> frameChecks t >> httpChecks t >> urlChecks t
    >> finish t "protocol-test"
