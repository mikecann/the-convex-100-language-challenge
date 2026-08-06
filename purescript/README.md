# Convex from PureScript

This is a PureScript client for [Convex](https://convex.dev). It reads a shared
counter over Convex's documented HTTP API, watches the same query over the
reactive `/api/sync` WebSocket, increments it once, and shows both surfaces
agreeing on the journey from `0` to `1`.

Everything Convex-specific is written in PureScript: the JSON codec, HTTP/1.1,
the WebSocket handshake and framing, the sync protocol, and the single Live
owner that holds all of it together. PureScript has no runtime of its own, so
the compiled program runs on the BEAM through the
[purerl](https://github.com/purerl/purerl) Erlang backend, and Erlang/OTP
supplies sockets, TLS, cryptography, timers, and processes through three small
FFI modules that contain no Convex logic.

## This is educational, not an SDK

This client is a demonstration written for a video and a website about how many
languages can talk to Convex. It is unofficial, it is not supported by Convex,
and it is not a production SDK. Do not depend on it.

## Start here

The canonical example is
[`examples/basics/Main.purs`](examples/basics/Main.purs). It is the whole
journey in one file:

1. Create a client for a deployment URL.
2. Read `demo:state` over HTTP and decode the counter, which starts at `0`.
3. Subscribe to the same query *before* changing anything, so no update can
   fall into a gap, and take the initial Live value.
4. Run the `demo:increment` mutation with an idempotency key.
5. Take the Live update the mutation causes, and confirm it agrees with the
   mutation's own return value.
6. Unsubscribe, close the client, and print the final verification line.

Every step checks the value it received. Compiling is not evidence, so the
example fails loudly rather than printing a line it did not earn.

## What works

Nothing has been verified yet. The source is complete and internally
consistent, but no Docker build has been run against it, so every row below is
unproven and no capability badge is claimed.

| Capability | Status | Evidence |
| --- | --- | --- |
| Compiles | not run | `./run test purescript` has not been executed |
| Canonical example | not run | `./run verify-example purescript` has not been executed |
| HTTP (`query`, `mutation`, `action`, structured errors, auth) | implemented, unproven | shared conformance has not been executed |
| Live (`/api/sync` subscribe, update, unsubscribe, five reconnects, query-error recovery) | implemented, unproven | shared conformance has not been executed |
| Live authentication, WebSocket mutations and actions | not implemented | deferred, see limitations |

## The canonical example

This block is generated from the runnable file, so the source here, in the
repository, and on the website are always the same bytes.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.purs -->
```text
-- | Convex from PureScript: one shared counter, read two different ways.
-- |
-- | The program reads a room's counter over Convex's HTTP API, subscribes to
-- | the same query over the reactive `/api/sync` WebSocket, increments the
-- | counter once, and shows both surfaces agreeing on the journey from 0 to 1.
-- |
-- | Everything it prints on standard output is the shared transcript every
-- | language in this repository has to match exactly. Anything explanatory
-- | goes to standard error instead.
module Main (main, count) where

import Convex.Prelude
import Convex as Convex
import Convex.Error (ConvexError)
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live (LiveEvent(..))
import Convex.Live as Live
import Convex.Sys as Sys

-- | A Live update should arrive in milliseconds. Waiting forever would turn a
-- | broken subscription into a hung example instead of a clear failure.
liveTimeout :: Int
liveTimeout = 10000

main :: Effect Unit
main = do
  -- The verifier passes a unique room so concurrent runs cannot share a
  -- counter. The default only exists for someone running the image by hand.
  arguments <- Sys.plainArguments
  let room = fromMaybe "purescript-basic-example" (listHead arguments)

  -- The verifier also supplies the deployment URL; the default points at the
  -- repository's local self-hosted backend.
  deployment <- Sys.env "CONVEX_URL" "http://127.0.0.1:3210"

  -- One client owns both the documented HTTP calls and the single sync
  -- connection. No socket is opened until something is subscribed.
  client <- required "the client could not be created" (Convex.new deployment)
  let args = JsonObject (listSingleton (Tuple "room" (JsonString room)))

  -- These demo functions are public, so no token is needed. A protected
  -- function would call `Convex.setAuth` before any HTTP call.

  -- Read the durable counter through Convex's documented HTTP API first.
  initial <- required "the initial query failed"
    (Convex.call client Convex.Query "demo:state" args)
  initialCount <- count initial.value
  expect (initialCount == 0) "expected the room to start at 0"
  Sys.println "current count: 0"

  -- Subscribe before changing anything. Starting Live first means no update
  -- can fall into a gap between the initial read and the subscription.
  -- Events arrive in this process's mailbox, so the sink is its own id.
  self <- Sys.selfPid
  subscription <- required "the subscription was refused"
    (Convex.subscribe client "demo:state" args self)

  -- A Live query first hydrates with its current value. Decode it into the
  -- same idiomatic integer the HTTP result produced.
  hydrated <- nextCount subscription
  expect (hydrated == 0) "expected Live to start at 0"
  Sys.println "live initial count: 0"

  -- Convex records this idempotency key, so retrying this exact write cannot
  -- increment the room twice.
  let
    mutationArgs = JsonObject
      ( Cons (Tuple "room" (JsonString room))
          ( Cons (Tuple "language" (JsonString "PureScript"))
              (listSingleton (Tuple "runId" (JsonString (room <> "-once"))))
          )
      )
  mutation <- required "the mutation failed"
    (Convex.call client Convex.Mutation "demo:increment" mutationArgs)
  expect (Json.field mutation.value "applied" == Just (JsonBool true))
    "expected the mutation to be applied"
  state <- expectField mutation.value "state"
  mutatedCount <- count state
  expect (mutatedCount == 1) "expected the mutation to leave the room at 1"
  Sys.println "mutation applied: true"
  Sys.println "mutation count: 1"

  -- The sole Live owner decodes the resulting WebSocket transition and relays
  -- the changed value in protocol order.
  updated <- nextCount subscription
  expect (updated == 1) "expected Live to report the incremented value"
  Sys.println "live updated count: 1"

  -- Remove the server-side query, then release the socket and the owner.
  _ <- required "the unsubscribe failed" (Convex.unsubscribe client subscription)
  _ <- required "the client did not close" (Convex.close client)

  -- Reaching this line proves HTTP and Live agreed on one 0 -> 1 journey.
  Sys.println "verified count: 0 -> 1"

-- | Wait for the next value on one subscription.
-- |
-- | Live also reports query failures and transport failures on the same
-- | channel. Turning those into an immediate stop keeps the example honest: a
-- | failed subscription must never look like a missing update.
nextCount :: String -> Effect Int
nextCount subscription = do
  delivery <- Sys.receiveEvent liveTimeout
  case delivery of
    Nothing -> Sys.fatal "Live delivered no update before the timeout"
    Just received -> do
      expect (received.subscriptionId == subscription)
        "received an event for another subscription"
      -- Tell the bounded relay this value has left our mailbox before it sends
      -- another one. A consumer that stops reading therefore cannot grow an
      -- unbounded BEAM mailbox behind the client's own queue limits.
      Live.acknowledge received
      case received.event of
        LiveValue value _logs -> count value
        LiveFailure problem ->
          Sys.fatal (problem.name <> ": " <> problem.message)

-- | Decode the room's counter.
-- |
-- | Convex may spell a whole number as `0` or `0.0`, so both are accepted, and
-- | a fraction, a quoted number, or an out-of-range value is rejected rather
-- | than rounded into something that looks like agreement.
-- |
-- | This is exported only so the regression test can exercise the exact
-- | function the example uses, rather than a second copy of it.
count :: Json -> Effect Int
count value = case Json.field value "count" of
  Nothing -> Sys.fatal "Convex value has no count field"
  Just raw -> case Json.integralInt raw of
    Just number -> pure number
    Nothing -> Sys.fatal "count is not a whole number in range"

-- | Unwrap a client call, stopping with the client's own message on failure.
-- | The three error names Convex distinguishes are preserved here so a
-- | deployment problem never reads like a network problem.
required :: forall a. String -> Effect (Either ConvexError a) -> Effect a
required context action = do
  outcome <- action
  case outcome of
    Right value -> pure value
    Left problem ->
      Sys.fatal (context <> ": " <> problem.name <> ": " <> problem.message)

expectField :: Json -> String -> Effect Json
expectField value key = case Json.field value key of
  Just inner -> pure inner
  Nothing -> Sys.fatal ("Convex value has no " <> key <> " field")

-- | Stop on an unexpected value. Compilation is not evidence, so every step
-- | the example demonstrates is checked at runtime.
expect :: Boolean -> String -> Effect Unit
expect condition message =
  if condition then pure unit else Sys.fatal message
```
<!-- END GENERATED EXAMPLE -->
## Verifying it in Docker

Every build, test, and verification step runs inside Docker. Nothing is
installed on the host.

```sh
./run test purescript
```

Builds the `test` target. That stage downloads the two pinned compiler
binaries, checks the style gate, type-checks and compiles the PureScript to
Erlang, compiles the Erlang with `erlc -Werror`, and runs the four
language-local test programs plus the adapter's stdin smoke tests against the
resulting bytecode.

```sh
./run verify-example purescript
```

Builds the minimal `example-runtime` image and runs the exact
`examples/basics/Main.purs` program against a unique room on the approved local
backend. Its stdout must match `_shared/examples/basics.expected.txt` exactly.

```sh
./run verify purescript
```

Adds the shared black-box conformance suite: the JavaScript oracle and this
client are driven through the same NDJSON adapter protocol against the same
deployment, and only the shared evaluator may award a capability badge.

```sh
./run verify-hosted purescript
./run verify-all purescript
```

Repeat the example and conformance checks against the dedicated hosted drift
target, and run both deployment profiles from one built image.

## How it is put together

| Module | What it owns |
| --- | --- |
| `client/Convex.purs` | The public client: HTTP calls, auth, and the one Live owner |
| `client/Convex/Json.purs` | A JSON codec with Convex's integer rules and its own budgets |
| `client/Convex/Http.purs` | HTTP/1.1 over a socket, with head, body, and deadline bounds |
| `client/Convex/Ws.purs` | RFC 6455 framing as a value, so a read timeout keeps parser state |
| `client/Convex/Live.purs` | The sync protocol: one owner, one socket, one relay per subscription |
| `client/Convex/Error.purs` | The three failures Convex asks callers to tell apart |
| `client/Convex/Prelude.purs` | The small prelude this client is written against |
| `client/Convex/Bytes.purs` | Byte strings and the scans that would be slow one byte at a time |
| `client/Convex/Sys.purs` | The OTP surface: sockets, TLS, crypto, clock, streams, processes |

### No package set

The client depends on no PureScript packages. PureScript ships no built-in
prelude, and the purerl ecosystem's preludes move independently of the
compiler, so depending on one would make a reproducible build depend on a
package set resolving the same way twice. Instead `Convex.Prelude` and
`Convex.Bytes` define the handful of types, operators, and primitives the
client actually uses, and the whole toolchain is two binaries pinned by
SHA-256.

Two consequences are worth knowing while reading the code. `do` notation always
means `Effect`, because `bind` and `discard` are defined for `Effect` only.
And `==`, `<`, and friends are Erlang term operations rather than type classes,
which is sound for the integers, strings, byte strings, and decoded JSON this
client compares.

### Live behaviour

One owner process holds the query-set version, the server's last transition
version, every subscription's last value, and the reconnect schedule. A
connection process owns the socket and is a byte pipe; frame decoding stays in
the owner, so a read timeout part-way through a frame is harmless. A relay
process per subscription carries one event at a time and must ask the owner for
permission immediately before delivery, which makes unsubscribe and
same-identifier replacement real barriers rather than timing assumptions.

Delivery is bounded twice over. Each subscription keeps at most the newest 16
undelivered events within an 8 MiB byte budget, counting the event its relay is
currently holding, and the subscriber must acknowledge each delivery before the
relay carries another. A subscriber that stops reading therefore cannot grow a
BEAM mailbox behind the client's own limits.

### Conformance adapter

`client/tests/conformance/Adapter.purs` is test infrastructure, not public
client code. It speaks NDJSON adapter protocol v1 over stdin/stdout, or over a
TCP connection when `ADAPTER_LISTEN` is set, reserves stdout for protocol
events, and calls the real client for every operation. It implements the
adapter-only `debugDisconnect` command so the shared controller can prove five
real reconnects; that command is declared in `manifest.yaml` and is not part of
the client API.

Input and output are both bounded. One NDJSON command may not exceed 9 MiB, and
a longer line is discarded up to its newline and answered with a protocol
error. Queued output has one global 16-event and 12 MiB budget that includes
the payload the sender is physically writing, and saturation closes the stalled
controller rather than retaining more events. The `runtime` image build proves
both bounds against the real final adapter with a reader that never reads.

### Protocol pins

| Pin | Value |
| --- | --- |
| Sync profile | `convex-rs-0.10.4-unversioned-sync` |
| Sync source commit | `6f1df8a8ba1665084ec001e307ca841ca17074d7` |
| Sync endpoint | `/api/sync` |
| Adapter protocol | v1 |
| PureScript compiler | `purs` 0.15.14 |
| Erlang backend | `purerl` 0.0.24 |
| Runtime | Erlang/OTP 26 |
| Platform | `linux/amd64` |

The sync protocol is not a documented, stable Convex API. It is pinned to the
revision above and treated as drift-sensitive: anything the client cannot
reconcile with that profile is reported as a `ProtocolError` rather than
absorbed.

## Honest limitations

- **Nothing has been verified.** The source is complete, but no Docker build
  has been run, so compilation, the tests, the final image policy, the
  canonical example, and shared conformance are all unproven.
- **The BEAM is a delegated runtime.** PureScript compiles to a host language,
  and this client targets purerl, so the final images contain the BEAM emulator
  plus the `kernel`, `stdlib`, `crypto`, `ssl`, `public_key`, and `asn1`
  applications. No compiler, package manager, or other delegated runtime is
  present, and the image build proves that.
- **`purs-tidy` is not run.** The standard PureScript formatter is distributed
  as a Node package, and adding a JavaScript runtime to this build only to
  reformat source would undercut the point of a two-binary toolchain. The test
  stage enforces a deterministic style gate over the checked-in source instead.
- **Live authentication is deferred.** `Convex.setAuth` affects HTTP calls only;
  the sync connection does not send an `Authenticate` message.
- **WebSocket mutations and actions are deferred.** Mutations and actions go
  over HTTP; only queries are subscribed over the socket.
- **Tagged Convex values are deferred.** The client speaks the `json` format
  and does not decode Convex's tagged representations of `Int64`, `Bytes`, or
  `Set`.
- **`TransitionChunk` assembly is deferred.** Receiving one is reported as
  protocol drift rather than reassembled.
- **JSON has hard bounds.** An object may carry at most 256 entries, nesting is
  limited to 64 levels, and a document to 65536 structural values.
- **Equality is Erlang term equality.** That is sound for everything this
  client compares, but it would not be for values containing functions.
