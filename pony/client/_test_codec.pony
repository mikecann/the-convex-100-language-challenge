use "pony_test"

// Byte level codecs. These have published test vectors, so they are checked
// against those rather than against themselves.

class iso _TestBase64 is UnitTest
  fun name(): String => "codec/base64"

  fun apply(h: TestHelper) ? =>
    h.assert_eq[String]("", Base64Codec.encode(recover val Array[U8] end))
    h.assert_eq[String]("Zg==", Base64Codec.encode(Bytes.of_string("f")))
    h.assert_eq[String]("Zm8=", Base64Codec.encode(Bytes.of_string("fo")))
    h.assert_eq[String]("Zm9v", Base64Codec.encode(Bytes.of_string("foo")))
    h.assert_eq[String](
      "Zm9vYmFy", Base64Codec.encode(Bytes.of_string("foobar")))

    h.assert_eq[String](
      "foobar", Bytes.to_string(Base64Codec.decode("Zm9vYmFy")?))
    h.assert_eq[String]("f", Bytes.to_string(Base64Codec.decode("Zg==")?))

    // The initial sync timestamp must decode to exactly eight zero bytes.
    let initial = Base64Codec.decode(SyncTimestamp.initial())?
    h.assert_eq[USize](8, initial.size())
    for byte in initial.values() do
      h.assert_eq[U8](0, byte)
    end

    // Strictness: padding may only appear in the final quad, the length must
    // be a multiple of four, and the alphabet is fixed.
    h.assert_error({()? => Base64Codec.decode("Zm9vYmF")? })
    h.assert_error({()? => Base64Codec.decode("Zg==Zg==")? })
    h.assert_error({()? => Base64Codec.decode("Zm9-")? })

class iso _TestSha1 is UnitTest
  fun name(): String => "codec/sha1"

  fun apply(h: TestHelper) =>
    h.assert_eq[String](
      "da39a3ee5e6b4b0d3255bfef95601890afd80709",
      Hex.encode(Sha1(recover val Array[U8] end)))
    h.assert_eq[String](
      "a9993e364706816aba3e25717850c26c9cd0d89d",
      Hex.encode(Sha1(Bytes.of_string("abc"))))
    h.assert_eq[String](
      "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
      Hex.encode(Sha1(Bytes.of_string(
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))))

class iso _TestWebsocketAccept is UnitTest
  fun name(): String => "codec/websocket-accept"

  fun apply(h: TestHelper) =>
    // The worked example from RFC 6455 section 1.3. Getting this right is what
    // makes the handshake a real check instead of a formality.
    h.assert_eq[String](
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      WsHandshake.accept_for("dGhlIHNhbXBsZSBub25jZQ=="))

primitive _InvalidUtf8
  """
  Genuinely malformed byte sequences.

  A Pony string literal's `\xHH` escape inserts the UTF-8 encoding of that
  Unicode scalar value, not the raw byte, so `"\x80"` is actually the
  well-formed two byte sequence for U+0080. These build the raw bytes
  directly instead, so the fixtures below test what their names say.
  """

  fun lone_continuation(): Array[U8] val =>
    recover val
      let out = Array[U8](1)
      out.push(0x80)
      out
    end

  fun truncated_sequence(): Array[U8] val =>
    recover val
      let out = Array[U8](2)
      out.push(0xe2)
      out.push(0x82)
      out
    end

  fun overlong_encoding(): Array[U8] val =>
    recover val
      let out = Array[U8](2)
      out.push(0xc0)
      out.push(0xaf)
      out
    end

  fun encoded_surrogate_half(): Array[U8] val =>
    recover val
      let out = Array[U8](3)
      out.push(0xed)
      out.push(0xa0)
      out.push(0x80)
      out
    end

class iso _TestUtf8 is UnitTest
  fun name(): String => "codec/utf8"

  fun apply(h: TestHelper) =>
    h.assert_true(Utf8.valid(Bytes.of_string("plain ascii")))
    h.assert_true(Utf8.valid(
      Bytes.of_string("Καλημέρα مرحبا 🟨🟩🟦")))

    // A lone continuation byte, a truncated sequence, an over-long encoding,
    // and an encoded surrogate half are all rejected.
    h.assert_false(Utf8.valid(_InvalidUtf8.lone_continuation()))
    h.assert_false(Utf8.valid(_InvalidUtf8.truncated_sequence()))
    h.assert_false(Utf8.valid(_InvalidUtf8.overlong_encoding()))
    h.assert_false(Utf8.valid(_InvalidUtf8.encoded_surrogate_half()))

class iso _TestEndpoint is UnitTest
  fun name(): String => "endpoint/parse"

  fun apply(h: TestHelper) ? =>
    let plain = ConvexEndpoint("http://127.0.0.1:3210")?
    h.assert_false(plain.secure)
    h.assert_eq[String]("127.0.0.1", plain.host)
    h.assert_eq[String]("3210", plain.service)
    h.assert_eq[String]("127.0.0.1:3210", plain.authority)
    h.assert_eq[String]("/api/query", plain.function_path("query"))
    h.assert_eq[String]("/api/sync", plain.sync_path())

    let secure = ConvexEndpoint("https://example.convex.cloud")?
    h.assert_true(secure.secure)
    h.assert_eq[String]("443", secure.service)
    // The default port is omitted from the Host header.
    h.assert_eq[String]("example.convex.cloud", secure.authority)

    // A trailing slash must not produce `//api/query`.
    let prefixed = ConvexEndpoint("https://example.test/deployment/")?
    h.assert_eq[String](
      "/deployment/api/query", prefixed.function_path("query"))

    // Anything that could hide a credential, a query string, or a header
    // terminator is refused rather than quietly ignored.
    h.assert_error({()? => ConvexEndpoint("ftp://example.test")? })
    h.assert_error({()? => ConvexEndpoint("https://user:pass@example.test")? })
    h.assert_error({()? => ConvexEndpoint("https://example.test?token=1")? })
    h.assert_error({()? => ConvexEndpoint("https://exam ple.test")? })
    h.assert_error({()? => ConvexEndpoint("https://example.test:80a")? })
