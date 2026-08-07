use "pony_test"

// RFC 6455 framing. These tests build server frames by hand, because a fixture
// that used this file's own encoder to produce them would only prove the code
// agrees with itself.

primitive TestFrames
  """
  Server-to-client frames, which are never masked.
  """

  fun server(opcode: U8, payload: Array[U8] val, fin: Bool = true)
    : Array[U8] val
  =>
    var out: Array[U8] iso = Array[U8](payload.size() + 10)
    out.push((if fin then 0x80 else U8(0) end) or (opcode and 0x0f))
    let length = payload.size()
    if length < 126 then
      out.push(length.u8())
    elseif length < 65536 then
      out.push(126)
      out.push(((length >> 8) and 0xff).u8())
      out.push((length and 0xff).u8())
    else
      out.push(127)
      var shift: I32 = 56
      while shift >= 0 do
        out.push(((length.u64() >> shift.u64()) and 0xff).u8())
        shift = shift - 8
      end
    end
    var index: USize = 0
    while index < payload.size() do
      out.push(try payload(index)? else 0 end)
      index = index + 1
    end
    consume out

  fun text(payload: String, fin: Bool = true): Array[U8] val =>
    TestFrames.server(WsOpcode.text(), Bytes.of_string(payload), fin)

  fun continuation(payload: String, fin: Bool = true): Array[U8] val =>
    TestFrames.server(
      WsOpcode.continuation(), Bytes.of_string(payload), fin)

  fun mask(): Array[U8] val =>
    recover val
      let out = Array[U8](4)
      out.push(0x01)
      out.push(0x02)
      out.push(0x03)
      out.push(0x04)
      out
    end

class iso _TestWsHandshake is UnitTest
  fun name(): String => "websocket/handshake"

  fun apply(h: TestHelper) ? =>
    let endpoint = ConvexEndpoint("http://127.0.0.1:3210")?
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    let request = Bytes.to_string(
      WsHandshake.request(endpoint, endpoint.sync_path(), "pony-0.1.0", key)?)
    h.assert_true(Bytes.starts_with(request, "GET /api/sync HTTP/1.1\r\n"))
    h.assert_true(request.contains("Upgrade: websocket\r\n"))
    h.assert_true(request.contains("Sec-WebSocket-Version: 13\r\n"))
    h.assert_true(request.contains("Sec-WebSocket-Key: " + key + "\r\n"))

    // A correct upgrade response, with the first frames arriving in the same
    // read as the response head.
    let reader = WsHandshakeReader(WsHandshake.accept_for(key))
    let head: String val =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
      "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: " +
      WsHandshake.accept_for(key) + "\r\n\r\n"
    let combined: Array[U8] val = recover val
      let out = Array[U8](128)
      Bytes.append_string(out, head)
      Bytes.append_all(out, TestFrames.text("hello"))
      out
    end
    reader.push(combined)?
    h.assert_true(reader.complete())
    h.assert_eq[USize](7, reader.take_remainder().size())

class iso _TestWsHandshakeRejection is UnitTest
  fun name(): String => "websocket/handshake-rejection"

  fun apply(h: TestHelper) =>
    let accept = WsHandshake.accept_for("dGhlIHNhbXBsZSBub25jZQ==")

    // A wrong accept value means the peer did not prove it read the key, so
    // it is not a WebSocket peer this client will talk to.
    h.assert_error({()? =>
      let reader = WsHandshakeReader(accept)
      reader.push(Bytes.of_string(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
        "Connection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n"))?
    })

    // Anything other than 101 is a refusal, not an upgrade.
    h.assert_error({()? =>
      let reader = WsHandshakeReader(accept)
      reader.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
        "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"))?
    })

    // No extension was offered, so none may be selected.
    h.assert_error({()? =>
      let reader = WsHandshakeReader(accept)
      reader.push(Bytes.of_string(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
        "Connection: Upgrade\r\nSec-WebSocket-Extensions: permessage-deflate" +
        "\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"))?
    })

    // The status code is a token, not a prefix.
    h.assert_error({()? =>
      let reader = WsHandshakeReader(accept)
      reader.push(Bytes.of_string(
        "HTTP/1.1 1010 Nope\r\nUpgrade: websocket\r\n" +
        "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept +
        "\r\n\r\n"))?
    })

    // The accept proof is singular. A proxy may not smuggle a second value
    // that overwrites a wrong first value.
    h.assert_error({()? =>
      let reader = WsHandshakeReader(accept)
      reader.push(Bytes.of_string(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
        "Connection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n" +
        "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"))?
    })

class iso _TestWsFraming is UnitTest
  fun name(): String => "websocket/framing"

  fun apply(h: TestHelper) ? =>
    let parser = WsFrameParser

    // A whole frame delivered in one read.
    parser.push(TestFrames.text("first"))?
    match parser.next()?
    | let message: WsMessage => h.assert_eq[String]("first", message.text())
    | None => h.fail("expected a complete message")
    end

    // A frame split across two reads must not be visible until it is whole,
    // and the parser must report that it is holding a partial frame.
    let whole = TestFrames.text("second")
    parser.push(Bytes.freeze(whole, 0, 3))?
    h.assert_true(parser.partial())
    match parser.next()?
    | None => None
    | let message: WsMessage => h.fail("a partial frame must not yield")
    end
    parser.push(Bytes.freeze(whole, 3, whole.size()))?
    match parser.next()?
    | let message: WsMessage => h.assert_eq[String]("second", message.text())
    | None => h.fail("expected the completed message")
    end
    h.assert_false(parser.partial())

class iso _TestWsFragments is UnitTest
  fun name(): String => "websocket/fragments"

  fun apply(h: TestHelper) ? =>
    let parser = WsFrameParser

    // The euro sign is three bytes. Splitting it across two frames is legal,
    // so validation has to happen after reassembly.
    let euro = Bytes.of_string("€")
    var first: Array[U8] iso = Array[U8](2)
    first.push(try euro(0)? else 0 end)
    var rest: Array[U8] iso = Array[U8](2)
    rest.push(try euro(1)? else 0 end)
    rest.push(try euro(2)? else 0 end)

    parser.push(TestFrames.server(WsOpcode.text(), consume first, false))?
    h.assert_true(parser.partial())
    match parser.next()?
    | None => None
    | let message: WsMessage => h.fail("an unfinished message must not yield")
    end
    parser.push(
      TestFrames.server(WsOpcode.continuation(), consume rest, true))?
    match parser.next()?
    | let message: WsMessage => h.assert_eq[String]("€", message.text())
    | None => h.fail("expected the reassembled message")
    end

    // A control frame may be interleaved between fragments and is delivered
    // immediately rather than joined into the message.
    parser.push(TestFrames.text("a", false))?
    parser.push(TestFrames.server(WsOpcode.ping(), Bytes.of_string("p")))?
    parser.push(TestFrames.continuation("b", true))?
    match parser.next()?
    | let message: WsMessage => h.assert_eq[U8](WsOpcode.ping(), message.opcode)
    | None => h.fail("expected the interleaved ping")
    end
    match parser.next()?
    | let message: WsMessage => h.assert_eq[String]("ab", message.text())
    | None => h.fail("expected the reassembled fragments")
    end

class iso _TestWsStrict is UnitTest
  fun name(): String => "websocket/strict"

  fun apply(h: TestHelper) =>
    // A masked server frame is illegal and could hide payload from anything
    // reading the stream.
    h.assert_error({()? =>
      let parser = WsFrameParser
      var frame: Array[U8] iso = Array[U8](8)
      frame.push(0x81)
      frame.push(0x81)
      frame.push(0)
      frame.push(0)
      frame.push(0)
      frame.push(0)
      frame.push('x')
      parser.push(consume frame)?
      parser.next()?
    })

    // A close frame cannot contain half of its two-byte status code.
    h.assert_error({()? =>
      let parser = WsFrameParser
      parser.push(TestFrames.server(
        WsOpcode.close(), recover val [as U8: 0x03] end))?
      parser.next()?
    })

    // Reserved bits are not negotiated, so they must be zero.
    h.assert_error({()? =>
      let parser = WsFrameParser
      var frame: Array[U8] iso = Array[U8](4)
      frame.push(0xc1)
      frame.push(0x01)
      frame.push('x')
      parser.push(consume frame)?
      parser.next()?
    })

    // A control frame may not be fragmented.
    h.assert_error({()? =>
      let parser = WsFrameParser
      parser.push(
        TestFrames.server(WsOpcode.ping(), Bytes.of_string("p"), false))?
      parser.next()?
    })

    // A continuation without a message to continue is a framing error.
    h.assert_error({()? =>
      let parser = WsFrameParser
      parser.push(TestFrames.continuation("orphan"))?
      parser.next()?
    })

    // Invalid UTF-8 in a completed text message is a framing error, not a
    // lossy decode. Built from raw bytes directly: a Pony string literal's
    // `\xHH` escape UTF-8-encodes that scalar value rather than inserting the
    // raw byte, so `"\xff\xfe"` would actually be well-formed UTF-8.
    h.assert_error({()? =>
      let parser = WsFrameParser
      parser.push(TestFrames.server(
        WsOpcode.text(), recover val [as U8: 0xff; 0xfe] end))?
      parser.next()?
    })

class iso _TestWsClientFrames is UnitTest
  fun name(): String => "websocket/client-frames"

  fun apply(h: TestHelper) ? =>
    let encoded = WsFrame.text("hi", TestFrames.mask())?
    // Client frames are always masked, so the mask bit is set and the payload
    // is exclusive-ored with the key.
    h.assert_eq[U8](0x81, encoded(0)?)
    h.assert_eq[U8](0x82, encoded(1)?)
    h.assert_eq[U8]('h' xor 0x01, encoded(6)?)
    h.assert_eq[U8]('i' xor 0x02, encoded(7)?)

    let closed = WsFrame.close(1000, TestFrames.mask())?
    h.assert_eq[U8](0x88, closed(0)?)
    h.assert_eq[U8](0x82, closed(1)?)

    // The masking key must be four bytes.
    h.assert_error({()? =>
      WsFrame.text("hi", recover val Array[U8] end)?
    })
