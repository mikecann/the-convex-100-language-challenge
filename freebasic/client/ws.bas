' RFC 6455 client framing implementation.

#include once "ws.bi"

' The fixed GUID from RFC 6455 section 1.3.
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
const WS_HANDSHAKE_MAX_BYTES = 16384

sub WsReset(byref conn as WsConnection)
  StreamReset(conn.stream)
  conn.inbound.Clear()
  conn.cursor = 0
  conn.fragmentActive = false
  conn.fragment.Clear()
  conn.frameDeadline = 0
  conn.messageDeadline = 0
  conn.sawCloseFrame = false
end sub

function WsAcceptToken(byref nonceKey as string) as string
  return Base64Encode(Sha1(nonceKey & WS_GUID))
end function

function WsHeaderHasToken(byref value as string, byref wanted as string) as boolean
  dim as string loweredWanted = AsciiLower(AsciiTrim(wanted))
  dim as integer start = 1
  do
    dim as integer comma = instr(start, value, ",")
    dim as string token
    if comma = 0 then
      token = mid(value, start)
    else
      token = mid(value, start, comma - start)
    end if
    if AsciiLower(AsciiTrim(token)) = loweredWanted then
      return true
    end if
    if comma = 0 then
      exit do
    end if
    start = comma + 1
  loop
  return false
end function

sub WsFeed(byref conn as WsConnection, byref chunk as string)
  conn.inbound.Append(chunk)
end sub

' Build one masked client frame. RFC 6455 requires a fresh unpredictable
' masking key per frame; the caller supplies it so tests can build fixtures.
function WsBuildFrame( _
    byval opcode as long, _
    byref payload as string, _
    byref mask as string) as string
  dim as StrBuf frame
  frame.AppendByte(&h80 or (opcode and &h0f))
  dim as ulongint length = culngint(len(payload))
  if length < 126 then
    frame.AppendByte(&h80 or cast(ubyte, length))
  elseif length <= 65535 then
    frame.AppendByte(&h80 or 126)
    frame.AppendByte((length shr 8) and &hff)
    frame.AppendByte(length and &hff)
  else
    frame.AppendByte(&h80 or 127)
    for shift as integer = 7 to 0 step -1
      frame.AppendByte((length shr (shift * 8)) and &hff)
    next
  end if
  for index as integer = 0 to 3
    frame.AppendByte(mask[index])
  next
  for index as integer = 0 to len(payload) - 1
    frame.AppendByte(payload[index] xor mask[index mod 4])
  next
  return frame.Take()
end function

function WsSendFrame( _
    byref conn as WsConnection, _
    byval opcode as long, _
    byref payload as string, _
    byval deadline as longint, _
    byref reason as string) as boolean
  if len(payload) > WS_MAX_MESSAGE_BYTES then
    reason = "WebSocket payload exceeds 2 MiB"
    return false
  end if
  if opcode >= 8 andalso len(payload) > 125 then
    reason = "WebSocket control payload exceeds 125 bytes"
    return false
  end if
  dim as string mask = RandomBytes(4)
  if len(mask) <> 4 then
    reason = "could not obtain a WebSocket masking key"
    return false
  end if
  dim as string frame = WsBuildFrame(opcode, payload, mask)
  return StreamWriteAll(conn.stream, frame, deadline, reason)
end function

function WsSendText( _
    byref conn as WsConnection, _
    byref payload as string, _
    byval deadline as longint, _
    byref reason as string) as boolean
  return WsSendFrame(conn, WS_OP_TEXT, payload, deadline, reason)
end function

private function HandshakeHeaderValue( _
    byref headers as string, _
    byref fieldName as string, _
    byref value as string) as boolean
  dim as string lowered = AsciiLower(headers)
  dim as string needle = chr(10) & AsciiLower(fieldName) & ":"
  dim as integer at = instr(lowered, needle)
  if at = 0 then
    return false
  end if
  if instr(at + len(needle), lowered, needle) > 0 then
    return false
  end if
  dim as integer start = at + len(needle)
  dim as integer stop_at = instr(start, headers, chr(13))
  if stop_at = 0 then
    stop_at = len(headers) + 1
  end if
  value = AsciiTrim(mid(headers, start, stop_at - start))
  return true
end function

function WsValidateHandshake( _
    byref headers as string, _
    byref nonceKey as string, _
    byref reason as string) as boolean
  dim as string afterStatus = mid(headers, 13, 1)
  if left(headers, 9) <> "HTTP/1.1 " orelse mid(headers, 10, 3) <> "101" orelse _
     (afterStatus <> " " andalso afterStatus <> chr(13)) then
    reason = "Convex did not accept the WebSocket upgrade"
    return false
  end if
  dim as string upgradeValue
  if not HandshakeHeaderValue(headers, "Upgrade", upgradeValue) orelse _
     AsciiLower(upgradeValue) <> "websocket" then
    reason = "WebSocket upgrade header was missing"
    return false
  end if
  dim as string connectionValue
  if not HandshakeHeaderValue(headers, "Connection", connectionValue) orelse _
     not WsHeaderHasToken(connectionValue, "upgrade") then
    reason = "WebSocket connection header was missing"
    return false
  end if
  dim as string acceptValue
  if not HandshakeHeaderValue(headers, "Sec-WebSocket-Accept", acceptValue) then
    reason = "WebSocket accept header was missing"
    return false
  end if
  if acceptValue <> WsAcceptToken(nonceKey) then
    reason = "WebSocket accept token did not match the key"
    return false
  end if
  ' No extension or subprotocol was offered, so accepting one would leave the
  ' peer framing messages in a way this decoder does not implement.
  dim as string negotiated
  if HandshakeHeaderValue(headers, "Sec-WebSocket-Extensions", negotiated) andalso _
     len(negotiated) > 0 then
    reason = "Convex negotiated an unrequested WebSocket extension"
    return false
  end if
  if HandshakeHeaderValue(headers, "Sec-WebSocket-Protocol", negotiated) andalso _
     len(negotiated) > 0 then
    reason = "Convex negotiated an unrequested WebSocket subprotocol"
    return false
  end if
  return true
end function

function WsHandshake( _
    byref conn as WsConnection, _
    byref target as ConvexUrl, _
    byref path as string, _
    byval timeoutMs as long, _
    byref fault as ConvexFault) as boolean
  WsReset(conn)
  dim as longint deadline = MonotonicMs() + timeoutMs
  dim as long remaining = cast(long, deadline - MonotonicMs())
  if remaining <= 0 then
    FaultSet(fault, FAULT_TRANSPORT, "WebSocket upgrade timed out")
    return false
  end if
  if not StreamConnect(conn.stream, target.host, target.port, target.useTls, _
                       remaining, fault) then
    return false
  end if

  dim as string nonce = RandomBytes(16)
  if len(nonce) <> 16 then
    FaultSet(fault, FAULT_TRANSPORT, "could not obtain a WebSocket nonce")
    StreamClose(conn.stream)
    return false
  end if
  dim as string nonceKey = Base64Encode(nonce)
  dim as string hostHeader = target.host
  if (target.useTls andalso target.port <> 443) orelse _
     ((not target.useTls) andalso target.port <> 80) then
    hostHeader &= ":" & FormatInteger(target.port)
  end if

  dim as StrBuf request
  request.Append("GET " & path & " HTTP/1.1" & chr(13, 10))
  request.Append("Host: " & hostHeader & chr(13, 10))
  request.Append("Upgrade: websocket" & chr(13, 10))
  request.Append("Connection: Upgrade" & chr(13, 10))
  request.Append("Sec-WebSocket-Key: " & nonceKey & chr(13, 10))
  request.Append("Sec-WebSocket-Version: 13" & chr(13, 10))
  request.Append("Convex-Client: freebasic-0.1.0" & chr(13, 10))
  request.Append(chr(13, 10))

  dim as string wire = request.Take()
  dim as string reason
  if not StreamWriteAll(conn.stream, wire, deadline, reason) then
    FaultSet(fault, FAULT_TRANSPORT, "could not send the WebSocket upgrade: " & reason)
    StreamClose(conn.stream)
    return false
  end if

  ' Read exactly the response header block. Bytes after the terminator are the
  ' first WebSocket frames and must not be discarded.
  dim as StrBuf received
  dim as string scratch = space(4096)
  dim as integer terminator = 0
  do
    if MonotonicMs() >= deadline then
      FaultSet(fault, FAULT_TRANSPORT, "WebSocket upgrade timed out")
      StreamClose(conn.stream)
      return false
    end if
    dim as long count = StreamRead( _
      conn.stream, cast(ubyte ptr, strptr(scratch)), 4096, deadline, reason)
    if count < 0 then
      FaultSet(fault, FAULT_TRANSPORT, "WebSocket upgrade failed: " & reason)
      StreamClose(conn.stream)
      return false
    end if
    if count > 0 then
      received.Append(left(scratch, count))
      dim as string sofar = received.Take()
      terminator = instr(sofar, chr(13, 10, 13, 10))
      if terminator > 0 then
        exit do
      end if
    end if
    if received.count > WS_HANDSHAKE_MAX_BYTES then
      FaultSet(fault, FAULT_PROTOCOL, "WebSocket upgrade response was oversized")
      StreamClose(conn.stream)
      return false
    end if
  loop

  dim as string full = received.Take()
  dim as string headers = left(full, terminator + 1)
  dim as string residue = mid(full, terminator + 4)
  if not WsValidateHandshake(headers, nonceKey, reason) then
    FaultSet(fault, FAULT_PROTOCOL, reason)
    StreamClose(conn.stream)
    return false
  end if

  conn.inbound.Clear()
  conn.inbound.Append(residue)
  conn.cursor = 0
  return true
end function

private function CloseStatusIsValid(byval status as ulong) as boolean
  if status >= 3000 andalso status <= 4999 then
    return true
  end if
  if status < 1000 orelse status > 1014 then
    return false
  end if
  ' 1004 is undefined, and 1005/1006 must never appear on the wire.
  return status <> 1004 andalso status <> 1005 andalso status <> 1006
end function

function WsDecode( _
    byref conn as WsConnection, _
    byref message as string, _
    byval deadline as longint, _
    byref reason as string) as long
  ' Locals are hoisted so the frame decoder is one flat loop with a single
  ' scope, which keeps the cursor arithmetic easy to audit.
  dim as uinteger available
  dim as ubyte firstOctet
  dim as ubyte secondOctet
  dim as boolean finalFrame
  dim as long opcode
  dim as ulongint length
  dim as uinteger headerLength
  dim as boolean control
  dim as string payload
  dim as ulong status
  dim as string ignored

  message = ""
  dim as longint now = MonotonicMs()
  if conn.frameDeadline > 0 andalso now >= conn.frameDeadline then
    reason = "WebSocket frame assembly exceeded its absolute deadline"
    return WS_PROTOCOL_ERROR
  end if
  if conn.messageDeadline > 0 andalso now >= conn.messageDeadline then
    reason = "WebSocket message assembly exceeded its absolute deadline"
    return WS_PROTOCOL_ERROR
  end if
  do
    available = conn.inbound.count - conn.cursor
    if available < 2 then
      exit do
    end if
    firstOctet = conn.inbound.store[conn.cursor]
    secondOctet = conn.inbound.store[conn.cursor + 1]
    finalFrame = ((firstOctet and &h80) <> 0)
    opcode = firstOctet and &h0f
    if (firstOctet and &h70) <> 0 then
      reason = "WebSocket frame used reserved bits"
      return WS_PROTOCOL_ERROR
    end if
    if (secondOctet and &h80) <> 0 then
      reason = "WebSocket server frame was masked"
      return WS_PROTOCOL_ERROR
    end if
    select case opcode
      case WS_OP_CONTINUATION, WS_OP_TEXT, WS_OP_BINARY, WS_OP_CLOSE, WS_OP_PING, WS_OP_PONG
      case else
        reason = "WebSocket frame used an unknown opcode"
        return WS_PROTOCOL_ERROR
    end select

    length = secondOctet and &h7f
    headerLength = 2
    if length = 126 then
      if available < 4 then
        exit do
      end if
      length = (cast(ulongint, conn.inbound.store[conn.cursor + 2]) shl 8) or _
               cast(ulongint, conn.inbound.store[conn.cursor + 3])
      headerLength = 4
      ' A minimal encoding is mandatory; a padded length is a framing bug or
      ' an attempt to confuse a lenient parser.
      if length < 126 then
        reason = "WebSocket frame used a noncanonical length"
        return WS_PROTOCOL_ERROR
      end if
    elseif length = 127 then
      if available < 10 then
        exit do
      end if
      if (conn.inbound.store[conn.cursor + 2] and &h80) <> 0 then
        reason = "WebSocket frame length exceeded 63 bits"
        return WS_PROTOCOL_ERROR
      end if
      length = 0
      for offset as integer = 2 to 9
        length = (length shl 8) or cast(ulongint, conn.inbound.store[conn.cursor + offset])
      next
      headerLength = 10
      if length <= 65535 then
        reason = "WebSocket frame used a noncanonical length"
        return WS_PROTOCOL_ERROR
      end if
    end if

    control = (opcode >= 8)
    if control andalso ((not finalFrame) orelse length > 125) then
      reason = "WebSocket control frame was fragmented or oversized"
      return WS_PROTOCOL_ERROR
    end if
    if length > WS_MAX_MESSAGE_BYTES then
      reason = "Live message exceeds 2 MiB"
      return WS_PROTOCOL_ERROR
    end if
    if cast(ulongint, available) < cast(ulongint, headerLength) + length then
      ' Once a header has been consumed the parser state must survive a
      ' timeout; leaving the cursor untouched keeps the frame boundary exact.
      exit do
    end if

    payload = conn.inbound.Slice(conn.cursor + headerLength, cast(uinteger, length))
    conn.cursor += headerLength + cast(uinteger, length)
    if conn.cursor > 0 then
      conn.inbound.DropFront(conn.cursor)
      conn.cursor = 0
    end if
    ' This frame is now complete. A following partial frame receives its own
    ' absolute deadline, while a fragmented message keeps its older deadline.
    conn.frameDeadline = 0

    select case opcode
      case WS_OP_CLOSE
        conn.sawCloseFrame = true
        if len(payload) = 1 then
          reason = "WebSocket Close frame omitted a complete status"
          return WS_PROTOCOL_ERROR
        end if
        if len(payload) >= 2 then
          status = (cast(ulong, payload[0]) shl 8) or cast(ulong, payload[1])
          if not CloseStatusIsValid(status) then
            reason = "WebSocket Close frame used an invalid status"
            return WS_PROTOCOL_ERROR
          end if
          if not IsValidUtf8(mid(payload, 3)) then
            reason = "WebSocket Close reason was not valid UTF-8"
            return WS_PROTOCOL_ERROR
          end if
        end if
        ' Echo the validated payload to finish the closing handshake, then let
        ' the caller retire the transport.
        WsSendFrame(conn, WS_OP_CLOSE, payload, deadline, ignored)
        reason = "server closed the Live WebSocket"
        return WS_TRANSPORT_LOST

      case WS_OP_PING
        if not WsSendFrame(conn, WS_OP_PONG, payload, deadline, reason) then
          return WS_TRANSPORT_LOST
        end if
        return WS_CONTROL

      case WS_OP_PONG
        return WS_CONTROL

      case WS_OP_BINARY
        reason = "Convex sent a binary Live message"
        return WS_PROTOCOL_ERROR

      case WS_OP_CONTINUATION
        if not conn.fragmentActive then
          reason = "WebSocket continuation had no leading text frame"
          return WS_PROTOCOL_ERROR
        end if
        if conn.fragment.count + culngint(len(payload)) > WS_MAX_MESSAGE_BYTES then
          reason = "Live message exceeds 2 MiB"
          return WS_PROTOCOL_ERROR
        end if
        conn.fragment.Append(payload)
        if not finalFrame then
          continue do
        end if
        message = conn.fragment.Take()
        conn.fragment.Clear()
        conn.fragmentActive = false
        conn.messageDeadline = 0

      case WS_OP_TEXT
        if conn.fragmentActive then
          reason = "WebSocket text frame interrupted a fragmented message"
          return WS_PROTOCOL_ERROR
        end if
        if not finalFrame then
          conn.fragmentActive = true
          conn.fragment.Clear()
          conn.fragment.Append(payload)
          conn.messageDeadline = MonotonicMs() + WS_MESSAGE_ASSEMBLY_TIMEOUT_MS
          continue do
        end if
        message = payload
    end select

    if not IsValidUtf8(message) then
      reason = "Live message was not valid UTF-8"
      return WS_PROTOCOL_ERROR
    end if
    return WS_MESSAGE
  loop

  if conn.cursor > 0 then
    conn.inbound.DropFront(conn.cursor)
    conn.cursor = 0
  end if
  if conn.inbound.count > WS_MAX_BUFFER_BYTES then
    reason = "WebSocket read buffer exceeded its bound"
    return WS_PROTOCOL_ERROR
  end if
  if conn.inbound.count > 0 andalso conn.frameDeadline = 0 then
    conn.frameDeadline = MonotonicMs() + WS_FRAME_ASSEMBLY_TIMEOUT_MS
  end if
  return WS_NEED_MORE
end function

function WsReceive( _
    byref conn as WsConnection, _
    byref message as string, _
    byval deadline as longint, _
    byref reason as string) as long
  dim as long decoded = WsDecode(conn, message, deadline, reason)
  if decoded <> WS_NEED_MORE then
    return decoded
  end if
  if not StreamIsOpen(conn.stream) then
    reason = "Live WebSocket is not connected"
    return WS_TRANSPORT_LOST
  end if
  dim as string scratch = space(16384)
  dim as long count = StreamRead( _
    conn.stream, cast(ubyte ptr, strptr(scratch)), 16384, deadline, reason)
  if count = 0 then
    return WS_NEED_MORE
  end if
  if count = -2 then
    reason = "Live WebSocket peer closed the transport"
    return WS_TRANSPORT_LOST
  end if
  if count < 0 then
    return WS_TRANSPORT_LOST
  end if
  conn.inbound.Append(left(scratch, count))
  return WsDecode(conn, message, deadline, reason)
end function

' Send a Close frame, then drop the transport. This never waits for the peer's
' reply: an idle or stalled peer must not extend a bounded close.
sub WsShutdown(byref conn as WsConnection, byval deadline as longint)
  if StreamIsOpen(conn.stream) andalso (not conn.sawCloseFrame) then
    dim as string payload = chr(3, 232)
    dim as string ignored
    WsSendFrame(conn, WS_OP_CLOSE, payload, deadline, ignored)
  end if
  StreamClose(conn.stream)
  conn.inbound.Clear()
  conn.cursor = 0
  conn.fragmentActive = false
  conn.fragment.Clear()
  conn.frameDeadline = 0
  conn.messageDeadline = 0
end sub
