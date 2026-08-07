NB. convex.ijs -- the native Convex client: deployment URL handling, the
NB. documented JSON HTTP envelope (query/mutation/action), and the small
NB. framing helpers HTTP needs (status line, headers, chunked bodies).
NB. Live (WebSocket sync) lives in live.ijs, loaded separately, and reuses
NB. these same HTTP framing verbs for its upgrade handshake.
NB.
NB. Every string here is a raw byte string (one J character per byte, same
NB. discipline as json.ijs): HTTP headers and status lines are ASCII, and a
NB. JSON body's own bytes pass straight from the socket to the JSON reader
NB. with no re-encoding step, so nothing here can corrupt UTF-8 content it
NB. never decoded in the first place.

load '/project/client/json.ijs'
load '/project/client/transport.ijs'

CR=: 13 { a.
LF=: 10 { a.
CRLF=: CR , LF

NB. ---------------------------------------------------------------------------
NB. Client state
NB.
NB. One client per process, held in globals -- the adapter and the example
NB. each open exactly one, so this mirrors the single-owner design the rest
NB. of the project's interpreted clients use instead of threading a handle
NB. through every call.
NB. ---------------------------------------------------------------------------

CX_URL=: ''
CX_HOST=: ''
CX_PORT=: 0
CX_SECURE=: 0
CX_HOST_HEADER=: ''
CX_TOKEN=: ''
CX_CLIENT_VERSION=: ''
CX_ERROR_NAME=: ''
CX_ERROR_MESSAGE=: ''
CX_ERROR_DATA=: 'null'
CX_HTTP_CONNECT_MS=: 10000
CX_HTTP_TOTAL_MS=: 30000
CX_HTTP_MAX_HEADERS=: 65536
CX_HTTP_MAX_BODY=: 2097152

cx_fail=: 3 : 0
  'name message'=. y
  CX_ERROR_NAME=: name
  CX_ERROR_MESSAGE=: message
  CX_ERROR_DATA=: 'null'
  0
)

convex_error_name=: 3 : 0
  CX_ERROR_NAME
)
convex_error_message=: 3 : 0
  CX_ERROR_MESSAGE
)
convex_error_data=: 3 : 0
  CX_ERROR_DATA
)

NB. ---------------------------------------------------------------------------
NB. Deployment URL parsing. http(s)://host[:port], no path, no userinfo,
NB. no query string -- the documented shape of a Convex deployment URL.
NB. ---------------------------------------------------------------------------

cx_is_hostchar=: (('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-.') e.~ ])

cx_parse_url=: 3 : 0
  url=. y
  if. 8 <: # url do.
    if. 'https://' -: 8 {. url do.
      secure=. 1
      rest=. 8 }. url
    elseif. (7 <: #url) *. 'http://' -: 7 {. url do.
      secure=. 0
      rest=. 7 }. url
    else.
      cx_fail 'ConfigError';'deployment URL must start with http:// or https://'
      _1;0;'';0 return.
    end.
  else.
    cx_fail 'ConfigError';'deployment URL must start with http:// or https://'
    _1;0;'';0 return.
  end.
  if. 1 e. rest e. '@?#' do.
    cx_fail 'ConfigError';'deployment URL must not contain userinfo, a query, or a fragment'
    _1;0;'';0 return.
  end.
  slash=. rest i. '/'
  if. slash < # rest do.
    authority=. slash {. rest
    suffix=. slash }. rest
    if. -. suffix -: '/' do.
      cx_fail 'ConfigError';'deployment URL must not contain a path'
      _1;0;'';0 return.
    end.
  else.
    authority=. rest
  end.
  if. 0 = # authority do.
    cx_fail 'ConfigError';'deployment URL has no host'
    _1;0;'';0 return.
  end.
  colon=. authority i: ':'
  if. colon < # authority do.
    host=. colon {. authority
    portstr=. (colon+1) }. authority
    if. (0 = # portstr) +. -. *./ portstr e. '0123456789' do.
      cx_fail 'ConfigError';'deployment URL port is invalid'
      _1;0;'';0 return.
    end.
    port=. ". portstr
    if. (port < 1) +. port > 65535 do.
      cx_fail 'ConfigError';'deployment URL port is invalid'
      _1;0;'';0 return.
    end.
  else.
    host=. authority
    port=. secure {:: 80;443
  end.
  if. 0 = # host do.
    cx_fail 'ConfigError';'deployment URL has no host'
    _1;0;'';0 return.
  end.
  if. -. *./ cx_is_hostchar host do.
    cx_fail 'ConfigError';'deployment URL host is invalid'
    _1;0;'';0 return.
  end.
  hostheader=. host
  if. (secure *. port ~: 443) +. (-.secure) *. port ~: 80 do.
    hostheader=. host , ':' , ": port
  end.
  0;secure;host;port;hostheader
)

convex_open=: 3 : 0
  'url version'=. y
  parsed=. cx_parse_url url
  if. 0 ~: > 0 { parsed do. 0 return. end.
  CX_URL=: url
  CX_SECURE=: > 1 { parsed
  CX_HOST=: > 2 { parsed
  CX_PORT=: > 3 { parsed
  CX_HOST_HEADER=: > 4 { parsed
  CX_CLIENT_VERSION=: (0 = # version) {:: version;'j-0.1.0'
  CX_TOKEN=: ''
  1
)

convex_set_auth=: 3 : 0
  CX_TOKEN=: y
  1
)

NB. ---------------------------------------------------------------------------
NB. HTTP framing over a tx_connect/tx_send/tx_recv connection. Buffers are
NB. plain character strings (one J char per byte); transport.ijs's
NB. byte-value lists are converted at exactly this boundary.
NB. ---------------------------------------------------------------------------

NB. Find the first occurrence of `needle` in `haystack` at or after `start`,
NB. or the haystack length if absent (so callers can compare against #buffer
NB. instead of a separate "not found" sentinel).
cx_find=: 4 : 0
  'needle start'=. y
  hay=. start }. x
  hit=. needle (I.@E.) hay
  if. 0 = # hit do. # x return. end.
  start + {. hit
)

NB. Read from `conn` into `buffer` until it holds at least one occurrence of
NB. `needle`, bounded by `deadline`. Result is (<ok),(<buffer),(<matchpos).
NB. y is (<conn),(<needle),(<buffer),(<deadline),(<maxlen); conn (a
NB. multi-item connection record) is pulled out with an explicit index
NB. rather than multi-name assignment for the reason noted on tx_send.
cx_read_until=: 3 : 0
  conn=. > 0 { y
  'needle buffer deadline maxlen'=. 1 }. y
  while. 1 do.
    at=. buffer cx_find needle;0
    if. at < # buffer do. (<1),(<buffer),(<at) return. end.
    if. (# buffer) > maxlen do.
      cx_fail 'ProtocolError';'HTTP response header exceeds the response limit'
      (<0),(<buffer),(<0) return.
    end.
    remaining=. tx_remaining deadline
    if. remaining = 0 do.
      cx_fail 'TransportError';'timed out reading the HTTP response'
      (<0),(<buffer),(<0) return.
    end.
    'status payload'=. tx_recv (<conn),(<16384),(<remaining)
    if. status = TX_IO_TIMEOUT do. continue. end.
    if. status = TX_IO_EOF do.
      cx_fail 'TransportError';'the deployment closed the connection before responding'
      (<0),(<buffer),(<0) return.
    end.
    if. status ~: TX_IO_OK do.
      cx_fail 'TransportError';'response read failed'
      (<0),(<buffer),(<0) return.
    end.
    buffer=. buffer , a. {~ payload
  end.
)

NB. Read exactly `need` more bytes into `buffer` (which may already hold
NB. some of them), bounded by `deadline`. y is (<conn),(<need),(<buffer),
NB. (<deadline).
cx_read_atleast=: 3 : 0
  conn=. > 0 { y
  'need buffer deadline'=. 1 }. y
  while. (# buffer) < need do.
    remaining=. tx_remaining deadline
    if. remaining = 0 do.
      cx_fail 'TransportError';'timed out reading the HTTP response body'
      (<0),(<buffer) return.
    end.
    'status payload'=. tx_recv (<conn),(<16384),(<remaining)
    if. status = TX_IO_TIMEOUT do. continue. end.
    if. status = TX_IO_EOF do.
      cx_fail 'TransportError';'the deployment closed the connection before the body completed'
      (<0),(<buffer) return.
    end.
    if. status ~: TX_IO_OK do.
      cx_fail 'TransportError';'response read failed'
      (<0),(<buffer) return.
    end.
    buffer=. buffer , a. {~ payload
  end.
  (<1),(<buffer)
)

NB. Unpack the 2-item (<a),(<b) results tx_send/tx_recv/etc return.
NB. Unpack a (<a),(<b) pair for multi-name assignment. Built with explicit
NB. boxing and catenate rather than Link (`;`): Link re-boxes an
NB. already-boxed atom but splices an already-boxed multi-item array (a
NB. connection record, for instance), so a bare `(>0{y);>1{y` would silently
NB. flatten whenever the second item was itself a compound value.
cx_unpack2=: 3 : 0
  (< > 0 { y),(< > 1 { y)
)

NB. `*.`/`+.` are not short-circuit, so each length-dependent check is its
NB. own `if.` guard here rather than one combined boolean expression --
NB. indexing position 7 or 8 of a too-short line would otherwise throw an
NB. index error before the length check ever had a chance to reject it.
cx_http_status=: 3 : 0
  line=. y
  cr=. line i. CR
  line=. cr {. line
  if. 12 > # line do.
    (cx_fail 'ProtocolError';'HTTP status line is invalid') ] (_1) return.
  end.
  if. -. 'HTTP/1.' -: 7 {. line do.
    (cx_fail 'ProtocolError';'HTTP status line is invalid') ] (_1) return.
  end.
  if. -. (7 { line) e. '01' do.
    (cx_fail 'ProtocolError';'HTTP status line is invalid') ] (_1) return.
  end.
  if. -. (8 { line) = ' ' do.
    (cx_fail 'ProtocolError';'HTTP status line is invalid') ] (_1) return.
  end.
  codestr=. 3 {. 9 }. line
  if. -. *./ codestr e. '0123456789' do.
    (cx_fail 'ProtocolError';'HTTP status code is invalid') ] (_1) return.
  end.
  ". codestr
)

NB. Parse a CRLF-separated header block (not including the status line) into
NB. an n-by-2 array of (lowercased-name, value) rows, matching json.ijs's
NB. object-pairs shape so the same jfind-style lookup works on it.
NB. Result is (<ok),(<rows) -- rows is itself a boxed-cell array, so it is
NB. wrapped explicitly with `<` and joined with catenate rather than Link:
NB. Link splices an already-boxed multi-item array instead of keeping it as
NB. one cell, which would have handed a caller `ok` followed by rows's own
NB. entries flattened into the result instead of the pair it expects.
cx_http_headers=: 3 : 0
  block=. y
  rows=. 0 2 $ a:
  if. 0 = # block do. (<1),(<rows) return. end.
  lines=. cx_split_crlf block
  for_line. lines do.
    line=. > line
    if. 0 = # line do. continue. end.
    if. (line {~ 0) e. ' ',TAB do.
      cx_fail 'ProtocolError';'folded HTTP headers are not supported'
      (<0),(<rows) return.
    end.
    colon=. line i. ':'
    if. colon >: # line do.
      cx_fail 'ProtocolError';'HTTP header line is malformed'
      (<0),(<rows) return.
    end.
    name=. cx_lower colon {. line
    value=. cx_trim (colon+1) }. line
    rows=. rows , 1 2 $ (<name),(<value)
  end.
  (<1),(<rows)
)

cx_split_crlf=: 3 : 0
  text=. y
  out=. 0 $ a:
  start=. 0
  while. start <: # text do.
    at=. text cx_find CRLF;start
    NB. cx_find returns an absolute position; the line itself is that many
    NB. bytes past `start`, not `at` bytes into the already-shifted tail.
    out=. out , < (at - start) {. start }. text
    if. at >: # text do. start=. (#text) + 1 else. start=. at + 2 end.
  end.
  out
)

NB. Lowercase every ASCII uppercase letter, leaving everything else as-is.
NB. `up i. y` gives 26 (out of bounds for `lo`) at every non-uppercase
NB. position, so those indices are clamped before indexing and only the
NB. genuinely-uppercase positions are amended into the result.
cx_lower=: 3 : 0
  up=. 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  lo=. 'abcdefghijklmnopqrstuvwxyz'
  hits=. up i. y
  mask=. hits < 26
  safe=. 25 <. hits
  lowered=. lo {~ safe
  idx=. I. mask
  (lowered {~ idx) (idx }) y
)

NB. Sequential `if.`/`break.` rather than one combined `(0<#text)*.(...)`
NB. condition: `*.` evaluates both sides unconditionally, and indexing an
NB. empty string once the length guard alone would have stopped the loop is
NB. exactly the index-error trap json.ijs's jp_peek works around.
cx_trim=: 3 : 0
  text=. y
  ws=. ' ',TAB
  while. 1 do.
    if. 0 = # text do. break. end.
    if. -. (0 { text) e. ws do. break. end.
    text=. }. text
  end.
  while. 1 do.
    if. 0 = # text do. break. end.
    if. -. ({: text) e. ws do. break. end.
    text=. }: text
  end.
  text
)

cx_header_find=: 4 : 0
  rows=. x
  if. 0 = # rows do. '' return. end.
  keys=. 0 {"1 rows
  hit=. keys i. <y
  if. hit = # keys do. '' return. end.
  > 1 { hit { rows
)

cx_header_present=: 4 : 0
  rows=. x
  if. 0 = # rows do. 0 return. end.
  keys=. 0 {"1 rows
  hit=. keys i. <y
  hit < # keys
)

NB. ---------------------------------------------------------------------------
NB. One request/response exchange against the documented JSON HTTP API.
NB. Result is ok;response where response is value;logs on success or
NB. name;message;data;logs on failure -- see cx_call for the full contract.
NB. ---------------------------------------------------------------------------

cx_http_request=: 3 : 0
  'method path body'=. y
  deadline=. (tx_now_ms '') + CX_HTTP_TOTAL_MS
  connect_budget=. CX_HTTP_CONNECT_MS <. tx_remaining deadline
  'cstatus conn'=. cx_unpack2 (CX_HOST;CX_PORT;CX_SECURE) tx_connect connect_budget
  if. cstatus ~: TX_IO_OK do.
    cx_fail 'TransportError';conn
    0;0;'' return.
  end.

  request=. method,' ',path,' HTTP/1.1',CRLF
  request=. request,'Host: ',CX_HOST_HEADER,CRLF
  request=. request,'Content-Type: application/json',CRLF
  request=. request,'Accept: application/json',CRLF
  request=. request,'Connection: close',CRLF
  request=. request,'Convex-Client: ',CX_CLIENT_VERSION,CRLF
  if. 0 < # CX_TOKEN do.
    request=. request,'Authorization: Bearer ',CX_TOKEN,CRLF
  end.
  request=. request,'Content-Length: ',(": #body),CRLF,CRLF,body

  'wstatus wmsg'=. cx_unpack2 tx_send (<conn),(<(a. i. request)),(<tx_remaining deadline)
  if. wstatus ~: TX_IO_OK do.
    tx_close conn
    cx_fail 'TransportError';'request write failed'
    0;0;'' return.
  end.

  'ok buffer headerend'=. cx_read_until (<conn),(<(CRLF,CRLF)),(<''),(<deadline),(<CX_HTTP_MAX_HEADERS)
  if. -. ok do. (tx_close conn) ] (0;0;'') return. end.
  status=. cx_http_status buffer
  if. status < 0 do. (tx_close conn) ] (0;0;'') return. end.
  statuslineend=. buffer cx_find CRLF;0
  hparsed=. cx_http_headers (statuslineend + 2) }. headerend {. buffer
  hok=. > 0 { hparsed
  headers=. > 1 { hparsed
  if. -. hok do. (tx_close conn) ] (0;0;'') return. end.
  buffer=. (headerend + 4) }. buffer

  has_len=. headers cx_header_present 'content-length'
  has_chunked=. headers cx_header_present 'transfer-encoding'
  if. has_len *. has_chunked do.
    tx_close conn
    cx_fail 'ProtocolError';'HTTP response has both Transfer-Encoding and Content-Length'
    0;0;'' return.
  end.

  if. has_chunked do.
    encoding=. cx_lower headers cx_header_find 'transfer-encoding'
    if. -. encoding -: 'chunked' do.
      tx_close conn
      cx_fail 'ProtocolError';'HTTP response uses an unsupported transfer encoding'
      0;0;'' return.
    end.
    'bok body'=. cx_read_chunked (<conn),(<buffer),(<deadline)
    tx_close conn
    if. -. bok do. 0;0;'' return. end.
  elseif. has_len do.
    lenstr=. headers cx_header_find 'content-length'
    if. (0 = #lenstr) +. -. *./ lenstr e. '0123456789' do.
      tx_close conn
      cx_fail 'ProtocolError';'HTTP Content-Length is invalid'
      0;0;'' return.
    end.
    length=. ". lenstr
    if. length > CX_HTTP_MAX_BODY do.
      tx_close conn
      cx_fail 'ProtocolError';'HTTP body exceeds the response limit'
      0;0;'' return.
    end.
    'bok buffer'=. cx_read_atleast (<conn),(<length),(<buffer),(<deadline)
    tx_close conn
    if. -. bok do. 0;0;'' return. end.
    body=. length {. buffer
  else.
    'bok body'=. cx_read_to_eof (<conn),(<buffer),(<deadline)
    tx_close conn
    if. -. bok do. 0;0;'' return. end.
  end.

  1;status;body
)

NB. y is (<conn),(<buffer),(<deadline).
cx_read_to_eof=: 3 : 0
  conn=. > 0 { y
  'buffer deadline'=. 1 }. y
  while. 1 do.
    remaining=. tx_remaining deadline
    if. remaining = 0 do.
      cx_fail 'TransportError';'timed out reading the HTTP response body'
      (<0),(<buffer) return.
    end.
    'status payload'=. tx_recv (<conn),(<16384),(<remaining)
    if. status = TX_IO_TIMEOUT do. continue. end.
    if. status = TX_IO_EOF do. (<1),(<buffer) return. end.
    if. status ~: TX_IO_OK do.
      cx_fail 'TransportError';'response read failed'
      (<0),(<buffer) return.
    end.
    buffer=. buffer , a. {~ payload
    if. (# buffer) > CX_HTTP_MAX_BODY do.
      cx_fail 'ProtocolError';'HTTP body exceeds the response limit'
      (<0),(<buffer) return.
    end.
  end.
)

cx_hex_value=: 3 : 0
  digits=. y
  vals=. jp_hexval"0 digits
  16 #. vals
)

NB. y is (<conn),(<buffer),(<deadline).
cx_read_chunked=: 3 : 0
  conn=. > 0 { y
  'buffer deadline'=. 1 }. y
  body=. ''
  while. 1 do.
    'ok buffer lineend'=. cx_read_until (<conn),(<CRLF),(<buffer),(<deadline),(<CX_HTTP_MAX_HEADERS)
    if. -. ok do. (<0),(<'') return. end.
    sizeline=. lineend {. buffer
    semi=. sizeline i. ';'
    sizeline=. semi {. sizeline
    if. (0 = #sizeline) +. -. *./ jp_hexval"0 sizeline >: 0 do.
      cx_fail 'ProtocolError';'chunked HTTP size is invalid'
      (<0),(<'') return.
    end.
    size=. cx_hex_value sizeline
    buffer=. (lineend + 2) }. buffer
    if. size = 0 do.
      'ok buffer trailend'=. cx_read_until (<conn),(<(CRLF,CRLF)),(<buffer),(<deadline),(<CX_HTTP_MAX_HEADERS)
      if. -. ok do. (<0),(<'') return. end.
      if. 0 < trailend do.
        tparsed=. cx_http_headers trailend {. buffer
        tok=. > 0 { tparsed
        trailers=. > 1 { tparsed
        if. -. tok do. (<0),(<'') return. end.
        if. (trailers cx_header_present 'content-length') +. trailers cx_header_present 'transfer-encoding' do.
          cx_fail 'ProtocolError';'chunked HTTP trailers are invalid'
          (<0),(<'') return.
        end.
      end.
      (<1),(<body) return.
    end.
    if. (#body) + size > CX_HTTP_MAX_BODY do.
      cx_fail 'ProtocolError';'HTTP body exceeds the response limit'
      (<0),(<'') return.
    end.
    'bok buffer'=. cx_read_atleast (<conn),(<(size+2)),(<buffer),(<deadline)
    if. -. bok do. (<0),(<'') return. end.
    if. -. (CR,LF) -: size }. buffer do.
      cx_fail 'ProtocolError';'chunked HTTP data is missing its terminator'
      (<0),(<'') return.
    end.
    body=. body , size {. buffer
    buffer=. (size + 2) }. buffer
  end.
)

NB. Convex's documented JSON HTTP envelope. `operation` is query, mutation,
NB. or action; `args` is an already-encoded JSON object body. Result is
NB. ok;value;logs on success, or ok=0 with the structured error left in
NB. CX_ERROR_NAME/MESSAGE/DATA (logs, when any accompanied a function
NB. failure, are returned as the second item so a FunctionError still
NB. carries them).
cx_call=: 3 : 0
  'operation path args'=. y
  if. 0 = # CX_URL do. (cx_fail 'ConfigError';'the client is not open') ] (0;'';'[]') return. end.
  colon=. path i: ':'
  if. (colon = 0) +. colon >: (#path)-1 do.
    cx_fail 'ClientError';'function path must be module:function'
    0;'';'[]' return.
  end.
  body=. '{"path":',(jw_quote path),',"args":',args,',"format":"json"}'
  reqtuple=. (<'POST'),(<('/api/',operation)),(<body)
  'ok status respbody'=. cx_http_request reqtuple
  if. -. ok do. 0;'';'[]' return. end.
  if. (status < 200) +. status >: 300 do.
    cx_fail 'TransportError';'Convex HTTP request returned status ',": status
    0;'';'[]' return.
  end.
  'pok payload'=. cx_unpack2 cx_json_parse respbody
  if. -. pok do.
    cx_fail 'ProtocolError';'HTTP ',(": status),' returned a non-Convex body: ',payload
    0;'';'[]' return.
  end.
  if. -. 'o' -: jtag payload do.
    cx_fail 'ProtocolError';'HTTP ',(": status),' returned a non-Convex body'
    0;'';'[]' return.
  end.
  statusnode=. payload jfind 'status'
  logsnode=. payload jfind 'logLines'
  logs=. cx_logs_text logsnode
  NB. `-:` (match), not `=`: `=` requires equal shapes and errors on a
  NB. length mismatch, but a genuine non-empty logs string is exactly the
  NB. case that must compare unequal here without crashing.
  if. logs -: '' do.
    cx_fail 'ProtocolError';'Convex logLines must be an array of strings'
    0;'';'[]' return.
  end.
  if. (_1 ~: statusnode) *. ('s' -: jtag > statusnode) *. 'success' -: jpay > statusnode do.
    valuenode=. payload jfind 'value'
    if. _1 = valuenode do.
      cx_fail 'ProtocolError';'a successful Convex response has no value'
      0;'';logs return.
    end.
    1;(cx_json_encode > valuenode);logs return.
  end.
  if. (_1 ~: statusnode) *. ('s' -: jtag > statusnode) *. 'error' -: jpay > statusnode do.
    messagenode=. payload jfind 'errorMessage'
    datanode=. payload jfind 'errorData'
    if. (_1 = messagenode) +. -. 's' -: jtag > messagenode do.
      cx_fail 'ProtocolError';'a failed Convex response has no errorMessage string'
      0;'';logs return.
    end.
    CX_ERROR_NAME=: 'FunctionError'
    CX_ERROR_MESSAGE=: jpay > messagenode
    CX_ERROR_DATA=: (_1 = datanode) {:: (cx_json_encode > datanode);'null'
    0;'';logs return.
  end.
  cx_fail 'ProtocolError';'HTTP ',(": status),' response has an unknown status'
  0;'';logs
)

NB. Convex log lines are always an array of strings; anything else is a
NB. protocol problem rather than a value to forward, signalled by ''.
cx_logs_text=: 3 : 0
  node=. y
  if. _1 = node do. '[]' return. end.
  node=. > node
  if. -. 'a' -: jtag node do. '' return. end.
  items=. jpay node
  for_item. items do.
    if. -. 's' -: jtag > item do. '' return. end.
  end.
  cx_json_encode node
)

NB. y is path;args (both plain strings; args is an already-encoded JSON
NB. object). Link's splice-an-already-boxed-array behavior is what makes
NB. `'query';y` expand to the 3-item operation;path;args cx_call expects
NB. here, rather than nesting y as one more cell.
convex_query=: 3 : 0
  cx_call 'query';y
)
convex_mutation=: 3 : 0
  cx_call 'mutation';y
)
convex_action=: 3 : 0
  cx_call 'action';y
)

NB. Convex may report an integral number as 0 or as 0.0. Accept both;
NB. reject fractional, non-finite, out-of-range, or malformed literals.
convex_integral=: 3 : 0
  literal=. y
  if. 0 = # literal do. 0 return. end.
  digits=. literal -. '-'
  if. -. *./ digits e. '0123456789.eE+' do. 0 return. end.
  if. 1 e. literal e. 'eE.' do.
    value=. ". literal
    if. 0 = # value do. 0 return. end.
    if. (value < _9007199254740992) +. value > 9007199254740992 do. 0 return. end.
    value = <. value return.
  end.
  bound=. '9007199254740992'
  mag=. literal -. '-'
  if. (0 = #mag) +. -. *./ mag e. '0123456789' do. 0 return. end.
  if. (#mag) > #bound do. 0 return. end.
  NB. `>` compares numbers, not characters (`x is character and y is
  NB. character` is a domain error), so an equal-length digit string is
  NB. compared lexicographically by byte value instead -- one digit at a
  NB. time from the most significant end, the same left-to-right shape as
  NB. the timestamp comparison in live.ijs, because both operands can carry
  NB. 17 digits, one past J's exact-double-precision safe range.
  if. (#mag) = #bound do.
    magvals=. a. i. mag
    boundvals=. a. i. bound
    toobig=. 0
    done=. 0
    i=. 0
    while. (i < #mag) *. (-. done) do.
      if. (i{magvals) > (i{boundvals) do. toobig=. 1 [ done=. 1
      elseif. (i{magvals) < (i{boundvals) do. done=. 1
      end.
      i=. i + 1
    end.
    if. toobig do. 0 return. end.
  end.
  1
)
