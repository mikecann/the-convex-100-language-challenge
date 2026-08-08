# Convex from Agda

This is a small native Agda client that calls Convex functions over HTTP and keeps a query current over Live WebSockets. Agda is a dependently typed language with no sockets of its own, so the interesting question is how much of Convex can be expressed in Agda itself. The answer here is: all of it except the octets on the wire.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/Main.agda`](examples/basics/Main.agda). It queries a fresh counter, starts Live before changing it, applies one idempotent mutation, and checks that HTTP, the mutation result, and Live all agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Implemented, awaiting shared evidence |
| Bearer authentication and structured function errors | Implemented, awaiting shared evidence |
| Live initial values, updates, and query-error recovery | Implemented, awaiting shared evidence |
| Unsubscribe barriers, five reconnects, and bounded delivery | Implemented, awaiting shared evidence |

The Docker `test` target builds the toolchain, type-checks and compiles the client, and runs its unit, conformance, and TLS tests on native `linux/amd64`. Shared local and hosted conformance have not run yet, so no capability badge is claimed.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.agda -->
```agda
{-# OPTIONS --without-K #-}

module Main where

open import Convex

-- Convex may send an integral number in a decimal form such as `0.0`. This
-- narrows a Convex value to the non-negative integer the example's output
-- contract needs, and rejects a fractional, non-finite, or out-of-range value
-- rather than rounding it into agreement.
exampleCount : String → JSON → Either String Nat
exampleCount label value = onField (objGet value "count")
  where
    onNat : Maybe Nat → Either String Nat
    onNat nothing = left (label <> " returned a non-integral or out-of-range count")
    onNat (just n) = right n

    onField : Maybe JSON → Either String Nat
    onField nothing = left (label <> " returned no count")
    onField (just counted) = onNat (asNat counted)

-- A Live update carries either a value or a structured error. The example
-- treats a failed query as a failure of the demonstration rather than
-- continuing with a placeholder.
liveValue : String → Maybe Update → Either String JSON
liveValue label nothing = left (label <> " timed out")
liveValue label (just u) = onError (updError u)
  where
    onError : Maybe ConvexError → Either String JSON
    onError (just e) = left (label <> " failed: " <> message e)
    onError nothing = right (updValue u)

-- Cleanup uses the same acknowledged, bounded operations as the rest of the
-- example, so the program cannot exit while the Live worker still owns a
-- socket.
shutdown : Client → Nat → IO ⊤
shutdown client subscriptionId =
  clientUnsubscribe client subscriptionId >> clientClose client >> return tt

stop : Client → String → IO ⊤
stop client text =
  errLine ("Agda example failed: " <> text) >> clientClose client >> exitProcess 1

-- The final Live value after the mutation. Everything the example claims has
-- now been observed on all three surfaces, so the proof line is printed last.
finish : Client → Nat → Nat → Nat → Maybe Update → IO ⊤
finish client subscriptionId current expected latest = onValue (liveValue "updated Live value" latest)
  where
    onCount : Either String Nat → IO ⊤
    onCount (left text) = stop client text
    onCount (right updated) =
      if not (updated ==ⁿ expected) then stop client "updated Live count disagreed with the mutation"
      else
        putLine ("live updated count: " <> showNat updated)
          >> putLine ("verified count: " <> showNat current <> " -> " <> showNat updated)
          >> shutdown client subscriptionId
          >> exitProcess 0

    onValue : Either String JSON → IO ⊤
    onValue (left text) = stop client text
    onValue (right value) = onCount (exampleCount "updated Live value" value)

-- The mutation result. `applied` proves the increment ran for this runId, and
-- `state.count` is the value Live must converge on.
afterMutation : Client → Nat → Nat → Either ConvexError CallResult → IO ⊤
afterMutation client subscriptionId current outcome = onOutcome outcome
  where
    expected : Nat
    expected = suc current

    onCount : JSON → Either String Nat → IO ⊤
    onCount _ (left text) = stop client text
    onCount value (right counted) =
      if not (counted ==ⁿ expected) then stop client "mutation returned an unexpected count"
      else if not (fromMaybe false (asBool (objOr value "applied" jnull))) then
        stop client "mutation was not applied"
      else
        putLine "mutation applied: true"
          >> putLine ("mutation count: " <> showNat counted)
          -- The increment reaches this program through Live rather than
          -- through another HTTP poll.
          >> clientNext client subscriptionId 10000
          >>= finish client subscriptionId current expected

    onOutcome : Either ConvexError CallResult → IO ⊤
    onOutcome (left e) = stop client ("mutation failed: " <> message e)
    onOutcome (right result) =
      onCount (resultValue result)
              (exampleCount "mutation" (objOr (resultValue result) "state" jnull))

-- The first Live value hydrates the query the HTTP call already answered, so
-- the two must agree before the example changes anything.
afterInitial : Client → String → Nat → Nat → Maybe Update → IO ⊤
afterInitial client room subscriptionId current initial = onValue (liveValue "initial Live value" initial)
  where
    increment : String → IO ⊤
    increment runId =
      clientMutation client "demo:increment"
        (jobj (("room" , jstr room) ∷ ("language" , jstr "agda") ∷ ("runId" , jstr runId) ∷ []))
        >>= afterMutation client subscriptionId current

    onCount : Either String Nat → IO ⊤
    onCount (left text) = stop client text
    onCount (right initialCount) =
      if not (initialCount ==ⁿ current) then stop client "initial Live count disagreed with HTTP"
      else
        putLine ("live initial count: " <> showNat initialCount)
          -- runId is the mutation's idempotency key. Reusing it returns the
          -- previous result instead of incrementing twice.
          >> randomHex >>= increment

    onValue : Either String JSON → IO ⊤
    onValue (left text) = stop client text
    onValue (right value) = onCount (exampleCount "initial Live value" value)

-- Live is started before the mutation so no reactive update can be missed
-- between the read and the write.
afterQuery : Client → String → Either ConvexError CallResult → IO ⊤
afterQuery client room outcome = onOutcome outcome
  where
    onSubscribed : Nat → Either ConvexError Nat → IO ⊤
    onSubscribed _ (left e) = stop client ("subscribe failed: " <> message e)
    onSubscribed current (right subscriptionId) =
      clientNext client subscriptionId 10000 >>= afterInitial client room subscriptionId current

    onCount : Either String Nat → IO ⊤
    onCount (left text) = stop client text
    onCount (right current) =
      putLine ("current count: " <> showNat current)
        >> clientSubscribe client "demo:state" (jobj (("room" , jstr room) ∷ []))
        >>= onSubscribed current

    onOutcome : Either ConvexError CallResult → IO ⊤
    onOutcome (left e) = stop client ("current query failed: " <> message e)
    onOutcome (right result) = onCount (exampleCount "current query" (resultValue result))

-- Configure one native Agda client for the deployment the runtime container
-- supplies, then read the shared counter over Convex's documented HTTP
-- endpoint.
run : String → String → IO ⊤
run url room = newClient url "agda-0.1.0" >>= onClient
  where
    onClient : Either ConvexError Client → IO ⊤
    onClient (left e) = errLine ("Agda example failed: " <> message e) >> exitProcess 1
    onClient (right client) =
      clientQuery client "demo:state" (jobj (("room" , jstr room) ∷ []))
        >>= afterQuery client room

-- The verifier passes the unique room as the first argument; the environment
-- variable and the literal are friendly defaults for running the image by
-- hand.
roomFrom : List String → Maybe String → String
roomFrom (first ∷ _) _ = first
roomFrom [] (just configured) = configured
roomFrom [] nothing = "agda-example"

main : IO ⊤
main =
  initStandardStreams
    >> getEnvironment "CONVEX_URL"
    >>= λ url → getArguments
    >>= λ arguments → getEnvironment "EXAMPLE_ROOM"
    >>= λ configured → start url (roomFrom arguments configured)
  where
    start : Maybe String → String → IO ⊤
    start nothing _ = errLine "Agda example failed: CONVEX_URL is required" >> exitProcess 1
    start (just url) room =
      if stringLength url ==ⁿ 0
        then errLine "Agda example failed: CONVEX_URL is required" >> exitProcess 1
        else run url room
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test agda
./run verify-example agda
./run verify agda
./run verify-hosted agda
./run verify-all agda
```

`test` builds the pinned Agda compiler from Hackage, type-checks the client, then compiles and runs the protocol, adapter, TLS, and Live fixture tests before saving the adapter and the canonical example as native `linux/amd64` executables. `verify-example` runs the example from its minimal image against a unique room. The remaining shared commands add local and hosted black-box conformance. Only the root result evaluator can award HTTP or Live badges, so this language branch does not claim them.

## Conformance and protocol notes

The public client implements Convex's documented JSON HTTP endpoints and this repository's pinned `/api/sync` profile directly in Agda. The JSON codec, UTF-8, base64, SHA-1, FNV-1a, HTTP request construction and response framing, RFC6455 framing and handshake verification, the Live envelope and state machine, and the NDJSON adapter are all Agda code. No request invokes another Convex client, the Convex CLI, `curl`, Node.js, or Python.

The reviewed foreign boundary is one file, [`client/Convex/Prim.agda`](client/Convex/Prim.agda). It supplies only what Agda's runtime does not have: a packed byte buffer with constant-time length and indexing, TCP and TLS byte transport, a listener for the adapter's TCP mode, threads and one `MVar`, a monotonic clock, entropy from `/dev/urandom`, and process I/O. None of those primitives understands Convex, HTTP, or WebSockets. TLS is the pure-Haskell `tls` package with the system certificate store, and the client asks it to verify the hostname it was told to connect to; `client/tests/TlsTest.agda` proves the same certificate is accepted for `localhost` and refused for `127.0.0.1`.

One worker owns the Live socket. It alone connects, reads, writes, retires, reconnects, and changes the query-set version; the public API queues acknowledged commands and waits for the worker's reply. A monotonically increasing transport generation is stamped on every published update, and unsubscribe, same-identifier replacement, and the adapter-only debug disconnect each advance it before their acknowledgement is published, so a consumer that already dequeued an update from a retired connection can still recognise and drop it. A valid value received just before a transport failure is restamped rather than discarded, so it stays ahead of the structured failure event. Unchanged rehydration after a reconnect is suppressed with a 64-bit FNV-1a signature instead of a retained copy of the value.

Bounds are byte budgets, not event counts. JSON decoding refuses input past 1 MiB, 64 levels, or 4096 structural nodes, and a lexical pre-pass enforces the two structural limits before a value is built. A WebSocket frame header declaring more than 1 MiB is rejected before any payload octet is buffered. Every read carries an absolute monotonic deadline computed once, so a peer that dribbles a frame one octet at a time is abandoned rather than granted an extension, and a partially filled buffer is never rewound to a false frame boundary. The Live manager retains the newest 16 deliveries within a conservative 20 MiB budget charged at four times the exact encoded length plus a fixed record allowance; active subscriptions have a separate 64-entry, 8 MiB budget. Reconnect backoff starts at 100 ms, caps at 15 seconds, and resets after a successful handshake or a valid server transition.

The adapter speaks bounded UTF-8 NDJSON protocol v1 over stdin/stdout or one `ADAPTER_LISTEN` connection. Its own output queue retains at most the newest 16 encoded events within 6 MiB, including a write currently in flight. Subscription values are droppable under pressure; acknowledgements and errors wait for room until a deadline and then fail rather than being lost. `client/tests/AdapterTest.agda` drives that queue with a reader that never drains and checks the serialised shape of every event kind, including that an absent `id` or `logs` field is omitted rather than sent as null.

Waiting is implemented as bounded polling against absolute deadlines rather than condition variables. That is a deliberate trade: it costs a few milliseconds of latency and keeps the shared state to a single `MVar` per component, which is the whole synchronisation surface a reviewer has to audit.

The final images contain the compiled executable, glibc, `libgmp`, `libffi`, the DNS resolver modules, certificate roots, `/bin/sh`, and the individual POSIX tools the shared verifier requires. They contain no Agda, GHC, Cabal, C compiler, package or network tool, delegated runtime, or multicall binary. Both run as `65532:65532` under the repository's read-only, capability-drop, no-new-privileges, 128 MiB policy.

## Limitations

No Docker build, image, example run, or conformance run has been executed for this checkpoint. Every statement above describes the checked-in source, not observed behaviour, and the manifest deliberately leaves the capability badges empty.

Live authentication, optimistic updates, mutations and actions over the WebSocket, journals, and `TransitionChunk` assembly are deferred; a `TransitionChunk` is treated as recoverable protocol drift and retires the socket rather than publishing partial state. Values cover Convex's JSON-safe subset; tagged Convex value encodings are not converted into richer Agda types. The client depends on Agda's builtin modules only, so `agda-stdlib` is not fetched and the Docker build has a single Agda dependency to pin; the trade is that `client/Convex/Prelude.agda` re-implements a small set of list, string, and arithmetic helpers. Naturals compile to `Integer`, so the byte-at-a-time parsers are correct but not fast, and the documented 1 MiB ceilings are set with that cost in mind. Input beyond the documented line, JSON, subscription, delivery, or output bounds is rejected or coalesced instead of risking unbounded memory.
