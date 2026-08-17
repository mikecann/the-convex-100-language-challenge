<img src="logo.png" alt="PureScript logo" width="220">
<!-- Logo source: https://github.com/purescript/logo/blob/master/PS_Logo_Final.svg -->

# PureScript

[PureScript](https://www.purescript.org/) is a small, strongly typed functional
language created by Phil Freeman and heavily inspired by Haskell. Its usual
home is the JavaScript ecosystem, where people use its expressive types and
JavaScript interop for web applications, servers, and libraries. It remains a
specialist choice today, but it has an active package and learning ecosystem.

PureScript can target other backends too. This demonstration uses
[purerl](https://github.com/purerl/purerl), which turns the compiler's CoreFn
output into Erlang source, so the client ultimately runs on the BEAM instead of
Node.js. This is an educational, unofficial Convex client for a video and
website, not a production SDK and not supported by Convex.

## Getting Started

The best place to begin is the
[canonical counter example](examples/basics/Main.purs). It reads `demo:state`,
starts a Live subscription, calls `demo:increment`, and checks the same `0` to
`1` journey through both interfaces.

From the repository root, run:

```sh
./run verify-example purescript
```

The command builds the minimal example image and runs that exact source file in
Docker against a unique room. Nothing from the PureScript toolchain needs to be
installed on your host.

## Interesting Parts

### JSON is a sum type, not an object literal

PureScript inherits Haskell's algebraic data types, so this client models a
Convex value as a real `Json` sum type rather than leaning on JavaScript's
grab-bag `object`. Building a request means reaching for constructors —
`JsonObject`, `JsonString`, `Tuple` — instead of writing object-literal syntax.

```purescript
data Json
  = JsonNull
  | JsonBool Boolean
  | JsonInt Int
  | JsonNumber Number
  | JsonString String
  | JsonArray (List Json)
  | JsonObject (List (Tuple String Json)) -- keeps key order, unlike a JS object

let mutationArgs = JsonObject
      ( Cons (Tuple "room" (JsonString room))
          (listSingleton (Tuple "language" (JsonString "PureScript")))
      )
-- TypeScript: await increment({ room, language: "PureScript" })
```

Convex re-encodes and compares these values elsewhere in the client, so making
key order part of the type — rather than trusting whatever a hash map hands
back — is a deliberate design choice, not an oversight.

### A missing field is `Nothing`, never an exception

Convex results arrive as untyped JSON, so instead of trusting a generated type
and throwing on a bad shape, this client leans on PureScript's `Maybe`.
Decoding a mutation's result means matching down through every layer by hand.

```purescript
case Json.field result.value "state" of
  Nothing -> Sys.fatal "the mutation returned no state"
  Just state -> case Json.field state "count" of
    Nothing -> Sys.fatal "the state returned no count"
    Just raw -> case Json.integralInt raw of
      Nothing -> Sys.fatal "count was not a whole number"
      Just count ->
        Sys.println ("mutation count: " <> intToString count)
        -- TypeScript: result.state.count, trusted from generated types
```

The chain doesn't get shorter as the response gets deeper, but it also never
gets to lie: every field that might be missing has to be opened before it can
be used.

### A Live update lands in your mailbox, not a callback

This client's PureScript compiles through [purerl](https://github.com/purerl/purerl)
to Erlang, so it runs as an honest-to-goodness BEAM process — and Live is built
on that fact rather than emulated on top of it. Subscribing hands Convex a
process id, and updates arrive as ordinary messages in that process's mailbox.

```purescript
self <- Sys.selfPid
subscription <- Convex.subscribe client "demo:state" args self
delivery <- Sys.receiveEvent liveTimeout
case delivery of
  Nothing -> Sys.fatal "Live timed out"
  Just received -> do
    Live.acknowledge received -- backpressure: this value has left the mailbox
    case received.event of
      LiveValue value _logs -> count value
      LiveFailure problem -> Sys.fatal problem.message
-- TypeScript: useQuery(api.demo.state, { room }) triggers a rerender instead
```

Each subscription holds at most 16 undelivered events, so `acknowledge` is not
optional bookkeeping — it's the signal that keeps a slow reader's mailbox from
growing without bound.

## Status

The checked-in evidence awarded both `http` and `live`. This README rewrite did
not rerun shared verification or change those claims.

| Capability | Status | Existing evidence |
| --- | --- | --- |
| Compiles | verified | `./run test purescript` completed the PureScript, purerl, and Erlang build plus four language-local suites |
| Canonical example | verified | the exact six-line transcript matched on local and hosted deployments |
| HTTP | verified | query, mutation, action, structured errors, and authentication passed local and hosted conformance |
| Live | verified | subscribe, update, unsubscribe, five reconnects, and query-error recovery passed local and hosted conformance |
| Live authentication, WebSocket mutations, WebSocket actions | not implemented | deliberately deferred |

## Example

This generated block is the runnable
[`examples/basics/Main.purs`](examples/basics/Main.purs) file. The repository
and website use the same bytes.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.purs -->
```purescript
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

## Implementation Notes

This implementation is declared `transpiled`. The pinned build path is
`purs` 0.15.14 to CoreFn, `purerl` 0.0.24 to Erlang source, then Erlang/OTP 26
to BEAM bytecode for `linux/amd64`. OTP provides sockets, TLS, cryptography,
timers, and processes through three small Erlang FFI modules. All JSON, HTTP,
WebSocket, and Convex-specific decisions remain in PureScript.

There is no package set. [`Convex.Prelude`](client/Convex/Prelude.purs) and
[`Convex.Bytes`](client/Convex/Bytes.purs) contain the small vocabulary the
client needs, keeping the build to two pinned compiler binaries. In this code,
`do` notation is specifically wired to `Effect`, while equality and ordering
use Erlang term operations. That is safe for the concrete values this client
compares, but it is a deliberate local design rather than normal unrestricted
PureScript.

Live has one owner process for connection and query state, one socket process,
and one relay per subscription. Each subscription retains at most 16
undelivered events within an 8 MiB budget, and every delivered event must be
acknowledged. That explicit backpressure is why the mailbox example calls
`Live.acknowledge`.

The Live implementation targets the pinned
`convex-rs-0.10.4-unversioned-sync` profile at source commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. `/api/sync` is not a documented,
stable public protocol, so unfamiliar transitions become `ProtocolError`
values rather than being guessed at.

The useful Docker checks remain separate:

```sh
./run test purescript
./run verify-example purescript
./run verify purescript
./run verify-hosted purescript
./run verify-all purescript
```

`test` covers the language-local build and tests. `verify-example` runs the
teaching example. `verify` and `verify-hosted` add shared conformance against
local and hosted deployments, while `verify-all` runs both profiles from the
same built source.

## Known Issues

1. Live authentication is not implemented. `Convex.setAuth` affects HTTP calls
   only.
2. Mutations and actions use HTTP. The WebSocket side subscribes to queries
   only.
3. Tagged Convex `Int64`, `Bytes`, and `Set` values are not decoded, and a
   `TransitionChunk` is reported as protocol drift instead of being assembled.
4. JSON is intentionally bounded to 256 entries per object, 64 nesting levels,
   and 65,536 structural values.
5. `purs-tidy` is not part of the pinned toolchain. Docker applies the
   repository's deterministic style checks instead.
