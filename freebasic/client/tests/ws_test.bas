' Adversarial coverage for RFC 6455 framing. Frames are built by hand and fed
' to the decoder in deliberately awkward splits, because a decoder that only
' works on whole frames will silently restart at a false frame boundary the
' first time a real read stops mid-header.

#include once "ws.bi"
#include once "testing.bi"

' Server frames are never masked, so the fixtures are built directly rather
' than through WsBuildFrame.
function ServerFrame( _
    byval opcode as long, _
    byref payload as string, _
    byval finalFrame as boolean) as string
  dim as StrBuf frame
  dim as ubyte firstOctet = opcode and &h0f
  if finalFrame then
    firstOctet or= &h80
  end if
  frame.AppendByte(firstOctet)
  dim as integer length = len(payload)
  if length < 126 then
    frame.AppendByte(length)
  elseif length <= 65535 then
    frame.AppendByte(126)
    frame.AppendByte((length shr 8) and &hff)
    frame.AppendByte(length and &hff)
  else
    frame.AppendByte(127)
    for shift as integer = 7 to 0 step -1
      frame.AppendByte((length shr (shift * 8)) and &hff)
    next
  end if
  frame.Append(payload)
  return frame.Take()
end function

function DecodeWhole( _
    byref conn as WsConnection, _
    byref wire as string, _
    byref message as string, _
    byref reason as string) as long
  WsReset(conn)
  WsFeed(conn, wire)
  return WsDecode(conn, message, MonotonicMs() + 50, reason)
end function

dim as WsConnection conn
dim as string message
dim as string reason

' --- accept token ---------------------------------------------------------
CheckEqual(WsAcceptToken("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", _
  "the handshake accept token matches RFC 6455")
Check(WsAcceptToken("x") <> WsAcceptToken("y"), "different keys produce different tokens")
Check(WsHeaderHasToken("keep-alive, Upgrade", "upgrade"), _
  "Connection tokens are matched case-insensitively")
Check(not WsHeaderHasToken("notupgrade", "upgrade"), _
  "a Connection token is not accepted by substring")

dim as string handshakeKey = "dGhlIHNhbXBsZSBub25jZQ=="
dim as string handshake = "HTTP/1.1 101 Switching Protocols" & chr(13, 10) & _
  "Upgrade: WebSocket" & chr(13, 10) & _
  "Connection: keep-alive, Upgrade" & chr(13, 10) & _
  "Sec-WebSocket-Accept: " & WsAcceptToken(handshakeKey) & chr(13, 10, 13, 10)
Check(WsValidateHandshake(handshake, handshakeKey, reason), _
  "the exact case-insensitive 101 handshake is accepted")
dim as string substringConnection = "HTTP/1.1 101 Switching Protocols" & chr(13, 10) & _
  "Upgrade: websocket" & chr(13, 10) & _
  "Connection: notupgrade" & chr(13, 10) & _
  "Sec-WebSocket-Accept: " & WsAcceptToken(handshakeKey) & chr(13, 10, 13, 10)
Check(not WsValidateHandshake(substringConnection, handshakeKey, reason), _
  "a substring cannot satisfy the Connection token")
dim as string wrongAccept = "HTTP/1.1 101 Switching Protocols" & chr(13, 10) & _
  "Upgrade: websocket" & chr(13, 10) & _
  "Connection: Upgrade" & chr(13, 10) & _
  "Sec-WebSocket-Accept: wrong" & chr(13, 10, 13, 10)
Check(not WsValidateHandshake(wrongAccept, handshakeKey, reason), _
  "a 101 with the wrong accept token is rejected")
dim as string duplicateAccept = left(handshake, len(handshake) - 2) & _
  "Sec-WebSocket-Accept: " & WsAcceptToken(handshakeKey) & chr(13, 10, 13, 10)
Check(not WsValidateHandshake(duplicateAccept, handshakeKey, reason), _
  "a duplicated accept header is rejected rather than guessed at")

' --- client framing -------------------------------------------------------
dim as string mask = chr(1, 2, 3, 4)
dim as string frame = WsBuildFrame(WS_OP_TEXT, "hi", mask)
Check(len(frame) = 8, "a short client frame is header, mask, and payload")
Check(frame[0] = &h81, "a final text frame sets FIN and opcode 1")
Check(frame[1] = &h82, "the mask bit is set and the length is two")
Check(frame[6] = (asc("h") xor 1), "the payload is masked with the supplied key")
Check(frame[7] = (asc("i") xor 2), "the mask cycles through its four bytes")

dim as string medium = WsBuildFrame(WS_OP_TEXT, string(200, "x"), mask)
Check(medium[1] = (&h80 or 126), _
  "a 200 byte payload uses the 16-bit length form")
Check(medium[2] = 0 andalso medium[3] = 200, _
  "the 16-bit length is big endian")

dim as string largeClientFrame = WsBuildFrame(WS_OP_TEXT, string(65536, "z"), mask)
Check(largeClientFrame[1] = (&h80 or 127), _
  "a 65536 byte client payload uses the 64-bit length form")
Check(largeClientFrame[2] = 0 andalso largeClientFrame[3] = 0 andalso _
  largeClientFrame[4] = 0 andalso largeClientFrame[5] = 0 andalso _
  largeClientFrame[6] = 0 andalso largeClientFrame[7] = 1 andalso _
  largeClientFrame[8] = 0 andalso largeClientFrame[9] = 0, _
  "the 64-bit client length is encoded in network order")

dim as string ping = WsBuildFrame(WS_OP_PING, "", mask)
Check(len(ping) = 6, "an empty control frame is header plus mask")
Check(ping[0] = &h89, "a ping sets FIN and opcode 9")

' --- accepted server frames -----------------------------------------------
Check(DecodeWhole(conn, ServerFrame(WS_OP_TEXT, "{""type"":""Ping""}", true), _
  message, reason) = WS_MESSAGE, "a complete text frame decodes")
CheckEqual(message, "{""type"":""Ping""}", "the message payload is exact")

' Fragmentation across three frames, delivered one byte at a time.
dim as string fragmented = ServerFrame(WS_OP_TEXT, "abc", false) & _
  ServerFrame(WS_OP_CONTINUATION, "def", false) & _
  ServerFrame(WS_OP_CONTINUATION, "ghi", true)
WsReset(conn)
dim as long outcome = WS_NEED_MORE
for index as integer = 0 to len(fragmented) - 1
  WsFeed(conn, mid(fragmented, index + 1, 1))
  outcome = WsDecode(conn, message, MonotonicMs() + 50, reason)
  if outcome <> WS_NEED_MORE then
    exit for
  end if
next
Check(outcome = WS_MESSAGE, "a fragmented message decodes across split reads")
CheckEqual(message, "abcdefghi", "the fragments reassemble in order")

' A read that stops inside a header must not resume at a false boundary.
dim as string whole = ServerFrame(WS_OP_TEXT, string(300, "y"), true)
WsReset(conn)
WsFeed(conn, left(whole, 3))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_NEED_MORE, _
  "a partial extended header waits for more bytes")
WsFeed(conn, mid(whole, 4))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_MESSAGE, _
  "the frame completes once the rest arrives")
Check(len(message) = 300, "the extended length payload is complete")

' Absolute deadlines survive repeated decoder calls. A peer cannot keep an
' incomplete frame or fragmented message alive forever by dribbling bytes.
WsReset(conn)
WsFeed(conn, chr(&h81))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_NEED_MORE, _
  "an incomplete frame starts its assembly deadline")
conn.frameDeadline = MonotonicMs() - 1
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_PROTOCOL_ERROR, _
  "an incomplete frame expires on its original absolute deadline")

WsReset(conn)
WsFeed(conn, ServerFrame(WS_OP_TEXT, "part", false))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_NEED_MORE, _
  "a fragmented message starts its assembly deadline")
conn.messageDeadline = MonotonicMs() - 1
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_PROTOCOL_ERROR, _
  "a fragmented message expires even between otherwise valid frames")

' Two frames in one read are both decoded, one call at a time.
WsReset(conn)
WsFeed(conn, ServerFrame(WS_OP_TEXT, "one", true) & ServerFrame(WS_OP_TEXT, "two", true))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_MESSAGE, _
  "the first of two frames")
CheckEqual(message, "one", "the first payload")
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_MESSAGE, _
  "the second of two frames")
CheckEqual(message, "two", "the second payload")

' --- rejected server frames -----------------------------------------------
dim as string reserved = ServerFrame(WS_OP_TEXT, "x", true)
reserved[0] = reserved[0] or &h40
Check(DecodeWhole(conn, reserved, message, reason) = WS_PROTOCOL_ERROR, _
  "a reserved bit is a protocol error")

dim as string masked = ServerFrame(WS_OP_TEXT, "x", true)
masked[1] = masked[1] or &h80
Check(DecodeWhole(conn, masked, message, reason) = WS_PROTOCOL_ERROR, _
  "a masked server frame is a protocol error")

dim as string unknownOpcode = ServerFrame(WS_OP_TEXT, "x", true)
unknownOpcode[0] = &h83
Check(DecodeWhole(conn, unknownOpcode, message, reason) = WS_PROTOCOL_ERROR, _
  "an unknown opcode is a protocol error")

' A 16-bit length used for a payload that fits in seven bits.
dim as string padded = chr(&h81, 126, 0, 3) & "abc"
Check(DecodeWhole(conn, padded, message, reason) = WS_PROTOCOL_ERROR, _
  "a noncanonical 16-bit length is a protocol error")
dim as string padded64 = chr(&h81, 127, 0, 0, 0, 0, 0, 0, 0, 3) & "abc"
Check(DecodeWhole(conn, padded64, message, reason) = WS_PROTOCOL_ERROR, _
  "a noncanonical 64-bit length is a protocol error")
dim as string hugeLength = chr(&h81, 127, &h80, 0, 0, 0, 0, 0, 0, 0)
Check(DecodeWhole(conn, hugeLength, message, reason) = WS_PROTOCOL_ERROR, _
  "a length with the top bit set is a protocol error")
dim as string oversized = chr(&h81, 127, 0, 0, 0, 0, 0, &h40, 0, 1)
Check(DecodeWhole(conn, oversized, message, reason) = WS_PROTOCOL_ERROR, _
  "a frame past the 2 MiB bound is a protocol error")

Check(DecodeWhole(conn, ServerFrame(WS_OP_PING, string(126, "p"), true), message, reason) _
  = WS_PROTOCOL_ERROR, "an oversized control frame is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_PING, "p", false), message, reason) _
  = WS_PROTOCOL_ERROR, "a fragmented control frame is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_BINARY, "x", true), message, reason) _
  = WS_PROTOCOL_ERROR, "a binary data frame is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_CONTINUATION, "x", true), message, reason) _
  = WS_PROTOCOL_ERROR, "a continuation without a leading text frame is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_TEXT, "a", false) & _
  ServerFrame(WS_OP_TEXT, "b", true), message, reason) = WS_PROTOCOL_ERROR, _
  "a text frame interrupting a fragmented message is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_TEXT, chr(255, 254), true), message, reason) _
  = WS_PROTOCOL_ERROR, "a text frame that is not valid UTF-8 is a protocol error")

' --- close frames ---------------------------------------------------------
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, chr(3), true), message, reason) _
  = WS_PROTOCOL_ERROR, "a one byte close status is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, chr(3, 236), true), message, reason) _
  = WS_PROTOCOL_ERROR, "close status 1004 is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, chr(3, 238), true), message, reason) _
  = WS_PROTOCOL_ERROR, "close status 1006 must never appear on the wire")
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, chr(0, 1), true), message, reason) _
  = WS_PROTOCOL_ERROR, "an unregistered close status is a protocol error")
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, chr(3, 232) & chr(255), true), _
  message, reason) = WS_PROTOCOL_ERROR, "a close reason that is not UTF-8 is a protocol error")
' 4000 is the private-use code the shared controller's oracle disconnects with.
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, chr(15, 160) & "bye", true), _
  message, reason) = WS_TRANSPORT_LOST, "a valid close retires the transport")
Check(DecodeWhole(conn, ServerFrame(WS_OP_CLOSE, "", true), message, reason) _
  = WS_TRANSPORT_LOST, "an empty close payload is valid and retires the transport")

' --- control frames keep the stream healthy -------------------------------
Check(DecodeWhole(conn, ServerFrame(WS_OP_PONG, "keepalive", true), message, reason) _
  = WS_CONTROL, "a pong is healthy traffic rather than a message")

' A ping between two fragments must not disturb the reassembly.
WsReset(conn)
WsFeed(conn, ServerFrame(WS_OP_TEXT, "ab", false))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_NEED_MORE, _
  "the first fragment waits for its continuation")
WsFeed(conn, ServerFrame(WS_OP_PONG, "", true))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_CONTROL, _
  "an interleaved control frame is handled on its own")
WsFeed(conn, ServerFrame(WS_OP_CONTINUATION, "cd", true))
Check(WsDecode(conn, message, MonotonicMs() + 50, reason) = WS_MESSAGE, _
  "the fragmented message still completes")
CheckEqual(message, "abcd", "an interleaved control frame does not corrupt the payload")

end TestSummary("freebasic websocket")
