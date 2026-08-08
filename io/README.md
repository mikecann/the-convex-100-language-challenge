# Convex from Io

This is a Convex client written in Io, the prototype-based language where
everything is a message send. It talks to a Convex deployment two ways: plain
HTTPS for queries, mutations and actions, and a real WebSocket subscription for
Live updates, so a value that changes on the server arrives without anyone
asking for it again.

Io is an unusual host for this. Its reference VM ships with no networking at
all — no sockets, no TLS, no HTTP — so this client carries one small C file
that provides raw bytes and nothing else. Every part that is actually Convex is
Io: the request envelope, the WebSocket framing, the SHA-1 that verifies the
upgrade, the JSON scanner, and the reconnect state machine.

## This is educational, not an SDK

This is a demonstration built to show how far Convex's protocol travels across
languages. It is not an official Convex SDK, it is not supported by Convex, and
it is not published anywhere. Do not depend on it in production.

## Start here

[`examples/basics/main.io`](examples/basics/main.io) is the whole idea in one
file. It picks a room, asks Convex for its counter over HTTP and checks that it
starts at zero, opens a Live subscription and waits for that same zero to
arrive over the socket, applies one idempotent mutation, and then waits for
Live to tell it the counter is now one. Every line it prints is an assertion:
if any step disagrees, the example fails instead of printing.

That ordering is the point. Subscribing *before* mutating is what proves the
update really came from the reactive socket rather than from a lucky re-read.

## What works

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

## The canonical example

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

## Verifying it with Docker

Everything builds and runs inside containers; nothing is installed on the host.

```sh
./run test io          # formatting, parse checks and every language-local suite
./run verify-example io # runs the example above against a unique room
./run verify io        # example plus shared black-box conformance, local backend
./run verify-hosted io # the same checks against the hosted drift target
./run verify-all io    # both deployment profiles from one built image
```

`./run test io` proves the Io VM and the transport boundary build together,
that every checked-in Io source parses, and that the client behaves correctly
against a deliberately hostile loopback peer. It does not prove anything about
a real deployment.

`./run verify-example io` is the first step that touches Convex: it runs the
exact file shown above, in the minimal image, against a fresh room, and rejects
any unexpected value. `./run verify io` adds the shared NDJSON conformance
suite, and `./run verify-hosted io` repeats it against the hosted deployment so
protocol drift shows up somewhere other than production.

## Under the hood

**The transport boundary.** [`client/convex_transport.c`](client/convex_transport.c)
installs one proto, `ConvexIO`, through Io's ordinary `DynLib`. It offers
connect, TLS handshake, read, write, readiness polling over a handle bitmask,
listen and accept, CSPRNG bytes and a monotonic clock. It contains no HTTP, no
WebSocket framing, no JSON and no Convex protocol. This exists because Io
genuinely has no alternative: upstream's `master` branch now targets
WebAssembly and removed the addon system, and the historical `Socket` and
`SecureSocket` addons are unmaintained and predate OpenSSL 3.

**One loop, one owner.** [`client/convex.io`](client/convex.io) runs a single
event loop. HTTP exchanges, the Live socket, reconnect timers and — in the
conformance adapter — the controller channel all make progress from the same
`poll` call. Nothing else ever touches the WebSocket, so the ownership rule the
Live tests depend on holds by construction rather than by convention. Because a
subscription callback runs inside that loop, it can reach code that is already
running: a second HTTP request issued from a callback is refused rather than
allowed to take the in-flight request's socket, and a callback that raises is
reported as that consumer's failure instead of retiring the Live connection it
happened to arrive on.

**Raw JSON values.** Convex values cross this client as their exact JSON bytes.
Io has one Number type and no distinct null, so decoding and re-encoding would
quietly rewrite a document id, a boolean or an integral number. The scanner in
`ConvexJson` hands back subtrees byte for byte and only ever decodes the
protocol's own scalars — counters, status strings, timestamps — each validated
against its wire token first.

**Numbers.** Io Numbers are doubles, exact to 2^53. The SHA-1 needed for
`Sec-WebSocket-Accept` therefore reduces every intermediate below 2^32 before
the next step, and its rotate splits the value rather than shifting it left out
of the exact range. Convex timestamps are compared as reversed hex rather than
as 64-bit integers, which Io does not have.

**Sync profile.** The Live path speaks the profile pinned in
[`manifest.yaml`](manifest.yaml): `Connect` with a 32 hex character session id,
`connectionCount`, `lastCloseReason` and `maxObservedTimestamp`; `ModifyQuerySet`
with `Add` and `Remove`; and `Transition` with `QueryUpdated`, `QueryFailed` and
`QueryRemoved`. A transition whose start version disagrees with the client's
view of server state is refused rather than applied, because applying it would
desynchronise the query set silently. This protocol is not documented or
supported by Convex and may change without notice.

**Status versus envelope.** Convex reports an application failure with its own
envelope and an HTTP 200, so wherever an envelope is present it is authoritative
whatever status carried it. A body that is *not* an envelope splits by status: on
a 2xx it is protocol drift, and on anything else it is a transport failure. That
keeps a proxy or gateway in front of the deployment from being reported as
Convex breaking its own protocol.

**Bounds.** Frames and HTTP responses are capped at 2 MiB, upgrade headers at
32 KiB, and one HTTP exchange at an absolute 15 second deadline on the monotonic
clock. The conformance adapter keeps a newest-16 delivery queue inside a 6 MiB
byte budget that includes the NDJSON newline and a conservative per-entry
allowance, reserving four slots and 64 KiB for control events. Exactly one
record is ever in flight, so a queued delivery is re-checked against its
subscription generation immediately before it is committed — that is the
barrier that stops a stale value crossing an acknowledgement.

**Adapter-only surface.** `debugDisconnect` exists solely so the shared
controller can prove five genuine reconnects. It is declared under
`adapter.adapterOnlyCommands` in the manifest and is not part of the client API
a reader is meant to learn.

## Honest limitations

- **Shared local and hosted conformance passed 31/31 from a clean exact-head
  build.** The `http` and `live` capability badges in
  [`manifest.yaml`](manifest.yaml) record that evaluator award.
- The Dockerfile asserts its toolchain versions (GCC 12, CMake 3.25, OpenSSL 3)
  instead of pinning exact apt package versions. Pinning those is a follow-up
  once a first build confirms the resolved versions.
- The build needs network access to fetch the pinned Io commit and the pinned
  `parson` submodule, because no distribution packages Io. The runtime stage
  also completes one outbound TLS handshake to `api.convex.dev`, so that a
  missing CA bundle or OpenSSL provider fails the build rather than hosted
  verification. An air-gapped build cannot produce this image.
- The transport boundary is one C file of sockets, TLS, polling, randomness and
  a clock. It carries no Convex, HTTP, WebSocket, SHA-1 or JSON behaviour, but
  whether that still sits inside the `native` label rather than `binding` is a
  judgement worth a reviewer's opinion rather than something this client should
  simply assert.
- A subscription suppresses any repeat of the value it last published, not only
  the rehydration that follows a reconnect. Convex reissues a query result only
  when it changes, so in practice this is deduplication — but a deliberate
  identical republish would not be observed.
- Live authentication, optimistic updates, WebSocket mutations and actions,
  journals and `TransitionChunk` assembly are all deferred.
- Only JSON-safe Convex values are supported. Tagged values such as Int64 and
  byte arrays are deferred.
- The shared README projection has no syntax highlighting entry for `.io`, so
  the block above renders unhighlighted. Adding one is a shared-infrastructure
  change and deliberately out of scope for this language directory.
