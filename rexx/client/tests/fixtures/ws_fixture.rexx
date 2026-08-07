/* Loopback WebSocket/sync-protocol fixture for client/tests/live_test.rexx.
 *
 * Speaks just enough of the pinned sync profile, as a real TCP+WS peer, to
 * drive convex.rexx's Live state machine through a real handshake, an
 * initial value, an external update, an unsubscribe, and a debugDisconnect
 * -> reconnect -> fresh-value cycle. This is test-only infrastructure: it
 * duplicates convex.rexx's RXFUNCADD registration (a separate process
 * needs its own) and hand-encodes just enough JSON/WebSocket framing to
 * act as a peer, but it holds no Convex client logic of its own.
 */
call rxfuncadd 'RXLISTEN', 'convexshim', 'RXLISTEN'
call rxfuncadd 'RXACCEPT', 'convexshim', 'RXACCEPT'
call rxfuncadd 'RXSEND', 'convexshim', 'RXSEND'
call rxfuncadd 'RXRECV', 'convexshim', 'RXRECV'
call rxfuncadd 'RXCLOSE', 'convexshim', 'RXCLOSE'
call rxfuncadd 'RXRANDBYTES', 'convexshim', 'RXRANDBYTES'

parse arg port

listenResult = RXLISTEN('127.0.0.1', port)
if left(listenResult, 1) <> 'K' then do
  call lineout 'stderr', 'ws_fixture: listen failed:' substr(listenResult, 3)
  exit 1
end
listenHandle = substr(listenResult, 3)
call lineout 'stdout', 'READY'
call stream 'stdout', 'c', 'flush'

/* --- connection 1: handshake, Add, initial value, external update, Remove --- */
handle = accept_and_handshake(listenHandle)
if handle == '' then exit 1

queryId0 = read_modify_query_set_add(handle)
call send_transition handle, 0, 0, 'AAAAAAAAAAA=', 1, 0, timestamp_for(1), ,
  '[{"type":"QueryUpdated","queryId":' || queryId0 || ',"value":{"room":"fixture-room","count":0,"lastLanguage":null,"latestRunId":null,"updatedAt":null},"logLines":[]}]'

/* External update: as if another client incremented the room. */
call send_transition handle, 1, 0, timestamp_for(1), 2, 0, timestamp_for(2), ,
  '[{"type":"QueryUpdated","queryId":' || queryId0 || ',"value":{"room":"fixture-room","count":1,"lastLanguage":"rexx","latestRunId":"r1","updatedAt":1},"logLines":[]}]'

/* Expect a Remove (unsubscribe) next; drop the connection right after,
 * which the driver observes as the debugDisconnect-equivalent trigger for
 * the reconnect phase below (a real debugDisconnect closes from the
 * client side, so from this fixture's point of view both look the same:
 * the accepted socket goes away). */
call read_one_message handle
call RXCLOSE handle

/* --- connection 2: proves reconnect resends Add, surfaces a QueryFailed,
 * and then recovers with a fresh value (query-error-recovery), all in one
 * scripted connection so the fixture stays a single small file. --- */
handle2 = accept_and_handshake(listenHandle)
if handle2 == '' then exit 1
queryId1 = read_modify_query_set_add(handle2)
call send_transition handle2, 0, 0, 'AAAAAAAAAAA=', 1, 0, timestamp_for(3), ,
  '[{"type":"QueryFailed","queryId":' || queryId1 || ,
  ',"errorMessage":"Increment the room to repair this reactive query","errorData":{"code":"ROOM_EMPTY"},"logLines":[]}]'
call send_transition handle2, 1, 0, timestamp_for(3), 2, 0, timestamp_for(4), ,
  '[{"type":"QueryUpdated","queryId":' || queryId1 || ',"value":{"room":"fixture-room","count":2,"lastLanguage":"rexx","latestRunId":"r2","updatedAt":2},"logLines":[]}]'

call read_one_message handle2
call RXCLOSE handle2
call RXCLOSE listenHandle
exit 0

/* ---------------- helpers ---------------- */

accept_and_handshake: procedure
  parse arg listenHandle
  acceptResult = RXACCEPT(listenHandle, 15000)
  if left(acceptResult, 1) <> 'K' then do
    call lineout 'stderr', 'ws_fixture: accept failed:' substr(acceptResult, 3)
    return ''
  end
  handle = substr(acceptResult, 3)

  buf = ''
  do while pos('0d0a0d0a'x, buf) == 0
    chunk = RXRECV(handle, 65536, 5000)
    if left(chunk, 1) == 'D' then buf = buf || substr(chunk, 3)
    else do
      call lineout 'stderr', 'ws_fixture: handshake request incomplete'
      return ''
    end
  end
  parse var buf headerText '0d0a0d0a'x .
  key = ''
  do while headerText <> ''
    parse var headerText headerLine '0d0a'x headerText
    parse var headerLine hname ':' hvalue
    if translate(strip(hname)) == 'SEC-WEBSOCKET-KEY' then key = strip(hvalue)
  end

  accept = ws_accept_value(key)
  response = 'HTTP/1.1 101 Switching Protocols' || '0d0a'x || 'Upgrade: websocket' || '0d0a'x || ,
    'Connection: Upgrade' || '0d0a'x || 'Sec-WebSocket-Accept:' accept || '0d0a'x || '0d0a'x
  call RXSEND handle, response
  return handle

/* Reads one WebSocket text frame (assumed to arrive whole, which is true
 * for the small Connect/ModifyQuerySet messages this fixture expects) and
 * returns its decoded payload. */
read_one_message: procedure
  parse arg handle
  buf = ''
  do forever
    chunk = RXRECV(handle, 65536, 5000)
    if left(chunk, 1) == 'D' then buf = buf || substr(chunk, 3)
    else return ''
    parsed = ws_try_parse(buf)
    parse var parsed status '0b'x payload
    if status == 'FRAME' then return payload
  end

/* Reads messages until a ModifyQuerySet with an Add is seen, and returns
 * its queryId. The very first message on a connection is always Connect,
 * which this simply discards. */
read_modify_query_set_add: procedure
  parse arg handle
  do forever
    payload = read_one_message(handle)
    if pos('"ModifyQuerySet"', payload) > 0 & pos('"Add"', payload) > 0 then do
      parse var payload . '"queryId":' queryIdPart
      parse var queryIdPart queryId ',' .
      return queryId
    end
  end

ws_try_parse: procedure
  n = length(arg(1))
  buf = arg(1)
  if n < 2 then return 'INCOMPLETE' || '0b'x || ''
  b1 = c2d(substr(buf, 2, 1))
  masked = (b1 % 128) == 1
  len7 = b1 // 128
  headerLen = 2
  payloadLen = len7
  if len7 == 126 then do
    if n < 4 then return 'INCOMPLETE' || '0b'x || ''
    payloadLen = (c2d(substr(buf,3,1)) * 256) + c2d(substr(buf,4,1))
    headerLen = 4
  end
  maskLen = 0
  if masked then maskLen = 4
  totalLen = headerLen + maskLen + payloadLen
  if n < totalLen then return 'INCOMPLETE' || '0b'x || ''
  payload = substr(buf, headerLen + maskLen + 1, payloadLen)
  if masked then do
    maskKey = substr(buf, headerLen + 1, 4)
    payload = unmask(payload, maskKey)
  end
  return 'FRAME' || '0b'x || payload

unmask: procedure
  parse arg payload, maskKey
  n = length(payload)
  if n == 0 then return ''
  repeated = left(copies(maskKey, (n % 4) + 2), n)
  return bitxor(payload, repeated)

send_transition: procedure
  parse arg handle, startQuerySet, startIdentity, startTs, endQuerySet, endIdentity, endTs, modifications
  msg = '{"type":"Transition","startVersion":{"querySet":' || startQuerySet || ,
    ',"identity":' || startIdentity || ',"ts":"' || startTs || '"},"endVersion":{"querySet":' || ,
    endQuerySet || ',"identity":' || endIdentity || ',"ts":"' || endTs || '"},"modifications":' || ,
    modifications || '}'
  call RXSEND handle, ws_build_server_frame(msg)
  return

/* Server-to-client frames must NOT be masked (RFC 6455). */
ws_build_server_frame: procedure
  parse arg payload
  len = length(payload)
  first = d2c(129) /* FIN=1, opcode=1 (text) */
  if len <= 125 then lenField = d2c(len)
  else do
    hi = len % 256
    lo = len // 256
    lenField = d2c(126) || d2c(hi) || d2c(lo)
  end
  return first || lenField || payload

/* A distinct, monotonically increasing 8-byte little-endian-on-the-wire
 * timestamp per logical step, base64 encoded, matching the pinned
 * profile's opaque ts representation. */
timestamp_for: procedure
  parse arg step
  bytes = d2c(step) || '00'x || '00'x || '00'x || '00'x || '00'x || '00'x || '00'x
  return b64encode(bytes)

b64encode: procedure
  parse arg raw
  alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  n = length(raw)
  out = ''
  i = 1
  do while i <= n
    chunk = substr(raw, i, 3)
    chunkLen = min(3, n - i + 1)
    b0 = c2d(substr(chunk, 1, 1))
    b1 = 0
    b2 = 0
    if chunkLen >= 2 then b1 = c2d(substr(chunk, 2, 1))
    if chunkLen >= 3 then b2 = c2d(substr(chunk, 3, 1))
    c0 = b0 % 4
    c1 = ((b0 // 4) * 16) + (b1 % 16)
    c2 = ((b1 // 16) * 4) + (b2 % 64)
    c3 = b2 // 64
    out = out || substr(alphabet, c0 + 1, 1) || substr(alphabet, c1 + 1, 1)
    if chunkLen >= 2 then out = out || substr(alphabet, c2 + 1, 1)
    else out = out || '='
    if chunkLen >= 3 then out = out || substr(alphabet, c3 + 1, 1)
    else out = out || '='
    i = i + 3
  end
  return out

ws_accept_value: procedure
  parse arg key
  return b64encode(x2c(sha1hex(key || '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))

/* ---- sha1, duplicated from convex.rexx: a separate OS process cannot
 * reach convex.rexx's internal (non-dispatched) routines, and this
 * fixture must compute a real Sec-WebSocket-Accept to complete a genuine
 * RFC 6455 handshake with the client under test. ---- */
sha1_mod32: procedure
  numeric digits 20
  parse arg v
  m = 4294967296
  r = v // m
  if r < 0 then r = r + m
  return r

sha1_rotl: procedure
  numeric digits 20
  parse arg v, bits
  v = sha1_mod32(v)
  left = sha1_mod32(v * (2 ** bits))
  right = v % (2 ** (32 - bits))
  return sha1_mod32(left + right)

sha1_word_to_bytes: procedure
  numeric digits 20
  parse arg v
  v = sha1_mod32(v)
  b0 = v % 16777216
  r0 = v // 16777216
  b1 = r0 % 65536
  r1 = r0 // 65536
  b2 = r1 % 256
  b3 = r1 // 256
  return d2c(b0) || d2c(b1) || d2c(b2) || d2c(b3)

sha1_bytes_to_word: procedure
  numeric digits 20
  parse arg bytes
  return (c2d(substr(bytes,1,1)) * 16777216) + (c2d(substr(bytes,2,1)) * 65536) + ,
         (c2d(substr(bytes,3,1)) * 256) + c2d(substr(bytes,4,1))

sha1_and: procedure
  numeric digits 20
  parse arg a, b
  return sha1_bytes_to_word(bitand(sha1_word_to_bytes(a), sha1_word_to_bytes(b)))

sha1_or: procedure
  numeric digits 20
  parse arg a, b
  return sha1_bytes_to_word(bitor(sha1_word_to_bytes(a), sha1_word_to_bytes(b)))

sha1_xor: procedure
  numeric digits 20
  parse arg a, b
  return sha1_bytes_to_word(bitxor(sha1_word_to_bytes(a), sha1_word_to_bytes(b)))

sha1_not: procedure
  numeric digits 20
  parse arg a
  return sha1_mod32(4294967295 - sha1_mod32(a))

sha1hex: procedure
  numeric digits 20
  parse arg message
  h0 = 1732584193
  h1 = 4023233417
  h2 = 2562383102
  h3 = 271733878
  h4 = 3285377520

  msgLen = length(message)
  bitLen = msgLen * 8
  padded = message || '80'x
  do while (length(padded) // 64) <> 56
    padded = padded || '00'x
  end
  hi = bitLen % 4294967296
  lo = bitLen // 4294967296
  padded = padded || sha1_word_to_bytes(hi) || sha1_word_to_bytes(lo)

  blocks = length(padded) % 64
  blockIndex = 1
  do while blockIndex <= blocks
    block = substr(padded, (blockIndex - 1) * 64 + 1, 64)
    do w = 0 to 15
      wArr.w = sha1_bytes_to_word(substr(block, w * 4 + 1, 4))
    end
    do w = 16 to 79
      i3 = w - 3
      i8 = w - 8
      i14 = w - 14
      i16 = w - 16
      v = sha1_xor(sha1_xor(wArr.i3, wArr.i8), sha1_xor(wArr.i14, wArr.i16))
      wArr.w = sha1_rotl(v, 1)
    end

    a = h0
    b = h1
    c = h2
    d = h3
    e = h4
    do t = 0 to 79
      select
        when t <= 19 then do
          f = sha1_or(sha1_and(b, c), sha1_and(sha1_not(b), d))
          k = 1518500249
        end
        when t <= 39 then do
          f = sha1_xor(sha1_xor(b, c), d)
          k = 1859775393
        end
        when t <= 59 then do
          f = sha1_or(sha1_or(sha1_and(b, c), sha1_and(b, d)), sha1_and(c, d))
          k = 2400959708
        end
        otherwise do
          f = sha1_xor(sha1_xor(b, c), d)
          k = 3395469782
        end
      end
      temp = sha1_mod32(sha1_rotl(a, 5) + f + e + k + wArr.t)
      e = d
      d = c
      c = sha1_rotl(b, 30)
      b = a
      a = temp
    end

    h0 = sha1_mod32(h0 + a)
    h1 = sha1_mod32(h1 + b)
    h2 = sha1_mod32(h2 + c)
    h3 = sha1_mod32(h3 + d)
    h4 = sha1_mod32(h4 + e)
    blockIndex = blockIndex + 1
  end

  return translate(right(d2x(h0), 8, '0') || right(d2x(h1), 8, '0') || right(d2x(h2), 8, '0') || ,
         right(d2x(h3), 8, '0') || right(d2x(h4), 8, '0'), 'abcdef', 'ABCDEF')
