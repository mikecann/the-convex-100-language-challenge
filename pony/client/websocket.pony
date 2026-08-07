// RFC 6455 client framing, written for the Convex sync socket.
//
// Convex Live runs over an ordinary WebSocket, so this is ordinary WebSocket
// work: an HTTP upgrade whose `Sec-WebSocket-Accept` is actually verified, a
// masked client-to-server framing layer, and an incremental reader that
// reassembles fragments before anything above it sees a message.
//
// Two properties matter more here than anywhere else in the client.
//
// The reader never discards a partially received frame. Bytes stay in the
// buffer until a whole frame is available, so a read timeout can only abandon
// the connection; it can never resume at a byte that is not a frame boundary
// and mistake payload for a header.
//
// UTF-8 is validated on the reassembled message rather than per fragment,
// because a multi-byte code point is allowed to be split across two frames.

primitive WsOpcode
  fun continuation(): U8 => 0x0
  fun text(): U8 => 0x1
  fun binary(): U8 => 0x2
  fun close(): U8 => 0x8
  fun ping(): U8 => 0x9
  fun pong(): U8 => 0xa

class val WsMessage
  """
  One complete application message or control frame.
  """

  let opcode: U8
  let payload: Array[U8] val

  new val create(opcode': U8, payload': Array[U8] val) =>
    opcode = opcode'
    payload = payload'

  fun text(): String => Bytes.to_string(payload)

primitive WsHandshake
  """
  The HTTP upgrade half of the connection.
  """

  fun guid(): String => "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  fun accept_for(key: String): String =>
    Base64Codec.encode(Sha1(Bytes.of_string(key + WsHandshake.guid())))

  fun request(
    endpoint: ConvexEndpoint,
    path: String,
    client_version: String,
    key: String)
    : Array[U8] val ?
  =>
    if not HttpRequest.safe_header_value(client_version) then error end
    if not HttpRequest.safe_header_value(key) then error end
    if not HttpRequest.safe_header_value(path) then error end
    recover val
      let out = Array[U8](256)
      Bytes.append_string(out, "GET ")
      Bytes.append_string(out, path)
      Bytes.append_string(out, " HTTP/1.1\r\n")
      Bytes.append_string(out, "Host: ")
      Bytes.append_string(out, endpoint.authority)
      Bytes.append_string(out, "\r\n")
      Bytes.append_string(out, "Upgrade: websocket\r\n")
      Bytes.append_string(out, "Connection: Upgrade\r\n")
      Bytes.append_string(out, "Sec-WebSocket-Key: ")
      Bytes.append_string(out, key)
      Bytes.append_string(out, "\r\n")
      Bytes.append_string(out, "Sec-WebSocket-Version: 13\r\n")
      Bytes.append_string(out, "Convex-Client: ")
      Bytes.append_string(out, client_version)
      Bytes.append_string(out, "\r\n\r\n")
      out
    end

class ref WsHandshakeReader
  """
  Reads the upgrade response and hands back whatever frame bytes arrived with
  it.

  A server is allowed to put the first frames in the same TCP segment as the
  `101`, so dropping the remainder here would lose the first `Transition`.
  """

  let _expected_accept: String
  let _buffer: Array[U8] = Array[U8]
  var _complete: Bool = false
  var _body_start: USize = 0

  new ref create(expected_accept: String) =>
    _expected_accept = expected_accept

  fun ref push(data: Array[U8] val) ? =>
    if _complete then
      if (_buffer.size() + data.size()) >
        (ConvexLimits.max_header_bytes() +
          ConvexLimits.max_websocket_frame_bytes() + 4096)
      then
        error
      end
      Bytes.append_all(_buffer, data)
      return
    end
    if (_buffer.size() + data.size()) >
      (ConvexLimits.max_header_bytes() +
        ConvexLimits.max_websocket_frame_bytes() + 4096)
    then
      error
    end
    Bytes.append_all(_buffer, data)
    var index: USize = 0
    var found = false
    while (index + 4) <= _buffer.size() do
      if (_buffer(index)? == '\r') and (_buffer(index + 1)? == '\n') and
        (_buffer(index + 2)? == '\r') and (_buffer(index + 3)? == '\n')
      then
        found = true
        break
      end
      index = index + 1
    end
    if not found then
      if _buffer.size() > ConvexLimits.max_header_bytes() then error end
      return
    end
    _verify(Bytes.to_string(Bytes.freeze(_buffer, 0, index)))?
    _body_start = index + 4
    _complete = true

  fun ref complete(): Bool => _complete

  fun ref take_remainder(): Array[U8] val =>
    """
    Frame bytes that arrived with or after the handshake response.
    """
    if not _complete then return recover val Array[U8] end end
    let remainder = Bytes.freeze(_buffer, _body_start, _buffer.size())
    _buffer.clear()
    _body_start = 0
    remainder

  fun ref _verify(head: String) ? =>
    let lines = HttpText.split_lines(head)
    if lines.size() == 0 then error end
    let status_line = lines(0)?
    if not ((status_line == "HTTP/1.1 101") or
      Bytes.starts_with(status_line, "HTTP/1.1 101 "))
    then
      error
    end

    var upgrade_ok = false
    var connection_ok = false
    var accept_ok = false
    var accept_seen = false
    var line_index: USize = 1
    while line_index < lines.size() do
      let line = lines(line_index)?
      line_index = line_index + 1
      if line.size() == 0 then continue end
      let colon = HttpText.index_of(line, ':')?
      let name = Bytes.lower(HttpText.slice(line, 0, colon))
      let value = HttpText.trim(HttpText.slice(line, colon + 1, line.size()))
      if name == "upgrade" then
        upgrade_ok = upgrade_ok or
          HttpText.has_token(Bytes.lower(value), "websocket")
      elseif name == "connection" then
        // The header is a comma separated list, and `keep-alive, Upgrade` is
        // a legal way for a proxy to write it.
        connection_ok = connection_ok or
          HttpText.has_token(Bytes.lower(value), "upgrade")
      elseif name == "sec-websocket-accept" then
        if accept_seen then error end
        accept_seen = true
        accept_ok = value == _expected_accept
      elseif name == "sec-websocket-extensions" then
        // No extension was offered, so the server may not select one.
        if value.size() > 0 then error end
      end
    end
    if not (upgrade_ok and connection_ok and accept_ok) then error end


primitive WsFrame
  """
  Client-to-server framing. RFC 6455 requires every client frame to be masked.
  """

  fun encode(opcode: U8, payload: Array[U8] val, mask: Array[U8] val)
    : Array[U8] val ?
  =>
    if mask.size() != 4 then error end
    if payload.size() > ConvexLimits.max_websocket_frame_bytes() then error end
    var out: Array[U8] iso = Array[U8](payload.size() + 14)
    out.push(0x80 or (opcode and 0x0f))
    let length = payload.size()
    if length < 126 then
      out.push(0x80 or length.u8())
    elseif length < 65536 then
      out.push(0x80 or 126)
      out.push(((length >> 8) and 0xff).u8())
      out.push((length and 0xff).u8())
    else
      out.push(0x80 or 127)
      var shift: I32 = 56
      while shift >= 0 do
        out.push(((length.u64() >> shift.u64()) and 0xff).u8())
        shift = shift - 8
      end
    end
    var index: USize = 0
    while index < 4 do
      out.push(mask(index)?)
      index = index + 1
    end
    index = 0
    while index < payload.size() do
      out.push(payload(index)? xor mask(index % 4)?)
      index = index + 1
    end
    consume out

  fun text(payload: String, mask: Array[U8] val): Array[U8] val ? =>
    WsFrame.encode(WsOpcode.text(), Bytes.of_string(payload), mask)?

  fun pong(payload: Array[U8] val, mask: Array[U8] val): Array[U8] val ? =>
    WsFrame.encode(WsOpcode.pong(), payload, mask)?

  fun close(code: U16, mask: Array[U8] val): Array[U8] val ? =>
    let payload = recover val
      let body = Array[U8](2)
      body.push(((code >> 8) and 0xff).u8())
      body.push((code and 0xff).u8())
      body
    end
    WsFrame.encode(WsOpcode.close(), payload, mask)?

class ref WsFrameParser
  """
  Incremental server-to-client frame reader.
  """

  let _buffer: Array[U8] = Array[U8]
  var _position: USize = 0
  let _fragments: Array[U8] = Array[U8]
  var _fragment_opcode: U8 = 0
  var _assembling: Bool = false

  new ref create() =>
    None

  fun ref push(data: Array[U8] val) ? =>
    // The buffer holds at most one incomplete frame plus whatever arrived with
    // it. Exceeding the frame budget by a wide margin means the peer is not
    // speaking the pinned protocol.
    let retained = _buffer.size() - _position
    let limit = ConvexLimits.max_websocket_frame_bytes() + 4096
    if (retained > limit) or (data.size() > (limit - retained))
    then
      error
    end
    Bytes.append_all(_buffer, data)

  fun ref partial(): Bool =>
    """
    True when bytes of an unfinished frame are buffered. The Live owner arms an
    absolute deadline while this holds, and abandons the connection when it
    expires rather than trying to resynchronise.
    """
    (_position < _buffer.size()) or _assembling

  fun ref next(): (WsMessage | None) ? =>
    """
    Returns the next complete message, or `None` when more bytes are needed.
    Raises on any frame this client's contract does not allow.
    """
    while true do
      let available = _buffer.size() - _position
      if available < 2 then
        _compact()
        return None
      end
      let byte0 = _buffer(_position)?
      let byte1 = _buffer(_position + 1)?
      let fin = (byte0 and 0x80) != 0
      if (byte0 and 0x70) != 0 then error end
      let opcode = byte0 and 0x0f
      // A server frame is never masked. Accepting one would let a peer hide
      // payload from anything inspecting the stream.
      if (byte1 and 0x80) != 0 then error end

      var header: USize = 2
      var length: USize = (byte1 and 0x7f).usize()
      if length == 126 then
        if available < 4 then
          _compact()
          return None
        end
        length = (_buffer(_position + 2)?.usize() << 8) or
          _buffer(_position + 3)?.usize()
        if length < 126 then error end
        header = 4
      elseif length == 127 then
        if available < 10 then
          _compact()
          return None
        end
        if _buffer(_position + 2)? != 0 then error end
        var wide: U64 = 0
        var index: USize = 2
        while index < 10 do
          wide = (wide << 8) or _buffer(_position + index)?.u64()
          index = index + 1
        end
        if wide < 65536 then error end
        if wide > ConvexLimits.max_websocket_frame_bytes().u64() then error end
        length = wide.usize()
        header = 10
      end
      if length > ConvexLimits.max_websocket_frame_bytes() then error end
      if available < (header + length) then
        _compact()
        return None
      end

      let payload_start = _position + header
      let payload = Bytes.freeze(
        _buffer, payload_start, payload_start + length)
      _position = payload_start + length

      if opcode >= 0x8 then
        // Control frames must be self contained so they can be answered even
        // while a data message is still being assembled.
        if (not fin) or (length > 125) then error end
        if (opcode != WsOpcode.close()) and (opcode != WsOpcode.ping()) and
          (opcode != WsOpcode.pong())
        then
          error
        end
        // A close payload may be empty or contain a two-byte status followed
        // by UTF-8 reason text. A one-byte status can never be valid.
        if opcode == WsOpcode.close() then
          if length == 1 then error end
          if (length > 2) and
            (not Utf8.valid(Bytes.freeze(payload, 2, payload.size())))
          then
            error
          end
        end
        return WsMessage(opcode, payload)
      end

      if opcode == WsOpcode.continuation() then
        if not _assembling then error end
        if payload.size() >
          (ConvexLimits.max_websocket_message_bytes() - _fragments.size())
        then
          error
        end
        Bytes.append_all(_fragments, payload)
      elseif (opcode == WsOpcode.text()) or (opcode == WsOpcode.binary()) then
        if _assembling then error end
        _fragments.clear()
        if payload.size() > ConvexLimits.max_websocket_message_bytes() then
          error
        end
        Bytes.append_all(_fragments, payload)
        _fragment_opcode = opcode
        _assembling = true
      else
        error
      end
      if _fragments.size() > ConvexLimits.max_websocket_message_bytes() then
        error
      end

      if fin then
        let complete = Bytes.freeze(_fragments, 0, _fragments.size())
        _fragments.clear()
        _assembling = false
        if _fragment_opcode == WsOpcode.text() then
          // Validation happens here, on the joined message, because a code
          // point may legally straddle a fragment boundary.
          if not Utf8.valid(complete) then error end
        end
        return WsMessage(_fragment_opcode, complete)
      end
    end
    None

  fun ref _compact() =>
    // Reclaim the consumed prefix once it is worth doing, so a long-lived
    // connection does not accumulate an ever growing buffer of read frames.
    if _position == 0 then return end
    if (_position < 4096) and (_position < (_buffer.size() / 2)) then return end
    let remainder = Bytes.freeze(_buffer, _position, _buffer.size())
    _buffer.clear()
    Bytes.append_all(_buffer, remainder)
    _position = 0
