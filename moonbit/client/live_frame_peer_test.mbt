// Hostile WebSocket framing fixtures.
//
// These tests drive a peer that writes RFC 6455 frames by hand, so they can do
// things a well behaved WebSocket library will not: answer the handshake with
// the wrong `Sec-WebSocket-Accept`, send a binary frame where the sync protocol
// requires text, send a message larger than this client will assemble, and stop
// dead halfway through a frame.
//
// The property under test in every case is the same: the client abandons the
// connection rather than resuming a parser whose state it cannot trust, reports
// a structured failure, and recovers on the next connection.

///|
/// RFC 6455's fixed handshake GUID.
const WEBSOCKET_GUID : String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

///|
struct Counter {
  mut value : Int
}

///|
/// Complete the opening handshake by hand.
///
/// With `valid_accept` false the peer returns a `Sec-WebSocket-Accept` that does
/// not match the client's key, which a conforming client must reject.
async fn raw_handshake(connection : @socket.Tcp, valid_accept~ : Bool) -> Unit {
  guard connection.read_until("\r\n\r\n") is Some(head) else {
    fail("client sent no handshake")
  }
  let lower = head.to_lower()
  guard lower.find("sec-websocket-key:") is Some(start) else {
    fail("handshake omitted Sec-WebSocket-Key")
  }
  let rest = head.substring(start=start + 18)
  let end = match rest.find("\r\n") {
    Some(index) => index
    None => rest.length()
  }
  let key = rest.substring(start=0, end~).trim_space().to_owned()
  let accept = if valid_accept {
    @base64.encode(@tls.sha1(@utf8.encode(key + WEBSOCKET_GUID)))
  } else {
    "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
  }
  connection.write(
    @utf8.encode(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
      accept +
      "\r\n\r\n",
    ),
  )
}

///|
/// Build an unmasked server frame header. Server frames are never masked.
fn frame_header(opcode : Int, length : Int) -> Bytes {
  frame_header_at(opcode, length, fin=true)
}

///|
/// Build an unmasked server frame header, optionally without the FIN bit so the
/// message continues in a later continuation frame.
fn frame_header_at(opcode : Int, length : Int, fin~ : Bool) -> Bytes {
  let header = @buffer.Buffer(size_hint=10)
  header.write_byte(((if fin { 0x80 } else { 0x00 }) | opcode).to_byte())
  if length < 126 {
    header.write_byte(length.to_byte())
  } else if length < 65536 {
    header.write_byte((126).to_byte())
    header.write_byte(((length >> 8) & 0xff).to_byte())
    header.write_byte((length & 0xff).to_byte())
  } else {
    header.write_byte((127).to_byte())
    for shift = 56; shift >= 0; shift = shift - 8 {
      header.write_byte(((length >> shift) & 0xff).to_byte())
    }
  }
  header.to_bytes()
}

///|
async fn send_raw_text(connection : @socket.Tcp, text : String) -> Unit {
  let payload = @utf8.encode(text)
  connection.write(frame_header(0x1, payload.length()))
  connection.write(payload)
}

///|
async fn send_raw_binary(connection : @socket.Tcp, payload : Bytes) -> Unit {
  connection.write(frame_header(0x2, payload.length()))
  connection.write(payload)
}

///|
async fn send_raw_ping(connection : @socket.Tcp) -> Unit {
  connection.write(frame_header(0x9, 0))
}

///|
/// Send the closing handshake with an RFC 6455 status code.
async fn send_raw_close(connection : @socket.Tcp, code : Int) -> Unit {
  let payload = Bytes::makei(2, index => {
    if index == 0 {
      ((code >> 8) & 0xff).to_byte()
    } else {
      (code & 0xff).to_byte()
    }
  })
  connection.write(frame_header(0x8, payload.length()))
  connection.write(payload)
}

///|
/// Copy `source[start:end]` into its own `Bytes`.
fn bytes_slice(source : Bytes, start : Int, end : Int) -> Bytes {
  let out = @buffer.Buffer(size_hint=end - start)
  out.write_bytes(source[start:end])
  out.to_bytes()
}

///|
/// The first offset that falls strictly inside a multi-byte UTF-8 sequence.
///
/// Splitting a fragment there is the case that separates a decoder which
/// assembles the whole message before decoding from one that decodes each frame
/// on its own: the second kind sees a lead byte with no continuation and either
/// fails or substitutes a replacement character.
fn utf8_split_point(payload : Bytes) -> Int {
  for index = 0; index < payload.length(); index = index + 1 {
    if (payload[index].to_int() & 0xc0) == 0xc0 {
      return index + 1
    }
  }
  payload.length() / 2
}

///|
/// Send one text message as two fragments with a ping between them.
///
/// Both halves of the hazard are present: the split lands inside a multi-byte
/// character, and a control frame is interleaved in the middle of a message
/// that RFC 6455 explicitly allows to be interrupted that way.
async fn send_split_text(connection : @socket.Tcp, text : String) -> Unit {
  let payload = @utf8.encode(text)
  let split = utf8_split_point(payload)
  connection.write(frame_header_at(0x1, split, fin=false))
  connection.write(bytes_slice(payload, 0, split))
  send_raw_ping(connection)
  let rest = payload.length() - split
  connection.write(frame_header_at(0x0, rest, fin=true))
  connection.write(bytes_slice(payload, split, payload.length()))
}

///|
/// Announce a text frame of `declared` bytes and then send only `prefix`,
/// leaving the client's parser stopped in the middle of a frame.
async fn send_stalled_text(
  connection : @socket.Tcp,
  declared : Int,
  prefix : Int,
) -> Unit {
  connection.write(frame_header(0x1, declared))
  connection.write(Bytes::make(prefix, b'x'))
}

///|
/// Read one masked client frame and return its payload as text.
async fn read_client_text(connection : @socket.Tcp) -> String {
  let head = connection.read_exactly(2)
  let masked = (head[1].to_int() & 0x80) != 0
  let mut length = head[1].to_int() & 0x7f
  if length == 126 {
    let extended = connection.read_exactly(2)
    length = (extended[0].to_int() << 8) | extended[1].to_int()
  } else if length == 127 {
    let extended = connection.read_exactly(8)
    length = 0
    for index = 0; index < 8; index = index + 1 {
      length = (length << 8) | extended[index].to_int()
    }
  }
  let mask = if masked { connection.read_exactly(4) } else { b"" }
  let payload = connection.read_exactly(length)
  let plain = FixedArray::make(length, b'\x00')
  for index = 0; index < length; index = index + 1 {
    plain[index] = if masked {
      payload[index] ^ mask[index % 4]
    } else {
      payload[index]
    }
  }
  @utf8.decode(plain.unsafe_reinterpret_as_bytes()[:])
}

///|
/// Run `body` against a raw framing peer. `handle` is called once per accepted
/// connection with the zero-based connection index.
async fn with_frame_peer(
  handle : async (Int, @socket.Tcp) -> Unit,
  body : async (String) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    group.spawn_bg(
      () => {
        defer server.close()
        let counter = { value: 0 }
        for ;; {
          let (connection, _) = server.accept()
          let current = counter.value
          counter.value = counter.value + 1
          group.spawn_bg(
            () => {
              defer connection.close()
              handle(current, connection) catch {
                _ => ()
              }
            },
            no_wait=true,
            allow_failure=true,
          )
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    body("http://127.0.0.1:" + port.to_string())
  })
}

///|
/// Read the client's `Connect` and `ModifyQuerySet` and return the query id it
/// asked to add.
///
/// The observation is recorded rather than asserted for the same reason as in
/// `live_sync_peer_test.mbt`: a handler that must tolerate its socket being
/// torn down would otherwise swallow the assertion along with the teardown.
async fn raw_expect_add(log : PeerLog, connection : @socket.Tcp) -> Int {
  let connect = @json.parse(read_client_text(connection))
  log.check(
    @convex.json_field(connect, "type") is Some(String("Connect")),
    "expected a Connect message",
  )
  let modify = @json.parse(read_client_text(connection))
  add_query_id(modify)
}

///|
async test "a wrong Sec-WebSocket-Accept is refused and the client retries" {
  let peer = PeerLog::new()
  let attempts = { value: 0 }
  with_frame_peer(
    (index, connection) => {
      attempts.value = attempts.value + 1
      // The first two connections answer with an accept key that does not
      // match the client's nonce. A conforming client must not proceed.
      raw_handshake(connection, valid_accept=index >= 2)
      if index >= 2 {
        let query_id = raw_expect_add(peer, connection)
        send_raw_text(
          connection,
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":7}"),
          ),
        )
        read_client_text(connection) |> ignore
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        // The rejected handshakes never produce a value; the first value the
        // consumer sees comes from the connection that answered correctly.
        @test.assert_eq(update_count(expect_update(subscription)), 7L)
        @test.assert_eq(attempts.value >= 3, true)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a binary data frame abandons the connection and recovery follows" {
  let peer = PeerLog::new()
  with_frame_peer(
    (index, connection) => {
      raw_handshake(connection, valid_accept=true)
      let query_id = raw_expect_add(peer, connection)
      if index == 0 {
        // The sync protocol is text only. A binary frame is drift.
        send_raw_binary(connection, b"\x00\x01\x02")
        read_client_text(connection) |> ignore
      } else {
        send_raw_text(
          connection,
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":1}"),
          ),
        )
        read_client_text(connection) |> ignore
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        let dropped = expect_update(subscription)
        guard dropped.error is Some(info) else {
          fail("expected the connection to be reported as lost")
        }
        // A binary frame is something the peer said, not something the network
        // did, so it is reported as protocol drift.
        @test.assert_eq(info.kind.to_string(), "ProtocolError")
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a message larger than the assembly limit is refused" {
  let peer = PeerLog::new()
  with_frame_peer(
    (index, connection) => {
      raw_handshake(connection, valid_accept=true)
      let query_id = raw_expect_add(peer, connection)
      if index == 0 {
        send_stalled_text(
          connection,
          @convex.LIVE_MAX_MESSAGE_BYTES + 4096,
          @convex.LIVE_MAX_MESSAGE_BYTES + 4096,
        )
        read_client_text(connection) |> ignore
      } else {
        send_raw_text(
          connection,
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":2}"),
          ),
        )
        read_client_text(connection) |> ignore
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        let refused = expect_update(subscription)
        guard refused.error is Some(info) else {
          fail("expected the oversized message to be refused")
        }
        @test.assert_eq(info.kind.to_string(), "ProtocolError")
        @test.assert_eq(update_count(expect_update(subscription)), 2L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "control frames between messages do not disturb decoding" {
  let peer = PeerLog::new()
  with_frame_peer(
    (_, connection) => {
      raw_handshake(connection, valid_accept=true)
      let query_id = raw_expect_add(peer, connection)
      send_raw_ping(connection)
      send_raw_text(
        connection,
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":0}"),
        ),
      )
      send_raw_ping(connection)
      send_raw_text(
        connection,
        transition(
          1,
          peer_ts(1),
          2,
          peer_ts(2),
          query_updated(query_id, "{\"count\":1}"),
        ),
      )
      // Drain whatever the client writes, including its pong replies, so the
      // peer never blocks on an unread socket.
      for ;; {
        read_client_text(connection) |> ignore
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a peer stalled mid-frame cannot block unsubscribe or close" {
  let peer = PeerLog::new()
  with_frame_peer(
    (_, connection) => {
      raw_handshake(connection, valid_accept=true)
      let query_id = raw_expect_add(peer, connection)
      send_raw_text(
        connection,
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":0}"),
        ),
      )
      // Announce four kilobytes and send sixteen. The client's reader is now
      // parked in the middle of a frame and will never leave it.
      send_stalled_text(connection, 4096, 16)
      @async.sleep(30000)
    },
    origin => {
      let started = @async.now()
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        // The reader is stuck, but it is not the owner: control work goes
        // through the command queue and must still complete.
        client.unsubscribe(subscription)
        // Nothing was manufactured out of the truncated frame.
        @test.assert_eq(subscription.pending_updates(), 0)
      })
      let elapsed = @async.now() - started
      // Deadlines, not cooperation: assert the bound rather than trusting the
      // fixture to have closed politely.
      @test.assert_eq(elapsed < 8000L, true)
    },
  )
  peer.assert_clean()
}

///|
async test "a fragmented message split inside a character is reassembled" {
  let peer = PeerLog::new()
  // The value carries a two-byte character, and the fragment boundary lands
  // between its lead byte and its continuation byte. A decoder that treated
  // each frame as its own message would either fail here or quietly substitute
  // a replacement character, and a demonstration that silently mangles text is
  // worse than one that refuses it.
  let note = "café"
  with_frame_peer(
    (_, connection) => {
      raw_handshake(connection, valid_accept=true)
      let query_id = raw_expect_add(peer, connection)
      send_split_text(
        connection,
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":1,\"note\":\"" + note + "\"}"),
        ),
      )
      for ;; {
        read_client_text(connection) |> ignore
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        let update = expect_update(subscription)
        @test.assert_eq(update_count(update), 1L)
        guard update.value is Some(value) else { fail("expected a value") }
        @test.assert_eq(
          @convex.json_field(value, "note") is Some(String(found)) &&
          found == note,
          true,
        )
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a Close frame ends the connection and the client comes back" {
  let peer = PeerLog::new()
  with_frame_peer(
    (index, connection) => {
      raw_handshake(connection, valid_accept=true)
      let query_id = raw_expect_add(peer, connection)
      send_raw_text(
        connection,
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":" + index.to_string() + "}"),
        ),
      )
      if index == 0 {
        // A peer that says goodbye politely is still a peer that has gone. The
        // subscription must not be stranded on a socket that has been retired.
        send_raw_close(connection, 1001)
      }
      for ;; {
        read_client_text(connection) |> ignore
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        let lost = expect_update(subscription)
        guard lost.error is Some(info) else {
          fail("expected the closed connection to be reported")
        }
        // Either family is honest about a closing handshake: the peer said
        // something this client cannot continue from, or the bytes stopped.
        @test.assert_eq(
          info.kind.to_string() == "TransportError" ||
          info.kind.to_string() == "ProtocolError",
          true,
        )
        // Recovery on the replacement connection, on the same subscription.
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}
