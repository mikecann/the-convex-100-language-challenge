# Clean

[Clean](https://clean-lang.org/) is a general-purpose, pure, lazy functional
language created by researchers at Radboud University Nijmegen. It is close to
Haskell in feel, but uses uniqueness types to safely thread state and I/O
through otherwise pure code. Clean is a small modern niche, with current work
centred on its package ecosystem and projects such as the iTask web workflow
system.

This client is unofficial educational material. It demonstrates Convex from
Clean, but it is not an official Convex SDK or a package intended for
production use.

## Getting Started

The canonical [`examples/basics/main.icl`](examples/basics/main.icl) queries a
counter, subscribes before mutating it, and checks the reactive `0 -> 1`
update. From the repository root, Docker builds the exact example below and
runs it against a fresh room:

```sh
./run verify-example clean
```

## Interesting Parts

### The compiler proves there is only one world

Haskell answered "how does a pure language do I/O?" with monads. Clean — born
at Radboud University Nijmegen — answered with uniqueness types: the `*` in
`*World` promises there is never a second reference to the world, so each
Convex call consumes it and hands back a fresh one. The `!` marks are
strictness annotations, eagerness declared right in the type.

```text
clientCall :: !String !String !JSON !Client !*World -> (!Result CallResult, !*World)

// TypeScript: const state = await client.query("demo:state", { room })
# (queryResult, w) = clientCall "query" "demo:state" (JObject [("room", JString room)]) client w
= case queryResult of
	RErr e = abort ("query failed: " +++ e)
	ROk cr = afterQuery room client cr w
```

Use `w` twice and the program simply does not compile: sequencing bugs are
type errors here.

### `#` makes pure code read top to bottom

Clean's `#` is a "let-before": each line rebinds a name for the rest of the
function, so `w` can shadow its previous self one step at a time. The mutation
below reads like an imperative script, yet it desugars to nested lets and
stays a pure expression.

```text
runMutation :: !String !Client !Int !*World -> *World
runMutation room client before w
	// TypeScript: await client.mutation("demo:increment", { room, language, runId })
	# args = JObject [("room", JString room), ("language", JString "Clean"), ("runId", JString (room +++ "-once"))]
	# (mutResult, w) = clientCall "mutation" "demo:increment" args client w
	= case mutResult of
		RErr e = abort ("mutation failed: " +++ e)
		ROk cr = afterMutation room client before cr w
```

That `runId` is an idempotency key: retrying against the same room is safe.

### Arguments are constructors, not strings

Clean 3.1 ships no JSON library, so `Convex.Wire` defines the wire format as a
plain algebraic type. Arguments are assembled from constructors and taken
apart with `jsonLookup` — and `jsonAsWholeInt` knowingly accepts the `0.0`
Convex's JSON profile may use for a whole count.

```text
:: JSON = JNull | JBool Bool | JInt Int | JReal Real
	| JString String | JArray [JSON] | JObject [(String, JSON)]

// TypeScript: { room } — the object literal, spelled as constructor calls
args = JObject [("room", JString room)]
```

### A Live update is something you step toward

Convex's realtime side usually arrives as a callback; this client inverts the
flow. `clientSubscribe` registers interest in `demo:state`, then each
`clientStep 100` advances the WebSocket by at most one bounded step and maybe
hands back a `SyncEvent`. The `|` line is a guard; the example subscribes
before mutating, so the `0 -> 1` update cannot be missed.

```text
// TypeScript: useQuery re-renders for you; here the caller asks for each step
loop client d w
	# (expiredNow, w) = isExpired d w
	| expiredNow = (RErr "timed out waiting for a Live update", client, w)
	# (eventOpt, client1, w) = clientStep 100 client w
	= case eventOpt of
		Nothing = loop client1 d w
		Just event = case event.seKind of
			SeFailed = (RErr ("subscription failed: " +++ event.seErrorMessage), client1, w)
			SeUpdated = (ROk event, client1, w)
```

Demand-driven Live keeps the caller in charge of when the network may act —
and the same loop quietly drives the reconnects counted in the Status table
below.

## Status

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, and action | verified | Shared local and hosted conformance passed 31/31 from a clean exact-head build, including real TLS 1.3 against the hosted deployment. |
| Bearer-token lifecycle | verified | `clientSetAuth`, exercised by the shared conformance suite's bearer-token test. |
| Live initial values, updates, unsubscribe | verified | Verified against both the local and hosted backends. |
| Live reconnect | verified | Five real `debugDisconnect`-driven reconnects, each resending the active subscription and correctly suppressing a duplicate event for an unchanged rehydrated value. |
| Earned capability badges | http, live | Awarded by the shared result evaluator from local and hosted runs at this exact head. |
| Convex tagged values | deferred | JSON-safe values only |
| Live authentication, optimistic writes, WebSocket mutations/actions | deferred | |

These claims come from the repository's recorded shared evaluator results. No
fresh conformance run was performed for this documentation-only change.

## Example

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

## Implementation Notes

- This is a native Clean implementation. Convex-specific HTTP, JSON,
  WebSocket, and Live behaviour is written under [`client/Convex/`](client/Convex/).
  Raw TCP and OpenSSL are reached through Clean's C FFI; no JavaScript client,
  Convex CLI, `curl`, or other delegated client performs the calls.
- The bundled Clean 3.1 distribution has no ready-made JSON, HTTP, or
  WebSocket stack for this setup, so the client includes those layers. HTTP
  calls open one connection per query, mutation, or action. Live keeps one
  connection and one call stack in charge of reads, writes, subscription
  state, and reconnects.
- Clean's uniqueness typing matters most at the actual effect boundary here.
  Memory helpers thread both their pointer and `*World` through FFI reads and
  writes, preventing reordering or accidental loss of a write. `Client` and
  its internal `LiveManager` are explicitly returned as updated values, but
  they are not declared unique types.
- Clean 3.1 miscompiled void-returning OpenSSL `ccall` declarations in this
  workload and corrupted the Clean heap. `Convex.TLS` works around that
  measured toolchain bug by declaring those functions as returning a discarded
  `Int`. TLS still verifies the certificate and hostname.

## Known Issues

1. WebSocket UTF-8 checking validates byte sequence shape but does not reject
   every overlong encoding, surrogate, or code point above U+10FFFF.
2. Live authentication, optimistic writes, WebSocket mutations and actions,
   and `TransitionChunk` assembly are deferred. HTTP bearer authentication and
   JSON-safe query, mutation, and action calls are supported.
3. Failed Live reconnects have no exponential backoff. The next `clientStep`
   retries immediately.
4. The conformance adapter polls command input for up to 100 ms before a
   non-blocking Live step, so either kind of input may take roughly 100 ms to
   be noticed.
