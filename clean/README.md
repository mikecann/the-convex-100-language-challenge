# Convex from Clean

This folder is a native [Clean](https://clean.cs.ru.nl) client for Convex's
documented JSON HTTP endpoints and the project's pinned `/api/sync` Live
WebSocket profile. Clean is a pure, lazy functional language whose
*uniqueness types* let the compiler prove a value has exactly one live
reference and therefore mutate it in place without breaking referential
transparency — the ownership reasoning Rust made famous, arriving roughly
twenty-five years earlier. Clean's distribution has no JSON, HTTP, or
WebSocket support to reach for, so all three are written here in Clean
itself, over a hand-rolled TCP socket layer reached through Clean's own
`ccall` C FFI. OpenSSL's `libssl`/`libcrypto` are reached the same way, for
the TLS record layer, SHA-1, Base64, and randomness — the same kind of
foreign-function boundary every other native client in this project uses for
its language's TLS story. Everything Convex-specific stays in Clean.

This is unofficial, educational teaching material, not an official Convex SDK
and not a package meant for publication.

## Start here

Read [`examples/basics/main.icl`](examples/basics/main.icl). It configures
the deployment from `CONVEX_URL`, performs an HTTP query, starts a Live
subscription before the mutation so the initial snapshot cannot be missed,
applies an idempotent mutation, and checks that both the HTTP and Live paths
agree on the resulting `0 -> 1` count.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, and action | verified | Shared local and hosted conformance passed 31/31 from a clean exact-head build, including real TLS 1.3 against the hosted deployment. |
| Bearer-token lifecycle | verified | `clientSetAuth`, exercised by the shared conformance suite's bearer-token test. |
| Live initial values, updates, unsubscribe | verified | Verified against both the local and hosted backends. |
| Live reconnect | verified | Five real `debugDisconnect`-driven reconnects, each resending the active subscription and correctly suppressing a duplicate event for an unchanged rehydrated value. |
| Earned capability badges | http, live | Awarded by the shared result evaluator from local and hosted runs at this exact head. |
| Convex tagged values | deferred | JSON-safe values only |
| Live authentication, optimistic writes, WebSocket mutations/actions | deferred | |

The full teaching example below is generated directly from the runnable
source.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.icl -->
```text
module main

// A short tour of the native Clean Convex client: an HTTP query, a Live
// subscription started before a mutation so the initial snapshot cannot be
// missed, an idempotent mutation, and the resulting Live update. Every
// printed line is checked against the value Convex actually returned;
// `abort` (which reports to stderr and exits non-zero) fires if any of them
// disagree, so this program cannot silently print a wrong value.

import StdEnv
import StdMaybe
import System.Environment
import System.IO
from ArgEnv import getCommandLine
from System._Posix import exit
import Convex.Result
import Convex.Deadline
import Convex.Wire
import Convex.HTTP
import Convex.Live
import Convex.Client

printLine :: !String !*World -> *World
printLine text w = execIO (putStrLn text) w

// Convex's JSON-safe profile may represent a whole number as either an
// integer or a float (for example the literal `0.0`); `jsonAsWholeInt`
// (Convex.Wire) accepts both shapes but only when the value is finite,
// mathematically integral, and in range — see WireTest.icl for the
// regression covering that exact rule.
countOf :: !JSON -> Int
countOf v = case jsonLookup "count" v of
	Nothing = abort "demo state was missing count"
	Just countJson = case jsonAsWholeInt countJson of
		Nothing = abort "demo count was not numeric or not a whole integer"
		Just n = n

Start :: *World -> *World
Start w
	// Configure the deployment: the client reads the URL from CONVEX_URL,
	// same as this project's other native clients, and accepts a room name
	// as its first argument so the shared verifier can target a unique room
	// per run.
	# (urlOpt, w) = getEnvironmentVariable "CONVEX_URL" w
	# url = case urlOpt of
		?Just u = u
		?None = abort "CONVEX_URL is required"
	# commandLine = getCommandLine
	# room = if (size commandLine > 1) commandLine.[1] "clean-basic-example"
	// Create the native Clean client.
	# (clientResult, w) = clientInit url w
	= case clientResult of
		RErr e = abort ("could not create the client: " +++ e)
		ROk client = runExample room client w

runExample :: !String !Client !*World -> *World
runExample room client w
	// Query the counter through Convex's documented HTTP endpoint.
	# (queryResult, w) = clientCall "query" "demo:state" (JObject [("room", JString room)]) client w
	= case queryResult of
		RErr e = abort ("query failed: " +++ e)
		ROk cr = afterQuery room client cr w

afterQuery :: !String !Client !CallResult !*World -> *World
afterQuery room client cr w = case cr.crFailure of
	Just (msg, _) = abort ("query returned a function error: " +++ msg)
	Nothing
		# before = countOf cr.crValue
		# w = printLine ("current count: " +++ toString before) w
		= startLive room client before w

// Start Live before the mutation so the initial snapshot cannot be missed:
// subscribing after the mutation could race the server and deliver the
// post-mutation value as if it were the starting point.
startLive :: !String !Client !Int !*World -> *World
startLive room client before w
	# (subResult, w) = clientSubscribe "example" "demo:state" (JObject [("room", JString room)]) client w
	= case subResult of
		RErr e = abort ("subscribe failed: " +++ e)
		ROk client1 = afterSubscribe room client1 before w

// Wait for the actual initial Live value from the bounded event stream,
// rather than assuming the first step call already delivered it.
afterSubscribe :: !String !Client !Int !*World -> *World
afterSubscribe room client before w
	# (eventResult, client1, w) = waitForUpdate client "example" w
	= case eventResult of
		RErr e = abort e
		ROk event = afterInitialLive room client1 before event w

afterInitialLive :: !String !Client !Int !SyncEvent !*World -> *World
afterInitialLive room client before event w = case event.seValue of
	Nothing = abort "live initial event had no value"
	Just v
		| countOf v <> before = abort "live initial count did not match the query count"
		# w = printLine ("live initial count: " +++ toString before) w
		= runMutation room client before w

// Apply the mutation with a stable idempotency key, so retrying this
// example against the same room is always safe.
runMutation :: !String !Client !Int !*World -> *World
runMutation room client before w
	# args = JObject [("room", JString room), ("language", JString "Clean"), ("runId", JString (room +++ "-once"))]
	# (mutResult, w) = clientCall "mutation" "demo:increment" args client w
	= case mutResult of
		RErr e = abort ("mutation failed: " +++ e)
		ROk cr = afterMutation room client before cr w

afterMutation :: !String !Client !Int !CallResult !*World -> *World
afterMutation room client before cr w = case cr.crFailure of
	Just (msg, _) = abort ("mutation returned a function error: " +++ msg)
	Nothing = checkApplied room client before cr.crValue w

checkApplied :: !String !Client !Int !JSON !*World -> *World
checkApplied room client before value w
	# applied = case jsonLookup "applied" value of
		Just appliedJson = case jsonAsBool appliedJson of
			Just b = b
			Nothing = abort "mutation response's applied field was not a boolean"
		Nothing = abort "mutation response was missing applied"
	| not applied = abort "mutation was not applied"
	# newState = case jsonLookup "state" value of
		Just s = s
		Nothing = abort "mutation response was missing state"
	# after = countOf newState
	| after <> before + 1 = abort "mutation count did not advance by exactly one"
	# w = printLine "mutation applied: true" w
	# w = printLine ("mutation count: " +++ toString after) w
	= waitForFinalLive room client before after w

// Wait for the actual resulting Live value before printing the
// verification line, rather than assuming the mutation's own HTTP response
// implies Live has already caught up.
waitForFinalLive :: !String !Client !Int !Int !*World -> *World
waitForFinalLive room client before after w
	# (eventResult, client1, w) = waitForUpdate client "example" w
	= case eventResult of
		RErr e = abort e
		ROk event = finishExample client1 before after event w

finishExample :: !Client !Int !Int !SyncEvent !*World -> *World
finishExample client before after event w = case event.seValue of
	Nothing = abort "live updated event had no value"
	Just v
		| countOf v <> after = abort "live updated count did not match the mutation count"
		# w = printLine ("live updated count: " +++ toString after) w
		# w = printLine ("verified count: " +++ toString before +++ " -> " +++ toString after) w
		= cleanup client w

// Cleanup: drop the Live subscription, close the client, then exit
// explicitly. Clean's runtime otherwise auto-displays whatever `Start`
// returns (this is by design for a bare `Start :: Int`-style program, and
// is how the hello-world and every language-local test in this client
// prove their own result); for `*World -> *World` there is nothing
// meaningful left to show, but the runtime still prints the World token's
// own internal representation. An explicit `exit 0` (libc's `exit`, which
// flushes stdio same as a normal return) ends the process before that
// default display ever runs, keeping stdout exactly the transcript above
// and nothing else.
cleanup :: !Client !*World -> *World
cleanup client w
	# (unsubResult, w) = clientUnsubscribe "example" client w
	= case unsubResult of
		RErr e = abort ("unsubscribe failed: " +++ e)
		ROk client1
			# w = clientClose client1 w
			# (_, w) = exit 0 w
			= w

// Steps the Live connection until an UPDATED event arrives for the given
// subscription, or ten seconds pass without one.
waitForUpdate :: !Client !String !*World -> (!Result SyncEvent, !Client, !*World)
waitForUpdate client subId w
	# (d, w) = deadlineIn 10000 w
	= loop client d w
where
	loop client d w
		# (expiredNow, w) = isExpired d w
		| expiredNow = (RErr "timed out waiting for a Live update", client, w)
		# (eventOpt, client1, w) = clientStep 100 client w
		= case eventOpt of
			Nothing = loop client1 d w
			Just event = afterEvent client1 subId event d w

	afterEvent client1 subId event d w
		| event.seSubscriptionId <> subId = loop client1 d w
		= case event.seKind of
			SeFailed = (RErr ("subscription failed: " +++ event.seErrorMessage), client1, w)
			SeUpdated = (ROk event, client1, w)
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test clean           # compiles the client, the example, and the adapter; runs offline unit tests
./run verify-example clean # runs the canonical example against a unique room
./run verify clean         # adds shared local black-box conformance
./run verify-hosted clean  # repeats example and conformance against the real hosted deployment, over real TLS
./run verify-all clean     # builds once, then runs both deployment profiles
```

`./run test clean` proves the client compiles, its offline unit tests pass
(`FoundationTest`, `WireTest`, `HTTPTest`, `WebSocketTest`, `ClientTest`), and
both `convex-adapter` and `convex-example` build as `linux/amd64` binaries.
Two of the test binaries (`ConvexCallTest`, `ConvexLiveTest`) exercise a real
backend end-to-end — an HTTP query/mutation round trip, and the full Live
subscribe/update/five-reconnect sequence — but only when `CONVEX_URL` is set,
so `./run test` itself stays entirely offline while the same binaries are
real, runnable regressions against a live deployment.

## Conformance and protocol notes

- `client/tests/conformance/main.icl` is the NDJSON adapter protocol v1
  executable. It is test infrastructure, not part of the educational API: it
  decodes one command per input line, calls the real client in `client/`, and
  encodes one event per output line, in both stdin/stdout mode and the
  `ADAPTER_LISTEN` TCP mode the shared harness uses (a raw POSIX
  socket/bind/listen/accept, since this is the one place in this client that
  needs a server-side socket).
- The Live layer (`client/Convex/Live.icl`) is a single call stack owning the
  connection at all times, threaded explicitly as a `LiveManager` record
  through every function (Clean's natural analogue of a mutable owning
  pointer) rather than handed to a background worker. `liveStep` advances the
  connection by at most one step — reconnecting if there are active
  subscriptions but no socket, or waiting up to a caller-chosen timeout for
  the next frame — so a caller loop that alternates between reading its own
  command source and calling this function stays responsive to `close`,
  `unsubscribe`, and `debugDisconnect` instead of blocking for seconds inside
  one deep read. Delivery buffering is a direct consequence of this: at most
  one already-decoded event is held between calls, so the step function
  itself is the backpressure.
- Every connection-level failure inside `liveStep` (a stalled peer, a
  protocol violation) closes the socket and is published as a
  `FunctionError`-shaped event per active subscription rather than returned
  as a hard error, so a caller never needs a second failure channel.
- `Convex.TLS`'s handshake and encrypted read/write retry against
  non-blocking `SSL_get_error` results, polled through the same `Deadline`
  the rest of this client threads everywhere — verified end-to-end against
  the real hosted deployment, including full certificate and hostname
  verification. See the honest-limitations section below for the real `clm`
  3.1 code-generation defect this required working around.

## Honest limitations

- **A real `clm` 3.1 code-generation defect, worked around in `Convex.TLS`.**
  Every real TLS handshake against the hosted deployment used to crash the
  Clean runtime with `Run Time Warning: cycle in spine detected` and exit
  255, 100% reproducibly. Root-caused by bisection: a ccall whose type
  string declares a `void` return (`"...:V:A"` — `SSL_free`, `SSL_CTX_free`,
  `SSL_CTX_set_verify`) reliably corrupts Clean's own heap the moment *any*
  other ccall in that connection's lifetime runs afterward, regardless of
  which call it is, its argument types, or Clean-level function boundaries.
  A minimal probe that completes a real handshake against the hosted
  deployment and then forces GC pressure after each individual cleanup step
  isolated it precisely: `SSL_shutdown` then `SSL_free`, with nothing
  after, ran clean every time; adding a single further ccall after
  `SSL_free` — `SSL_CTX_free`, `closeRaw`, even an unrelated diagnostic
  `fcntl` probe — crashed every time. The fix, applied throughout
  `client/Convex/TLS.icl`: every genuinely void-returning OpenSSL binding
  is declared as returning a discarded `Int` instead (`"...:I:A"`), which
  alone eliminates the corruption with no change in behavior. See
  `SSL_CTX_free`'s own comment in that file for the full writeup; this is
  likely worth reporting to the Clean toolchain maintainers.
- Convex.WebSocket's UTF-8 validator is a pragmatic well-formedness check
  (every leading byte's declared sequence length is followed by exactly that
  many continuation bytes), not a full RFC 3629 validator: it does not
  additionally reject overlong encodings, surrogate code points, or
  codepoints above U+10FFFF.
- Live authentication, optimistic writes, WebSocket mutations/actions, and
  `TransitionChunk` assembly are all deferred; only the JSON-safe
  query/mutation/action profile is implemented.
- Reconnection has no exponential backoff yet: a Live bring-up that keeps
  failing is retried on the very next `liveStep` call rather than after a
  growing delay.
- The adapter's own combined wait on both the command input and the Live
  socket is a single 100ms poll on input followed unconditionally by one
  non-blocking `liveStep 0`, rather than a true combined poll on both file
  descriptors: `Client` is an abstract type with no exposed file descriptor.
