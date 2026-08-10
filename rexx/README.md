# Rexx

[Rexx](https://www.rexxla.org/) is a readable language usually run through an
interpreter. [Mike Cowlishaw created it at IBM in
1979](https://www.rexxla.org/rexxlang/history/mfc/rexxhist.html), and it grew
from command and string processing into a general-purpose language used for
[scripts, macros, application front ends, and automation](https://www.ibm.com/docs/en/cics-ts/6.x?topic=reference-rexx-general-concepts)
across IBM systems and personal computers. Its modern niche is still scripting
and systems integration, with portable implementations such as
[Regina Rexx](https://sourceforge.net/p/regina-rexx/).

This project uses Regina to make ordinary HTTP calls and keep a Convex query
current over WebSockets. It is an educational, unofficial experiment, not a
production SDK, an officially sanctioned Convex client, or a package intended
for publication.

## Getting Started

The canonical [`examples/basics/main.rexx`](examples/basics/main.rexx) walks a
fresh counter from `0` to `1` with an HTTP query, a Live subscription, and an
idempotent mutation. From the repository root, run it entirely in Docker:

```sh
./run verify-example rexx
```

That command builds the minimal example image, gives it a unique room, and
runs the exact source reproduced under [Example](#example) against the approved
local backend.

## Interesting Parts

### A query can be reactive and typed, or one-shot and textual

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const room = "readme-rexx-query";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // state.count is a type-safe number here.
}
```

**Rexx**

```rexx
convexUrl = value('CONVEX_URL',, 'ENVIRONMENT')
if convexUrl == '' then do
  call lineout 'stderr', 'CONVEX_URL is required'
  exit 1
end
roomArgs = '{"room":"readme-rexx-query"}'

/* One CALL opens the HTTP connection, sends demo:state, and closes it. */
call '/opt/convex/client/convex.rexx' 'http_call', 'query', 'demo:state', ,
  roomArgs, convexUrl, ''
stateEnvelope = result

say stateEnvelope /* Plain character data, not a statically typed object. */
```

The function and arguments match, but the lifecycle does not. React keeps
`useQuery` subscribed and rerenders when the value changes. Rexx's `http_call`
is deliberately a single request, and this small client returns a JSON envelope
as text for the caller to validate and decode.

### Live makes ownership visible

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const room = "readme-rexx-live";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Connecting...</p>;
  return <p>{state.count}</p>; // React owns subscribe, update, and cleanup.
}
```

**Rexx**

```rexx
convexUrl = value('CONVEX_URL',, 'ENVIRONMENT')
if convexUrl == '' then do
  call lineout 'stderr', 'CONVEX_URL is required'
  exit 1
end
roomArgs = '{"room":"readme-rexx-live"}'
subscriptionId = 'readme-rexx-subscription'

scheme = 'ws'
if translate(left(convexUrl, 8)) == 'HTTPS://' then scheme = 'wss'
parse var convexUrl '//' hostAndMore
liveUrl = scheme || '://' || hostAndMore || '/api/sync'

liveState = ''
call '/opt/convex/client/convex.rexx' 'live_add', liveState, liveUrl, ,
  subscriptionId, 'demo:state', roomArgs
parse var result liveState '0b'x events

/* Poll again later for the initial value or a reactive update. */
call '/opt/convex/client/convex.rexx' 'live_poll', liveState, 500
parse var result liveState '0b'x events
say events /* Form-feed-separated JSON event text, not a typed value. */

/* A command-line caller must explicitly unsubscribe and close. */
call '/opt/convex/client/convex.rexx' 'live_remove', liveState, subscriptionId
parse var result liveState '0b'x .
call '/opt/convex/client/convex.rexx' 'live_close', liveState
```

This explicit polling API is a choice made by this client, not a limitation of
Rexx. Each operation returns a new serialized `liveState`, so the caller owns
the subscription and connection lifetime that React normally hides.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, five-reconnect-capable backoff, reactive error recovery, and clean close are implemented and pass shared local and hosted black-box conformance, including a debugDisconnect-triggered reconnect and a QueryFailed-then-recovery cycle. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS. This documentation rewrite does not claim a fresh verification
run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.rexx -->
```text
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

## Implementation Notes

- [`client/convex.rexx`](client/convex.rexx) implements Convex HTTP, JSON,
  WebSocket framing, the handshake helpers, and the Live state machine in
  Rexx. The implementation is native, not a bridge to another Convex client.
- Classic Rexx has no module system that leaves an imported client object alive
  between calls. The file therefore dispatches fixed `CALL` operations. HTTP is
  stateless, while Live threads a JSON state string through `live_add`,
  `live_poll`, `live_remove`, and `live_close`.
- Regina does not provide sockets or TLS itself. The narrow
  [`client/shim.c`](client/shim.c) extension moves raw bytes and performs the
  OpenSSL handshake. It contains no Convex, HTTP, JSON, or WebSocket behavior.
- The pinned Docker toolchain is Regina Rexx `3.6-2.4` on Debian bookworm-slim
  for `linux/amd64`. Language-local tests cover pure helpers plus real loopback
  HTTP and Live sockets, and the minimal runtime includes Regina, its library
  closure, CA certificates, and the OpenSSL runtime files it loads.
- The Live API uses a single caller-owned polling loop. That keeps reads,
  writes, reconnects, and subscription changes serialized without pretending
  that a command-line Rexx process has React's component lifecycle.

## Known Issues

1. Live authentication, WebSocket mutations and actions, journals, and
   `TransitionChunk` assembly are deferred. Receiving a `TransitionChunk`
   reports protocol drift and triggers a reconnect.
2. Multi-frame WebSocket message fragmentation is not reassembled. A fragmented
   message is treated as unsupported and forces a reconnect.
3. Reconnect and partial-frame deadlines use milliseconds since local midnight.
   A run that crosses midnight could observe one incorrect backoff interval.
4. Every caller uses the fixed installed path
   `/opt/convex/client/convex.rexx`, because classic Rexx `CALL` cannot invoke a
   client filename held in a variable.
