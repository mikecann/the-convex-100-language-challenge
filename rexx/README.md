# Convex from Rexx

This demonstration uses Regina Rexx to call Convex's documented JSON HTTP
endpoints and to keep a reactive query current through a native Rexx
WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.rexx`](examples/basics/main.rexx) is the canonical
example. It reads a new counter room over HTTP, starts Live before changing
it, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that
exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Not yet verified | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass real loopback tests in Docker, but shared local and hosted black-box conformance have not run yet. |
| Live | Not yet verified | Subscribe/unsubscribe, five-reconnect-capable backoff, reactive error recovery, and clean close are implemented and pass real loopback tests in Docker (including a debugDisconnect-triggered reconnect and a QueryFailed-then-recovery cycle), but shared local and hosted black-box conformance have not run yet. |

No capability badge is claimed until the shared evaluator runs local and
hosted conformance from a clean exact-head build.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.rexx -->
```rexx
#!/usr/local/bin/regina
/* Convex from Rexx: the canonical shared-counter walk. This is the exact
 * source shown in the README and on the website, and it is also what
 * Docker verification runs against a live deployment -- there is no
 * separate "test" copy of this file.
 *
 * It reuses the same client library the conformance adapter calls into,
 * client/convex.rexx, installed at /opt/convex/client/convex.rexx.
 * convex.rexx implements the whole Convex HTTP and Live protocol itself
 * in Rexx (RFC 6455 framing, the sync state machine, JSON, and even
 * SHA-1/base64 for the WebSocket handshake); the only things it delegates
 * outside Rexx are raw TCP/TLS bytes, via a small C shim (client/shim.c)
 * loaded with RXFUNCADD -- the same mechanism Regina's own built-in
 * packages use to reach the C library.
 */

/* Configuration: the deployment URL is required, exactly like every other
 * client here, and the room name is this run's unique identity so
 * concurrent verification runs never collide. */
convexUrl = value('CONVEX_URL',, 'ENVIRONMENT')
if convexUrl == '' then do
  call lineout 'stderr', 'CONVEX_URL is required'
  exit 1
end
room = arg(1)
if room == '' then room = 'rexx-example'

/* Live speaks over wss:// (or ws:// for the self-hosted backend), while
 * ordinary query/mutation calls speak plain HTTPS -- convex.rexx derives
 * both from convexUrl itself, so the example only builds the Live one. */
scheme = 'ws'
if translate(left(convexUrl, 8)) == 'HTTPS://' then scheme = 'wss'
parse var convexUrl '//' hostAndMore
liveUrl = scheme || '://' || hostAndMore || '/api/sync'

liveState = ''

/* Ask Convex once over plain HTTPS before opening Live, to establish the
 * fresh room and prove the two transports agree on the starting value. */
call '/opt/convex/client/convex.rexx' 'http_call', 'query', 'demo:state', ,
  '{"room":' || json_estr(room) || '}', convexUrl, ''
currentEnvelope = result
call require_result currentEnvelope, 'current query'
currentCount = whole_count(field_json(currentEnvelope, 'value'), 'current query')
if currentCount <> 0 then do
  call lineout 'stderr', 'current count was' currentCount', expected 0'
  exit 1
end
say 'current count:' currentCount

/* Start Live, and subscribe, before issuing the mutation below: its
 * initial value is what proves no mutation can slip in between opening
 * the subscription and the later idempotent write. */
call '/opt/convex/client/convex.rexx' 'live_add', liveState, liveUrl, 'basics', 'demo:state', ,
  '{"room":' || json_estr(room) || '}'
parse var result liveState '0b'x .
liveState = strip(liveState)

initialCount = ''
call poll_for_value 'initial'
if initialCount <> currentCount then do
  call lineout 'stderr', 'initial Live count disagreed with HTTP'
  exit 1
end
say 'live initial count:' initialCount

/* A unique runId is the mutation's idempotency key: retrying this exact
 * logical request would not double-increment the room. */
runId = 'rexx-' || date('S') || '-' || space(translate(time('L'), '', ':.'), 0)
call '/opt/convex/client/convex.rexx' 'http_call', 'mutation', 'demo:increment', ,
  '{"room":' || json_estr(room) || ',"language":"Rexx","runId":' || json_estr(runId) || '}', convexUrl, ''
mutationEnvelope = result
call require_result mutationEnvelope, 'mutation'
mutationValue = field_json(mutationEnvelope, 'value')
applied = field_json(mutationValue, 'applied')
if applied <> 'true' then do
  call lineout 'stderr', 'mutation was not applied'
  exit 1
end
say 'mutation applied: true'
mutationCount = whole_count(field_json(mutationValue, 'state'), 'mutation')
if mutationCount <> 1 then do
  call lineout 'stderr', 'mutation count was' mutationCount', expected 1'
  exit 1
end
say 'mutation count:' mutationCount

/* Wait for the changed value from Live rather than issuing another
 * query, so the printed result is proof the subscription itself saw the
 * update, not just that a second poll happened to see fresh data. */
updatedCount = ''
call poll_for_change 'updated'
if updatedCount <> 1 then do
  call lineout 'stderr', 'updated Live count was' updatedCount', expected 1'
  exit 1
end
say 'live updated count:' updatedCount

call '/opt/convex/client/convex.rexx' 'live_remove', liveState, 'basics'
parse var result liveState '0b'x .
call '/opt/convex/client/convex.rexx' 'live_close', liveState

say 'verified count: 0 -> 1'
exit 0

/* ---------------- helpers ----------------
 * Each handles one failure a real run can hit and explains why it is
 * checked, rather than trusting the shape of a successful response. */

/* Polls Live until a value for this subscription arrives at all (used
 * for the very first value after subscribing). */
poll_for_value: procedure expose liveState initialCount
  parse arg which
  deadline = elapsed_deadline(15)
  do while elapsed_now() < deadline
    call '/opt/convex/client/convex.rexx' 'live_poll', liveState, 500
    parse var result liveState '0b'x events
    liveState = strip(liveState)
    do while events <> ''
      parse var events oneEvent '0c'x events
      if oneEvent == '' then leave
      if pos('"subscriptionId":"basics"', oneEvent) == 0 then iterate
      call require_no_live_error oneEvent
      initialCount = whole_count(field_json(oneEvent, 'value'), which 'Live value')
      return
    end
  end
  call lineout 'stderr', 'timed out waiting for the' which 'Live value'
  exit 1

/* Polls Live until a value strictly different from count 0 arrives (the
 * post-mutation update): a fresh Live connection can also rehydrate the
 * same initial value once, which is not the event this is waiting for. */
poll_for_change: procedure expose liveState updatedCount
  parse arg which
  deadline = elapsed_deadline(15)
  do while elapsed_now() < deadline
    call '/opt/convex/client/convex.rexx' 'live_poll', liveState, 500
    parse var result liveState '0b'x events
    liveState = strip(liveState)
    do while events <> ''
      parse var events oneEvent '0c'x events
      if oneEvent == '' then leave
      if pos('"subscriptionId":"basics"', oneEvent) == 0 then iterate
      call require_no_live_error oneEvent
      candidate = whole_count(field_json(oneEvent, 'value'), which 'Live value')
      if candidate <> 0 then do
        updatedCount = candidate
        return
      end
    end
  end
  call lineout 'stderr', 'timed out waiting for the' which 'Live value'
  exit 1

require_no_live_error: procedure
  parse arg oneEvent
  if pos('"error":', oneEvent) > 0 & pos('"value":', oneEvent) == 0 then do
    call lineout 'stderr', 'Live query failed:' oneEvent
    exit 1
  end
  return

/* elapsed_now/elapsed_deadline: TIME('E') resets on every separate
 * external CALL to convex.rexx, so it cannot time a loop that calls it
 * repeatedly. TIME('L') is wall-clock and does not reset. */
elapsed_now: procedure
  parse value time('L') with hh ':' mm ':' ss '.' frac
  return (hh * 3600) + (mm * 60) + ss + (frac / 1000000)

elapsed_deadline: procedure
  parse arg secondsFromNow
  return elapsed_now() + secondsFromNow

require_result: procedure
  parse arg envelope, label
  if field_found(envelope, 'value') then return
  call lineout 'stderr', label 'failed:' envelope
  exit 1

/* Convex JSON can spell a whole number as 0 or 0.0; this accepts either
 * mathematically-integral form while rejecting fractions, strings,
 * non-finite values, and anything too large to be a real count. */
whole_count: procedure
  parse arg value, operation
  parse var value 'count":' countText
  countText = strip(word(translate(countText, ' ', ','), 1))
  if \datatype(countText, 'NUMBER') | pos('E', translate(countText)) > 0 then do
    call lineout 'stderr', operation 'count was not a finite whole number'
    exit 1
  end
  if countText \= trunc(countText) then do
    call lineout 'stderr', operation 'count was not a finite whole number'
    exit 1
  end
  return trunc(countText)

/* Extracts one top-level field's raw JSON text from an object, using the
 * same span-based approach as convex.rexx's own JSON handling (kept as a
 * small local copy: this example intentionally reuses only convex.rexx's
 * public operations, never its internal, non-dispatched routines). */
field_json: procedure
  parse arg objectJson, key
  marker = '"' || key || '":'
  at = pos(marker, objectJson)
  if at == 0 then return ''
  start = at + length(marker)
  c = substr(objectJson, start, 1)
  select
    when c == '"' then do
      i = start + 1
      do while i <= length(objectJson)
        ch = substr(objectJson, i, 1)
        if ch == '\' then i = i + 2
        else if ch == '"' then return substr(objectJson, start, i - start + 1)
        else i = i + 1
      end
      return ''
    end
    when c == '{' | c == '[' then do
      openc = c
      closec = '}'
      if c == '[' then closec = ']'
      depth = 0
      i = start
      do while i <= length(objectJson)
        ch = substr(objectJson, i, 1)
        if ch == '"' then do
          i = i + 1
          do while i <= length(objectJson) & substr(objectJson, i, 1) <> '"'
            if substr(objectJson, i, 1) == '\' then i = i + 1
            i = i + 1
          end
        end
        else do
          if ch == openc then depth = depth + 1
          else if ch == closec then do
            depth = depth - 1
            if depth == 0 then return substr(objectJson, start, i - start + 1)
          end
        end
        i = i + 1
      end
      return ''
    end
    otherwise do
      i = start
      do while i <= length(objectJson) & pos(substr(objectJson, i, 1), ',}] ') == 0
        i = i + 1
      end
      return substr(objectJson, start, i - start)
    end
  end

field_found: procedure
  parse arg objectJson, key
  return pos('"' || key || '":', objectJson) > 0

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
      otherwise out = out || c
    end
    i = i + 1
  end
  return out || '"'
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test rexx           # format/lint-equivalent checks, unit tests, and the
                           # real loopback HTTP/Live fixtures, entirely offline
./run verify-example rexx # runs the exact block above against a unique room
                           # on the local self-hosted backend
./run verify rexx         # verify-example plus shared black-box conformance
```

`./run test rexx` builds the `test` Docker stage: it compiles the small C
transport shim with `-Wall -Wextra -Werror`, runs `client/tests/
selftest_test.rexx` (the JSON codec, base64/SHA-1, WebSocket framing, HTTP
response classification, and Live state-surgery helpers, exercised directly
through `convex.rexx`'s own `selftest` operation), `client/tests/
http_test.rexx` and `client/tests/live_test.rexx` (real loopback fixtures
under `client/tests/fixtures/`, not mocks, proving the actual sockets and
protocol state machine work), and a smoke check of the conformance adapter
and the canonical example.

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync`, matching every other client in this project.
- `client/convex.rexx` is a single file because classic Rexx's `CALL`
  statement has no library/import system: an external file loaded with
  `CALL` runs from its first line every time, with no memory of previous
  invocations. HTTP calls are one CALL each; Live is a small reducer where
  the caller (the adapter, the example, or a test) holds a JSON "state"
  string across many separate CALLs and gets an updated state plus any new
  events back each time.
- The C shim (`client/shim.c`) supplies only raw byte transport: TCP
  connect/listen/accept/send/recv/close and the OpenSSL TLS handshake. It
  carries no Convex, HTTP, JSON, or WebSocket logic; everything a reader
  would recognise as "the protocol" is in `convex.rexx` itself.
- `client/tests/conformance/adapter.rexx` implements NDJSON adapter
  protocol v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode,
  and declares `debugDisconnect` as its one adapter-only command.

## Limitations

- Shared local and hosted black-box conformance have not run yet. Every
  claim above is language-local Docker evidence only; no capability badge
  is claimed until the shared evaluator runs from a clean exact-head build.
- Live authentication, WebSocket-issued mutations/actions, journals, and
  `TransitionChunk` assembly are deferred; a `TransitionChunk` is reported
  as protocol drift and the connection reconnects.
- A WebSocket message is assumed to arrive as one unfragmented frame. A
  genuinely fragmented message is treated as an unsupported opcode.
- Reconnect backoff and the partial-frame abandonment deadline are timed
  with wall-clock milliseconds since midnight, because Rexx's `TIME('E')`
  resets on every separate external `CALL` and so cannot time anything
  spanning more than one call into `convex.rexx`. A run that straddles
  local midnight could see one incorrect backoff interval.
