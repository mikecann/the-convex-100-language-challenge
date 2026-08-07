NB. live.ijs -- the Convex Live sync state machine: one WebSocket connection
NB. owned by a single pump loop, subscriptions that survive a reconnect by
NB. replaying their Add, Transition validation and application, exponential
NB. backoff that resets on a healthy transition, and a bounded delivery
NB. queue. The adapter (or an interactive caller) drives this by calling
NB. cx_live_pump repeatedly and draining cx_live_next_update between calls;
NB. nothing else touches the socket, matching every other single-owner
NB. client in this project.
NB.
NB. Subscriptions and queued deliveries are held in small boxed tables
NB. (parallel-row arrays, the same shape json.ijs uses for JSON object
NB. pairs) rather than an associative array, since J has no native map type.

load '/project/client/websocket.ijs'

NB. ---------------------------------------------------------------------------
NB. State
NB. ---------------------------------------------------------------------------

CX_LIVE_INITIAL_TS=: 'AAAAAAAAAAA='
CX_LIVE_INITIAL_BACKOFF_MS=: 100
CX_LIVE_MAX_BACKOFF_MS=: 15000
CX_LIVE_CONNECT_MS=: 10000
CX_LIVE_WRITE_MS=: 5000
CX_LIVE_MAX_SUBSCRIPTIONS=: 64
CX_LIVE_MAX_MESSAGE_BYTES=: 8388608 NB. 8 MiB per decoded message, well under the 128 MiB adapter ceiling
CX_LIVE_QUEUE_COUNT=: 16
CX_LIVE_QUEUE_BYTES=: 4194304

cx_live_reset=: 3 : 0
  CX_LIVE_CONN=: ''
  CX_LIVE_CONNECTED=: 0
  CX_LIVE_BUFFER=: ''
  CX_LIVE_FRAG_ACTIVE=: 0
  CX_LIVE_FRAG_OPCODE=: 0
  CX_LIVE_FRAG_PAYLOAD=: ''
  CX_LIVE_SESSION_ID=: tx_uuid ''
  CX_LIVE_CONNECTION_COUNT=: 0
  CX_LIVE_LAST_CLOSE=: 'InitialConnect'
  CX_LIVE_BACKOFF_MS=: CX_LIVE_INITIAL_BACKOFF_MS
  CX_LIVE_NEXT_CONNECT_MS=: 0
  CX_LIVE_NEXT_QUERY_ID=: 0
  CX_LIVE_QUERY_SET_VERSION=: 0
  CX_LIVE_REMOTE_QUERYSET=: 0
  CX_LIVE_REMOTE_IDENTITY=: 0
  CX_LIVE_REMOTE_TS=: CX_LIVE_INITIAL_TS
  CX_LIVE_MAX_OBSERVED_TS=: CX_LIVE_INITIAL_TS
  CX_SUBS=: 0 5 $ a: NB. rows: queryId, path, args(json text), tag, lastSignature
  CX_QUEUE=: 0 6 $ a: NB. rows: tag, value(json)/'' , logs(json), errName, errMessage, errData
  CX_QUEUE_DROPPED=: 0
  1
)

NB. ---------------------------------------------------------------------------
NB. Subscription table helpers
NB. ---------------------------------------------------------------------------

cx_subs_row_by_id=: 3 : 0
  qid=. y
  if. 0 = # CX_SUBS do. _1 return. end.
  idvals=. > 0 {"1 CX_SUBS  NB. all-number column opens cleanly with one >
  hit=. idvals i. qid
  if. hit = # idvals do. _1 return. end.
  hit
)

cx_subs_row_by_tag=: 3 : 0
  tag=. y
  if. 0 = # CX_SUBS do. _1 return. end.
  tags=. 3 {"1 CX_SUBS
  hit=. tags i. <tag
  if. hit = # tags do. _1 return. end.
  hit
)

NB. ---------------------------------------------------------------------------
NB. Wire message builders (Convex sync protocol JSON)
NB. ---------------------------------------------------------------------------

cx_live_connect_message=: 3 : 0
  msg=. '{"type":"Connect","sessionId":',(jw_quote CX_LIVE_SESSION_ID)
  msg=. msg,',"connectionCount":',(": CX_LIVE_CONNECTION_COUNT)
  msg=. msg,',"lastCloseReason":',(jw_quote CX_LIVE_LAST_CLOSE)
  msg=. msg,',"clientTs":0'
  if. -. CX_LIVE_MAX_OBSERVED_TS -: CX_LIVE_INITIAL_TS do.
    msg=. msg,',"maxObservedTimestamp":',jw_quote CX_LIVE_MAX_OBSERVED_TS
  end.
  msg,'}'
)

cx_live_add_json=: 3 : 0
  row=. y
  qid=. > 0 { row
  path=. > 1 { row
  args=. > 2 { row
  '{"type":"Add","queryId":',(": qid),',"udfPath":',(jw_quote path),',"args":[',args,']}'
)

cx_live_remove_json=: 3 : 0
  '{"type":"Remove","queryId":',(": y),'}'
)

NB. Send a ModifyQuerySet built from a boxed list of already-encoded
NB. modification JSON strings.
cx_live_modify=: 3 : 0
  mods=. y
  base=. CX_LIVE_QUERY_SET_VERSION
  parts=. 0 $ a:
  for_m. mods do. parts=. parts , m end.
  body=. '{"type":"ModifyQuerySet","baseVersion":',(": base),',"newVersion":',(": base+1)
  body=. body,',"modifications":['
  first=. 1
  for_p. parts do.
    if. -. first do. body=. body,',' end.
    body=. body, > p
    first=. 0
  end.
  body=. body,']}'
  deadline=. (tx_now_ms '') + CX_LIVE_WRITE_MS
  frame=. ws_encode_text a. i. body
  'wstatus wmsg'=. tx_send (<CX_LIVE_CONN),(<frame),(<tx_remaining deadline)
  if. wstatus ~: TX_IO_OK do.
    cx_live_retire 'TransportError';'Live write failed';1
    0 return.
  end.
  CX_LIVE_QUERY_SET_VERSION=: base + 1
  1
)

NB. ---------------------------------------------------------------------------
NB. Connection lifecycle
NB. ---------------------------------------------------------------------------

cx_live_retire=: 3 : 0
  'name message publish'=. y
  if. -. CX_LIVE_CONN -: '' do.
    tx_close CX_LIVE_CONN
    CX_LIVE_CONNECTION_COUNT=: CX_LIVE_CONNECTION_COUNT + 1
  end.
  CX_LIVE_CONN=: ''
  CX_LIVE_CONNECTED=: 0
  CX_LIVE_BUFFER=: ''
  CX_LIVE_FRAG_ACTIVE=: 0
  CX_LIVE_FRAG_PAYLOAD=: ''
  CX_LIVE_QUERY_SET_VERSION=: 0
  CX_LIVE_REMOTE_QUERYSET=: 0
  CX_LIVE_REMOTE_IDENTITY=: 0
  CX_LIVE_REMOTE_TS=: CX_LIVE_INITIAL_TS
  CX_LIVE_LAST_CLOSE=: (0 = # message) {:: message;'ClientClosed'
  CX_LIVE_NEXT_CONNECT_MS=: (tx_now_ms '') + CX_LIVE_BACKOFF_MS
  CX_LIVE_BACKOFF_MS=: CX_LIVE_MAX_BACKOFF_MS <. CX_LIVE_BACKOFF_MS * 2
  if. publish do.
    for_row. CX_SUBS do.
      tag=. > 3 { row
      cx_live_enqueue tag;'';'[]';name;message;'null'
    end.
  end.
  1
)

cx_live_connect=: 3 : 0
  deadline=. (tx_now_ms '') + CX_LIVE_CONNECT_MS
  'cstatus conn'=. cx_unpack2 (CX_HOST;CX_PORT;CX_SECURE) tx_connect tx_remaining deadline
  if. cstatus ~: TX_IO_OK do.
    CX_LIVE_CONNECTION_COUNT=: CX_LIVE_CONNECTION_COUNT + 1
    CX_LIVE_LAST_CLOSE=: conn
    CX_LIVE_NEXT_CONNECT_MS=: (tx_now_ms '') + CX_LIVE_BACKOFF_MS
    CX_LIVE_BACKOFF_MS=: CX_LIVE_MAX_BACKOFF_MS <. CX_LIVE_BACKOFF_MS * 2
    0 return.
  end.
  hparsed=. ws_handshake (<conn),(<deadline)
  hok=. > 0 { hparsed
  leftover=. > 1 { hparsed
  if. -. hok do.
    tx_close conn
    CX_LIVE_CONNECTION_COUNT=: CX_LIVE_CONNECTION_COUNT + 1
    CX_LIVE_LAST_CLOSE=: convex_error_message ''
    CX_LIVE_NEXT_CONNECT_MS=: (tx_now_ms '') + CX_LIVE_BACKOFF_MS
    CX_LIVE_BACKOFF_MS=: CX_LIVE_MAX_BACKOFF_MS <. CX_LIVE_BACKOFF_MS * 2
    0 return.
  end.
  CX_LIVE_CONN=: conn
  CX_LIVE_BUFFER=: leftover
  CX_LIVE_QUERY_SET_VERSION=: 0
  CX_LIVE_REMOTE_QUERYSET=: 0
  CX_LIVE_REMOTE_IDENTITY=: 0
  CX_LIVE_REMOTE_TS=: CX_LIVE_INITIAL_TS

  frame=. ws_encode_text a. i. cx_live_connect_message ''
  'wstatus wmsg'=. tx_send (<CX_LIVE_CONN),(<frame),(<tx_remaining deadline)
  if. wstatus ~: TX_IO_OK do.
    cx_live_retire 'TransportError';'Live connect write failed';0
    0 return.
  end.
  CX_LIVE_CONNECTION_COUNT=: CX_LIVE_CONNECTION_COUNT + 1

  if. 0 < # CX_SUBS do.
    mods=. 0 $ a:
    for_row. CX_SUBS do.
      mods=. mods , < cx_live_add_json row
    end.
    if. -. cx_live_modify mods do. 0 return. end.
  end.

  CX_LIVE_BACKOFF_MS=: CX_LIVE_INITIAL_BACKOFF_MS
  CX_LIVE_NEXT_CONNECT_MS=: 0
  CX_LIVE_CONNECTED=: 1
  1
)

cx_live_ensure=: 3 : 0
  if. -. CX_LIVE_CONN -: '' do. 1 return. end.
  if. (tx_now_ms '') < CX_LIVE_NEXT_CONNECT_MS do. 0 return. end.
  cx_live_connect ''
)

NB. ---------------------------------------------------------------------------
NB. Bounded delivery queue
NB. ---------------------------------------------------------------------------

cx_live_enqueue=: 3 : 0
  'tag value logs errname errmsg errdata'=. y
  size=. (#tag)+(#value)+(#logs)+(#errname)+(#errmsg)+(#errdata)+128
  if. size > CX_LIVE_QUEUE_BYTES do.
    CX_QUEUE_DROPPED=: CX_QUEUE_DROPPED + 1
    0 return.
  end.
  CX_QUEUE=: CX_QUEUE , 1 6 $ (<tag),(<value),(<logs),(<errname),(<errmsg),(<errdata)
  while. (CX_LIVE_QUEUE_COUNT < # CX_QUEUE) do.
    CX_QUEUE=: 1 }. CX_QUEUE
    CX_QUEUE_DROPPED=: CX_QUEUE_DROPPED + 1
  end.
  qbytes=. 0
  for_row. CX_QUEUE do.
    qbytes=. qbytes + (#>0{row)+(#>1{row)+(#>2{row)+(#>3{row)+(#>4{row)+(#>5{row)+128
  end.
  while. (qbytes > CX_LIVE_QUEUE_BYTES) *. (0 < # CX_QUEUE) do.
    r0=. 0 { CX_QUEUE
    qbytes=. qbytes - ((#>0{r0)+(#>1{r0)+(#>2{r0)+(#>3{r0)+(#>4{r0)+(#>5{r0)+128)
    CX_QUEUE=: 1 }. CX_QUEUE
    CX_QUEUE_DROPPED=: CX_QUEUE_DROPPED + 1
  end.
  1
)

NB. Pop the oldest queued delivery. Result is (<ok),(<tag),(<value),
NB. (<logs),(<errname),(<errmsg),(<errdata).
cx_live_next_update=: 3 : 0
  if. 0 = # CX_QUEUE do. (<0),(<''),(<''),(<''),(<''),(<''),(<'') return. end.
  NB. row's own cells are already single boxes (the same row shape
  NB. cx_http_headers' rows use), so they join the result as-is -- wrapping
  NB. them in another `<` here would double-box every field.
  row=. 0 { CX_QUEUE
  CX_QUEUE=: 1 }. CX_QUEUE
  (<1),(0{row),(1{row),(2{row),(3{row),(4{row),(5{row)
)

NB. ---------------------------------------------------------------------------
NB. Subscribe / unsubscribe
NB. ---------------------------------------------------------------------------

NB. y is (<tag),(<path),(<argsjson). Result is (<ok).
cx_live_subscribe=: 3 : 0
  tag=. > 0 { y
  path=. > 1 { y
  args=. > 2 { y
  existing=. cx_subs_row_by_tag tag
  if. existing ~: _1 do.
    cx_live_unsubscribe tag
  end.
  if. CX_LIVE_MAX_SUBSCRIPTIONS <: # CX_SUBS do.
    (cx_fail 'ProtocolError';'Live subscription capacity exceeded') ] (0) return.
  end.
  qid=. CX_LIVE_NEXT_QUERY_ID
  CX_LIVE_NEXT_QUERY_ID=: CX_LIVE_NEXT_QUERY_ID + 1
  row=. 1 5 $ (<qid),(<path),(<args),(<tag),(<'')
  CX_SUBS=: CX_SUBS , row

  if. CX_LIVE_CONN -: '' do.
    if. -. cx_live_ensure '' do.
      (cx_fail 'TransportError';'Live connection failed: ',CX_LIVE_LAST_CLOSE) ] (1) return.
    end.
    1 return.
  end.
  if. -. cx_live_modify < cx_live_add_json 0 { row do. 1 return. end.
  1
)

NB. y is tag. Removes the subscription and any of its queued deliveries;
NB. sends Remove only if connected. Result is always 1 (best-effort by
NB. design, matching every other client in this repository: an unsubscribe
NB. against a connection that is mid-retirement still forgets the local
NB. state cleanly).
cx_live_unsubscribe=: 3 : 0
  tag=. y
  hit=. cx_subs_row_by_tag tag
  if. hit = _1 do. 1 return. end.
  qid=. > 0 { hit { CX_SUBS
  keeprows=. 0 5 $ a:
  n=. # CX_SUBS
  i=. 0
  while. i < n do.
    if. i ~: hit do. keeprows=. keeprows , 1 5 $ i { CX_SUBS end.
    i=. i + 1
  end.
  CX_SUBS=: keeprows
  purged=. 0 6 $ a:
  for_row. CX_QUEUE do.
    if. -. (> 0 { row) -: tag do.
      purged=. purged , 1 6 $ row
    end.
  end.
  CX_QUEUE=: purged
  if. -. CX_LIVE_CONN -: '' do.
    cx_live_modify < cx_live_remove_json qid
  end.
  1
)

cx_live_debug_disconnect=: 3 : 0
  if. CX_LIVE_CONN -: '' do.
    (cx_fail 'TransportError';'Live WebSocket is not connected') ] (0) return.
  end.
  cx_live_retire 'DebugDisconnect';'DebugDisconnect';0
  1
)

cx_live_close=: 3 : 0
  budget_ms=. y
  if. -. CX_LIVE_CONN -: '' do.
    deadline=. (tx_now_ms '') + budget_ms
    closeframe=. ws_encode_close 1000
    tx_send (<CX_LIVE_CONN),(<closeframe),(<tx_remaining deadline)
    tx_close CX_LIVE_CONN
  end.
  CX_LIVE_CONN=: ''
  CX_LIVE_CONNECTED=: 0
  CX_SUBS=: 0 5 $ a:
  CX_QUEUE=: 0 6 $ a:
  1
)

NB. ---------------------------------------------------------------------------
NB. Timestamp comparison
NB.
NB. Convex sync timestamps are base64-encoded little-endian unsigned 64-bit
NB. values. They are compared byte by byte from the most significant byte
NB. down rather than converted to one J number, so a 64-bit value nowhere
NB. near J's exact-integer range never loses a bit of precision.
NB. ---------------------------------------------------------------------------

cx_live_ts_greater=: 3 : 0
  'a b'=. y
  abytes=. tx_base64_decode a
  bbytes=. tx_base64_decode b
  result=. 0
  done=. 0
  i=. 7
  while. (i >: 0) *. (-. done) do.
    if. (i { abytes) > (i { bbytes) do.
      result=. 1
      done=. 1
    elseif. (i { abytes) < (i { bbytes) do.
      result=. 0
      done=. 1
    end.
    i=. i - 1
  end.
  result
)

NB. ---------------------------------------------------------------------------
NB. Transition validation and application
NB. ---------------------------------------------------------------------------

NB. Parse a {querySet,identity,ts} state-version object. Result is
NB. (<ok),(<querySet),(<identity),(<ts).
cx_live_parse_version=: 3 : 0
  node=. y
  if. -. 'o' -: jtag node do. (<0),(<0),(<0),(<'') return. end.
  qsnode=. node jfind 'querySet'
  idnode=. node jfind 'identity'
  tsnode=. node jfind 'ts'
  if. qsnode = _1 do. (<0),(<0),(<0),(<'') return. end.
  if. idnode = _1 do. (<0),(<0),(<0),(<'') return. end.
  if. tsnode = _1 do. (<0),(<0),(<0),(<'') return. end.
  if. -. 'n' -: jtag > qsnode do. (<0),(<0),(<0),(<'') return. end.
  if. -. 'n' -: jtag > idnode do. (<0),(<0),(<0),(<'') return. end.
  if. -. 's' -: jtag > tsnode do. (<0),(<0),(<0),(<'') return. end.
  qslit=. jpay > qsnode
  idlit=. jpay > idnode
  if. -. convex_integral qslit do. (<0),(<0),(<0),(<'') return. end.
  if. -. convex_integral idlit do. (<0),(<0),(<0),(<'') return. end.
  (<1),(<(". qslit)),(<(". idlit)),(<(jpay > tsnode))
)

cx_live_valid_logs=: 3 : 0
  node=. y
  if. node = _1 do. 1 return. end.
  if. -. 'a' -: jtag > node do. 0 return. end.
  items=. jpay > node
  for_item. items do.
    if. -. 's' -: jtag > item do. 0 return. end.
  end.
  1
)

cx_live_valid_modification=: 3 : 0
  mod=. y
  if. -. 'o' -: jtag mod do. 0 return. end.
  typenode=. mod jfind 'type'
  qidnode=. mod jfind 'queryId'
  if. typenode = _1 do. 0 return. end.
  if. qidnode = _1 do. 0 return. end.
  if. -. 's' -: jtag > typenode do. 0 return. end.
  if. -. 'n' -: jtag > qidnode do. 0 return. end.
  qidlit=. jpay > qidnode
  if. -. convex_integral qidlit do. 0 return. end.
  kind=. jpay > typenode
  if. kind -: 'QueryUpdated' do.
    valnode=. mod jfind 'value'
    if. valnode = _1 do. 0 return. end.
    logsnode=. mod jfind 'logLines'
    cx_live_valid_logs logsnode return.
  end.
  if. kind -: 'QueryFailed' do.
    msgnode=. mod jfind 'errorMessage'
    if. msgnode = _1 do. 0 return. end.
    if. -. 's' -: jtag > msgnode do. 0 return. end.
    logsnode=. mod jfind 'logLines'
    cx_live_valid_logs logsnode return.
  end.
  kind -: 'QueryRemoved'
)

NB. Replace CX_SUBS row `rowidx`'s dedup signature (column 4) with `sig`,
NB. by rebuilding the table rather than a multi-axis Amend -- keeping the
NB. same explicit-index-rebuild shape already proven for unsubscribe.
cx_live_set_signature=: 4 : 0
  rowidx=. x
  sig=. y
  row=. rowidx { CX_SUBS
  newrow=. (0 { row),(1 { row),(2 { row),(3 { row),(< sig)
  n=. # CX_SUBS
  out=. 0 5 $ a:
  i=. 0
  while. i < n do.
    if. i = rowidx do.
      out=. out , 1 5 $ newrow
    else.
      out=. out , 1 5 $ i { CX_SUBS
    end.
    i=. i + 1
  end.
  CX_SUBS=: out
  1
)

NB. Apply one already-validated modification: look up its local
NB. subscription (a modification for a query this client never asked for,
NB. or already removed, is valid protocol traffic to ignore), compute the
NB. delivered value or structured error, suppress a repeat of the same
NB. value (what makes reconnect rehydration silent), and enqueue.
cx_live_apply_modification=: 3 : 0
  mod=. y
  typenode=. mod jfind 'type'
  qidnode=. mod jfind 'queryId'
  kind=. jpay > typenode
  qid=. ". jpay > qidnode
  rowidx=. cx_subs_row_by_id qid
  if. rowidx = _1 do. 1 return. end.
  row=. rowidx { CX_SUBS
  tag=. > 3 { row

  if. kind -: 'QueryRemoved' do. 1 return. end.

  logsnode=. mod jfind 'logLines'
  logsjson=. '[]'
  if. logsnode ~: _1 do. logsjson=. cx_json_encode > logsnode end.

  if. kind -: 'QueryUpdated' do.
    valnode=. mod jfind 'value'
    valuejson=. cx_json_encode > valnode
    sig=. 'V', valuejson
    if. sig -: > 4 { row do. 1 return. end.
    rowidx cx_live_set_signature sig
    cx_live_enqueue tag;valuejson;logsjson;'';'';''
    1 return.
  end.

  if. kind -: 'QueryFailed' do.
    msgnode=. mod jfind 'errorMessage'
    datanode=. mod jfind 'errorData'
    msg=. jpay > msgnode
    datajson=. 'null'
    if. datanode ~: _1 do. datajson=. cx_json_encode > datanode end.
    sig=. 'F', msg, datajson
    if. sig -: > 4 { row do. 1 return. end.
    rowidx cx_live_set_signature sig
    cx_live_enqueue tag;'';logsjson;'FunctionError';msg;datajson
    1 return.
  end.
  1
)

cx_live_transition=: 3 : 0
  root=. y
  startnode=. root jfind 'startVersion'
  endnode=. root jfind 'endVersion'
  if. startnode = _1 do.
    cx_live_retire 'ProtocolError';'Transition omitted startVersion';1
    0 return.
  end.
  if. endnode = _1 do.
    cx_live_retire 'ProtocolError';'Transition omitted endVersion';1
    0 return.
  end.
  'sok sqs sid sts'=. cx_live_parse_version > startnode
  if. -. sok do.
    cx_live_retire 'ProtocolError';'Transition has an invalid startVersion';1
    0 return.
  end.
  'eok eqs eid ets'=. cx_live_parse_version > endnode
  if. -. eok do.
    cx_live_retire 'ProtocolError';'Transition has an invalid endVersion';1
    0 return.
  end.
  if. sqs ~: CX_LIVE_REMOTE_QUERYSET do.
    cx_live_retire 'ProtocolError';'Transition start version does not match the local version';1
    0 return.
  end.
  if. sid ~: CX_LIVE_REMOTE_IDENTITY do.
    cx_live_retire 'ProtocolError';'Transition start version does not match the local version';1
    0 return.
  end.
  if. -. sts -: CX_LIVE_REMOTE_TS do.
    cx_live_retire 'ProtocolError';'Transition start version does not match the local version';1
    0 return.
  end.

  modsnode=. root jfind 'modifications'
  if. modsnode = _1 do.
    cx_live_retire 'ProtocolError';'Transition omitted modifications';1
    0 return.
  end.
  modsnode=. > modsnode
  if. -. 'a' -: jtag modsnode do.
    cx_live_retire 'ProtocolError';'Transition modifications must be an array';1
    0 return.
  end.
  mods=. jpay modsnode

  NB. Validate every modification before applying any of them, so a
  NB. rejected Transition can never publish half of itself.
  for_m. mods do.
    if. -. cx_live_valid_modification > m do.
      cx_live_retire 'ProtocolError';'Transition modification is malformed';1
      0 return.
    end.
  end.

  CX_LIVE_REMOTE_QUERYSET=: eqs
  CX_LIVE_REMOTE_IDENTITY=: eid
  CX_LIVE_REMOTE_TS=: ets
  if. cx_live_ts_greater ets;CX_LIVE_MAX_OBSERVED_TS do.
    CX_LIVE_MAX_OBSERVED_TS=: ets
  end.

  for_m. mods do.
    cx_live_apply_modification > m
  end.

  CX_LIVE_BACKOFF_MS=: CX_LIVE_INITIAL_BACKOFF_MS
  1
)

cx_live_report_server_error=: 3 : 0
  'kind payload'=. y
  errnode=. payload jfind 'error'
  errtext=. kind
  if. errnode ~: _1 do.
    if. 's' -: jtag > errnode do.
      errtext=. jpay > errnode
    end.
  end.
  cx_live_retire 'ProtocolError';'Live server reported ',kind,': ',errtext;1
  0
)

cx_live_handle_message=: 3 : 0
  text=. y
  'pok payload'=. cx_unpack2 cx_json_parse text
  if. -. pok do.
    cx_live_retire 'ProtocolError';'Live message is not valid JSON';1
    0 return.
  end.
  if. -. 'o' -: jtag payload do.
    cx_live_retire 'ProtocolError';'Live message is not a JSON object';1
    0 return.
  end.
  typenode=. payload jfind 'type'
  if. typenode = _1 do.
    cx_live_retire 'ProtocolError';'Live message has no type';1
    0 return.
  end.
  if. -. 's' -: jtag > typenode do.
    cx_live_retire 'ProtocolError';'Live message has no type';1
    0 return.
  end.
  kind=. jpay > typenode
  if. kind -: 'Transition' do.
    cx_live_transition payload return.
  end.
  if. kind -: 'Ping' do.
    CX_LIVE_BACKOFF_MS=: CX_LIVE_INITIAL_BACKOFF_MS
    1 return.
  end.
  if. kind -: 'MutationResponse' do.
    CX_LIVE_BACKOFF_MS=: CX_LIVE_INITIAL_BACKOFF_MS
    1 return.
  end.
  if. kind -: 'ActionResponse' do.
    CX_LIVE_BACKOFF_MS=: CX_LIVE_INITIAL_BACKOFF_MS
    1 return.
  end.
  if. kind -: 'FatalError' do. cx_live_report_server_error kind;payload return. end.
  if. kind -: 'AuthError' do. cx_live_report_server_error kind;payload return. end.
  cx_live_retire 'ProtocolError';'unsupported Live server message: ',kind;1
  0
)

NB. ---------------------------------------------------------------------------
NB. The pump: one budgeted slice of the Live owner's work. Connects (or
NB. waits out backoff) when there is no socket, otherwise reads and
NB. dispatches at most as many frames as fit in the budget. Every branch
NB. that ends the connection returns through cx_live_retire, which is the
NB. single place backoff, subscription rehydration flags, and queued
NB. TransportError/ProtocolError delivery are decided.
NB. ---------------------------------------------------------------------------

cx_live_pump=: 3 : 0
  budget_ms=. y
  deadline=. (tx_now_ms '') + budget_ms
  while. 1 do.
    if. CX_LIVE_CONN -: '' do.
      if. 0 = # CX_SUBS do. 1 return. end.
      if. (tx_now_ms '') < CX_LIVE_NEXT_CONNECT_MS do. 1 return. end.
      if. -. cx_live_connect '' do. 1 return. end.
    end.

    remaining=. tx_remaining deadline
    if. remaining = 0 do. 1 return. end.

    'rstatus rbuffer rfin ropcode rpayload'=. ws_read_frame (<CX_LIVE_CONN),(<CX_LIVE_BUFFER),(<deadline)
    CX_LIVE_BUFFER=: rbuffer
    if. rstatus = WS_IO_TIMEOUT do. 1 return. end.
    if. rstatus = WS_IO_EOF do.
      cx_live_retire 'TransportError';'the deployment closed the WebSocket';1
      1 return.
    end.
    if. rstatus = WS_IO_PROTOCOL do.
      cx_live_retire 'ProtocolError';'received a masked frame from the server';1
      1 return.
    end.
    if. rstatus ~: WS_IO_OK do.
      cx_live_retire 'TransportError';'Live read failed';1
      1 return.
    end.

    if. ropcode = WS_OP_PING do.
      pong=. ws_encode_frame (<WS_OP_PONG),(<rpayload)
      'wstatus wmsg'=. tx_send (<CX_LIVE_CONN),(<pong),(<tx_remaining deadline)
      if. wstatus ~: TX_IO_OK do.
        cx_live_retire 'TransportError';'pong write failed';1
      end.
      continue.
    end.
    if. ropcode = WS_OP_PONG do. continue. end.
    if. ropcode = WS_OP_CLOSE do.
      cx_live_retire 'TransportError';'the deployment closed the WebSocket';1
      1 return.
    end.

    if. ropcode = WS_OP_CONT do.
      if. -. CX_LIVE_FRAG_ACTIVE do.
        cx_live_retire 'ProtocolError';'unexpected continuation frame';1
        1 return.
      end.
      CX_LIVE_FRAG_PAYLOAD=: CX_LIVE_FRAG_PAYLOAD , rpayload
    elseif. (ropcode = WS_OP_TEXT) +. ropcode = WS_OP_BINARY do.
      if. CX_LIVE_FRAG_ACTIVE do.
        cx_live_retire 'ProtocolError';'expected a continuation frame';1
        1 return.
      end.
      CX_LIVE_FRAG_ACTIVE=: 1
      CX_LIVE_FRAG_OPCODE=: ropcode
      CX_LIVE_FRAG_PAYLOAD=: rpayload
    else.
      cx_live_retire 'ProtocolError';'unsupported WebSocket opcode';1
      1 return.
    end.

    if. (# CX_LIVE_FRAG_PAYLOAD) > CX_LIVE_MAX_MESSAGE_BYTES do.
      cx_live_retire 'ProtocolError';'Live message exceeds the size limit';1
      1 return.
    end.

    if. rfin do.
      CX_LIVE_FRAG_ACTIVE=: 0
      msgopcode=. CX_LIVE_FRAG_OPCODE
      msgpayload=. CX_LIVE_FRAG_PAYLOAD
      CX_LIVE_FRAG_PAYLOAD=: ''
      if. msgopcode ~: WS_OP_TEXT do.
        cx_live_retire 'ProtocolError';'binary Live messages are unsupported';1
        1 return.
      end.
      if. -. ws_utf8_valid msgpayload do.
        cx_live_retire 'ProtocolError';'Live text message is not valid UTF-8';1
        1 return.
      end.
      cx_live_handle_message a. {~ msgpayload
    end.
  end.
)
