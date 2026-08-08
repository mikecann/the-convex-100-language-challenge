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
            File standardError write("convex-io example failed: " .. Convex errorMessage(problem) .. "\n")
            System exit(1)
        )
        0
    )
)

// Tests load this file to exercise the same decoder without contacting a
// deployment. Running the file normally still starts the demonstration.
if(Lobby hasLocalSlot("ConvexExampleLoadOnly") not, ConvexBasics main)
