// ws.b -- an RFC 6455 WebSocket client, written in BCPL.
//
// The receive path is a resumable parser rather than a blocking reader. Bytes
// accumulate in Ws_rx and Ws_rxpos only ever advances over a frame that has
// arrived in full, so a deadline that expires halfway through a frame simply
// leaves the parser where it was. There is no code path that can re-enter the
// stream at a guessed frame boundary, which is the failure this design exists
// to prevent.

LET wsHandle(connection) = connection!Ws_handle

// The status codes RFC 6455 permits on the wire. 1005 and 1006 are reserved
// for local reporting and must never be sent, 1015 likewise, 1004 was never
// assigned, and anything below 1000 or between 1016 and 2999 is outside the
// registry. A peer that sends one of those is not speaking RFC 6455, and
// echoing it back would make this client send an illegal code too.
AND wsCloseCodeValid(code) = VALOF
{ IF code = 1000 RESULTIS TRUE
  IF code = 1001 RESULTIS TRUE
  IF code = 1002 RESULTIS TRUE
  IF code = 1003 RESULTIS TRUE
  IF 1007 <= code <= 1011 RESULTIS TRUE
  IF 3000 <= code <= 4999 RESULTIS TRUE
  RESULTIS FALSE
}

// Decides whether a server's answer to the opening handshake is one this
// client may keep using. Split out from wsConnect so the whole matrix -- a
// wrong proof, a missing token, an extension or subprotocol this client never
// offered -- can be driven from a test with a synthetic header block instead
// of being reachable only through a live deployment.
//
// `rx` holds the response, `headerend` is the offset just past its blank line,
// and `expected` is the base64 SHA-1 proof this client computed for its key.
AND wsHandshakeOk(rx, headerend, expected) = VALOF
{ LET accept = 0
  LET upgrade = 0
  LET connectionheader = 0
  LET extensions = 0
  LET subprotocol = 0
  LET ok = bbMatchStrAt(rx, 0, "HTTP/1.1 101")

  accept := httpHeaderValue(rx, headerend, "sec-websocket-accept")
  upgrade := httpHeaderValue(rx, headerend, "upgrade")
  connectionheader := httpHeaderValue(rx, headerend, "connection")
  // Neither was offered, so a server that answers with either is not speaking
  // the framing this client is about to decode.
  extensions := httpHeaderValue(rx, headerend, "sec-websocket-extensions")
  subprotocol := httpHeaderValue(rx, headerend, "sec-websocket-protocol")

  IF ok DO ok := bbEqual(accept, expected)
  IF ok DO ok := upgrade ~= 0
  IF ok DO ok := bbEqualFoldStr(upgrade, 0, upgrade!Bb_len, "websocket")
  IF ok DO ok := extensions = 0
  IF ok DO ok := subprotocol = 0
  IF ok DO
  { // The Connection header is a comma separated token list, so look for the
    // upgrade token rather than requiring the whole field to equal it.
    LET found = FALSE
    LET start = 0
    TEST connectionheader = 0
    THEN ok := FALSE
    ELSE
    { FOR index = 0 TO connectionheader!Bb_len DO
      { LET atend = index = connectionheader!Bb_len
        LET byte = (atend -> ',', bbGet(connectionheader, index))
        IF byte = ',' DO
        { LET from = start
          LET to = index
          UNTIL from >= to DO
          { UNLESS bbGet(connectionheader, from) = 32 DO BREAK
            from := from + 1
          }
          UNTIL to <= from DO
          { UNLESS bbGet(connectionheader, to - 1) = 32 DO BREAK
            to := to - 1
          }
          IF bbEqualFoldStr(connectionheader, from, to - from, "upgrade") DO
            found := TRUE
          start := index + 1
        }
      }
      ok := found
    }
  }

  bbFree(accept)
  bbFree(upgrade)
  bbFree(connectionheader)
  bbFree(extensions)
  bbFree(subprotocol)
  RESULTIS ok
}

AND wsFree(connection) BE
{ UNLESS connection RETURN
  IF connection!Ws_handle >= 0 DO cxCloseHandle(connection!Ws_handle)
  bbFree(connection!Ws_rx)
  bbFree(connection!Ws_msg)
  freevec(connection)
}

// Opens the connection and performs the RFC 6455 opening handshake, including
// checking the server's Sec-WebSocket-Accept proof. Accepting the upgrade
// without checking it would let any HTTP server that answers 101 pretend to
// speak the sync protocol.
AND wsConnect(endpoint, target, version, deadline) = VALOF
{ LET hostname = VEC 64
  LET keyraw = VEC 3
  LET keytext = 0
  LET expected = 0
  LET digest = 0
  LET request = 0
  LET connection = 0
  LET handle = 0
  LET headerend = 0
  LET ok = FALSE

  bbToStr(endpoint!Ep_host, hostname, 250)
  handle := cxConnect(hostname, endpoint!Ep_port, endpoint!Ep_tls, deadline)
  IF handle < 0 DO
  { errFromNative(Ek_transport, "TransportError",
                  "could not open the Convex sync connection")
    RESULTIS 0
  }

  connection := getvec(Ws_upb)
  UNLESS connection DO { cxCloseHandle(handle); RESULTIS 0 }
  connection!Ws_handle := handle
  connection!Ws_rx := bbNew(8192)
  connection!Ws_msg := bbNew(4096)
  connection!Ws_rxpos := 0
  connection!Ws_msgop := 0
  connection!Ws_broken := FALSE
  connection!Ws_closesent := FALSE
  connection!Ws_lastrx := cxNow()
  connection!Ws_pingsent := FALSE
  IF connection!Ws_rx = 0 DO { wsFree(connection); RESULTIS 0 }
  IF connection!Ws_msg = 0 DO { wsFree(connection); RESULTIS 0 }

  UNLESS cxRandomBytes(keyraw, 0, 16) DO
  { errSetStr(Ek_transport, "TransportError",
              "could not generate a WebSocket key")
    wsFree(connection)
    RESULTIS 0
  }
  keytext := bbNew(32)
  UNLESS keytext DO { wsFree(connection); RESULTIS 0 }
  base64Into(keyraw, 0, 16, keytext)

  request := bbNew(512)
  UNLESS request DO { bbFree(keytext); wsFree(connection); RESULTIS 0 }
  bbPushStr(request, "GET ")
  bbPushBuffer(request, endpoint!Ep_path)
  bbPushStr(request, target)
  bbPushStr(request, " HTTP/1.1*c*n")
  bbPushStr(request, "Host: ")
  bbPushBuffer(request, endpoint!Ep_host)
  UNLESS endpoint!Ep_port = (endpoint!Ep_tls -> 443, 80) DO
  { bbPush(request, ':')
    bbPushNum(request, endpoint!Ep_port)
  }
  bbPushStr(request, "*c*n")
  bbPushStr(request, "Upgrade: websocket*c*n")
  bbPushStr(request, "Connection: Upgrade*c*n")
  bbPushStr(request, "Sec-WebSocket-Key: ")
  bbPushBuffer(request, keytext)
  bbPushStr(request, "*c*n")
  bbPushStr(request, "Sec-WebSocket-Version: 13*c*n")
  bbPushStr(request, "Convex-Client: ")
  bbPushBuffer(request, version)
  bbPushStr(request, "*c*n*c*n")

  IF cxWriteBuffer(handle, request, deadline) < 0 DO
  { errFromNative(Ek_transport, "TransportError",
                  "the WebSocket handshake could not be sent")
    bbFree(request)
    bbFree(keytext)
    wsFree(connection)
    RESULTIS 0
  }
  bbFree(request)

  headerend := httpReadHeaders(handle, connection!Ws_rx, deadline)
  IF headerend < 0 DO { bbFree(keytext); wsFree(connection); RESULTIS 0 }

  // The proof is base64(sha1(key + the RFC's fixed GUID)).
  digest := bbNew(64)
  expected := bbNew(32)
  IF digest = 0 DO { bbFree(expected); bbFree(keytext)
                     wsFree(connection); RESULTIS 0 }
  IF expected = 0 DO { bbFree(digest); bbFree(keytext)
                       wsFree(connection); RESULTIS 0 }
  bbPushBuffer(digest, keytext)
  bbPushStr(digest, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  { LET proof = bbNew(32)
    IF proof ~= 0 DO
    { sha1Into(digest!Bb_vec, 0, digest!Bb_len, proof)
      base64Into(proof!Bb_vec, 0, proof!Bb_len, expected)
      bbFree(proof)
    }
  }
  bbFree(digest)
  bbFree(keytext)

  ok := wsHandshakeOk(connection!Ws_rx, headerend, expected)
  bbFree(expected)

  UNLESS ok DO
  { errSetStr(Ek_transport, "TransportError",
              "the Convex sync WebSocket upgrade was rejected")
    wsFree(connection)
    RESULTIS 0
  }

  // Anything the server sent after the header block is already frame data.
  bbTrimFront(connection!Ws_rx, headerend)
  connection!Ws_rxpos := 0
  wsStatus := Wss_message
  RESULTIS connection
}

// Client frames must always be masked. The mask is fresh per frame.
//
// An outgoing frame this client could not assemble in full must never reach
// the wire: a truncated frame would desynchronise the peer's parser rather
// than fail visibly. The one caller-sized quantity is the payload, so it is
// checked against the same bound the reader enforces before anything is built.
AND wsSendFrame(connection, opcode, payload, deadline) = VALOF
{ LET length = (payload = 0 -> 0, payload!Bb_len)
  LET frame = 0
  LET mask = VEC 0
  LET sent = 0
  IF length > Maxframebytes DO
  { errSetStr(Ek_protocol, "ProtocolError",
              "a Convex sync frame exceeded the frame bound")
    RESULTIS FALSE
  }
  frame := bbNew(length + 16)
  UNLESS frame RESULTIS FALSE
  bbPush(frame, #x80 | opcode)
  TEST length < 126
  THEN bbPush(frame, #x80 | length)
  ELSE TEST length < 65536
  THEN { bbPush(frame, #x80 | 126)
         bbPush(frame, shr32(length, 8) & 255)
         bbPush(frame, length & 255)
       }
  ELSE { bbPush(frame, #x80 | 127)
         bbPush(frame, 0)
         bbPush(frame, 0)
         bbPush(frame, 0)
         bbPush(frame, 0)
         bbPush(frame, shr32(length, 24) & 255)
         bbPush(frame, shr32(length, 16) & 255)
         bbPush(frame, shr32(length, 8) & 255)
         bbPush(frame, length & 255)
       }
  UNLESS cxRandomBytes(mask, 0, 4) DO { bbFree(frame); RESULTIS FALSE }
  FOR index = 0 TO 3 DO bbPush(frame, mask%index)
  FOR index = 0 TO length - 1 DO
    bbPush(frame, bbGet(payload, index) NEQV mask%(index REM 4))
  sent := cxWriteBuffer(connection!Ws_handle, frame, deadline)
  bbFree(frame)
  IF sent < 0 DO
  { connection!Ws_broken := TRUE
    errFromNative(Ek_transport, "TransportError",
                  "the Convex sync frame could not be sent")
    RESULTIS FALSE
  }
  RESULTIS TRUE
}

AND wsSendText(connection, payload, deadline) =
      wsSendFrame(connection, Op_text, payload, deadline)

AND wsSendControl(connection, opcode, payload, deadline) =
      wsSendFrame(connection, opcode, payload, deadline)

// Returns the next complete application message, or 0 with wsStatus telling
// the caller why. Wss_none means "nothing yet, ask again"; the connection is
// still usable and the parser has not moved.
AND wsNextMessage(connection, deadline) = VALOF
{ // A peer that never stops sending would otherwise hold this loop forever:
  // once its bytes are already in the kernel buffer, every read succeeds
  // without ever consulting the deadline, so a flood of pings or of tiny
  // fragments would be consumed indefinitely. The deadline is therefore tested
  // between frames as well, after at least one frame has been handled, so a
  // caller that passes an expired deadline still gets a frame that had already
  // arrived and a caller that is closing still gets out on time.
  LET consumed = FALSE
  // The broken test is inside the loop, not only at entry: answering a ping
  // or echoing a close can itself fail the connection part way through, and
  // reading on afterwards would be reading from a stream this client has
  // already declared unusable.
  { LET rx = connection!Ws_rx
    LET position = connection!Ws_rxpos
    LET available = rx!Bb_len - position
    LET first = 0
    LET second = 0
    LET opcode = 0
    LET final = FALSE
    LET length = 0
    LET headerlength = 2
    LET got = 0

    IF connection!Ws_broken DO { wsStatus := Wss_transport; RESULTIS 0 }
    IF consumed DO
      IF cxExpired(deadline) DO { wsStatus := Wss_none; RESULTIS 0 }

    IF available >= 2 DO
    { first := bbGet(rx, position)
      second := bbGet(rx, position + 1)
      opcode := first & 15
      final := (first & #x80) ~= 0

      IF (first & #x70) ~= 0 DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "a Convex sync frame set a reserved WebSocket bit")
        connection!Ws_broken := TRUE
        wsStatus := Wss_protocol
        RESULTIS 0
      }
      IF (second & #x80) ~= 0 DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "a server WebSocket frame must not be masked")
        connection!Ws_broken := TRUE
        wsStatus := Wss_protocol
        RESULTIS 0
      }

      length := second & 127
      TEST length = 126
      THEN
      { headerlength := 4
        IF available >= 4 DO
          length := (bbGet(rx, position + 2) << 8) | bbGet(rx, position + 3)
      }
      ELSE IF length = 127 DO
      { headerlength := 10
        IF available >= 10 DO
        { LET high = 0
          FOR index = 2 TO 5 DO high := high | bbGet(rx, position + index)
          IF high ~= 0 DO
          { errSetStr(Ek_protocol, "ProtocolError",
                      "a Convex sync frame declared an impossible length")
            connection!Ws_broken := TRUE
            wsStatus := Wss_protocol
            RESULTIS 0
          }
          length := (bbGet(rx, position + 6) << 24) |
                    (bbGet(rx, position + 7) << 16) |
                    (bbGet(rx, position + 8) << 8) |
                    bbGet(rx, position + 9)
        }
      }

      IF available >= headerlength DO
      { IF length < 0 | length > Maxframebytes DO
        { errSetStr(Ek_protocol, "ProtocolError",
                    "a Convex sync frame exceeded the frame bound")
          connection!Ws_broken := TRUE
          wsStatus := Wss_protocol
          RESULTIS 0
        }
        IF opcode >= 8 DO
        { LET bad = length > 125
          UNLESS final DO bad := TRUE
          IF bad DO
          { errSetStr(Ek_protocol, "ProtocolError",
                      "a WebSocket control frame was fragmented or oversized")
            connection!Ws_broken := TRUE
            wsStatus := Wss_protocol
            RESULTIS 0
          }
        }

        IF available >= headerlength + length DO
        { LET body = position + headerlength
          // Only now, with the whole frame present, does the cursor move.
          connection!Ws_rxpos := position + headerlength + length
          // A complete frame of any kind, including a control frame this
          // reader answers itself, proves the peer is still there. That is
          // what the Live owner's inactivity deadline is measured against.
          connection!Ws_lastrx := cxNow()
          connection!Ws_pingsent := FALSE
          consumed := TRUE

          IF opcode = Op_ping DO
          { LET echo = bbSlice(rx, body, length)
            IF echo ~= 0 DO
            { wsSendControl(connection, Op_pong, echo, deadline)
              bbFree(echo)
            }
            LOOP
          }
          IF opcode = Op_pong DO LOOP
          IF opcode = Op_close DO
          { LET echo = 0
            IF length = 1 DO
            { errSetStr(Ek_protocol, "ProtocolError",
                        "a WebSocket close frame carried a one byte payload")
              connection!Ws_broken := TRUE
              wsStatus := Wss_protocol
              RESULTIS 0
            }
            IF length >= 2 DO
            { LET code = (bbGet(rx, body) << 8) | bbGet(rx, body + 1)
              UNLESS wsCloseCodeValid(code) DO
              { errSetStr(Ek_protocol, "ProtocolError",
                          "a WebSocket close frame carried a reserved status code")
                connection!Ws_broken := TRUE
                wsStatus := Wss_protocol
                RESULTIS 0
              }
              // RFC 6455 makes the reason a UTF-8 string, and the same rule
              // that fails a text frame has to fail this.
              IF length > 2 DO
                UNLESS utf8Valid(rx!Bb_vec, body + 2, length - 2) DO
                { errSetStr(Ek_protocol, "ProtocolError",
                            "a WebSocket close reason was not valid UTF-8")
                  connection!Ws_broken := TRUE
                  wsStatus := Wss_protocol
                  RESULTIS 0
                }
            }
            // Exactly one close frame per endpoint: if this client has
            // already sent its own, the peer's close completes the handshake
            // rather than starting a second one. Only the validated status
            // code is echoed; the reason is the peer's, not this client's.
            UNLESS connection!Ws_closesent DO
            { echo := bbSlice(rx, body, (length > 2 -> 2, length))
              IF echo ~= 0 DO
              { connection!Ws_closesent := TRUE
                wsSendControl(connection, Op_close, echo, deadline)
                bbFree(echo)
              }
            }
            wsStatus := Wss_eof
            RESULTIS 0
          }

          IF opcode = Op_text | opcode = Op_binary DO
          { IF connection!Ws_msgop ~= 0 DO
            { errSetStr(Ek_protocol, "ProtocolError",
                        "a new WebSocket message began before the previous one finished")
              connection!Ws_broken := TRUE
              wsStatus := Wss_protocol
              RESULTIS 0
            }
            bbClear(connection!Ws_msg)
            connection!Ws_msgop := opcode
          }
          IF opcode = Op_continue DO
            IF connection!Ws_msgop = 0 DO
            { errSetStr(Ek_protocol, "ProtocolError",
                        "a WebSocket continuation frame had nothing to continue")
              connection!Ws_broken := TRUE
              wsStatus := Wss_protocol
              RESULTIS 0
            }
          UNLESS opcode = Op_text | opcode = Op_binary | opcode = Op_continue DO
          { errSetStr(Ek_protocol, "ProtocolError",
                      "an unsupported WebSocket opcode arrived")
            connection!Ws_broken := TRUE
            wsStatus := Wss_protocol
            RESULTIS 0
          }

          IF connection!Ws_msg!Bb_len + length > Maxmessagebytes DO
          { errSetStr(Ek_protocol, "ProtocolError",
                      "a Convex sync message exceeded the message bound")
            connection!Ws_broken := TRUE
            wsStatus := Wss_protocol
            RESULTIS 0
          }
          bbPushBytes(connection!Ws_msg, rx!Bb_vec, body, length)

          IF final DO
          { LET completed = connection!Ws_msgop
            connection!Ws_msgop := 0
            IF completed = Op_text DO
              UNLESS utf8Valid(connection!Ws_msg!Bb_vec, 0,
                               connection!Ws_msg!Bb_len) DO
              { errSetStr(Ek_protocol, "ProtocolError",
                          "a Convex sync text frame was not valid UTF-8")
                connection!Ws_broken := TRUE
                wsStatus := Wss_protocol
                RESULTIS 0
              }
            wsStatus := Wss_message
            RESULTIS connection!Ws_msg
          }
          LOOP
        }
      }
    }

    // Not enough bytes yet. Reclaim what has been consumed, then wait.
    IF connection!Ws_rxpos > 0 DO
    { bbTrimFront(rx, connection!Ws_rxpos)
      connection!Ws_rxpos := 0
    }
    IF rx!Bb_len >= Maxframebytes + 16 DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the Convex sync receive buffer exceeded its bound")
      connection!Ws_broken := TRUE
      wsStatus := Wss_protocol
      RESULTIS 0
    }
    got := bbReadInto(rx, connection!Ws_handle, 8192, deadline)
    IF got = Cx_timeout DO { wsStatus := Wss_none; RESULTIS 0 }
    IF got = Cx_eof DO { wsStatus := Wss_eof; RESULTIS 0 }
    IF got < 0 DO
    { errFromNative(Ek_transport, "TransportError",
                    "the Convex sync connection failed")
      connection!Ws_broken := TRUE
      wsStatus := Wss_transport
      RESULTIS 0
    }
  } REPEAT
}

// Sends a close frame and then drains, bounded by the caller's absolute
// deadline. A peer that is silent, a peer that never stops talking and a peer
// that stalls halfway through a frame all take the same bounded time here,
// because the deadline is absolute and is re-tested on every pass.
AND wsCloseGracefully(connection, deadline) BE
{ LET reason = bbNew(8)
  UNLESS connection RETURN
  UNLESS connection!Ws_broken DO
  { IF reason ~= 0 DO
      UNLESS connection!Ws_closesent DO
      { bbPush(reason, shr32(1000, 8) & 255)
        bbPush(reason, 1000 & 255)
        connection!Ws_closesent := TRUE
        wsSendControl(connection, Op_close, reason, deadline)
      }
    UNTIL cxExpired(deadline) DO
    { LET message = wsNextMessage(connection, deadline)
      IF message = 0 DO
        UNLESS wsStatus = Wss_message DO BREAK
    }
  }
  IF reason ~= 0 DO bbFree(reason)
  wsFree(connection)
}
