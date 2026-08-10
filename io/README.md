# Io

[Io](https://iolanguage.org/) is a small dynamic language created by Steve
Dekorte in 2002. It takes Smalltalk's all-object model and Self's prototypes,
then pares the syntax down until assignments, operators, method calls, and even
control flow are all messages sent to objects. The project describes its
present-day niche plainly: Io values runtime flexibility and a tiny conceptual
core over a large ecosystem, and its current main branch targets WASM/WASI.

This repository uses Io's maintained native branch to demonstrate HTTP and
reactive Convex access. It is educational, unofficial, unsupported by Convex,
and not a production SDK.

## Getting Started

Start with [`examples/basics/main.io`](examples/basics/main.io). It reads a
counter, subscribes before changing it, applies one idempotent mutation, and
waits for the reactive value to move from zero to one.

From the repository root, run the exact example in Docker:

```sh
./run verify-example io
```

Nothing from the Io toolchain is installed on your host.

## Interesting Parts

### A query is a chain of messages

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "io-readme-query" });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**Io**

```io
deploymentUrl := System getEnvironmentVariable("CONVEX_URL")
if(deploymentUrl isNil or deploymentUrl size == 0,
    Exception raise("CONVEX_URL is required")
)
room := "io-readme-query"

// list receives messages to build pairs, then object serializes those pairs.
arguments := Convex object(list("room", Convex string(room)))
client := Convex clientForUrl(deploymentUrl)
response := client query("demo:state", arguments)

// This client preserves Convex values as raw JSON, so this token is not typed.
countJson := Convex field(response value, "count")
countJson println
client close
```

Io has no classes here. `Convex`, `client`, `response`, and the argument list
are objects, and each space-separated operation sends a message to the object
on its left. The React hook owns a live subscription and rerenders the
component; this particular Io `query` is deliberately a one-off HTTP call. The
[full example](examples/basics/main.io) adds strict numeric validation before
using the raw `count` token.

### React hides a lifecycle that Io makes explicit

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const room = "io-readme-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <button disabled>Loading...</button>;
  return (
    <button
      onClick={async () => {
        const result = await increment({
          room,
          language: "typescript",
          runId: crypto.randomUUID(), // A fresh id makes the mutation idempotent.
        });
        console.log(result.state.count); // The mutation result is type-safe too.
      }}
    >
      Count: {state.count}
    </button>
  );
}
```

**Io**

```io
deploymentUrl := System getEnvironmentVariable("CONVEX_URL")
if(deploymentUrl isNil or deploymentUrl size == 0,
    Exception raise("CONVEX_URL is required")
)
room := "io-readme-live"
arguments := Convex object(list("room", Convex string(room)))
client := Convex clientForUrl(deploymentUrl)

// Clone a plain object and add slots to hold the callback's latest delivery.
watch := Object clone
watch latest := nil
watch deliveries := 0
report := block(kind, payload, logs,
    if(kind == "value",
        watch latest = payload
        watch deliveries = watch deliveries + 1
    )
)

// Unlike useQuery, this command-line program owns subscription setup and waits.
subscriptionId := client subscribe("demo:state", arguments, report)
client pumpUntil(block(watch deliveries > 0), client deadlineFor(30000))

runId := room .. "-" .. Convex randomToken(9) // Fresh idempotency key.
result := client mutation("demo:increment", Convex object(list(
    "room", Convex string(room),
    "language", Convex string("io"),
    "runId", Convex string(runId)
)))
result value println // The mutation result is raw JSON, not a typed object.

// Pump again for the reactive update, then release both subscription and client.
client pumpUntil(block(watch deliveries > 1), client deadlineFor(30000))
client unsubscribe(subscriptionId)
client close
```

React mounts, updates, and unmounts `useQuery` for you. This Io client instead
uses a callback plus an explicit event-loop pump, unsubscribe, and close. That
blocking API is a design choice made for this small command-line client, not a
limitation of Io: the language itself also supports coroutines, actors, and
futures.

## Status

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Verified by shared local and hosted conformance | JSON envelope, structured function errors, log lines |
| TLS | Verified by shared local and hosted conformance | OpenSSL client TLS with CA and hostname verification |
| Live subscriptions | Verified by shared local and hosted conformance | Pinned sync profile, Add/Remove, transitions, reconnect and rehydration |
| Bearer token auth | Verified by shared local and hosted conformance | Set and cleared on the HTTP path |
| Live authentication | Not implemented | Deferred |
| WebSocket mutations and actions | Not implemented | Deferred; mutations go over HTTP |
| Optimistic updates, journals, TransitionChunk | Not implemented | Deferred |
| Tagged Convex values (Int64, bytes) | Not implemented | JSON-safe values only |

Shared local and hosted conformance passed 31/31 from a clean exact-head
build, so both the `http` and `live` capability badges are earned. See
[`manifest.yaml`](manifest.yaml) for the `capabilities:` list the evaluator
recorded.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.io -->
```io
#!/usr/local/bin/io
//
// The canonical Convex-from-Io example: watch one shared counter go 0 -> 1.
//
// It asks Convex for the room over HTTP, starts a Live subscription, applies
// one idempotent mutation, and then waits for Live to deliver the new value.
// Every printed line is an assertion: if any operation disagrees with what
// Convex should have done, the example fails instead of printing.
//

// The runtime image installs the client beside this file's entrypoint. A
// source checkout resolves it relative to the script instead.
ConvexExampleBoot := Object clone do(
    clientPath := method(
        installed := "/opt/convex/client/convex.io"
        if(File with(installed) exists, return installed)
        script := System launchScript
        if(script isNil, return installed)
        script pathComponent .. "/../../client/convex.io"
    )
)

if(Lobby hasLocalSlot("Convex") not, Lobby doFile(ConvexExampleBoot clientPath))

ConvexBasics := Object clone do(
    // Convex JSON may spell a whole number as 0.0. Accept a value that is
    // mathematically an integer while rejecting fractions, quoted digits,
    // non-finite spellings and anything outside the range Io can hold exactly.
    // Reading the raw JSON token rather than a decoded Io Number is what makes
    // "1" and 1 distinguishable here at all.
    wholeNumber := method(raw, label,
        token := raw asString asMutable strip
        if(token size == 0, Exception raise(label .. " was empty"))
        index := 0
        if(token at(0) == 45, index = 1)
        digits := 0
        while(index < token size and token at(index) >= 48 and token at(index) <= 57,
            index = index + 1
            digits = digits + 1
        )
        if(digits == 0, Exception raise(label .. " was not a finite whole number"))
        // A decimal point is only acceptable when every following digit is a
        // zero, which is exactly the integral spelling Convex may emit.
        if(index < token size and token at(index) == 46,
            index = index + 1
            zeros := 0
            while(index < token size and token at(index) == 48,
                index = index + 1
                zeros = zeros + 1
            )
            if(zeros == 0, Exception raise(label .. " was not a finite whole number"))
        )
        if(index != token size, Exception raise(label .. " was not a finite whole number"))
        value := token asNumber
        if(value isNan, Exception raise(label .. " was not a finite whole number"))
        if(value abs > 9007199254740992, Exception raise(label .. " overflowed Io's exact integer range"))
        value
    )

    countOf := method(payload, label,
        ConvexBasics wholeNumber(Convex field(payload, "count"), label .. " count")
    )

    lastPathComponent := method(path,
        text := path asString
        slash := text reverseFindSeq("/")
        if(slash isNil, text, text exSlice(slash + 1))
    )

    // Io's VM does not promise a fixed position for a script's own arguments:
    // the interpreter and the script may both appear ahead of them, or neither
    // may. Trusting an index would silently subscribe the verifier's unique
    // room to a path instead. Naming what cannot be a room is reliable, because
    // the verifier's room is a plain identifier and never a path or a flag.
    roomFromArguments := method(arguments, script,
        if(arguments isNil, return nil)
        chosen := nil
        arguments foreach(entry,
            candidate := entry asString
            if(chosen isNil and ConvexBasics isLauncherArgument(candidate, script) not,
                chosen = candidate
            )
        )
        chosen
    )

    isLauncherArgument := method(candidate, script,
        if(candidate asMutable strip size == 0, return true)
        // An interpreter flag such as -e never names a room.
        if(candidate beginsWithSeq("-"), return true)
        name := ConvexBasics lastPathComponent(candidate)
        // The Io binary, and this script under either the installed entrypoint
        // name or its source checkout name.
        if(name == "io", return true)
        if(script isNil not,
            if(candidate == script asString, return true)
            if(name == ConvexBasics lastPathComponent(script), return true)
        )
        candidate containsSeq("/")
    )

    // The verifier passes a unique room as the entrypoint's first argument and
    // also publishes it as EXAMPLE_ROOM. The argument is authoritative; the
    // environment variable is the fallback, and the literal default only exists
    // so the image is pleasant to run by hand.
    room := method(
        chosen := ConvexBasics roomFromArguments(System args, System launchScript)
        if(chosen isNil, chosen = System getEnvironmentVariable("EXAMPLE_ROOM"))
        if(chosen isNil or chosen size == 0, chosen = "io-example")
        chosen
    )

    main := method(
        deploymentUrl := System getEnvironmentVariable("CONVEX_URL")
        if(deploymentUrl isNil or deploymentUrl size == 0,
            Exception raise("CONVEX_URL is required")
        )
        room := ConvexBasics room

        client := Convex clientForUrl(deploymentUrl)
        subscriptionId := nil

        // The Live callback runs inside the client's event loop, so it records
        // what it saw and lets the main flow do the asserting and printing.
        // A subscription always reports the newest value of its query, so the
        // latest payload plus a count of deliveries is everything the example
        // needs - and no update can be lost to a state machine that happened
        // to be looking the other way.
        watch := Object clone
        watch latest := nil
        watch deliveries := 0
        watch failure := nil

        report := block(kind, payload, logs,
            if(kind == "error") then(
                watch failure = Convex text(Convex field(payload, "message"))
            ) else(
                watch latest = payload
                watch deliveries = watch deliveries + 1
            )
        )

        problem := try(
            arguments := Convex object(list("room", Convex string(room)))

            // Ask Convex once over HTTP first. This proves the room really
            // starts at zero before anything subscribes to it.
            current := client query("demo:state", arguments)
            currentCount := ConvexBasics countOf(current value, "current query")
            if(currentCount != 0,
                Exception raise("current count was " .. currentCount .. ", expected 0")
            )
            writeln("current count: " .. currentCount)

            // Start Live before mutating. Its initial value is the proof that
            // no write slipped in between the subscription and the mutation.
            subscriptionId = client subscribe("demo:state", arguments, report)
            arrived := client pumpUntil(
                block(watch deliveries > 0 or watch failure isNil not),
                client deadlineFor(30000)
            )
            if(arrived not, Exception raise("Live did not deliver an initial value"))
            if(watch failure, Exception raise("Live query failed: " .. watch failure))
            initialCount := ConvexBasics countOf(watch latest, "initial Live value")
            if(initialCount != currentCount,
                Exception raise("initial Live count disagreed with the HTTP query")
            )
            writeln("live initial count: " .. initialCount)

            // Arm the wait for the changed value before the mutation goes out.
            // The client services Live while the HTTP exchange is in flight, so
            // a fast deployment can deliver the update before the mutation call
            // even returns.
            beforeMutation := watch deliveries

            // A unique runId is the mutation's idempotency key, so retrying
            // this logical request would not increment the room twice.
            runId := room .. "-" .. Convex randomToken(9)
            applied := client mutation("demo:increment", Convex object(list(
                "room", Convex string(room),
                "language", Convex string("io"),
                "runId", Convex string(runId)
            )))
            wasApplied := Convex field(applied value, "applied") asString asMutable strip
            if(wasApplied != "true", Exception raise("mutation was not applied"))
            writeln("mutation applied: true")
            mutationCount := ConvexBasics countOf(
                Convex field(applied value, "state"), "mutation"
            )
            if(mutationCount != 1,
                Exception raise("mutation count was " .. mutationCount .. ", expected 1")
            )
            writeln("mutation count: " .. mutationCount)

            // Wait for Live to report the change rather than polling with a
            // second query. That is the whole point of a reactive subscription.
            settled := client pumpUntil(
                block(watch deliveries > beforeMutation or watch failure isNil not),
                client deadlineFor(30000)
            )
            if(settled not, Exception raise("Live did not deliver the updated value"))
            if(watch failure, Exception raise("Live query failed: " .. watch failure))
            updatedCount := ConvexBasics countOf(watch latest, "updated Live value")
            if(updatedCount != 1,
                Exception raise("updated Live count was " .. updatedCount .. ", expected 1")
            )
            writeln("live updated count: " .. updatedCount)

            // Only now, with every operation agreeing, print the summary.
            writeln("verified count: " .. currentCount .. " -> " .. updatedCount)
        )

        // Always release the subscription and the sockets, then let a failure
        // set a non-zero exit status with its detail on stderr.
        if(subscriptionId isNil not, client unsubscribe(subscriptionId))
        client close
        if(problem,
            // See Convex writeDiagnostic in convex.io: retried rather than a
            // bare File write, so a transient hiccup in whatever is capturing
            // this process's stderr cannot mask the real failure this is
            // trying to report before exiting non-zero.
            Convex writeDiagnostic(
                File standardError,
                "convex-io example failed: " .. Convex errorMessage(problem) .. "\n"
            )
            System exit(1)
        )
        0
    )
)

// Tests load this file to exercise the same decoder without contacting a
// deployment. Running the file normally still starts the demonstration.
if(Lobby hasLocalSlot("ConvexExampleLoadOnly") not, ConvexBasics main)
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The current Io main branch targets WASM/WASI, while this demonstration builds
the native branch at a pinned commit. That native VM has no maintained modern
network stack, so [`client/convex_transport.c`](client/convex_transport.c)
provides sockets, OpenSSL TLS, polling, secure random bytes, and a monotonic
clock. HTTP, JSON scanning, WebSocket framing, and all Convex-specific behavior
remain in [`client/convex.io`](client/convex.io).

One event loop owns the HTTP exchanges, Live socket, reconnect timers, and
subscription callbacks. This avoids concurrent socket access and gives the
command-line example one explicit place to make progress. Callbacks cannot
start a second HTTP request while one is already running.

Convex values stay as their exact JSON text. Io has one floating-point `Number`
type and no separate JSON-null value, so eager decoding could silently change a
value. The canonical example therefore validates integral counts before
turning them into Io numbers. HTTP responses and WebSocket frames are capped at
2 MiB, headers at 32 KiB, and HTTP calls at a 15-second absolute deadline.

The Live implementation uses the sync profile pinned in
[`manifest.yaml`](manifest.yaml), including reconnect and subscription
rehydration. That profile is internal, undocumented, and may change.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   journals, and `TransitionChunk` assembly are not implemented.
2. The educational API supports JSON-safe Convex values only. Tagged values
   such as Int64 and bytes are deferred.
3. A subscription suppresses any repeat of its last published value. A
   deliberate identical republish would therefore not reach the callback.
4. Building requires network access to fetch the pinned Io commit and `parson`
   submodule. GCC 12, CMake 3.25, and OpenSSL 3 are asserted, but the exact apt
   package versions are not pinned.
5. The small C transport boundary contains no Convex behavior, but whether it
   should make the implementation `native` or `binding` remains a documented
   judgment call.
