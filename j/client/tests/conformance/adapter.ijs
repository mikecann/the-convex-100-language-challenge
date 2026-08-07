NB. adapter.ijs -- NDJSON adapter protocol v1 for the shared conformance
NB. controller. This is test infrastructure, not public client code: every
NB. operation is forwarded to the real client (convex.ijs, live.ijs), never
NB. talks to Convex directly, reserves stdout for protocol events, and sends
NB. diagnostics to stderr. It supports both stdin/stdout (the default) and
NB. the ADAPTER_LISTEN TCP mode the shared harness uses, over the same
NB. connection abstraction transport.ijs already gives plain sockets.
NB.
NB. J has one thread, so this loop *is* the Live owner, exactly like every
NB. other single-owner client in this project: it alternates pumping the
NB. WebSocket and taking one controller command, both bounded by a
NB. monotonic deadline.

load '/project/client/live.ijs'

ADAPTER_LANGUAGE=: 'j'
ADAPTER_IMPLEMENTATION=: 'native-j-15!:0-0.1.0'
ADAPTER_LINE_LIMIT=: 1048576
ADAPTER_OUTPUT_COUNT=: 8
ADAPTER_OUTPUT_BYTES=: 4194304
ADAPTER_PUMP_MS=: 15
ADAPTER_READ_MS=: 15
ADAPTER_FLUSH_MS=: 250

ADAPTER_CONN=: ''
ADAPTER_IN_BUFFER=: ''
ADAPTER_EOF=: 0
ADAPTER_DONE=: 0
ADAPTER_STATUS=: 0
ADAPTER_OUT=: 0 3 $ a: NB. rows: text, droppable(0/1), size

NB. Written straight to fd 2 through the same libc write() binding stdio
NB. transport uses, rather than J's own file-write foreign, so this needs
NB. no separate convention for "where stderr is".
adapter_diagnostic=: 3 : 0
  NB. write_J's *c parameter is marshaled as characters (cd's convention,
  NB. confirmed by the same domain error tx_sha1 hit before its input was
  NB. converted the same way): pass the text directly, not a.i.'s byte
  NB. values.
  text=. 'convex-adapter: ', y, LF
  write_J 2;text;(# text)
  i. 0
)

NB. ---------------------------------------------------------------------------
NB. Connection-agnostic read/write: dispatch on whether the adapter is
NB. talking over stdio or an accepted TCP controller socket.
NB. ---------------------------------------------------------------------------

adapter_recv=: 3 : 0
  'limit ms'=. y
  if. 'stdio' -: tx_kind ADAPTER_CONN do.
    tx_stdio_recv (<ADAPTER_CONN),(<limit),(<ms) return.
  end.
  tx_recv (<ADAPTER_CONN),(<limit),(<ms)
)

adapter_send=: 3 : 0
  'data ms'=. y
  if. 'stdio' -: tx_kind ADAPTER_CONN do.
    tx_stdio_send (<ADAPTER_CONN),(<data),(<ms) return.
  end.
  tx_send (<ADAPTER_CONN),(<data),(<ms)
)

NB. ---------------------------------------------------------------------------
NB. Controller input: one NDJSON line at a time.
NB. ---------------------------------------------------------------------------

adapter_read_line=: 3 : 0
  timeout_ms=. y
  deadline=. (tx_now_ms '') + timeout_ms
  while. 1 do.
    at=. ADAPTER_IN_BUFFER cx_find LF;0
    if. at < # ADAPTER_IN_BUFFER do.
      line=. at {. ADAPTER_IN_BUFFER
      ADAPTER_IN_BUFFER=: (at + 1) }. ADAPTER_IN_BUFFER
      if. (0 < #line) *. (CR = {: line) do. line=. }: line end.
      line return.
    end.
    if. (# ADAPTER_IN_BUFFER) > ADAPTER_LINE_LIMIT do.
      adapter_diagnostic 'controller line exceeds ', (": ADAPTER_LINE_LIMIT), ' bytes'
      ADAPTER_IN_BUFFER=: ''
      ADAPTER_EOF=: 1
      ADAPTER_STATUS=: 1
      '' return.
    end.
    if. ADAPTER_EOF do. '' return. end.
    remaining=. tx_remaining deadline
    if. remaining = 0 do. '' return. end.
    'status payload'=. adapter_recv 65536;remaining
    if. status = TX_IO_OK do.
      ADAPTER_IN_BUFFER=: ADAPTER_IN_BUFFER , a. {~ payload
      continue.
    end.
    if. status = TX_IO_TIMEOUT do. '' return. end.
    if. status = TX_IO_EOF do. ADAPTER_EOF=: 1 [ '' return. end.
    adapter_diagnostic 'controller read failed'
    ADAPTER_EOF=: 1
    ADAPTER_STATUS=: 1
    '' return.
  end.
)

NB. ---------------------------------------------------------------------------
NB. Controller output: charged before it is queued, so a controller that
NB. stops reading cannot hide memory in a blocked write. Responses are
NB. never dropped; subscription events are, oldest first.
NB. ---------------------------------------------------------------------------

adapter_emit=: 3 : 0
  'text droppable'=. y
  size=. (# text) + 64
  ADAPTER_OUT=: ADAPTER_OUT , 1 3 $ (<text),(<droppable),(<size)
  while. (ADAPTER_OUTPUT_COUNT < # ADAPTER_OUT) +. (adapter_out_bytes '') > ADAPTER_OUTPUT_BYTES do.
    if. -. adapter_drop_oldest '' do.
      adapter_diagnostic 'output budget exhausted by undroppable responses'
      ADAPTER_DONE=: 1
      ADAPTER_STATUS=: 1
      0 return.
    end.
  end.
  1
)

adapter_out_bytes=: 3 : 0
  total=. 0
  for_row. ADAPTER_OUT do. total=. total + > 2 { row end.
  total
)

adapter_drop_oldest=: 3 : 0
  n=. # ADAPTER_OUT
  i=. 0
  while. i < n do.
    if. > 1 { i { ADAPTER_OUT do.
      keep=. 0 3 $ a:
      j=. 0
      while. j < n do.
        if. j ~: i do. keep=. keep , 1 3 $ j { ADAPTER_OUT end.
        j=. j + 1
      end.
      ADAPTER_OUT=: keep
      1 return.
    end.
    i=. i + 1
  end.
  0
)

adapter_flush=: 3 : 0
  budget_ms=. y
  deadline=. (tx_now_ms '') + budget_ms
  while. 0 < # ADAPTER_OUT do.
    text=. > 0 { 0 { ADAPTER_OUT
    remaining=. tx_remaining deadline
    if. remaining = 0 do. 0 return. end.
    'status wmsg'=. adapter_send (a. i. text,LF);remaining
    if. status = TX_IO_TIMEOUT do. 0 return. end.
    if. status ~: TX_IO_OK do.
      adapter_diagnostic 'controller write failed'
      ADAPTER_DONE=: 1
      ADAPTER_STATUS=: 1
      0 return.
    end.
    ADAPTER_OUT=: 1 }. ADAPTER_OUT
  end.
  1
)

NB. ---------------------------------------------------------------------------
NB. Event shapes. Optional members are omitted rather than serialised as
NB. null, matching the shared adapter.schema.json.
NB. ---------------------------------------------------------------------------

adapter_error_object=: 3 : 0
  'name message data'=. y
  datajson=. data
  if. 0 = # datajson do. datajson=. 'null' end.
  '{"name":',(jw_quote name),',"message":',(jw_quote message),',"data":',datajson,'}'
)

adapter_ready=: 3 : 0
  id=. y
  msg=. '{"protocolVersion":1,"id":',(jw_quote id)
  msg=. msg,',"type":"ready","language":',(jw_quote ADAPTER_LANGUAGE)
  msg=. msg,',"implementation":',(jw_quote ADAPTER_IMPLEMENTATION)
  msg,',"runtime":',(jw_quote 'jsource 9.8.0-beta6'),'}'
)

adapter_result=: 3 : 0
  'id value logs'=. y
  logsjson=. logs
  if. 0 = # logsjson do. logsjson=. '[]' end.
  '{"id":',(jw_quote id),',"type":"result","value":',value,',"logs":',logsjson,'}'
)

adapter_error=: 3 : 0
  'id name message data'=. y
  idpart=. ''
  if. adapter_id_valid id do. idpart=. '"id":',(jw_quote id),',' end.
  '{',idpart,'"type":"error","error":',(adapter_error_object name;message;data),'}'
)

adapter_ack=: 3 : 0
  '{"id":',(jw_quote y),',"type":"ack"}'
)

adapter_closed=: 3 : 0
  '{"id":',(jw_quote y),',"type":"closed"}'
)

adapter_subscription_value=: 3 : 0
  'subid value logs'=. y
  logsjson=. logs
  if. 0 = # logsjson do. logsjson=. '[]' end.
  '{"type":"subscription","subscriptionId":',(jw_quote subid),',"value":',value,',"logs":',logsjson,'}'
)

adapter_subscription_error=: 3 : 0
  'subid name message data logs'=. y
  base=. '{"type":"subscription","subscriptionId":',(jw_quote subid),',"error":',(adapter_error_object name;message;data)
  if. (0 < #logs) *. (-. logs -: '[]') do. base=. base,',"logs":',logs end.
  base,'}'
)

adapter_publish_updates=: 3 : 0
  while. 1 do.
    'ok tag value logs errname errmsg errdata'=. cx_live_next_update ''
    if. -. ok do. 1 return. end.
    if. 0 < # errname do.
      adapter_emit (adapter_subscription_error tag;errname;errmsg;errdata;logs);1
    else.
      adapter_emit (adapter_subscription_value tag;value;logs);1
    end.
  end.
)

NB. ---------------------------------------------------------------------------
NB. Command dispatch
NB. ---------------------------------------------------------------------------

NB. A valid id is 1-128 UTF-8 code points and valid UTF-8.
adapter_id_valid=: 3 : 0
  value=. y
  if. 0 = # value do. 0 return. end.
  if. -. ws_utf8_valid a. i. value do. 0 return. end.
  cps=. 3 u: 9 u: a. {~ value
  (0 < #cps) *. #cps <: 128
)

adapter_call=: 3 : 0
  'id operation path args'=. y
  result=. cx_call operation;path;args
  ok=. > 0 { result
  if. ok do.
    value=. > 1 { result
    logs=. > 2 { result
    adapter_emit (adapter_result id;value;logs);0
    1 return.
  end.
  adapter_emit (adapter_error id;(convex_error_name ''); (convex_error_message '');(convex_error_data ''));0
  0
)

adapter_command=: 3 : 0
  line=. y
  'pok payload'=. cx_unpack2 cx_json_parse line
  if. -. pok do.
    adapter_emit (adapter_error '';'ProtocolError';'the controller sent invalid JSON';'null');0
    0 return.
  end.
  if. -. 'o' -: jtag payload do.
    adapter_emit (adapter_error '';'ProtocolError';'the controller sent invalid JSON';'null');0
    0 return.
  end.

  idnode=. payload jfind 'id'
  id=. ''
  if. idnode ~: _1 do.
    if. 's' -: jtag > idnode do. id=. jpay > idnode end.
  end.
  opnode=. payload jfind 'op'
  operation=. ''
  if. opnode ~: _1 do.
    if. 's' -: jtag > opnode do. operation=. jpay > opnode end.
  end.

  if. operation -: 'hello' do.
    adapter_emit (adapter_ready id);0
    1 return.
  end.
  if. (operation -: 'query') +. (operation -: 'mutation') +. operation -: 'action' do.
    pathnode=. payload jfind 'path'
    argsnode=. payload jfind 'args'
    path=. ''
    if. pathnode ~: _1 do.
      if. 's' -: jtag > pathnode do. path=. jpay > pathnode end.
    end.
    args=. '{}'
    if. argsnode ~: _1 do.
      if. 'o' -: jtag > argsnode do. args=. cx_json_encode > argsnode end.
    end.
    adapter_call id;operation;path;args return.
  end.
  if. operation -: 'setAuth' do.
    tokennode=. payload jfind 'token'
    token=. ''
    if. tokennode ~: _1 do.
      if. 's' -: jtag > tokennode do. token=. jpay > tokennode end.
    end.
    convex_set_auth token
    adapter_emit (adapter_ack id);0
    1 return.
  end.
  if. (operation -: 'subscribe') +. operation -: 'unsubscribe' do.
    subidnode=. payload jfind 'subscriptionId'
    subid=. ''
    if. subidnode ~: _1 do.
      if. 's' -: jtag > subidnode do. subid=. jpay > subidnode end.
    end.
    if. 0 = # subid do.
      adapter_emit (adapter_error id;'ProtocolError';(operation,' requires a subscription identifier');'null');0
      0 return.
    end.
    if. operation -: 'subscribe' do.
      pathnode=. payload jfind 'path'
      argsnode=. payload jfind 'args'
      path=. ''
      if. pathnode ~: _1 do.
        if. 's' -: jtag > pathnode do. path=. jpay > pathnode end.
      end.
      args=. '{}'
      if. argsnode ~: _1 do.
        if. 'o' -: jtag > argsnode do. args=. cx_json_encode > argsnode end.
      end.
      sok=. cx_live_subscribe (<subid),(<path),(<args)
      if. -. sok do.
        adapter_emit (adapter_error id;(convex_error_name '');(convex_error_message '');(convex_error_data ''));0
        0 return.
      end.
      adapter_emit (adapter_ack id);0
      1 return.
    end.
    cx_live_unsubscribe subid
    adapter_emit (adapter_ack id);0
    1 return.
  end.
  if. operation -: 'debugDisconnect' do.
    dok=. cx_live_debug_disconnect ''
    if. -. dok do.
      adapter_emit (adapter_error id;(convex_error_name '');(convex_error_message '');(convex_error_data ''));0
      0 return.
    end.
    adapter_emit (adapter_ack id);0
    1 return.
  end.
  if. operation -: 'close' do.
    cx_live_close 1000
    adapter_emit (adapter_closed id);0
    ADAPTER_DONE=: 1
    1 return.
  end.
  adapter_emit (adapter_error id;'ProtocolError';('unknown operation: ',operation);'null');0
  0
)

NB. ---------------------------------------------------------------------------
NB. Main loop
NB. ---------------------------------------------------------------------------

adapter_loop=: 3 : 0
  while. -. ADAPTER_DONE do.
    cx_live_pump ADAPTER_PUMP_MS
    adapter_publish_updates ''
    line=. adapter_read_line ADAPTER_READ_MS
    if. 0 < # line do.
      adapter_command line
    elseif. ADAPTER_EOF do.
      ADAPTER_DONE=: 1
    end.
    adapter_flush ADAPTER_FLUSH_MS
  end.
  1
)

adapter_last_colon=: 3 : 0
  text=. y
  found=. _1
  i=. 0
  while. i < # text do.
    if. (i { text) = ':' do. found=. i end.
    i=. i + 1
  end.
  found
)

adapter_main=: 3 : 0
  cx_live_reset ''
  url=. tx_getenv 'CONVEX_URL'
  if. 0 = # url do.
    adapter_diagnostic 'CONVEX_URL is required'
    1 return.
  end.
  if. -. convex_open url;'j-0.1.0' do.
    adapter_diagnostic convex_error_message ''
    1 return.
  end.

  address=. tx_getenv 'ADAPTER_LISTEN'
  if. 0 = # address do.
    ADAPTER_CONN=: (<'stdio'),(<0),(<1)
  else.
    sep=. adapter_last_colon address
    if. sep < 1 do.
      adapter_diagnostic 'ADAPTER_LISTEN must be host:port'
      1 return.
    end.
    host=. sep {. address
    port=. ". (sep + 1) }. address
    'rc listener'=. sdsocket ''
    if. rc ~: 0 do.
      adapter_diagnostic 'cannot open listening socket'
      1 return.
    end.
    bindresult=. sdbind listener;AF_INET;host;port
    if. 0 ~: {. bindresult do.
      adapter_diagnostic 'cannot bind ', address
      1 return.
    end.
    if. 0 ~: {. sdlisten listener;16 do.
      adapter_diagnostic 'cannot listen on ', address
      1 return.
    end.
    'rc infd'=. sdaccept listener
    if. rc ~: 0 do.
      adapter_diagnostic 'no controller connected'
      1 return.
    end.
    sdclose listener
    ADAPTER_CONN=: (<'plain'),(<infd)
  end.

  adapter_loop ''
  adapter_flush ADAPTER_FLUSH_MS
  ADAPTER_STATUS
)

exit adapter_main ''
