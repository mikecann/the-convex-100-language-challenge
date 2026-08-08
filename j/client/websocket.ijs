NB. websocket.ijs -- RFC 6455 framing over a tx_connect connection: the
NB. opening HTTP Upgrade handshake, client-to-server masking, fragment
NB. reassembly, control frames arriving mid-message, and one UTF-8
NB. validation pass over the reassembled text message. This is protocol
NB. logic, not transport, so unlike transport.ijs it is plain J throughout:
NB. no foreign call in this file does anything WebSocket-specific.
NB.
NB. Frame bytes are byte-VALUE lists (0-255 integers), matching
NB. transport.ijs's tx_send/tx_recv; HTTP-handshake text is a character
NB. string, matching convex.ijs. `a.{~`/`a.i.` convert between the two at
NB. exactly the seam where a length or mask field turns into wire bytes.

load '/project/client/json.ijs'
load '/project/client/transport.ijs'
load '/project/client/convex.ijs'

WS_OP_CONT=: 0
WS_OP_TEXT=: 1
WS_OP_BINARY=: 2
WS_OP_CLOSE=: 8
WS_OP_PING=: 9
WS_OP_PONG=: 10

WS_GUID=: '258EAFA5-E914-47DA-95CA-C5AB0DC85B11' NB. RFC 6455 fixed handshake GUID

NB. ---------------------------------------------------------------------------
NB. Handshake
NB. ---------------------------------------------------------------------------

NB. y is (<conn),(<deadline). Upgrades the given tx_connect connection to a
NB. WebSocket at /api/sync. Result is (<ok),(<leftover) where leftover is
NB. any bytes read past the handshake response (the server may pipeline the
NB. first frame right after the 101), as a byte-value list ready to seed the
NB. frame reader's carry buffer.
ws_handshake=: 3 : 0
  conn=. > 0 { y
  deadline=. > 1 { y
  NB. tx_base64_encode already returns characters (it indexes the alphabet
  NB. string directly), so `keychars` needs no further a.{~ conversion --
  NB. only the SHA-1 input, built by concatenating two character strings,
  NB. is converted back to byte values for tx_sha1's byte-value contract.
  keychars=. tx_base64_encode tx_random_bytes 16
  expect=. tx_base64_encode tx_sha1 a. i. keychars , WS_GUID

  request=. 'GET /api/sync HTTP/1.1', CRLF
  request=. request, 'Host: ', CX_HOST_HEADER, CRLF
  request=. request, 'Upgrade: websocket', CRLF
  request=. request, 'Connection: Upgrade', CRLF
  request=. request, 'Sec-WebSocket-Key: ', keychars, CRLF
  request=. request, 'Sec-WebSocket-Version: 13', CRLF
  request=. request, 'Convex-Client: ', CX_CLIENT_VERSION, CRLF, CRLF

  'wstatus wmsg'=. tx_send (<conn),(<(a. i. request)),(<tx_remaining deadline)
  if. wstatus ~: TX_IO_OK do.
    (cx_fail 'TransportError';'WebSocket upgrade write failed') ] ((<0),(<'')) return.
  end.

  'ok buffer headerend'=. cx_read_until (<conn),(<(CRLF,CRLF)),(<''),(<deadline),(<CX_HTTP_MAX_HEADERS)
  if. -. ok do. (<0),(<'') return. end.
  status=. cx_http_status buffer
  if. status < 0 do. (<0),(<'') return. end.
  statuslineend=. buffer cx_find CRLF;0
  hparsed=. cx_http_headers (statuslineend + 2) }. headerend {. buffer
  hok=. > 0 { hparsed
  headers=. > 1 { hparsed
  if. -. hok do. (<0),(<'') return. end.

  if. status ~: 101 do.
    (cx_fail 'ProtocolError';'the deployment refused the WebSocket upgrade') ] ((<0),(<'')) return.
  end.
  if. -. (cx_lower headers cx_header_find 'upgrade') -: 'websocket' do.
    (cx_fail 'ProtocolError';'the deployment refused the WebSocket upgrade') ] ((<0),(<'')) return.
  end.
  if. -. (cx_lower headers cx_header_find 'connection') -: 'upgrade' do.
    (cx_fail 'ProtocolError';'the deployment refused the WebSocket upgrade') ] ((<0),(<'')) return.
  end.
  accept=. headers cx_header_find 'sec-websocket-accept'
  if. -. accept -: expect do.
    (cx_fail 'ProtocolError';'the WebSocket accept key did not match') ] ((<0),(<'')) return.
  end.

  leftover=. a. i. (headerend + 4) }. buffer
  (<1),(<leftover)
)

NB. ---------------------------------------------------------------------------
NB. Frame encode (client -> server, always masked per RFC 6455)
NB. ---------------------------------------------------------------------------

NB. y is (<opcode),(<payload) where payload is a byte-value list. Result is
NB. a byte-value list ready for tx_send. The mask is fresh random bytes per
NB. frame, XORed against the payload with the whole-array bit transform
NB. tx_xor already provides -- no per-byte loop.
ws_encode_frame=: 3 : 0
  opcode=. > 0 { y
  payload=. > 1 { y
  n=. # payload
  first_byte=. 128 + opcode  NB. FIN=1, RSV=0, opcode
  if. n < 126 do.
    lenbytes=. , 128 + n      NB. MASK bit set, length in 7 bits
  elseif. n < 65536 do.
    lenbytes=. (, 128 + 126) , 2 tx_be n
  else.
    lenbytes=. (, 128 + 127) , 8 tx_be n
  end.
  mask=. tx_random_bytes 4
  masked=. payload tx_xor (n $ mask)
  (, first_byte) , lenbytes , mask , masked
)

NB. Convenience wrappers; both take a byte-value payload directly.
ws_encode_text=: 3 : 0
  ws_encode_frame (<WS_OP_TEXT),(<y)
)
ws_encode_close=: 3 : 0
  ws_encode_frame (<WS_OP_CLOSE),(<(2 tx_be y))
)

NB. ---------------------------------------------------------------------------
NB. Frame decode
NB.
NB. The server never masks; RFC 6455 says a client MUST close the
NB. connection if it does, so a set mask bit here is a protocol error, not
NB. something to honour.
NB. ---------------------------------------------------------------------------

WS_IO_OK=: 1
WS_IO_TIMEOUT=: 0
WS_IO_EOF=: _1
WS_IO_ERROR=: _2
WS_IO_PROTOCOL=: _3

NB. Ensure `buffer` (a byte-value list) holds at least `need` bytes, reading
NB. more from conn as required, bounded by `deadline`. Result is
NB. (<status),(<buffer).
ws_fill=: 3 : 0
  conn=. > 0 { y
  need=. > 1 { y
  buffer=. > 2 { y
  deadline=. > 3 { y
  while. (# buffer) < need do.
    remaining=. tx_remaining deadline
    if. remaining = 0 do. (<WS_IO_TIMEOUT),(<buffer) return. end.
    'status payload'=. tx_recv (<conn),(<16384),(<remaining)
    if. status = TX_IO_TIMEOUT do. continue. end.
    if. status = TX_IO_EOF do. (<WS_IO_EOF),(<buffer) return. end.
    if. status ~: TX_IO_OK do. (<WS_IO_ERROR),(<buffer) return. end.
    buffer=. buffer , payload
  end.
  (<WS_IO_OK),(<buffer)
)

NB. Read and decode exactly one WebSocket frame (not a whole message --
NB. callers assemble fragments). y is (<conn),(<buffer),(<deadline). Result
NB. is (<status),(<buffer),(<fin),(<opcode),(<payload): buffer is whatever
NB. is left over after this frame for the next call, payload is a
NB. byte-value list.
ws_read_frame=: 3 : 0
  conn=. > 0 { y
  buffer=. > 1 { y
  deadline=. > 2 { y

  'fstatus buffer'=. ws_fill (<conn),(<2),(<buffer),(<deadline)
  if. fstatus ~: WS_IO_OK do. (<fstatus),(<buffer),(<0),(<0),(<'') return. end.
  b0=. 0 { buffer
  b1=. 1 { buffer
  NB. `b.` bitwise codes need genuine 0/1 arrays (confirmed by testing --
  NB. applying them to a raw byte value is a domain error), so single-byte
  NB. bit-field extraction here is plain arithmetic instead: the FIN and
  NB. MASK bits are each the top bit of their byte (weight 128), and opcode
  NB. / the 7-bit length are simply the low bits via modulo.
  fin=. b0 >: 128
  opcode=. 16 | b0
  masked=. b1 >: 128
  len7=. 128 | b1
  if. masked do.
    (<WS_IO_PROTOCOL),(<buffer),(<0),(<0),(<'') return.
  end.

  hdr=. 2
  if. len7 = 126 do.
    'fstatus buffer'=. ws_fill (<conn),(<4),(<buffer),(<deadline)
    if. fstatus ~: WS_IO_OK do. (<fstatus),(<buffer),(<0),(<0),(<'') return. end.
    len=. tx_unbe 2 {. 2 }. buffer
    hdr=. 4
  elseif. len7 = 127 do.
    'fstatus buffer'=. ws_fill (<conn),(<10),(<buffer),(<deadline)
    if. fstatus ~: WS_IO_OK do. (<fstatus),(<buffer),(<0),(<0),(<'') return. end.
    len=. tx_unbe 8 {. 2 }. buffer
    hdr=. 10
  else.
    len=. len7
  end.

  if. len > 134217728 do. NB. 128 MiB adapter ceiling, refused well before the read
    (<WS_IO_PROTOCOL),(<buffer),(<0),(<0),(<'') return.
  end.

  'fstatus buffer'=. ws_fill (<conn),(<(hdr + len)),(<buffer),(<deadline)
  if. fstatus ~: WS_IO_OK do. (<fstatus),(<buffer),(<0),(<0),(<'') return. end.
  payload=. len {. hdr }. buffer
  buffer=. (hdr + len) }. buffer
  (<WS_IO_OK),(<buffer),(<fin),(<opcode),(<payload)
)

NB. Strict UTF-8 validation of a reassembled text message (a byte-value
NB. list). `9 u:` already rejects overlong, truncated, and out-of-range
NB. sequences; it does not reject an encoded surrogate half (technically
NB. CESU-8, not UTF-8), so that range is checked separately -- the same gap
NB. json.ijs documents for \u escape decoding.
ws_utf8_valid=: 3 : 0
  bytes=. a. {~ y
  ok=. 1
  cps=. 0
  try.
    decoded=. 9 u: bytes
    cps=. 3 u: decoded
  catch.
    ok=. 0
  end.
  if. -. ok do. 0 return. end.
  if. 0 = # cps do. 1 return. end.
  0 = +/ (cps >: 55296) *. cps <: 57343
)
