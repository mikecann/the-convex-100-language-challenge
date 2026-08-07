/* Real loopback coverage for the HTTP transport: client/tests/fixtures/
 * http_fixture.rexx is a genuine TCP peer (not a mock), so this proves
 * RXCONNECT/RXSEND/RXRECV and convex.rexx's HTTP response reader actually
 * work against a real socket, on top of the pure-function classification
 * coverage in convex.rexx's own selftest.
 *
 * Regina's CALL statement takes only a literal or a bare symbol as the
 * routine name -- there is no "call whatever this variable names"
 * indirection -- so every caller of convex.rexx, including this test and
 * the real adapter and example, addresses it by the one fixed path it is
 * installed at: /opt/convex/client/convex.rexx. Run this file with that
 * layout in place (see client/tests/run.sh for how the test image sets
 * it up alongside the fixtures directory this file also needs).
 */
parse source . . scriptPath
fixturePath = left(scriptPath, lastpos('/', scriptPath)) || 'fixtures/http_fixture.rexx'

failures = 0
basePort = 22100

call test_success
call test_success_with_logs
call test_function_error_via_status
call test_function_error_via_560
call test_transport_error_503
call test_protocol_error_404
call test_chunked_body

if failures == 0 then do
  say 'ALL HTTP LOOPBACK TESTS PASSED'
  exit 0
end
say failures 'HTTP LOOPBACK TEST(S) FAILED'
exit 1

test_success: procedure expose failures fixturePath basePort
  port = basePort + 1
  body = '{"status":"success","value":{"count":0},"logLines":[]}'
  response = 'HTTP/1.1 200 OK' || '0d0a'x || 'Content-Type: application/json' || '0d0a'x || ,
    'Content-Length:' length(body) || '0d0a'x || '0d0a'x || body
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"result","value":{"count":0}}', 'loopback success'
  return

test_success_with_logs: procedure expose failures fixturePath basePort
  port = basePort + 2
  body = '{"status":"success","value":1,"logLines":["a log line"]}'
  response = 'HTTP/1.1 200 OK' || '0d0a'x || 'Content-Length:' length(body) || '0d0a'x || '0d0a'x || body
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"result","value":1,"logs":["a log line"]}', 'loopback success with logs'
  return

test_function_error_via_status: procedure expose failures fixturePath basePort
  port = basePort + 3
  body = '{"status":"error","errorMessage":"boom","errorData":{"code":"X"},"logLines":[]}'
  response = 'HTTP/1.1 200 OK' || '0d0a'x || 'Content-Length:' length(body) || '0d0a'x || '0d0a'x || body
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"error","error":{"name":"FunctionError","message":"boom","data":{"code":"X"}}}', ,
    'loopback function error via status'
  return

test_function_error_via_560: procedure expose failures fixturePath basePort
  port = basePort + 4
  body = '{"status":"error","errorMessage":"boom560","logLines":[]}'
  response = 'HTTP/1.1 560 Function Error' || '0d0a'x || 'Content-Length:' length(body) || '0d0a'x || '0d0a'x || body
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"error","error":{"name":"FunctionError","message":"boom560"}}', ,
    'loopback function error via 560'
  return

test_transport_error_503: procedure expose failures fixturePath basePort
  port = basePort + 5
  body = '{"code":"Unavailable","message":"try later"}'
  response = 'HTTP/1.1 503 Service Unavailable' || '0d0a'x || 'Content-Length:' length(body) || '0d0a'x || '0d0a'x || body
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"error","error":{"name":"TransportError","message":"HTTP 503 from Convex: try later"}}', ,
    'loopback transport error'
  return

test_protocol_error_404: procedure expose failures fixturePath basePort
  port = basePort + 6
  body = ''
  response = 'HTTP/1.1 404 Not Found' || '0d0a'x || 'Content-Length: 0' || '0d0a'x || '0d0a'x
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"error","error":{"name":"ProtocolError","message":"HTTP 404 from Convex: no Convex error envelope"}}', ,
    'loopback protocol error'
  return

test_chunked_body: procedure expose failures fixturePath basePort
  port = basePort + 7
  body = '{"status":"success","value":"chunked-ok","logLines":[]}'
  chunkHex = d2x(length(body))
  response = 'HTTP/1.1 200 OK' || '0d0a'x || 'Transfer-Encoding: chunked' || '0d0a'x || '0d0a'x || ,
    chunkHex || '0d0a'x || body || '0d0a'x || '0' || '0d0a'x || '0d0a'x
  call start_fixture port, response
  result = http_call_direct(port)
  call assert_eq result, '{"type":"result","value":"chunked-ok"}', 'loopback chunked body'
  return

/* Backgrounds the fixture, writes its canned response to a temp file (raw
 * bytes, so the file's own CR/LF reach the socket exactly as authored
 * here), and blocks until the fixture has printed READY. The fixture's
 * listen backlog holds exactly one pending connection and it calls
 * RXACCEPT exactly once, so readiness cannot be polled by connecting: a
 * probe connection would itself be the one connection the fixture ever
 * accepts, starving the real request that follows. Watching its log file
 * for the READY line it prints right after RXLISTEN succeeds costs it
 * nothing. */
start_fixture: procedure expose fixturePath
  numeric digits 20
  parse arg port, responseBytes
  respFile = '/tmp/http_fixture_resp_' || port
  call charout respFile, responseBytes
  call stream respFile, 'c', 'close'
  logFile = '/tmp/http_fixture_' || port || '.log'
  'regina' fixturePath port respFile '>' logFile '2>&1 &'

  attempt = 0
  do while attempt < 50
    if stream(logFile, 'c', 'query exists') <> '' then do
      sawReady = 0
      do while lines(logFile) > 0
        if linein(logFile) == 'READY' then sawReady = 1
      end
      call stream logFile, 'c', 'close'
      if sawReady then return
    end
    call busy_wait_ms(100)
    attempt = attempt + 1
  end
  say 'fixture on port' port 'did not become ready; see' logFile
  exit 1

busy_wait_ms: procedure
  numeric digits 20
  parse arg ms
  target = time('E') + (ms / 1000)
  do while time('E') < target
    nop
  end
  return

/* Runs one demo:state-shaped query through the real client against the
 * fixture and returns the raw JSON envelope convex.rexx produced. */
http_call_direct: procedure
  parse arg port
  call '/opt/convex/client/convex.rexx' 'http_call', 'query', 'demo:state', '{"room":"x"}', 'http://127.0.0.1:' || port, ''
  return result

assert_eq: procedure expose failures
  parse arg actual, expected, label
  if actual == expected then return
  failures = failures + 1
  say 'FAIL' label': expected=['expected'] actual=['actual']'
  return
