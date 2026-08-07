# Convex from Icon

This demonstration uses Unicon (a modern superset of Icon) to call Convex's
documented JSON HTTP endpoints and to keep a reactive query current through
a native Unicon WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.icn`](examples/basics/main.icn) is the canonical
example. It reads a new counter room over HTTP, starts Live before changing
it, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that
exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, five-reconnect-capable backoff, reactive error recovery, and clean close are implemented and pass shared local and hosted black-box conformance, including a debugDisconnect-triggered reconnect and a QueryFailed-then-recovery cycle. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS.

## The basic example

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

## Verify it in Docker

```sh
./run test icon            # builds Unicon from source, then runs the real
                            # loopback HTTP/Live fixtures and unit tests,
                            # entirely offline
./run verify-example icon  # runs the exact block above against a unique
                            # room on the local self-hosted backend
./run verify icon          # verify-example plus shared black-box conformance
```

`./run test icon` builds the Unicon toolchain from source (Debian does not
package it, so this is pinned to a specific upstream commit), compiles the
small C transport shim with `-Wall -Wextra -Werror`, runs `client/tests/
selftest_test.icn` (the JSON codec, base64/SHA-1, WebSocket framing, and
HTTP response classification, exercised directly since Unicon's `link`
gives real, ordinary access to `convex.icn`'s procedures), `client/tests/
http_test.icn` and `client/tests/live_test.icn` (real loopback fixtures
under `client/tests/fixtures/`, not mocks, proving the actual sockets and
protocol state machine work), and a smoke check of the conformance adapter
and the canonical example.

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync`, matching every other client in this project.
- Unicon compiles multiple source files together at build time via `link`,
  so `client/convex.icn` is an ordinary reusable library: the adapter and
  the example each link it directly and call its procedures with real
  Icon values (tables, lists, records) -- no serialize-across-a-call
  trick is needed for Live's state, which is just a record the caller
  holds and mutates in place across calls.
- The C shim (`client/shim.c`) supplies raw byte transport -- TCP
  connect/listen/accept/send/recv/close and the OpenSSL TLS handshake --
  plus one non-transport primitive, wall-clock milliseconds (Icon's own
  `&time` is *execution* time and barely advances while blocked in
  `recv()`, which would leave Live's reconnect backoff effectively
  unbounded), loaded with Unicon's own `loadfunc()` foreign-function
  interface. It carries no Convex, HTTP, JSON, or WebSocket logic;
  everything a reader would recognise as "the protocol" is in
  `convex.icn` itself.
- `unicon -o out file.icn` does not produce a native ELF binary: it emits
  a small shell wrapper that execs `iconx` (the actual interpreter)
  against the compiled bytecode appended to the same file. The runtime
  images carry `iconx` and pin `$ICONX` so that wrapper always finds it.
- `client/tests/conformance/adapter.icn` implements NDJSON adapter
  protocol v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode,
  and declares `debugDisconnect` as its one adapter-only command.
- Fragmented WebSocket messages are reassembled correctly: continuation
  frames are concatenated as raw bytes into the message in progress,
  control frames (ping/pong/close) are handled immediately without
  disturbing that assembly since RFC 6455 permits them between the
  fragments of a data message, and UTF-8 is validated once on the
  complete reassembled message rather than per fragment, since a
  multi-byte character split across a frame boundary is invalid UTF-8 in
  either fragment's raw bytes alone. Fragment-assembly state lives on the
  Live connection's own state record, so it survives correctly across a
  `convex_live_poll` call that returns between fragments.

## Limitations

- Live authentication, WebSocket-issued mutations/actions, journals, and
  `TransitionChunk` assembly are deferred; a `TransitionChunk` is reported
  as protocol drift and the connection reconnects.
- The Unicon toolchain is built from source in the `test` stage (Debian
  does not package it), pinned to a specific upstream commit, with
  graphics, 3D graphics, audio, VOIP, concurrency, pattern types, and the
  built-in database disabled: none of them are needed for a headless
  network client, and disabling them removes a large, otherwise-unused
  build surface.
