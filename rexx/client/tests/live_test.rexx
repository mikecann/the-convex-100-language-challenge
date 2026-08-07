/* Real loopback coverage for Live: client/tests/fixtures/ws_fixture.rexx
 * is a genuine WebSocket peer (not a mock), so this drives convex.rexx's
 * public live_add/live_poll/live_remove/live_debug_disconnect operations
 * through a real RFC 6455 handshake, an initial value, an external
 * update, a debugDisconnect-triggered reconnect that resends the active
 * subscription, and a QueryFailed-then-recovery cycle -- the scenarios
 * AGENTS.md's "Live acceptance" section calls out. The pure state-surgery
 * helpers (dedup, subs map edits) have their own direct coverage in
 * convex.rexx's own selftest; this file is about the parts that are only
 * meaningful against a real socket.
 *
 * Regina's CALL statement has no variable indirection, so convex.rexx is
 * always addressed at its one fixed install path, exactly as the real
 * adapter and example do (see client/tests/http_test.rexx for the same
 * note in more detail).
 */
parse source . . scriptPath
fixturePath = left(scriptPath, lastpos('/', scriptPath)) || 'fixtures/ws_fixture.rexx'

failures = 0
port = 22200

logFile = '/tmp/ws_fixture_' || port || '.log'
'regina' fixturePath port '>' logFile '2>&1 &'
call wait_for_ready logFile

wsUrl = 'ws://127.0.0.1:' || port || '/api/sync'

/* 1. Add opens the connection and sends the subscribe; like the adapter's
 * own subscribe op, it acks/returns immediately and the initial value
 * arrives later as its own event, so it takes a poll to observe.
 *
 * 2. The fixture sends the initial value and the external update back to
 * back with no delay, so both frames typically arrive in the very same
 * poll: watch for both counts across as many polls as it takes rather
 * than returning on the first match, which would silently drop whichever
 * event shared that batch with it. */
call '/opt/convex/client/convex.rexx' 'live_add', '', wsUrl, 'sub1', 'demo:state', '{"room":"fixture-room"}'
parse var result state '0b'x .
state = strip(state)
call poll_until_counts_seen state, 'sub1', '0 1', 'initial value and external update'
state = result_state

/* 3. debugDisconnect must retire the old connection and arm a reconnect
 * before it acks -- convex.rexx does this synchronously, so the state it
 * hands back already shows disconnected. */
call '/opt/convex/client/convex.rexx' 'live_debug_disconnect', state
parse var result state '0b'x .
state = strip(state)
call assert_eq pos('"connected":false', state) > 0, 1, ,
  'debugDisconnect leaves state disconnected before any further poll'

/* 4. Polling drives the reconnect once backoff elapses; the fixture's
 * second connection resends Add (proving query-set rebuild), then scripts
 * a QueryFailed immediately followed by a recovering QueryUpdated. Both
 * can land in the very same poll (they arrive back to back on the wire),
 * so a single pass has to watch for both rather than returning on the
 * first match and losing whatever else was in that batch. */
call poll_until_error_then_count state, 'sub1', 'ROOM_EMPTY', 2, 'reconnect: QueryFailed then recovery'
state = result_state

/* 5. Clean shutdown: unsubscribe, then close. */
call '/opt/convex/client/convex.rexx' 'live_remove', state, 'sub1'
parse var result state '0b'x .
state = strip(state)
call '/opt/convex/client/convex.rexx' 'live_close', state

if failures == 0 then do
  say 'ALL LIVE LOOPBACK TESTS PASSED'
  exit 0
end
say failures 'LIVE LOOPBACK TEST(S) FAILED'
exit 1

/* ---------------- helpers ---------------- */

wait_for_ready: procedure
  parse arg logFile
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
  say 'ws fixture did not become ready; see' logFile
  exit 1

busy_wait_ms: procedure
  numeric digits 20
  parse arg ms
  target = time('E') + (ms / 1000)
  do while time('E') < target
    nop
  end
  return

/* Polls live_poll (short timeout per call, bounded overall deadline)
 * until a "subscription" event for subscriptionId has been seen for every
 * count in expectedCounts (a space separated list), scanning each poll's
 * whole event batch rather than returning on the first match, since two
 * expected events can legitimately arrive together in one batch. Leaves
 * the latest state in the global result_state so the caller can pick up
 * where this left off. */
poll_until_counts_seen: procedure expose failures result_state
  numeric digits 20
  parse arg state, subscriptionId, expectedCounts, label
  seen. = 0
  remaining = words(expectedCounts)
  deadline = time('E') + 15
  do while time('E') < deadline & remaining > 0
    call '/opt/convex/client/convex.rexx' 'live_poll', state, 500
    parse var result state '0b'x events
    state = strip(state)
    result_state = state
    do while events <> ''
      parse var events oneEvent '0c'x events
      if oneEvent == '' then leave
      if pos('"subscriptionId":"' || subscriptionId || '"', oneEvent) == 0 then iterate
      do i = 1 to words(expectedCounts)
        thisCount = word(expectedCounts, i)
        if seen.thisCount == 0 & pos('"count":' || thisCount, oneEvent) > 0 then do
          seen.thisCount = 1
          remaining = remaining - 1
        end
      end
    end
  end
  if remaining == 0 then return
  failures = failures + 1
  say 'FAIL' label': missing' remaining 'of the expected counts within deadline'
  return

/* Watches across as many live_poll calls as it takes for two events on
 * the same subscription: an error carrying expectedCode, and (at any
 * point before or after it) a value carrying expectedCount. Each poll's
 * whole event batch is scanned, so two events delivered together in one
 * Transition are not lost the way returning on the first match would
 * lose them. */
poll_until_error_then_count: procedure expose failures result_state
  numeric digits 20
  parse arg state, subscriptionId, expectedCode, expectedCount, label
  sawError = 0
  sawCount = 0
  deadline = time('E') + 15
  do while time('E') < deadline & (sawError == 0 | sawCount == 0)
    call '/opt/convex/client/convex.rexx' 'live_poll', state, 500
    parse var result state '0b'x events
    state = strip(state)
    result_state = state
    do while events <> ''
      parse var events oneEvent '0c'x events
      if oneEvent == '' then leave
      if pos('"subscriptionId":"' || subscriptionId || '"', oneEvent) == 0 then iterate
      if pos('"code":"' || expectedCode || '"', oneEvent) > 0 then sawError = 1
      if pos('"count":' || expectedCount, oneEvent) > 0 then sawCount = 1
    end
  end
  if sawError & sawCount then return
  failures = failures + 1
  say 'FAIL' label': sawError=' sawError 'sawCount=' sawCount
  return

assert_event_count: procedure expose failures
  parse arg events, subscriptionId, expectedCount, label
  found = 0
  do while events <> ''
    parse var events oneEvent '0c'x events
    if oneEvent == '' then leave
    if pos('"subscriptionId":"' || subscriptionId || '"', oneEvent) > 0 & ,
       pos('"count":' || expectedCount, oneEvent) > 0 then found = 1
  end
  if found then return
  failures = failures + 1
  say 'FAIL' label': expected an event for' subscriptionId 'with count' expectedCount
  return

assert_eq: procedure expose failures
  parse arg actual, expected, label
  if actual == expected then return
  failures = failures + 1
  say 'FAIL' label': expected=[' expected '] actual=[' actual ']'
  return
