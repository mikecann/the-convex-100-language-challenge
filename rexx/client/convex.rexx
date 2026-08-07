/* Native Convex client for Regina Rexx.
 *
 * Regina Rexx has no built-in sockets, TLS, JSON, or WebSocket support, so
 * this file implements all of Convex's HTTP and Live (WebSocket) behaviour
 * itself: request construction, response classification, JSON encoding and
 * decoding, RFC 6455 framing and masking, the SHA-1/base64 handshake
 * computation, and the sync protocol's Connect/ModifyQuerySet/Transition
 * state machine with reconnect and dedup. The only things delegated outside
 * Rexx are raw byte transport and TLS itself, via the small C shim in
 * shim.c (client/shim.c, compiled to libconvexshim.so and loaded here with
 * RXFUNCADD) -- the same officially supported mechanism Regina's own
 * built-in packages (regutil, rxmath, ...) use to reach the C library.
 *
 * Classic Rexx has no module/import system: an external file loaded with
 * CALL runs from its first line every time, with no memory of previous
 * invocations. This file is therefore structured as a small dispatcher
 * (immediately below) that jumps to an internal label per operation, and
 * every "connection" it manages is represented as a plain value the caller
 * holds and passes back in on the next call:
 *
 *   - HTTP has no session, so a single CALL does the whole request.
 *   - Live is a reducer: the caller holds a JSON "state" string across many
 *     separate CALLs (one per subscribe/unsubscribe/poll/debugDisconnect),
 *     gets an updated state and a list of newly observed events back each
 *     time, and stores the new state for its next call. All actual socket
 *     state (the open connection) lives behind a small integer handle
 *     inside the C shim, so the Rexx-side state blob only ever holds
 *     plain strings and numbers.
 *
 * client/tests/ exercises every routine below directly (by CALLing this
 * same file exactly as the adapter and example do); client/tests/conformance
 * implements the shared NDJSON adapter protocol on top of it.
 */

/* PROCEDURE (used by every operation below, so each one gets its own clean
 * variable scope) is only legal immediately after a genuine CALL or
 * function invocation, not after SIGNAL's GOTO-style jump -- and Regina
 * has no indirect "CALL (expression)" form -- so dispatch is a plain
 * SELECT of literal CALLs rather than a computed jump. Each call forwards
 * every positional argument the operation could possibly use; unused
 * trailing ones are simply empty. */
parse arg __op
call ensure_shim
select
  when __op == 'http_call' then call http_call __op, arg(2), arg(3), arg(4), arg(5), arg(6)
  when __op == 'live_add' then call live_add __op, arg(2), arg(3), arg(4), arg(5), arg(6)
  when __op == 'live_remove' then call live_remove __op, arg(2), arg(3)
  when __op == 'live_poll' then call live_poll __op, arg(2), arg(3)
  when __op == 'live_debug_disconnect' then call live_debug_disconnect __op, arg(2)
  when __op == 'live_close' then call live_close __op, arg(2)
  when __op == 'selftest' then call selftest
  otherwise do
    call lineout 'stderr', 'convex.rexx: unknown operation' __op
    exit 1
  end
end
exit result

/* ================================================================
 * Shim loading
 * ================================================================ */

ensure_shim: procedure
  call rxfuncadd 'RXCONNECT', 'convexshim', 'RXCONNECT'
  call rxfuncadd 'RXLISTEN', 'convexshim', 'RXLISTEN'
  call rxfuncadd 'RXACCEPT', 'convexshim', 'RXACCEPT'
  call rxfuncadd 'RXSEND', 'convexshim', 'RXSEND'
  call rxfuncadd 'RXRECV', 'convexshim', 'RXRECV'
  call rxfuncadd 'RXCLOSE', 'convexshim', 'RXCLOSE'
  call rxfuncadd 'RXRANDBYTES', 'convexshim', 'RXRANDBYTES'
  return

/* ================================================================
 * HTTP: query / mutation / action
 *
 * arg(2) = "query" | "mutation" | "action"
 * arg(3) = function path, e.g. "demo:state"
 * arg(4) = args, as a JSON object text (already encoded by the caller)
 * arg(5) = base Convex URL, e.g. "https://foo.convex.cloud"
 * arg(6) = bearer token, or "" for none
 *
 * Returns one JSON envelope:
 *   {"type":"result","value":<json>,"logs":[...]}
 *   {"type":"error","error":{"name":...,"message":...,"data":<json>?},"logs":[...]?}
 * "logs" and "error.data" are omitted (not sent as empty/null) when the
 * server did not provide them, matching the adapter protocol's own
 * "never invent an absent field" rule.
 * ================================================================ */

http_call: procedure
  numeric digits 20
  httpOp = arg(2)
  path = arg(3)
  argsJson = arg(4)
  baseUrl = arg(5)
  token = arg(6)

  parse var baseUrl scheme '://' hostport '/'
  useTls = 0
  if translate(scheme) == 'HTTPS' then useTls = 1
  if pos(':', hostport) > 0 then parse var hostport host ':' port
  else do
    host = hostport
    if useTls then port = '443'
    else port = '80'
  end

  body = '{"path":' || json_estr(path) || ',"args":' || argsJson || ',"format":"json"}'

  requestLine = 'POST /api/' || httpOp || ' HTTP/1.1' || '0d0a'x
  headers = 'Host:' host || '0d0a'x
  headers = headers || 'Content-Type: application/json' || '0d0a'x
  headers = headers || 'Accept: application/json' || '0d0a'x
  headers = headers || 'Convex-Client: rexx-0.1.0' || '0d0a'x
  if token <> '' then headers = headers || 'Authorization: Bearer' token || '0d0a'x
  headers = headers || 'Content-Length:' length(body) || '0d0a'x
  headers = headers || 'Connection: close' || '0d0a'x

  request = requestLine || headers || '0d0a'x || body

  connectResult = RXCONNECT(host, port, useTls)
  tag = left(connectResult, 1)
  if tag <> 'K' then return json_transport_error('connect failed:' substr(connectResult, 3))
  handle = substr(connectResult, 3)

  sendResult = http_send_all(handle, request)
  if left(sendResult, 1) <> 'K' then do
    call RXCLOSE handle
    return json_transport_error('send failed:' substr(sendResult, 3))
  end

  response = http_read_response(handle)
  call RXCLOSE handle
  if left(response, 1) == 'E' then return json_transport_error(substr(response, 2))

  parse var response statusCode '0a'x rawBody
  return http_classify(statusCode, rawBody)

/* Sends the whole request, looping over short writes. */
http_send_all: procedure
  parse arg handle, data
  total = length(data)
  sent = 0
  do while sent < total
    chunk = substr(data, sent + 1)
    result = RXSEND(handle, chunk)
    if left(result, 1) <> 'K' then return result
    n = substr(result, 3) + 0
    if n <= 0 then return 'E:send made no progress'
    sent = sent + n
  end
  return 'K:' || sent

/* Reads the full HTTP response (headers + body), honouring
 * Content-Length or a close-terminated body, with a bounded read budget.
 * Returns "<statusCode>\n<body>" or "E:<message>". */
http_read_response: procedure
  numeric digits 20
  parse arg handle
  maximumBytes = 8388608
  deadline = time('E') + 15
  buf = ''
  headerEnd = 0
  do while headerEnd == 0
    if time('E') > deadline then return 'E:timed out reading response headers'
    chunk = RXRECV(handle, 65536, 5000)
    ctag = left(chunk, 1)
    select
      when ctag == 'D' then buf = buf || substr(chunk, 3)
      when ctag == 'T' then nop: nop = 1
      when ctag == 'C' then leave
      otherwise return 'E:' || substr(chunk, 3)
    end
    headerEnd = pos('0d0a0d0a'x, buf)
    if length(buf) > maximumBytes then return 'E:response headers exceeded budget'
  end
  if headerEnd == 0 then return 'E:connection closed before headers completed'

  headerText = substr(buf, 1, headerEnd - 1)
  bodySoFar = substr(buf, headerEnd + 4)

  parse var headerText statusLine '0d0a'x restHeaders
  parse var statusLine 'HTTP/' . statusCode .

  contentLength = -1
  chunked = 0
  do while restHeaders <> ''
    parse var restHeaders headerLine '0d0a'x restHeaders
    parse var headerLine hname ':' hvalue
    hname = translate(strip(hname))
    hvalue = strip(hvalue)
    if hname == 'CONTENT-LENGTH' then contentLength = hvalue + 0
    if hname == 'TRANSFER-ENCODING' & translate(hvalue) == 'CHUNKED' then chunked = 1
  end

  if chunked then do
    decoded = http_dechunk(handle, bodySoFar, deadline)
    if left(decoded, 1) == 'E' then return decoded
    return statusCode || '0a'x || substr(decoded, 3)
  end

  if contentLength >= 0 then do
    do while length(bodySoFar) < contentLength
      if time('E') > deadline then return 'E:timed out reading response body'
      chunk = RXRECV(handle, 65536, 5000)
      ctag = left(chunk, 1)
      select
        when ctag == 'D' then bodySoFar = bodySoFar || substr(chunk, 3)
        when ctag == 'T' then nop2: nop2 = 1
        when ctag == 'C' then leave
        otherwise return 'E:' || substr(chunk, 3)
      end
      if length(bodySoFar) > maximumBytes then return 'E:response body exceeded budget'
    end
    return statusCode || '0a'x || substr(bodySoFar, 1, contentLength)
  end

  /* No Content-Length and not chunked: read until the peer closes. */
  do forever
    if time('E') > deadline then return 'E:timed out reading response body'
    chunk = RXRECV(handle, 65536, 5000)
    ctag = left(chunk, 1)
    select
      when ctag == 'D' then bodySoFar = bodySoFar || substr(chunk, 3)
      when ctag == 'T' then nop3: nop3 = 1
      when ctag == 'C' then leave
      otherwise return 'E:' || substr(chunk, 3)
    end
    if length(bodySoFar) > maximumBytes then return 'E:response body exceeded budget'
  end
  return statusCode || '0a'x || bodySoFar

http_dechunk: procedure
  numeric digits 20
  parse arg handle, buf, deadline
  out = ''
  do forever
    lineEnd = pos('0d0a'x, buf)
    do while lineEnd == 0
      if time('E') > deadline then return 'E:timed out reading chunk size'
      chunk = RXRECV(handle, 65536, 5000)
      if left(chunk, 1) == 'D' then buf = buf || substr(chunk, 3)
      else if left(chunk, 1) <> 'T' then return 'E:connection closed mid chunk'
      lineEnd = pos('0d0a'x, buf)
    end
    sizeLine = substr(buf, 1, lineEnd - 1)
    parse var sizeLine sizeHex ';' .
    buf = substr(buf, lineEnd + 2)
    size = x2d(strip(sizeHex))
    do while length(buf) < size + 2
      if time('E') > deadline then return 'E:timed out reading chunk body'
      chunk = RXRECV(handle, 65536, 5000)
      if left(chunk, 1) == 'D' then buf = buf || substr(chunk, 3)
      else if left(chunk, 1) <> 'T' then return 'E:connection closed mid chunk body'
    end
    if size == 0 then return 'K:' || out
    out = out || substr(buf, 1, size)
    buf = substr(buf, size + 3)
  end

/* Classifies a raw HTTP status + body into the adapter-style JSON envelope,
 * following the documented "format":"json" contract: 200 with
 * status:"success" is a result; 200 with status:"error", or HTTP 560
 * (Convex's function-threw status), is a structured FunctionError; other
 * 5xx/408/429 are retryable TransportErrors; everything else is a
 * ProtocolError. */
http_classify: procedure
  numeric digits 20
  parse arg statusCode, rawBody
  code = statusCode + 0

  if code == 200 | code == 560 then do
    parse value json_value_span(rawBody, 1) with topType topStart topEnd
    if topType <> 'object' then return json_protocol_error('HTTP response body was not a JSON object')
    parse value json_object_get(rawBody, topStart, topEnd, 'status') with foundStatus sStart sEnd
    if foundStatus == 'NOTFOUND' then return json_protocol_error('HTTP response omitted status')
    status = json_decode_string(rawBody, sStart, sEnd)

    if status == 'success' & code == 200 then do
      parse value json_object_get(rawBody, topStart, topEnd, 'value') with foundValue vStart vEnd
      if foundValue == 'NOTFOUND' then return json_protocol_error('HTTP success response omitted value')
      valueJson = substr(rawBody, vStart, vEnd - vStart)
      logsJson = http_extract_logs(rawBody, topStart, topEnd)
      out = '{"type":"result","value":' || valueJson
      if logsJson <> '' then out = out || ',"logs":' || logsJson
      return out || '}'
    end

    if status == 'error' | code == 560 then do
      message = 'Convex function failed'
      parse value json_object_get(rawBody, topStart, topEnd, 'errorMessage') with foundMsg mStart mEnd
      if foundMsg == 'FOUND' then message = json_decode_string(rawBody, mStart, mEnd)
      else do
        parse value json_object_get(rawBody, topStart, topEnd, 'message') with foundMsg2 mStart2 mEnd2
        if foundMsg2 == 'FOUND' then message = json_decode_string(rawBody, mStart2, mEnd2)
      end
      dataJson = ''
      parse value json_object_get(rawBody, topStart, topEnd, 'errorData') with foundData dStart dEnd
      if foundData == 'FOUND' then dataJson = substr(rawBody, dStart, dEnd - dStart)
      logsJson = http_extract_logs(rawBody, topStart, topEnd)
      out = '{"type":"error","error":{"name":"FunctionError","message":' || json_estr(message)
      if dataJson <> '' then out = out || ',"data":' || dataJson
      out = out || '}'
      if logsJson <> '' then out = out || ',"logs":' || logsJson
      return out || '}'
    end

    return json_protocol_error('HTTP response had unknown status')
  end

  /* Non-200/560: {"code":"...","message":"..."} envelope, if present. */
  detail = 'no Convex error envelope'
  parse value json_value_span(rawBody, 1) with topType topStart topEnd
  if topType == 'object' then do
    parse value json_object_get(rawBody, topStart, topEnd, 'errorMessage') with foundA aStart aEnd
    if foundA == 'FOUND' then detail = json_decode_string(rawBody, aStart, aEnd)
    else do
      parse value json_object_get(rawBody, topStart, topEnd, 'message') with foundB bStart bEnd
      if foundB == 'FOUND' then detail = json_decode_string(rawBody, bStart, bEnd)
    end
  end
  message = 'HTTP' code 'from Convex:' detail

  if code == 500 | code == 502 | code == 503 | code == 504 | code == 408 | code == 429 then ,
    return json_transport_error(message)
  return json_protocol_error(message)

/* logLines is only ever emitted when non-empty, so a genuinely empty or
 * missing array both collapse to "" (nothing to attach). */
http_extract_logs: procedure
  numeric digits 20
  parse arg text, objStart, objEnd
  parse value json_object_get(text, objStart, objEnd, 'logLines') with found lStart lEnd
  if found == 'NOTFOUND' then return ''
  items = json_array_items(text, lStart, lEnd)
  if items == '' then return ''
  return substr(text, lStart, lEnd - lStart)

json_transport_error: procedure
  parse arg message
  return '{"type":"error","error":{"name":"TransportError","message":' || json_estr(message) || '}}'

json_protocol_error: procedure
  parse arg message
  return '{"type":"error","error":{"name":"ProtocolError","message":' || json_estr(message) || '}}'

/* ================================================================
 * Live: WebSocket transport, RFC 6455 framing, and the Convex sync
 * protocol state machine.
 * ================================================================ */

/* live_add(stateJson, wsUrl, subscriptionId, path, argsJson) -> stepResult
 * If stateJson is "" a fresh state is created and connected first. */
live_add: procedure
  numeric digits 20
  stateJson = arg(2)
  wsUrl = arg(3)
  subscriptionId = arg(4)
  path = arg(5)
  argsJson = arg(6)

  if stateJson == '' then stateJson = live_initial_state(wsUrl)
  events = ''

  if live_state_get(stateJson, 'connected') <> 'true' then do
    __pv = live_connect(stateJson)
    parse var __pv stateJson '0b'x connEvents
    events = events || connEvents
  end

  queryId = live_state_get(stateJson, 'nextQueryId')
  stateJson = live_state_set(stateJson, 'nextQueryId', queryId + 1)
  stateJson = live_subs_put(stateJson, subscriptionId, queryId, path, argsJson, '', 0)

  if live_state_get(stateJson, 'connected') == 'true' then do
    handle = live_state_get(stateJson, 'handle')
    modJson = '[{"type":"Add","queryId":' || queryId || ',"udfPath":' || json_estr(path) || ',"args":[' || argsJson || ']}]'
    stateJson = live_send_modify_query_set(stateJson, handle, modJson)
  end

  return live_pack(stateJson, events)

/* live_remove(stateJson, subscriptionId) -> stepResult */
live_remove: procedure
  numeric digits 20
  stateJson = arg(2)
  subscriptionId = arg(3)
  queryId = live_subs_query_id(stateJson, subscriptionId)
  stateJson = live_subs_delete(stateJson, subscriptionId)
  if queryId >= 0 & live_state_get(stateJson, 'connected') == 'true' then do
    handle = live_state_get(stateJson, 'handle')
    modJson = '[{"type":"Remove","queryId":' || queryId || '}]'
    stateJson = live_send_modify_query_set(stateJson, handle, modJson)
  end
  return live_pack(stateJson, '')

/* live_poll(stateJson, timeoutMs) -> stepResult
 * Reads whatever is available within the timeout, decodes complete
 * frames, applies Transition modifications, retries a due reconnect, and
 * replies to pings. Never blocks longer than timeoutMs. */
live_poll: procedure
  numeric digits 20
  stateJson = arg(2)
  timeoutMs = arg(3) + 0
  events = ''

  if live_state_get(stateJson, 'connected') <> 'true' then do
    __pv = live_maybe_reconnect(stateJson)
    parse var __pv stateJson '0b'x reconnectEvents
    events = events || reconnectEvents
    if live_state_get(stateJson, 'connected') <> 'true' then return live_pack(stateJson, events)
  end

  handle = live_state_get(stateJson, 'handle')
  recvResult = RXRECV(handle, 262144, timeoutMs)
  tag = left(recvResult, 1)
  select
    when tag == 'T' then nop: nop = 1 /* nothing arrived within the budget */
    when tag == 'D' then do
      stateJson = live_state_set(stateJson, 'recvBuffer', live_state_get(stateJson, 'recvBuffer') || substr(recvResult, 3))
      __pv = live_drain_frames(stateJson)
      parse var __pv stateJson '0b'x frameEvents
      events = events || frameEvents
    end
    otherwise do
      reason = 'TransportError:' substr(recvResult, 3)
      if tag == 'C' then reason = 'TransportError: peer closed'
      __pv = live_retire(stateJson, reason)
      parse var __pv stateJson '0b'x retireEvents
      events = events || retireEvents
    end
  end

  return live_pack(stateJson, events)

/* live_debug_disconnect(stateJson) -> stepResult
 * Adapter-only test hook. Retires the current connection and arms the
 * reconnect timer synchronously, so the caller can ack immediately after
 * this returns, satisfying the "ack only after retirement and reconnect
 * scheduling" ordering AGENTS.md requires. */
live_debug_disconnect: procedure
  numeric digits 20
  stateJson = arg(2)
  __pv = live_retire(stateJson, 'DebugDisconnect')
  parse var __pv stateJson '0b'x events
  return live_pack(stateJson, events)

/* live_close(stateJson) -> stepResult */
live_close: procedure
  numeric digits 20
  stateJson = arg(2)
  if live_state_get(stateJson, 'connected') == 'true' then do
    handle = live_state_get(stateJson, 'handle')
    call RXCLOSE handle
  end
  stateJson = live_state_set(stateJson, 'connected', 'false')
  stateJson = live_state_set(stateJson, 'handle', '-1')
  return live_pack(stateJson, '')

live_pack: procedure
  parse arg stateJson, events
  return stateJson || '0b'x || events

/* ---------------- state blob accessors ----------------
 * The state is a flat JSON object; these small helpers read and rewrite a
 * single top-level field at a time by string surgery, since every field
 * here is a plain scalar. */

live_initial_state: procedure
  parse arg wsUrl
  return '{"connected":false,"handle":"-1","url":' || json_estr(wsUrl) || ,
    ',"connectionCount":0,"lastCloseReason":"InitialConnect","maxObservedTimestamp":"",' || ,
    '"querySet":0,"remoteQuerySet":0,"remoteIdentity":0,"remoteTs":"AAAAAAAAAAA=",' || ,
    '"nextQueryId":0,"reconnectDelayMs":100,"reconnectAtMs":-1,"recvBuffer":"",' || ,
    '"partialFrameSinceMs":-1,"subs":{}}'

live_state_get: procedure
  numeric digits 20
  parse arg stateJson, field
  parse value json_value_span(stateJson, 1) with t s e
  parse value json_object_get(stateJson, s, e, field) with found fStart fEnd
  if found == 'NOTFOUND' then return ''
  return json_decode_scalar_or_string(stateJson, fStart, fEnd)

json_decode_scalar_or_string: procedure
  parse arg text, start, end
  c = substr(text, start, 1)
  if c == '"' then return json_decode_string(text, start, end)
  return json_decode_scalar(text, start, end)

/* Replaces one top-level field's value (rendered via json_field_literal)
 * with a fresh string/number/boolean/object literal. */
live_state_set: procedure
  numeric digits 20
  parse arg stateJson, field, rawValue
  parse value json_value_span(stateJson, 1) with t s e
  parse value json_object_get(stateJson, s, e, field) with found fStart fEnd
  literal = json_field_literal(rawValue)
  if found == 'NOTFOUND' then do
    /* Insert before the closing brace. */
    return substr(stateJson, 1, e - 2) || ',"' || field || '":' || literal || '}'
  end
  return substr(stateJson, 1, fStart - 1) || literal || substr(stateJson, fEnd)

/* Numbers and true/false pass straight through; anything else becomes a
 * quoted, escaped JSON string. Callers that need to store raw JSON (like
 * the subs object) go through live_state_set_raw instead. */
json_field_literal: procedure
  parse arg rawValue
  if rawValue == 'true' | rawValue == 'false' then return rawValue
  if datatype(rawValue, 'NUMBER') then return rawValue
  return json_estr(rawValue)

live_state_set_raw: procedure
  numeric digits 20
  parse arg stateJson, field, rawJson
  parse value json_value_span(stateJson, 1) with t s e
  parse value json_object_get(stateJson, s, e, field) with found fStart fEnd
  if found == 'NOTFOUND' then return substr(stateJson, 1, e - 2) || ',"' || field || '":' || rawJson || '}'
  return substr(stateJson, 1, fStart - 1) || rawJson || substr(stateJson, fEnd)

live_state_get_raw: procedure
  numeric digits 20
  parse arg stateJson, field
  parse value json_value_span(stateJson, 1) with t s e
  parse value json_object_get(stateJson, s, e, field) with found fStart fEnd
  if found == 'NOTFOUND' then return ''
  return substr(stateJson, fStart, fEnd - fStart)

/* ---------------- subscriptions map (stored as state.subs) ---------------- */

live_subs_put: procedure
  numeric digits 20
  parse arg stateJson, subscriptionId, queryId, path, argsJson, lastSignature, hasLast
  subsJson = live_state_get_raw(stateJson, 'subs')
  entry = '{"queryId":' || queryId || ',"path":' || json_estr(path) || ',"args":' || argsJson || ,
    ',"lastSignature":' || json_estr(lastSignature) || ',"hasLast":' || (hasLast <> 0) || '}'
  subsJson = json_object_put_raw(subsJson, subscriptionId, entry)
  return live_state_set_raw(stateJson, 'subs', subsJson)

live_subs_delete: procedure
  numeric digits 20
  parse arg stateJson, subscriptionId
  subsJson = live_state_get_raw(stateJson, 'subs')
  subsJson = json_object_delete(subsJson, subscriptionId)
  return live_state_set_raw(stateJson, 'subs', subsJson)

live_subs_query_id: procedure
  numeric digits 20
  parse arg stateJson, subscriptionId
  subsJson = live_state_get_raw(stateJson, 'subs')
  parse value json_value_span(subsJson, 1) with t s e
  parse value json_object_get(subsJson, s, e, subscriptionId) with found eStart eEnd
  if found == 'NOTFOUND' then return -1
  parse value json_value_span(subsJson, eStart) with et es ee
  parse value json_object_get(subsJson, es, ee, 'queryId') with foundQ qStart qEnd
  return json_decode_scalar(subsJson, qStart, qEnd) + 0

/* Finds the subscriptionId whose recorded queryId matches, or "" if none. */
live_subs_find_by_query_id: procedure
  numeric digits 20
  parse arg stateJson, queryId
  subsJson = live_state_get_raw(stateJson, 'subs')
  parse value json_value_span(subsJson, 1) with t s e
  i = s + 1
  do while i < e
    i = json_skip_ws(subsJson, i)
    c = substr(subsJson, i, 1)
    if c == '}' then leave
    keyEnd = json_skip_string(subsJson, i)
    thisKey = json_decode_string(subsJson, i, keyEnd)
    i = json_skip_ws(subsJson, keyEnd)
    i = i + 1
    parse value json_value_span(subsJson, i) with vtype vstart vend
    parse value json_object_get(subsJson, vstart, vend, 'queryId') with foundQ qStart qEnd
    thisQueryId = json_decode_scalar(subsJson, qStart, qEnd) + 0
    if thisQueryId == queryId then return thisKey
    i = json_skip_ws(subsJson, vend)
    if substr(subsJson, i, 1) == ',' then i = i + 1
  end
  return ''

live_subs_each_add_modification: procedure
  numeric digits 20
  parse arg stateJson
  subsJson = live_state_get_raw(stateJson, 'subs')
  parse value json_value_span(subsJson, 1) with t s e
  mods = ''
  i = s + 1
  do while i < e
    i = json_skip_ws(subsJson, i)
    c = substr(subsJson, i, 1)
    if c == '}' then leave
    keyEnd = json_skip_string(subsJson, i)
    i = json_skip_ws(subsJson, keyEnd)
    i = i + 1
    parse value json_value_span(subsJson, i) with vtype vstart vend
    parse value json_object_get(subsJson, vstart, vend, 'queryId') with foundQ qStart qEnd
    thisQueryId = json_decode_scalar(subsJson, qStart, qEnd)
    parse value json_object_get(subsJson, vstart, vend, 'path') with foundP pStart pEnd
    thisPath = json_decode_string(subsJson, pStart, pEnd)
    parse value json_object_get(subsJson, vstart, vend, 'args') with foundA aStart aEnd
    thisArgs = substr(subsJson, aStart, aEnd - aStart)
    if mods <> '' then mods = mods || ','
    mods = mods || '{"type":"Add","queryId":' || thisQueryId || ',"udfPath":' || json_estr(thisPath) || ',"args":[' || thisArgs || ']}'
    i = json_skip_ws(subsJson, vend)
    if substr(subsJson, i, 1) == ',' then i = i + 1
  end
  return '[' || mods || ']'

/* Small generic helpers for treating a JSON object as a string-keyed map
 * with entirely opaque (already-encoded) values. */
json_object_put_raw: procedure
  numeric digits 20
  parse arg objJson, key, rawValueJson
  if objJson == '' then objJson = '{}'
  parse value json_value_span(objJson, 1) with t s e
  parse value json_object_get(objJson, s, e, key) with found fStart fEnd
  if found == 'NOTFOUND' then do
    if e - s == 2 then return '{"' || key || '":' || rawValueJson || '}'
    return substr(objJson, 1, e - 2) || ',"' || key || '":' || rawValueJson || '}'
  end
  return substr(objJson, 1, fStart - 1) || rawValueJson || substr(objJson, fEnd)

json_object_delete: procedure
  numeric digits 20
  parse arg objJson, key
  parse value json_value_span(objJson, 1) with t s e
  i = s + 1
  do while i < e
    entryStart = i
    i = json_skip_ws(objJson, i)
    c = substr(objJson, i, 1)
    if c == '}' then leave
    keyEnd = json_skip_string(objJson, i)
    thisKey = json_decode_string(objJson, i, keyEnd)
    j = json_skip_ws(objJson, keyEnd)
    j = j + 1
    parse value json_value_span(objJson, j) with vtype vstart vend
    afterValue = json_skip_ws(objJson, vend)
    hasComma = substr(objJson, afterValue, 1) == ','
    entryEnd = vend
    if hasComma then entryEnd = afterValue + 1
    if thisKey == key then do
      before = substr(objJson, 1, entryStart - 1)
      after = substr(objJson, entryEnd)
      /* If we removed the entry right after '{' and there's a following
       * entry, the leading comma we left behind (there is none, since we
       * only ever add a leading comma before later entries) is fine; if we
       * removed the *last* entry and there's a preceding comma, strip it. */
      if right(strip(before, 'T'), 1) == ',' then do
        trimmedBefore = strip(before, 'T')
        before = substr(trimmedBefore, 1, length(trimmedBefore) - 1)
      end
      return before || after
    end
    i = entryEnd
  end
  return objJson

/* ---------------- connection lifecycle ---------------- */

/* live_connect(stateJson) -> "stateJson\x0bevents"
 * Opens a fresh TCP+TLS+WS connection, performs the handshake, sends
 * Connect, and (if there are already subscriptions from a previous
 * connection) resends Add for every one of them in a single
 * ModifyQuerySet, at querySet version 1. */
live_connect: procedure
  numeric digits 20
  stateJson = arg(1)
  wsUrl = live_state_get(stateJson, 'url')

  parse var wsUrl scheme '://' hostport '/' pathpart
  useTls = 0
  if translate(scheme) == 'WSS' then useTls = 1
  if pos(':', hostport) > 0 then parse var hostport host ':' port
  else do
    host = hostport
    if useTls then port = '443'
    else port = '80'
  end
  urlPath = '/' || pathpart
  if pathpart == '' then urlPath = '/api/sync'

  connectResult = RXCONNECT(host, port, useTls)
  if left(connectResult, 1) <> 'K' then do
    __pv = live_retire(stateJson, 'TransportError: connect failed')
    parse var __pv stateJson '0b'x events
    return stateJson || '0b'x || events
  end
  handle = substr(connectResult, 3)

  keyBytes = RXRANDBYTES(16)
  wsKey = b64encode(substr(keyBytes, 3))
  handshake = 'GET' urlPath 'HTTP/1.1' || '0d0a'x
  handshake = handshake || 'Host:' host || '0d0a'x
  handshake = handshake || 'Upgrade: websocket' || '0d0a'x
  handshake = handshake || 'Connection: Upgrade' || '0d0a'x
  handshake = handshake || 'Sec-WebSocket-Key:' wsKey || '0d0a'x
  handshake = handshake || 'Sec-WebSocket-Version: 13' || '0d0a'x
  handshake = handshake || 'Convex-Client: rexx-0.1.0' || '0d0a'x
  handshake = handshake || '0d0a'x

  sendResult = http_send_all(handle, handshake)
  if left(sendResult, 1) <> 'K' then do
    call RXCLOSE handle
    __pv = live_retire(stateJson, 'TransportError: handshake send failed')
    parse var __pv stateJson '0b'x events
    return stateJson || '0b'x || events
  end

  handshakeResponse = http_read_handshake(handle)
  if left(handshakeResponse, 1) <> 'K' then do
    call RXCLOSE handle
    __pv = live_retire(stateJson, 'ProtocolError: handshake failed')
    parse var __pv stateJson '0b'x events
    return stateJson || '0b'x || events
  end
  parse var handshakeResponse handshakeStatusTag '0b'x acceptValue '0b'x leftoverBytes

  expectedAccept = b64encode(sha1_hex_to_bytes(sha1hex(wsKey || '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))
  if acceptValue <> expectedAccept then do
    call RXCLOSE handle
    __pv = live_retire(stateJson, 'ProtocolError: Sec-WebSocket-Accept mismatch')
    parse var __pv stateJson '0b'x events
    return stateJson || '0b'x || events
  end

  stateJson = live_state_set(stateJson, 'connected', 'true')
  stateJson = live_state_set(stateJson, 'handle', handle)
  stateJson = live_state_set(stateJson, 'querySet', 0)
  stateJson = live_state_set(stateJson, 'remoteQuerySet', 0)
  stateJson = live_state_set(stateJson, 'remoteIdentity', 0)
  stateJson = live_state_set(stateJson, 'remoteTs', 'AAAAAAAAAAA=')
  stateJson = live_state_set(stateJson, 'recvBuffer', leftoverBytes)
  stateJson = live_state_set(stateJson, 'partialFrameSinceMs', -1)

  connectionCount = live_state_get(stateJson, 'connectionCount')
  lastCloseReason = live_state_get(stateJson, 'lastCloseReason')
  maxObservedTs = live_state_get(stateJson, 'maxObservedTimestamp')
  sessionId = left(translate(c2x(RXRANDBYTES(16))), 32)
  sessionId = substr(sessionId, 3)
  sessionId = translate(sessionId, xrange('a','z'), xrange('A','Z'))

  connectMsg = '{"type":"Connect","sessionId":' || json_estr(sessionId) || ,
    ',"connectionCount":' || connectionCount || ',"lastCloseReason":' || json_estr(lastCloseReason) || ,
    ',"clientTs":0'
  if maxObservedTs <> '' then connectMsg = connectMsg || ',"maxObservedTimestamp":' || json_estr(maxObservedTs)
  connectMsg = connectMsg || '}'

  frame = ws_build_frame(1, connectMsg)
  sendResult = http_send_all(handle, frame)
  if left(sendResult, 1) <> 'K' then do
    call RXCLOSE handle
    __pv = live_retire(stateJson, 'TransportError: send Connect failed')
    parse var __pv stateJson '0b'x events
    return stateJson || '0b'x || events
  end

  addMods = live_subs_each_add_modification(stateJson)
  if addMods <> '[]' then stateJson = live_send_modify_query_set(stateJson, handle, addMods)

  return stateJson || '0b'x

/* Sends a ModifyQuerySet at the next local version and advances it. */
live_send_modify_query_set: procedure
  numeric digits 20
  parse arg stateJson, handle, modificationsJson
  baseVersion = live_state_get(stateJson, 'querySet')
  newVersion = baseVersion + 1
  msg = '{"type":"ModifyQuerySet","baseVersion":' || baseVersion || ',"newVersion":' || newVersion || ,
    ',"modifications":' || modificationsJson || '}'
  frame = ws_build_frame(1, msg)
  call http_send_all handle, frame
  return live_state_set(stateJson, 'querySet', newVersion)

/* http_read_handshake -> "K:<statusline>\x0b<Sec-WebSocket-Accept>\x0b<leftoverBytes>"
 * The leftover bytes are whatever the peer sent immediately after the
 * handshake response, in the same TCP read, and belong to the first
 * WebSocket frame. */
http_read_handshake: procedure
  numeric digits 20
  parse arg handle
  deadline = time('E') + 10
  buf = ''
  headerEnd = 0
  do while headerEnd == 0
    if time('E') > deadline then return 'E:timed out reading handshake'
    chunk = RXRECV(handle, 65536, 5000)
    ctag = left(chunk, 1)
    select
      when ctag == 'D' then buf = buf || substr(chunk, 3)
      when ctag == 'T' then nop: nop = 1
      otherwise return 'E:' || substr(chunk, 3)
    end
    headerEnd = pos('0d0a0d0a'x, buf)
    if length(buf) > 32768 then return 'E:handshake headers exceeded budget'
  end
  headerText = substr(buf, 1, headerEnd - 1)
  leftover = substr(buf, headerEnd + 4)

  parse var headerText statusLine '0d0a'x restHeaders
  if pos('101', statusLine) == 0 then return 'E:handshake did not return 101'

  accept = ''
  do while restHeaders <> ''
    parse var restHeaders headerLine '0d0a'x restHeaders
    parse var headerLine hname ':' hvalue
    if translate(strip(hname)) == 'SEC-WEBSOCKET-ACCEPT' then accept = strip(hvalue)
  end
  if accept == '' then return 'E:handshake omitted Sec-WebSocket-Accept'

  return 'K:ok' || '0b'x || accept || '0b'x || leftover

/* live_maybe_reconnect(stateJson) -> "stateJson\x0bevents"
 * Reconnects only once the backoff deadline has actually elapsed, and only
 * when there is at least one active subscription (matching AGENTS.md: a
 * client with nothing subscribed stays disconnected until asked again). */
live_maybe_reconnect: procedure
  numeric digits 20
  stateJson = arg(1)
  reconnectAt = live_state_get(stateJson, 'reconnectAtMs') + 0
  if reconnectAt < 0 then return stateJson || '0b'x
  if live_now_ms() < reconnectAt then return stateJson || '0b'x

  subsJson = live_state_get_raw(stateJson, 'subs')
  if subsJson == '{}' | subsJson == '' then return stateJson || '0b'x

  return live_connect(stateJson)

/* TIME('E') is elapsed time since the current external program started,
 * which resets to zero on every separate CALL to this file -- useless for
 * timing something (like reconnect backoff) that spans many such calls.
 * TIME('L') is wall-clock time of day at microsecond resolution and does
 * not reset, so milliseconds since midnight makes a perfectly good
 * monotonic clock for a run that (like every conformance run and every
 * realistic use of this client) never straddles midnight. */
live_now_ms: procedure
  numeric digits 20
  parse value time('L') with hh ':' mm ':' ss '.' frac
  return ((hh * 3600 + mm * 60 + ss) * 1000) + trunc(frac / 1000)

/* live_retire(stateJson, reason) -> "stateJson\x0bevents"
 * Closes the socket if open, records the reason, bumps connectionCount,
 * and -- only if there is still at least one subscription -- arms the
 * exponential backoff for the next reconnect attempt. Every path that
 * loses the connection (transport error, protocol error, peer close,
 * DebugDisconnect, or a clean client close) funnels through here so
 * connectionCount/lastCloseReason/backoff stay consistent. */
live_retire: procedure
  numeric digits 20
  parse arg stateJson, reason

  if live_state_get(stateJson, 'connected') == 'true' then do
    handle = live_state_get(stateJson, 'handle')
    call RXCLOSE handle
  end

  connectionCount = live_state_get(stateJson, 'connectionCount') + 1
  stateJson = live_state_set(stateJson, 'connected', 'false')
  stateJson = live_state_set(stateJson, 'handle', '-1')
  stateJson = live_state_set(stateJson, 'lastCloseReason', reason)
  stateJson = live_state_set(stateJson, 'connectionCount', connectionCount)
  stateJson = live_state_set(stateJson, 'recvBuffer', '')
  stateJson = live_state_set(stateJson, 'partialFrameSinceMs', -1)

  events = ''
  subsJson = live_state_get_raw(stateJson, 'subs')
  if subsJson == '{}' | subsJson == '' then do
    stateJson = live_state_set(stateJson, 'reconnectAtMs', -1)
    return stateJson || '0b'x || events
  end

  if reason == 'client-closed' then do
    stateJson = live_state_set(stateJson, 'reconnectAtMs', -1)
    return stateJson || '0b'x || events
  end

  delay = live_state_get(stateJson, 'reconnectDelayMs') + 0
  stateJson = live_state_set(stateJson, 'reconnectAtMs', live_now_ms() + delay)
  nextDelay = delay * 2
  if nextDelay > 15000 then nextDelay = 15000
  stateJson = live_state_set(stateJson, 'reconnectDelayMs', nextDelay)

  if reason <> 'DebugDisconnect' then do
    errName = 'TransportError'
    if left(reason, 14) == 'ProtocolError:' then errName = 'ProtocolError'
    events = events || live_event_for_all_subs(stateJson, errName, reason)
  end

  return stateJson || '0b'x || events

/* Surfaces a TransportError/ProtocolError to every currently active
 * subscription (never for a clean client-close or a debugDisconnect,
 * which the caller already excludes), so a subscriber that only reads
 * events for its own id sees the connection loss rather than silence.
 * Does not touch each subscription's dedup signature, so a genuinely new
 * value after reconnect is still delivered even if it happens to match
 * whatever was last delivered before the failure. */
live_event_for_all_subs: procedure
  numeric digits 20
  parse arg stateJson, errName, reason
  subsJson = live_state_get_raw(stateJson, 'subs')
  parse value json_value_span(subsJson, 1) with t s e
  events = ''
  i = s + 1
  do while i < e
    i = json_skip_ws(subsJson, i)
    c = substr(subsJson, i, 1)
    if c == '}' then leave
    keyEnd = json_skip_string(subsJson, i)
    subscriptionId = json_decode_string(subsJson, i, keyEnd)
    i = json_skip_ws(subsJson, keyEnd)
    i = i + 1
    parse value json_value_span(subsJson, i) with vtype vstart vend
    events = events || '{"subscriptionId":' || json_estr(subscriptionId) || ,
      ',"type":"subscription","error":{"name":"' || errName || '","message":' || json_estr(reason) || '}}' || '0c'x
    i = json_skip_ws(subsJson, vend)
    if substr(subsJson, i, 1) == ',' then i = i + 1
  end
  return events

/* ---------------- frame draining and Transition handling ---------------- */

/* live_drain_frames(stateJson) -> "stateJson\x0bevents"
 * Consumes as many complete WebSocket frames as are already buffered,
 * applying each Transition/Ping as it completes. Leaves any trailing
 * partial frame bytes in state.recvBuffer for the next poll, tracking
 * how long that partial frame has been outstanding so a stalled peer can
 * be abandoned deterministically instead of hanging forever. */
live_drain_frames: procedure
  numeric digits 20
  stateJson = arg(1)
  events = ''
  do forever
    buf = live_state_get(stateJson, 'recvBuffer')
    parsed = ws_parse_frame(buf)
    parse var parsed status '0b'x rest
    if status == 'INCOMPLETE' then do
      if buf <> '' then do
        since = live_state_get(stateJson, 'partialFrameSinceMs') + 0
        if since < 0 then stateJson = live_state_set(stateJson, 'partialFrameSinceMs', live_now_ms())
        else if live_now_ms() - since > 5000 then do
          parsedRetire = live_retire(stateJson, 'ProtocolError: partial frame deadline exceeded')
          parse var parsedRetire stateJson '0b'x retireEvents
          events = events || retireEvents
        end
      end
      leave
    end
    stateJson = live_state_set(stateJson, 'partialFrameSinceMs', -1)
    parse var rest opcode '0b'x payloadLen '0b'x payload '0b'x remainder
    opcode = opcode + 0
    stateJson = live_state_set(stateJson, 'recvBuffer', remainder)

    select
      when opcode == 8 then do /* close */
        parsedRetire = live_retire(stateJson, 'TransportError: peer closed')
        parse var parsedRetire stateJson '0b'x retireEvents
        events = events || retireEvents
        leave
      end
      when opcode == 9 then do /* ping -> pong */
        handle = live_state_get(stateJson, 'handle')
        call http_send_all handle, ws_build_frame(10, payload)
      end
      when opcode == 10 then nop: nop = 1 /* pong, ignored */
      when opcode == 1 then do /* text: a sync protocol JSON message */
        parsedMsg = live_handle_message(stateJson, payload)
        parse var parsedMsg stateJson '0b'x msgEvents
        events = events || msgEvents
      end
      otherwise do
        parsedRetire = live_retire(stateJson, 'ProtocolError: unsupported frame opcode')
        parse var parsedRetire stateJson '0b'x retireEvents
        events = events || retireEvents
        leave
      end
    end
  end
  return stateJson || '0b'x || events

live_handle_message: procedure
  numeric digits 20
  parse arg stateJson, payload
  parse value json_value_span(payload, 1) with topType s e
  if topType <> 'object' then do
    return live_retire(stateJson, 'ProtocolError: Live message was not a JSON object')
  end
  parse value json_object_get(payload, s, e, 'type') with foundType tStart tEnd
  if foundType == 'NOTFOUND' then return live_retire(stateJson, 'ProtocolError: Live message omitted type')
  msgType = json_decode_string(payload, tStart, tEnd)

  select
    when msgType == 'Transition' then return live_apply_transition(stateJson, payload, s, e)
    when msgType == 'Ping' then return stateJson || '0b'x
    when msgType == 'MutationResponse' then return stateJson || '0b'x
    when msgType == 'ActionResponse' then return stateJson || '0b'x
    when msgType == 'TransitionChunk' then return live_retire(stateJson, 'ProtocolError: TransitionChunk is not implemented')
    when msgType == 'FatalError' then return live_retire(stateJson, 'ProtocolError: FatalError from server')
    when msgType == 'AuthError' then return live_retire(stateJson, 'ProtocolError: AuthError from server')
    otherwise return live_retire(stateJson, 'ProtocolError: unsupported Live message' msgType)
  end

live_apply_transition: procedure
  numeric digits 20
  parse arg stateJson, payload, s, e

  parse value json_object_get(payload, s, e, 'startVersion') with foundStart svStart svEnd
  parse value json_object_get(payload, s, e, 'endVersion') with foundEnd evStart evEnd
  if foundStart == 'NOTFOUND' | foundEnd == 'NOTFOUND' then ,
    return live_retire(stateJson, 'ProtocolError: Transition omitted a version')

  parse value json_object_get(payload, svStart, svEnd, 'querySet') with fA aS aE
  parse value json_object_get(payload, svStart, svEnd, 'identity') with fB bS bE
  parse value json_object_get(payload, svStart, svEnd, 'ts') with fC cS cE
  startQuerySet = json_decode_scalar(payload, aS, aE) + 0
  startIdentity = json_decode_scalar(payload, bS, bE) + 0
  startTs = json_decode_string(payload, cS, cE)

  expectedQuerySet = live_state_get(stateJson, 'remoteQuerySet') + 0
  expectedIdentity = live_state_get(stateJson, 'remoteIdentity') + 0
  expectedTs = live_state_get(stateJson, 'remoteTs')
  if startQuerySet <> expectedQuerySet | startIdentity <> expectedIdentity | startTs <> expectedTs then ,
    return live_retire(stateJson, 'ProtocolError: transition start version mismatch')

  parse value json_object_get(payload, evStart, evEnd, 'querySet') with fD dS dE
  parse value json_object_get(payload, evStart, evEnd, 'identity') with fF fS fE2
  parse value json_object_get(payload, evStart, evEnd, 'ts') with fG gS gE
  endQuerySet = json_decode_scalar(payload, dS, dE)
  endIdentity = json_decode_scalar(payload, fS, fE2)
  endTs = json_decode_string(payload, gS, gE)

  stateJson = live_state_set(stateJson, 'remoteQuerySet', endQuerySet)
  stateJson = live_state_set(stateJson, 'remoteIdentity', endIdentity)
  stateJson = live_state_set(stateJson, 'remoteTs', endTs)

  previousMax = live_state_get(stateJson, 'maxObservedTimestamp')
  if previousMax == '' | timestamp_key(endTs) > timestamp_key(previousMax) then ,
    stateJson = live_state_set(stateJson, 'maxObservedTimestamp', endTs)

  parse value json_object_get(payload, s, e, 'modifications') with foundMods msStart msEnd
  events = ''
  if foundMods == 'FOUND' then do
    items = json_array_items(payload, msStart, msEnd)
    /* Coalesce same-queryId modifications within this one Transition to
     * their newest value before emitting anything: track which query ids
     * were seen and only act on their final occurrence. */
    finalByQuery. = ''
    order = ''
    do i = 1 to words(items)
      token = word(items, i)
      parse var token itemStart ',' itemEnd
      parse value json_object_get(payload, itemStart, itemEnd, 'queryId') with fQ qS qE
      qid = json_decode_scalar(payload, qS, qE) + 0
      if finalByQuery.qid == '' then order = order qid
      finalByQuery.qid = itemStart',' itemEnd
    end
    do i = 1 to words(order)
      qid = word(order, i)
      parse var finalByQuery.qid itemStart ',' itemEnd
      __pv = live_apply_one_modification(stateJson, payload, itemStart, itemEnd)
      parse var __pv stateJson '0b'x oneEvent
      if oneEvent <> '' then events = events || oneEvent || '0c'x
    end
  end

  return stateJson || '0b'x || events

live_apply_one_modification: procedure
  numeric digits 20
  parse arg stateJson, payload, itemStart, itemEnd
  parse value json_object_get(payload, itemStart, itemEnd, 'type') with fT tS tE
  modType = json_decode_string(payload, tS, tE)
  parse value json_object_get(payload, itemStart, itemEnd, 'queryId') with fQ qS qE
  queryId = json_decode_scalar(payload, qS, qE) + 0

  subscriptionId = live_subs_find_by_query_id(stateJson, queryId)
  if subscriptionId == '' then return stateJson || '0b'x /* unknown/removed id: ignore */

  if modType == 'QueryRemoved' then return stateJson || '0b'x

  if modType == 'QueryUpdated' then do
    parse value json_object_get(payload, itemStart, itemEnd, 'value') with fV vS vE
    valueJson = ''
    if fV == 'FOUND' then valueJson = substr(payload, vS, vE - vS)
    logsJson = http_extract_logs(payload, itemStart, itemEnd)
    signature = 'value' || valueJson || '|logs' || logsJson
    previous = live_subs_signature(stateJson, subscriptionId)
    stateJson = live_subs_set_signature(stateJson, subscriptionId, signature)
    if signature == previous then return stateJson || '0b'x
    evt = '{"subscriptionId":' || json_estr(subscriptionId) || ',"type":"subscription","value":' || valueJson
    if logsJson <> '' then evt = evt || ',"logs":' || logsJson
    evt = evt || '}'
    return stateJson || '0b'x || evt
  end

  if modType == 'QueryFailed' then do
    parse value json_object_get(payload, itemStart, itemEnd, 'errorMessage') with fM mS mE
    errMessage = ''
    if fM == 'FOUND' then errMessage = json_decode_string(payload, mS, mE)
    parse value json_object_get(payload, itemStart, itemEnd, 'errorData') with fD dS dE
    dataJson = ''
    if fD == 'FOUND' then dataJson = substr(payload, dS, dE - dS)
    logsJson = http_extract_logs(payload, itemStart, itemEnd)
    signature = 'error' || errMessage || '|' || dataJson || '|logs' || logsJson
    previous = live_subs_signature(stateJson, subscriptionId)
    stateJson = live_subs_set_signature(stateJson, subscriptionId, signature)
    if signature == previous then return stateJson || '0b'x
    evt = '{"subscriptionId":' || json_estr(subscriptionId) || ',"type":"subscription","error":{"name":"FunctionError","message":' || json_estr(errMessage)
    if dataJson <> '' then evt = evt || ',"data":' || dataJson
    evt = evt || '}'
    if logsJson <> '' then evt = evt || ',"logs":' || logsJson
    evt = evt || '}'
    return stateJson || '0b'x || evt
  end

  return stateJson || '0b'x

live_subs_signature: procedure
  numeric digits 20
  parse arg stateJson, subscriptionId
  subsJson = live_state_get_raw(stateJson, 'subs')
  parse value json_value_span(subsJson, 1) with t s e
  parse value json_object_get(subsJson, s, e, subscriptionId) with found eStart eEnd
  if found == 'NOTFOUND' then return ''
  parse value json_object_get(subsJson, eStart, eEnd, 'lastSignature') with fS sS sE
  if fS == 'NOTFOUND' then return ''
  return json_decode_string(subsJson, sS, sE)

live_subs_set_signature: procedure
  numeric digits 20
  parse arg stateJson, subscriptionId, signature
  subsJson = live_state_get_raw(stateJson, 'subs')
  parse value json_value_span(subsJson, 1) with t s e
  parse value json_object_get(subsJson, s, e, subscriptionId) with found eStart eEnd
  if found == 'NOTFOUND' then return stateJson
  entry = substr(subsJson, eStart, eEnd - eStart)
  parse value json_value_span(entry, 1) with et es ee
  parse value json_object_get(entry, es, ee, 'lastSignature') with fS sS sE
  if fS == 'NOTFOUND' then newEntry = substr(entry, 1, ee - 2) || ',"lastSignature":' || json_estr(signature) || '}'
  else newEntry = substr(entry, 1, sS - 1) || json_estr(signature) || substr(entry, sE)
  subsJson = substr(subsJson, 1, eStart - 1) || newEntry || substr(subsJson, eEnd)
  return live_state_set_raw(stateJson, 'subs', subsJson)

/* An 8-byte little-endian-on-the-wire timestamp, base64 encoded. Only ever
 * compared, never arithmetically interpreted, via a big-endian hex key so
 * ordinary string comparison gives the right ordering. */
timestamp_key: procedure
  parse arg base64Ts
  raw = b64decode(base64Ts)
  reversed = ''
  do i = length(raw) to 1 by -1
    reversed = reversed || substr(raw, i, 1)
  end
  return c2x(reversed)

/* ================================================================
 * RFC 6455 framing
 * ================================================================ */

/* Builds one unfragmented frame (FIN=1) with client-side masking, as
 * required for every client-to-server frame. opcode 1 = text, 10 = pong. */
ws_build_frame: procedure
  numeric digits 20
  parse arg opcode, payload
  len = length(payload)
  first = d2c(128 + opcode)

  if len <= 125 then lenField = d2c(128 + len)
  else if len <= 65535 then do
    hi = len % 256
    lo = len // 256
    lenField = d2c(128 + 126) || d2c(hi) || d2c(lo)
  end
  else do
    lenField = d2c(128 + 127) || '00000000'x || sha1_word_to_bytes(len)
  end

  maskKeyBytes = RXRANDBYTES(4)
  maskKey = substr(maskKeyBytes, 3)
  maskedPayload = ws_mask(payload, maskKey)

  return first || lenField || maskKey || maskedPayload

ws_mask: procedure
  parse arg payload, maskKey
  n = length(payload)
  if n == 0 then return ''
  repeats = (n % 4) + 1
  repeated = left(copies(maskKey, repeats + 1), n)
  return bitxor(payload, repeated)

/* ws_parse_frame(buf) -> "FRAME <opcode>\x0b<len>\x0b<payload>\x0b<remainder>"
 * or "INCOMPLETE\x0b<buf>" if buf does not yet contain a whole frame.
 * Only unfragmented server frames are accepted (FIN=1); a fragmented
 * message is reported as protocol drift by the caller via the unsupported
 * opcode path, since neither Convex's sync server nor this client ever
 * fragments a message in practice for the sizes this project bounds. */
ws_parse_frame: procedure
  numeric digits 20
  parse arg buf
  n = length(buf)
  if n < 2 then return 'INCOMPLETE' || '0b'x || buf

  b0 = c2d(substr(buf, 1, 1))
  b1 = c2d(substr(buf, 2, 1))
  fin = b0 % 128
  opcode = b0 // 16
  masked = (b1 % 128) == 1
  len7 = b1 // 128

  headerLen = 2
  payloadLen = len7
  if len7 == 126 then do
    if n < 4 then return 'INCOMPLETE' || '0b'x || buf
    payloadLen = (c2d(substr(buf,3,1)) * 256) + c2d(substr(buf,4,1))
    headerLen = 4
  end
  else if len7 == 127 then do
    if n < 10 then return 'INCOMPLETE' || '0b'x || buf
    payloadLen = sha1_bytes_to_word(substr(buf, 7, 4))
    headerLen = 10
  end

  maskLen = 0
  if masked then maskLen = 4
  totalLen = headerLen + maskLen + payloadLen
  if n < totalLen then return 'INCOMPLETE' || '0b'x || buf

  payload = substr(buf, headerLen + maskLen + 1, payloadLen)
  if masked then do
    maskKey = substr(buf, headerLen + 1, 4)
    payload = ws_mask(payload, maskKey)
  end

  remainder = substr(buf, totalLen + 1)
  return 'FRAME' || '0b'x || opcode || '0b'x || payloadLen || '0b'x || payload || '0b'x || remainder

/* ================================================================
 * JSON: span-based scanner and encoder.
 * ================================================================ */

json_skip_ws: procedure
  parse arg text, pos
  n = length(text)
  do while pos <= n
    c = substr(text, pos, 1)
    if c <> ' ' & c <> '09'x & c <> '0a'x & c <> '0d'x then leave
    pos = pos + 1
  end
  return pos

json_value_span: procedure
  parse arg text, pos
  pos = json_skip_ws(text, pos)
  c = substr(text, pos, 1)
  select
    when c == '"' then return 'string' pos json_skip_string(text, pos)
    when c == '{' then return 'object' pos json_skip_container(text, pos, '{', '}')
    when c == '[' then return 'array' pos json_skip_container(text, pos, '[', ']')
    when c == 't' then return 'true' pos (pos+4)
    when c == 'f' then return 'false' pos (pos+5)
    when c == 'n' then return 'null' pos (pos+4)
    otherwise return 'number' pos json_skip_number(text, pos)
  end

json_skip_string: procedure
  parse arg text, pos
  n = length(text)
  i = pos + 1
  do while i <= n
    c = substr(text, i, 1)
    if c == '\' then i = i + 2
    else if c == '"' then return i + 1
    else i = i + 1
  end
  return i

json_skip_container: procedure
  parse arg text, pos, openc, closec
  n = length(text)
  depth = 0
  i = pos
  do while i <= n
    c = substr(text, i, 1)
    if c == '"' then i = json_skip_string(text, i)
    else do
      if c == openc then depth = depth + 1
      else if c == closec then do
        depth = depth - 1
        if depth == 0 then return i + 1
      end
      i = i + 1
    end
  end
  return i

json_skip_number: procedure
  parse arg text, pos
  n = length(text)
  i = pos
  do while i <= n
    c = substr(text, i, 1)
    if verify(c, '0123456789+-.eE', 'match') == 0 then leave
    i = i + 1
  end
  return i

json_object_get: procedure
  parse arg text, objStart, objEnd, key
  i = objStart + 1
  do while i < objEnd
    i = json_skip_ws(text, i)
    c = substr(text, i, 1)
    if c == '}' then leave
    if c <> '"' then return 'NOTFOUND'
    keyEnd = json_skip_string(text, i)
    thisKey = json_decode_string(text, i, keyEnd)
    i = json_skip_ws(text, keyEnd)
    i = i + 1
    parse value json_value_span(text, i) with vtype vstart vend
    if thisKey == key then return 'FOUND' vstart vend
    i = json_skip_ws(text, vend)
    if substr(text, i, 1) == ',' then i = i + 1
  end
  return 'NOTFOUND'

json_array_items: procedure
  parse arg text, arrStart, arrEnd
  items = ''
  i = arrStart + 1
  do while i < arrEnd
    i = json_skip_ws(text, i)
    c = substr(text, i, 1)
    if c == ']' then leave
    parse value json_value_span(text, i) with vtype vstart vend
    items = items || vstart || ',' || vend || ' '
    i = json_skip_ws(text, vend)
    if substr(text, i, 1) == ',' then i = i + 1
  end
  return strip(items)

json_decode_string: procedure
  parse arg text, start, end
  inner = substr(text, start + 1, end - start - 2)
  out = ''
  n = length(inner)
  i = 1
  do while i <= n
    c = substr(inner, i, 1)
    if c == '\' then do
      e = substr(inner, i + 1, 1)
      select
        when e == '"' then out = out || '"'
        when e == '\' then out = out || '\'
        when e == '/' then out = out || '/'
        when e == 'b' then out = out || '08'x
        when e == 'f' then out = out || '0c'x
        when e == 'n' then out = out || '0a'x
        when e == 'r' then out = out || '0d'x
        when e == 't' then out = out || '09'x
        when e == 'u' then do
          hex = substr(inner, i + 2, 4)
          out = out || json_utf8_from_codepoint(x2d(hex))
          i = i + 4
        end
        otherwise out = out || e
      end
      i = i + 2
    end
    else do
      out = out || c
      i = i + 1
    end
  end
  return out

json_utf8_from_codepoint: procedure
  parse arg cp
  if cp <= 127 then return d2c(cp)
  /* "%" is truncated integer division, "//" is remainder. */
  if cp <= 2047 then do
    b1 = 192 + (cp % 64)
    b0 = 128 + (cp // 64)
    return d2c(b1) || d2c(b0)
  end
  b2 = 224 + (cp % 4096)
  rem = cp // 4096
  b1 = 128 + (rem % 64)
  b0 = 128 + (rem // 64)
  return d2c(b2) || d2c(b1) || d2c(b0)

json_decode_scalar: procedure
  parse arg text, start, end
  return substr(text, start, end - start)

json_estr: procedure
  parse arg raw
  out = '"'
  n = length(raw)
  i = 1
  do while i <= n
    c = substr(raw, i, 1)
    select
      when c == '"' then out = out || '\"'
      when c == '\' then out = out || '\\'
      when c == '0a'x then out = out || '\n'
      when c == '0d'x then out = out || '\r'
      when c == '09'x then out = out || '\t'
      when c2d(c) < 32 then out = out || '\u' || right(c2x(c), 4, '0')
      otherwise out = out || c
    end
    i = i + 1
  end
  return out || '"'

/* ================================================================
 * base64 and SHA-1 (WebSocket handshake only).
 * ================================================================ */

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

    out = out || substr(alphabet, c0 + 1, 1)
    out = out || substr(alphabet, c1 + 1, 1)
    if chunkLen >= 2 then out = out || substr(alphabet, c2 + 1, 1)
    else out = out || '='
    if chunkLen >= 3 then out = out || substr(alphabet, c3 + 1, 1)
    else out = out || '='

    i = i + 3
  end
  return out

b64decode: procedure
  parse arg text
  alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  text = strip(text, 'T', '=')
  n = length(text)
  bits = ''
  do i = 1 to n
    idx = pos(substr(text, i, 1), alphabet) - 1
    bits = bits || right(x2b(d2x(idx)), 6, '0')
  end
  out = ''
  do i = 1 to length(bits) - 7 by 8
    out = out || d2c(x2d(b2x(substr(bits, i, 8))))
  end
  return out

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

sha1_hex_to_bytes: procedure
  parse arg hex
  return x2c(hex)

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
         right(d2x(h3), 8, '0') || right(d2x(h4), 8, '0'), ,
         'abcdef', 'ABCDEF')

/* ================================================================
 * Self-test: exercises the internal routines above directly, in one
 * process, with no network. These routines are private to this file (an
 * external CALL can only reach the small set of operations dispatched at
 * the top), so this is how the tests under client/tests get real coverage
 * of the JSON codec, the crypto, WebSocket framing, HTTP response
 * classification, and the state-machine's pure JSON-surgery helpers
 * without duplicating any of that logic into the test files themselves.
 * The other files under client/tests additionally drive real loopback
 * sockets against this same file's public operations for the parts that
 * are only meaningful with an actual peer (handshake, Live reconnects,
 * deadlines).
 * ================================================================ */

selftest: procedure
  numeric digits 20
  failures = 0

  call lineout 'stderr', 'selftest: st_json'
  call st_json
  call lineout 'stderr', 'selftest: st_crypto'
  call st_crypto
  call lineout 'stderr', 'selftest: st_ws_frame'
  call st_ws_frame
  call lineout 'stderr', 'selftest: st_http_classify'
  call st_http_classify
  call lineout 'stderr', 'selftest: st_state_surgery'
  call st_state_surgery
  call lineout 'stderr', 'selftest: done'

  if failures = 0 then return 'PASS'
  return 'FAIL:' failures

/* The st_* routines below all use "expose failures" so one shared counter
 * accumulates across every check; each prints its own FAIL lines to
 * stderr so a failing run says exactly what broke. */

st_assert_eq: procedure expose failures
  parse arg actual, expected, label
  if actual == expected then return
  failures = failures + 1
  call lineout 'stderr', 'SELFTEST FAIL' label': expected=['expected'] actual=['actual']'
  return

st_json: procedure expose failures
  call st_assert_eq json_estr('hello'), '"hello"', 'json string'
  call st_assert_eq json_estr('a"b\c'), '"a\"b\\c"', 'json escaping'

  doc = '{"a":1,"b":"two","c":[1,2,3],"d":{"e":true,"f":null},"g":-4.5,"h":"utf8:世界"}'
  parse value json_value_span(doc, 1) with vtype vstart vend
  call st_assert_eq vtype, 'object', 'json top type'

  parse value json_object_get(doc, vstart, vend, 'a') with found aStart aEnd
  call st_assert_eq json_decode_scalar(doc, aStart, aEnd), '1', 'json number field'

  parse value json_object_get(doc, vstart, vend, 'b') with found bStart bEnd
  call st_assert_eq json_decode_string(doc, bStart, bEnd), 'two', 'json string field'

  parse value json_object_get(doc, vstart, vend, 'missing') with found . .
  call st_assert_eq found, 'NOTFOUND', 'json missing key'

  parse value json_object_get(doc, vstart, vend, 'c') with found cStart cEnd
  items = json_array_items(doc, cStart, cEnd)
  call st_assert_eq words(items), 3, 'json array item count'

  parse value json_object_get(doc, vstart, vend, 'h') with found hStart hEnd
  call st_assert_eq json_decode_string(doc, hStart, hEnd), 'utf8:世界', 'json utf8 passthrough'

  doc2 = '{"x":' || json_estr('a"b'||'0a'x||'c') || '}'
  parse value json_value_span(doc2, 1) with t2 s2 e2
  parse value json_object_get(doc2, s2, e2, 'x') with found xStart xEnd
  call st_assert_eq json_decode_string(doc2, xStart, xEnd), 'a"b'||'0a'x||'c', 'json round trip escaped'
  return

st_crypto: procedure expose failures
  call st_assert_eq b64encode('foobar'), 'Zm9vYmFy', 'base64 foobar'
  call st_assert_eq b64decode('Zm9vYmFy'), 'foobar', 'base64 decode foobar'
  call st_assert_eq b64decode(b64encode('a'||'00'x||'b')), 'a'||'00'x||'b', 'base64 round trip with nul'

  call st_assert_eq sha1hex(''), 'da39a3ee5e6b4b0d3255bfef95601890afd80709', 'sha1 empty'
  call st_assert_eq sha1hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d', 'sha1 abc'

  key = 'dGhlIHNhbXBsZSBub25jZQ=='
  magic = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
  accept = b64encode(sha1_hex_to_bytes(sha1hex(key || magic)))
  call st_assert_eq accept, 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=', 'rfc6455 handshake vector'
  return

st_ws_frame: procedure expose failures
  do trial = 1 to 3
    if trial == 1 then payload = 'hello'
    if trial == 2 then payload = copies('x', 130) /* forces the 2-byte extended length */
    if trial == 3 then payload = ''

    frame = ws_build_frame(1, payload)
    parsed = ws_parse_frame(frame)
    parse var parsed status '0b'x rest
    call st_assert_eq status, 'FRAME', 'ws frame trial' trial 'parses complete'
    parse var rest opcode '0b'x payloadLen '0b'x decodedPayload '0b'x remainder
    call st_assert_eq opcode + 0, 1, 'ws frame trial' trial 'opcode'
    call st_assert_eq decodedPayload, payload, 'ws frame trial' trial 'payload round trip'
    call st_assert_eq remainder, '', 'ws frame trial' trial 'no trailing bytes'
  end

  /* A frame missing its last byte must be reported incomplete, not
   * misparsed. */
  full = ws_build_frame(1, 'abcdef')
  truncated = substr(full, 1, length(full) - 1)
  parsedShort = ws_parse_frame(truncated)
  parse var parsedShort statusShort '0b'x .
  call st_assert_eq statusShort, 'INCOMPLETE', 'ws truncated frame is incomplete'
  return

st_http_classify: procedure expose failures
  success = http_classify(200, '{"status":"success","value":{"ok":true},"logLines":[]}')
  call st_assert_eq success, '{"type":"result","value":{"ok":true}}', 'http classify success, no logs'

  withLogs = http_classify(200, '{"status":"success","value":1,"logLines":["hi"]}')
  call st_assert_eq withLogs, '{"type":"result","value":1,"logs":["hi"]}', 'http classify success with logs'

  errViaStatus = http_classify(200, '{"status":"error","errorMessage":"boom","errorData":{"code":"X"},"logLines":[]}')
  call st_assert_eq errViaStatus, ,
    '{"type":"error","error":{"name":"FunctionError","message":"boom","data":{"code":"X"}}}', ,
    'http classify function error via status'

  err560 = http_classify(560, '{"status":"error","errorMessage":"boom560","logLines":[]}')
  call st_assert_eq err560, '{"type":"error","error":{"name":"FunctionError","message":"boom560"}}', ,
    'http classify function error via 560'

  transport = http_classify(503, '{"code":"Unavailable","message":"try later"}')
  call st_assert_eq transport, '{"type":"error","error":{"name":"TransportError","message":"HTTP 503 from Convex: try later"}}', ,
    'http classify transport error'

  protocolErr = http_classify(404, '')
  call st_assert_eq protocolErr, '{"type":"error","error":{"name":"ProtocolError","message":"HTTP 404 from Convex: no Convex error envelope"}}', ,
    'http classify protocol error'

  missingStatus = http_classify(200, '{"value":1}')
  parse value json_value_span(missingStatus, 1) with . ms me
  parse value json_object_get(missingStatus, ms, me, 'error') with found errS errE
  parse value json_object_get(missingStatus, errS, errE, 'name') with found2 nS nE
  call st_assert_eq json_decode_string(missingStatus, nS, nE), 'ProtocolError', 'http classify missing status is protocol error'
  return

st_state_surgery: procedure expose failures
  state = live_initial_state('wss://example.test/api/sync')
  call st_assert_eq live_state_get(state, 'connected'), 'false', 'initial state disconnected'
  call st_assert_eq live_state_get(state, 'lastCloseReason'), 'InitialConnect', 'initial close reason'

  state = live_state_set(state, 'connectionCount', 3)
  call st_assert_eq live_state_get(state, 'connectionCount'), 3, 'state set/get roundtrip number'

  state = live_state_set(state, 'lastCloseReason', 'TransportError: peer closed')
  call st_assert_eq live_state_get(state, 'lastCloseReason'), 'TransportError: peer closed', ,
    'state set/get roundtrip string with colon and space'

  state = live_subs_put(state, 'sub-a', 0, 'demo:state', '{"room":"r"}', '', 0)
  state = live_subs_put(state, 'sub-b', 1, 'demo:other', '{}', '', 0)
  call st_assert_eq live_subs_query_id(state, 'sub-a'), 0, 'subs query id a'
  call st_assert_eq live_subs_query_id(state, 'sub-b'), 1, 'subs query id b'
  call st_assert_eq live_subs_find_by_query_id(state, 1), 'sub-b', 'subs find by query id'

  mods = live_subs_each_add_modification(state)
  call st_assert_eq pos('"queryId":0', mods) > 0, 1, 'rebuild modifications include sub-a'
  call st_assert_eq pos('"queryId":1', mods) > 0, 1, 'rebuild modifications include sub-b'

  state = live_subs_delete(state, 'sub-a')
  call st_assert_eq live_subs_query_id(state, 'sub-a'), -1, 'subs delete removes entry'
  call st_assert_eq live_subs_query_id(state, 'sub-b'), 1, 'subs delete keeps the other entry'

  state = live_subs_delete(state, 'sub-b')
  call st_assert_eq live_state_get_raw(state, 'subs'), '{}', 'subs delete down to empty object'
  return
