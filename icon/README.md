# Icon

[Icon](https://www2.cs.arizona.edu/icon/) is a high-level, general-purpose
language first released in 1979 as a successor to SNOBOL4. It is best known
for string scanning and goal-directed evaluation, where an expression can
succeed, fail, or produce several results. Development of the original Icon
implementation is frozen.

This demonstration uses [Unicon](https://github.com/uniconproject/unicon), an
actively maintained Icon descendant with object-oriented, networking,
database, and concurrency features. Its project describes present-day use in
teaching, research, and applications. This client is an educational,
unofficial experiment, not a production SDK, an officially sanctioned Convex
client, or a package intended for publication.

## Getting Started

The canonical [`examples/basics/main.icn`](examples/basics/main.icn) example
queries a fresh counter, subscribes before mutating it, and checks that HTTP
and Live both observe `0 -> 1`. From the repository root, run it against the
approved local test deployment entirely through Docker:

```sh
./run verify-example icon
```

## Interesting Parts

### An expression can fail — and failure is the control flow

Icon, designed by SNOBOL4 creator Ralph Griswold, has no boolean type: every
expression either succeeds with a value or fails, and failure quietly calls
off whatever surrounds it. `/x` succeeds only when `x` is null, `|` tries
alternatives in order, and `find` returns a match position or fails — the
example's setup is built entirely from that:

```text
convexUrl := getenv("CONVEX_URL")
if /convexUrl | *convexUrl = 0 then stop("CONVEX_URL is required")
# map() lowercases, s[1:6] slices five characters, and `if` is an expression.
scheme := if map(convexUrl[1:6]) == "https" then "wss" else "ws"
hostAndMore := convexUrl[find("://", convexUrl) + 3 : 0]
```

No null checks, no ternary operator, no regex — just expressions that succeed
or step aside.

### The JSON decoder is one big string scan

`s ? expr` opens Icon's string-scanning environment: the subject string and a
cursor (`&subject`, `&pos`) become ambient state inside it, so nested calls
simply keep scanning where their caller stopped. The client parses all of
Convex's wire JSON this way, and `="true"` is a complete pattern in itself —
advance past the literal, or fail:

```text
procedure json_decode(s)
   s ? {                     # inside here, &subject/&pos are the scan state
      json_skip_ws()
      result := json_value()
   }
   return result
end

procedure json_match_true()
   ="true"                   # match the literal at the cursor, or fail
   return JBool(1)
end
```

### `!` deals each Live update, `every` takes them all

`!events` is a generator that yields a list's elements one at a time, and
`every` drives a generator until it has nothing left to give. The canonical
example subscribes before mutating, then polls Live for the changed value
instead of re-querying:

```text
convex_live_add(liveState, "basics", "demo:state", table_of(["room", room]))
# TypeScript: const state = useQuery(api.demo.state, { room })
while live_now_ms() < deadline do {
   events := convex_live_poll(liveState, 500)
   every evt := !events do {
      if evt["subscriptionId"] ~== "basics" then next
      candidate := whole_count(evt["value"], "updated Live value")
      if candidate ~= 0 then return candidate
   }
}
```

Where React's `useQuery` hides the subscription lifecycle, this client drains
it by hand, poll by poll.

### Argument objects are built two list items at a time

Icon has tables (hash maps) but no `{ key: value }` literal, so the client
grows its own: `every i := 1 to *pairs by 2` walks a flat list two at a time.
`&now`, one of Icon's ambient `&`-keywords, timestamps the idempotency key so
a retried mutation can never double-increment:

```text
procedure table_of(pairs)
   t := table()
   every i := 1 to *pairs by 2 do t[pairs[i]] := pairs[i + 1]
   return t
end

# TypeScript: await client.mutation(api.demo.increment, { room, language, runId })
mutation := convex_http_call("mutation", "demo:increment",
   table_of(["room", room, "language", "Icon", "runId", "icon-" || &now]),
   convexUrl, "")
```

One flat list in, one JSON object over the wire.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, reconnect backoff, reactive error recovery, and clean close pass shared local and hosted black-box conformance. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.icn -->
```text
#
# Convex from Unicon: the canonical shared-counter walk. This is the exact
# source shown in the README and on the website, and it is also what
# Docker verification runs against a live deployment -- there is no
# separate "test" copy of this file.
#
# It links against the same client library the conformance adapter uses,
# client/convex.icn, which implements the whole Convex HTTP and Live
# protocol itself in Unicon (RFC 6455 framing, the sync state machine,
# JSON, and even SHA-1/base64 for the WebSocket handshake); the only
# things it delegates outside Unicon are raw TCP/TLS bytes, via a small C
# shim (client/shim.c) loaded with Unicon's own loadfunc() foreign
# function interface.
#
# unicon's `link` finds an already-compiled library by the current working
# directory, not by this file's own location, so the build precompiles
# client/convex.icn once and every linking file names it bare, like this.
link "convex"

procedure main(args)
   local convexUrl, room, scheme, hostAndMore, liveUrl, liveState
   local current, currentCount, events, initialCount, updatedCount
   local runId, mutation, mutationValue, mutationCount

   # Configuration: the deployment URL is required, exactly like every
   # other client here, and the room name is this run's unique identity
   # so concurrent verification runs never collide.
   convexUrl := getenv("CONVEX_URL")
   if /convexUrl | *convexUrl = 0 then {
      write(&errout, "CONVEX_URL is required")
      exit(1)
   }
   room := args[1]
   if /room | *room = 0 then room := "icon-example"

   # Live speaks over wss:// (or ws:// for the self-hosted backend), while
   # ordinary query/mutation calls speak plain HTTPS -- convex.icn derives
   # both from convexUrl itself, so the example only builds the Live one.
   # convexUrl[1:6] is 5 characters (Icon's s[i:j] excludes j), so it must
   # be compared against the 5-character "https", not the 6-character
   # "https:" -- comparing against "https:" can never match, which was
   # silently forcing every deployment (including real wss:// hosted
   # ones) onto plain ws://, and then straight into Cloudflare's
   # plain-HTTP-to-HTTPS redirect for the WebSocket upgrade request.
   scheme := if map(convexUrl[1:6]) == "https" then "wss" else "ws"
   hostAndMore := convexUrl[find("://", convexUrl) + 3 : 0]
   liveUrl := scheme || "://" || hostAndMore || "/api/sync"

   # Ask Convex once over plain HTTPS before opening Live, to establish
   # the fresh room and prove the two transports agree on the starting
   # value.
   current := convex_http_call("query", "demo:state", table_of(["room", room]), convexUrl, "")
   require_result(current, "current query")
   currentCount := whole_count(current.value, "current query")
   if currentCount ~= 0 then fail_with("current count was " || currentCount || ", expected 0")
   write("current count: " || currentCount)

   # Start Live, and subscribe, before issuing the mutation below: its
   # initial value is what proves no mutation can slip in between opening
   # the subscription and the later idempotent write.
   liveState := convex_live_new(liveUrl)
   convex_live_add(liveState, "basics", "demo:state", table_of(["room", room]))

   initialCount := poll_for_value(liveState, "initial")
   if initialCount ~= currentCount then fail_with("initial Live count disagreed with HTTP")
   write("live initial count: " || initialCount)

   # A unique runId is the mutation's idempotency key: retrying this
   # exact logical request would not double-increment the room.
   runId := "icon-" || &now
   mutation := convex_http_call("mutation", "demo:increment",
      table_of(["room", room, "language", "Icon", "runId", runId]), convexUrl, "")
   require_result(mutation, "mutation")
   mutationValue := mutation.value
   if type(mutationValue["applied"]) ~== "JBool" | mutationValue["applied"].v ~= 1 then
      fail_with("mutation was not applied")
   write("mutation applied: true")
   mutationCount := whole_count(mutationValue["state"], "mutation")
   if mutationCount ~= 1 then fail_with("mutation count was " || mutationCount || ", expected 1")
   write("mutation count: " || mutationCount)

   # Wait for the changed value from Live rather than issuing another
   # query, so the printed result is proof the subscription itself saw
   # the update, not just that a second poll happened to see fresh data.
   updatedCount := poll_for_change(liveState, "updated")
   if updatedCount ~= 1 then fail_with("updated Live count was " || updatedCount || ", expected 1")
   write("live updated count: " || updatedCount)

   convex_live_remove(liveState, "basics")
   convex_live_close(liveState)

   write("verified count: 0 -> 1")
end

# Polls Live until a value for this subscription arrives at all (used for
# the very first value after subscribing).
procedure poll_for_value(liveState, which)
   local deadline, events, evt
   # live_now_ms() (from the linked client library) is real wall-clock
   # time; Icon's own &time is *execution* time, which barely advances
   # while convex_live_poll is blocked waiting on the network, so it
   # would not bound this loop the way a 15-second deadline implies.
   deadline := live_now_ms() + 15000
   while live_now_ms() < deadline do {
      events := convex_live_poll(liveState, 500)
      every evt := !events do {
         if evt["subscriptionId"] ~== "basics" then next
         require_no_live_error(evt)
         return whole_count(evt["value"], which || " Live value")
      }
   }
   fail_with("timed out waiting for the " || which || " Live value")
end

# Polls Live until a value strictly different from count 0 arrives (the
# post-mutation update): a fresh Live connection can also rehydrate the
# same initial value once, which is not the event this is waiting for.
procedure poll_for_change(liveState, which)
   local deadline, events, evt, candidate
   deadline := live_now_ms() + 15000
   while live_now_ms() < deadline do {
      events := convex_live_poll(liveState, 500)
      every evt := !events do {
         if evt["subscriptionId"] ~== "basics" then next
         require_no_live_error(evt)
         candidate := whole_count(evt["value"], which || " Live value")
         if candidate ~= 0 then return candidate
      }
   }
   fail_with("timed out waiting for the " || which || " Live value")
end

procedure require_no_live_error(evt)
   if member(evt, "error") then fail_with("Live query failed: " || evt["error"]["message"])
   return
end

procedure require_result(result, label)
   if result.kind == "result" then return
   fail_with(label || " failed: " || result.errName || ": " || result.errMessage)
end

# Convex JSON can spell a whole number as 0 or 0.0; Icon's json_decode
# already turned it into an integer or a real, so this only needs to
# reject the fractional/non-finite cases and normalise a whole real to an
# integer.
procedure whole_count(stateValue, operation)
   local count
   if type(stateValue) ~== "table" then fail_with(operation || " omitted count")
   count := stateValue["count"]
   case type(count) of {
      "integer": return count
      "real": {
         if count = integer(count) then return integer(count)
         fail_with(operation || " count was not a finite whole number")
      }
      default: fail_with(operation || " count was not a finite whole number")
   }
end

procedure fail_with(message)
   write(&errout, message)
   exit(1)
end
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The reusable client is written in Unicon and linked directly into both the
example and conformance adapter. It implements Convex's JSON HTTP behavior,
JSON codec, WebSocket framing, and pinned Live state machine itself. Decoded
JSON uses ordinary Icon tables, lists, strings, numbers, `&null`, and a small
`JBool` record because Icon has no separate boolean type.

Unicon provides sockets but this build delegates raw TCP/TLS byte transport
and wall-clock milliseconds to a narrow C/OpenSSL shim loaded through
`loadfunc()`. The shim contains no Convex, HTTP, JSON, or WebSocket behavior.
Wall-clock time is needed because Icon's `&time` measures execution time and
barely advances while network reads are blocked.

The Docker build pins Unicon `13.2-16bebbfd` and Debian Bookworm by digest. It
compiles the Unicon toolchain from source, runs pure codec/framing tests and
real loopback HTTP and WebSocket fixtures, then packages `iconx`, the compiled
programs, CA certificates, OpenSSL, and their runtime library closure. The
exported images contain no compiler or package manager and run as user
`65532:65532`.

## Known Issues

1. Live authentication, mutations and actions over WebSocket, journals, and
   `TransitionChunk` assembly are deferred. A `TransitionChunk` is treated as
   protocol drift and triggers reconnect behavior.
2. HTTP results are dynamically typed Icon values. There is no generated API
   layer comparable to Convex's TypeScript types.
3. The headless Docker build disables Unicon graphics, audio, VOIP,
   concurrency, pattern types, and database features because this client does
   not use them.
