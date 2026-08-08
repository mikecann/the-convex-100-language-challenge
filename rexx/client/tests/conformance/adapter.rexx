#!/usr/local/bin/regina
/* NDJSON adapter protocol v1 for the native Rexx Convex client.
 *
 * This is test infrastructure, not public client code: it is a thin
 * translator between the shared harness's newline-delimited JSON commands
 * and the real client operations in /opt/convex/client/convex.rexx (the
 * same file the canonical example uses). Every actual HTTP request and
 * every actual Live/WebSocket operation happens inside that file; this
 * file only decodes commands, calls it, and encodes the results.
 *
 * Protocol version, transport, and event shape are exactly the shared
 * v1 contract (_shared/schemas/adapter.schema.json): stdout carries only
 * NDJSON protocol events, one per line; diagnostics go to stderr. Without
 * ADAPTER_LISTEN this reads stdin/writes stdout; with it, it binds that
 * address, accepts exactly one controller connection, and carries the
 * same NDJSON stream over that socket instead.
 *
 * Regina has no threads, so one single-threaded loop owns the input
 * stream and the Live connection exclusively: each pass gives a short
 * timeout to "is there another command yet" and, if a Live subscription
 * is active, an equally short timeout to "did the server send anything",
 * so neither starves the other and no command or Live event is ever
 * handled concurrently with another.
 */
call rxfuncadd 'RXCONNECT', 'convexshim', 'RXCONNECT'
call rxfuncadd 'RXLISTEN', 'convexshim', 'RXLISTEN'
call rxfuncadd 'RXACCEPT', 'convexshim', 'RXACCEPT'
call rxfuncadd 'RXSEND', 'convexshim', 'RXSEND'
call rxfuncadd 'RXRECV', 'convexshim', 'RXRECV'
call rxfuncadd 'RXCLOSE', 'convexshim', 'RXCLOSE'

numeric digits 20

convexUrl = value('CONVEX_URL',, 'ENVIRONMENT')
listenSpec = value('ADAPTER_LISTEN',, 'ENVIRONMENT')

if listenSpec == '' then do
  inHandle = 0
  outHandle = 1
end
else do
  sepPos = lastpos(':', listenSpec)
  bindHost = substr(listenSpec, 1, sepPos - 1)
  bindPort = substr(listenSpec, sepPos + 1)
  if bindHost == '0.0.0.0' then bindHost = ''
  listenResult = RXLISTEN(bindHost, bindPort)
  if left(listenResult, 1) <> 'K' then do
    call lineout 'stderr', 'adapter: listen failed:' substr(listenResult, 3)
    exit 1
  end
  listenHandle = substr(listenResult, 3)
  acceptResult = RXACCEPT(listenHandle, 60000)
  if left(acceptResult, 1) <> 'K' then do
    call lineout 'stderr', 'adapter: accept failed:' substr(acceptResult, 3)
    exit 1
  end
  call RXCLOSE listenHandle
  inHandle = substr(acceptResult, 3)
  outHandle = inHandle
end

authToken = ''
liveState = ''
liveUrl = ''
inBuffer = ''
closed = 0

if convexUrl <> '' then do
  scheme = 'ws'
  if translate(left(convexUrl, 8)) == 'HTTPS://' then scheme = 'wss'
  parse var convexUrl '//' hostAndMore
  liveUrl = scheme || '://' || hostAndMore || '/api/sync'
end

do while closed == 0
  chunk = RXRECV(inHandle, 65536, 50)
  tag = left(chunk, 1)
  select
    when tag == 'D' then do
      inBuffer = inBuffer || substr(chunk, 3)
      if length(inBuffer) > 9437184 then do
        call lineout 'stderr', 'adapter: command frame exceeded 9 MiB budget'
        inBuffer = ''
      end
    end
    when tag == 'T' then nop: nop = 1
    otherwise closed = 1
  end

  do while pos('0a'x, inBuffer) > 0
    parse var inBuffer line '0a'x inBuffer
    line = strip(line, 'T', '0d'x)
    if strip(line) == '' then iterate
    call handle_command line
    if closed then leave
  end

  if closed == 0 & liveState <> '' then do
    call '/opt/convex/client/convex.rexx' 'live_poll', liveState, 50
    parse var result liveState '0b'x liveEvents
    liveState = strip(liveState)
    do while liveEvents <> ''
      parse var liveEvents oneEvent '0c'x liveEvents
      if oneEvent == '' then leave
      call emit_subscription_event oneEvent
    end
  end
end

exit 0

/* ---------------- command dispatch ---------------- */

handle_command: procedure expose authToken liveState liveUrl convexUrl closed outHandle
  parse arg line

  parse value cmd_field(line, 'op') with foundOp op
  parse value cmd_field(line, 'id') with foundId id

  if foundOp == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted a valid op'
    return
  end

  select
    when op == 'hello' then call op_hello line, id, foundId
    when op == 'query' then call op_call line, id, foundId, 'query'
    when op == 'mutation' then call op_call line, id, foundId, 'mutation'
    when op == 'action' then call op_call line, id, foundId, 'action'
    when op == 'setAuth' then call op_set_auth line, id, foundId
    when op == 'subscribe' then call op_subscribe line, id, foundId
    when op == 'unsubscribe' then call op_unsubscribe line, id, foundId
    when op == 'debugDisconnect' then call op_debug_disconnect id, foundId
    when op == 'close' then call op_close id, foundId
    otherwise call emit_protocol_error id, foundId, 'unrecognised op' op
  end
  return

op_hello: procedure expose outHandle
  parse arg line, id, foundId
  parse value cmd_field(line, 'protocolVersion') with foundPv pv
  if foundPv == 'NOTFOUND' | pv <> '1' then do
    call emit_protocol_error id, foundId, 'unsupported protocolVersion'
    return
  end
  /* A built-in, so this needs no writable filesystem: the runtime images
   * this adapter ships in are read-only. */
  parse version runtimeVersion
  event = '{"protocolVersion":1,"id":' || json_estr(id) || ',"type":"ready","language":"rexx",' || ,
    '"implementation":"native-regina-rexx-0.1.0","runtime":' || json_estr(runtimeVersion) || '}'
  call emit event
  return

op_call: procedure expose outHandle convexUrl authToken
  parse arg line, id, foundId, httpOp
  if foundId == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted valid id'
    return
  end
  parse value cmd_field(line, 'path') with foundPath path
  parse value cmd_raw_field(line, 'args') with foundArgs argsJson
  if foundPath == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted valid path'
    return
  end
  if foundArgs == 'NOTFOUND' then argsJson = '{}'

  call '/opt/convex/client/convex.rexx' 'http_call', httpOp, path, argsJson, convexUrl, authToken
  envelope = result
  call emit_call_result id, envelope
  return

op_set_auth: procedure expose outHandle authToken
  parse arg line, id, foundId
  parse value cmd_field(line, 'token') with foundToken token
  if foundToken == 'NOTFOUND' then authToken = ''
  else authToken = token
  call emit '{"id":' || json_estr(id) || ',"type":"ack"}'
  return

op_subscribe: procedure expose outHandle liveState liveUrl
  parse arg line, id, foundId
  if foundId == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted valid id'
    return
  end
  parse value cmd_field(line, 'subscriptionId') with foundSub subscriptionId
  parse value cmd_field(line, 'path') with foundPath path
  parse value cmd_raw_field(line, 'args') with foundArgs argsJson
  if foundSub == 'NOTFOUND' | foundPath == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted subscriptionId or path'
    return
  end
  if foundArgs == 'NOTFOUND' then argsJson = '{}'

  call '/opt/convex/client/convex.rexx' 'live_add', liveState, liveUrl, subscriptionId, path, argsJson
  parse var result liveState '0b'x liveEvents
  liveState = strip(liveState)
  call emit '{"id":' || json_estr(id) || ',"type":"ack"}'
  do while liveEvents <> ''
    parse var liveEvents oneEvent '0c'x liveEvents
    if oneEvent == '' then leave
    call emit_subscription_event oneEvent
  end
  return

op_unsubscribe: procedure expose outHandle liveState
  parse arg line, id, foundId
  if foundId == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted valid id'
    return
  end
  parse value cmd_field(line, 'subscriptionId') with foundSub subscriptionId
  if foundSub == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted subscriptionId'
    return
  end
  if liveState <> '' then do
    call '/opt/convex/client/convex.rexx' 'live_remove', liveState, subscriptionId
    parse var result liveState '0b'x .
    liveState = strip(liveState)
  end
  call emit '{"id":' || json_estr(id) || ',"type":"ack"}'
  return

op_debug_disconnect: procedure expose outHandle liveState
  parse arg id, foundId
  if foundId == 'NOTFOUND' then do
    call emit_protocol_error id, foundId, 'command omitted valid id'
    return
  end
  if liveState <> '' then do
    call '/opt/convex/client/convex.rexx' 'live_debug_disconnect', liveState
    parse var result liveState '0b'x .
    liveState = strip(liveState)
  end
  call emit '{"id":' || json_estr(id) || ',"type":"ack"}'
  return

op_close: procedure expose outHandle liveState closed
  parse arg id, foundId
  if liveState <> '' then do
    call '/opt/convex/client/convex.rexx' 'live_close', liveState
  end
  idPart = ''
  if foundId <> 'NOTFOUND' then idPart = '"id":' || json_estr(id) || ','
  call emit '{' || idPart || '"type":"closed"}'
  closed = 1
  return

/* ---------------- event emission ---------------- */

emit_call_result: procedure expose outHandle
  parse arg id, envelope
  parse value json_value_span(envelope, 1) with t s e
  parse value json_object_get(envelope, s, e, 'type') with fT tS tE
  kind = json_decode_string(envelope, tS, tE)
  if kind == 'result' then do
    parse value json_object_get(envelope, s, e, 'value') with fV vS vE
    valueJson = substr(envelope, vS, vE - vS)
    out = '{"id":' || json_estr(id) || ',"type":"result","value":' || valueJson
    parse value json_object_get(envelope, s, e, 'logs') with fL lS lE
    if fL == 'FOUND' then out = out || ',"logs":' || substr(envelope, lS, lE - lS)
    call emit out || '}'
  end
  else do
    parse value json_object_get(envelope, s, e, 'error') with fE errS errE
    errorJson = substr(envelope, errS, errE - errS)
    call emit '{"id":' || json_estr(id) || ',"type":"error","error":' || errorJson || '}'
  end
  return

emit_subscription_event: procedure expose outHandle
  parse arg oneEvent
  parse value json_value_span(oneEvent, 1) with t s e
  parse value json_object_get(oneEvent, s, e, 'subscriptionId') with fS sS sE
  subscriptionId = json_decode_string(oneEvent, sS, sE)
  parse value json_object_get(oneEvent, s, e, 'value') with fV vS vE
  parse value json_object_get(oneEvent, s, e, 'error') with fErr errS errE
  out = '{"subscriptionId":' || json_estr(subscriptionId) || ',"type":"subscription"'
  if fV == 'FOUND' then out = out || ',"value":' || substr(oneEvent, vS, vE - vS)
  if fErr == 'FOUND' then out = out || ',"error":' || substr(oneEvent, errS, errE - errS)
  parse value json_object_get(oneEvent, s, e, 'logs') with fL lS lE
  if fL == 'FOUND' then out = out || ',"logs":' || substr(oneEvent, lS, lE - lS)
  call emit out || '}'
  return

emit_protocol_error: procedure expose outHandle
  parse arg id, foundId, message
  idPart = ''
  if foundId <> 'NOTFOUND' then idPart = '"id":' || json_estr(id) || ','
  call emit '{' || idPart || '"type":"error","error":{"name":"ProtocolError","message":' || json_estr(message) || '}}'
  return

emit: procedure expose outHandle
  parse arg text
  call RXSEND outHandle, text || '0a'x
  return

/* ---------------- minimal command-line JSON field access ----------------
 * Adapter-protocol decoding is test infrastructure, not Convex client
 * behaviour, so it gets its own small span-based scanner rather than
 * reaching into convex.rexx's (non-dispatched, unreachable from here)
 * internals. Same technique, kept deliberately tiny: enough to read one
 * flat NDJSON command object's string/scalar/object fields. */

cmd_field: procedure
  parse arg line, key
  parse value json_value_span(line, 1) with t s e
  if t <> 'object' then return 'NOTFOUND' ''
  parse value json_object_get(line, s, e, key) with found fs fe
  if found == 'NOTFOUND' then return 'NOTFOUND' ''
  return 'FOUND' json_decode_scalar_or_string(line, fs, fe)

/* Like cmd_field, but returns the field's raw JSON text unparsed (for
 * "args", which is an opaque object relayed to the client verbatim). */
cmd_raw_field: procedure
  parse arg line, key
  parse value json_value_span(line, 1) with t s e
  if t <> 'object' then return 'NOTFOUND' ''
  parse value json_object_get(line, s, e, key) with found fs fe
  if found == 'NOTFOUND' then return 'NOTFOUND' ''
  return 'FOUND' substr(line, fs, fe - fs)

json_decode_scalar_or_string: procedure
  parse arg text, start, end
  c = substr(text, start, 1)
  if c == '"' then return json_decode_string(text, start, end)
  return substr(text, start, end - start)

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
          out = out || d2c(x2d(hex))
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
