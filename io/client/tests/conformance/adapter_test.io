//
// Coverage for the test-only adapter: exact event shapes, the bounded output
// queue under a genuinely stopped reader, and the generation barrier that
// keeps a stale subscription value from crossing an acknowledgement.
//
// The events are written through a real loopback socket and read back from the
// other end, so what is asserted is the bytes the shared controller would
// actually validate.
//

ConvexAdapterTest := Object clone do(
    // A peer that accepts the connection but is told when to read, so a test
    // can hold the reader still and watch the queue behave.
    openCapture := method(
        capture := Object clone
        capture peer := ConvexTestPeer clone start
        capture peer autoRecycle = false
        capture stream := ConvexStream clone openTo("127.0.0.1", capture peer port, false)
        capture output := ConvexAdapterOutput clone attachStream(capture stream)
        // Complete the non-blocking connect before anything is emitted.
        for(round, 1, 500,
            capture stream serviceWrite
            capture peer service
            if(capture stream isOpen, break)
        )
        capture
    )

    settle := method(capture, rounds,
        for(round, 1, rounds,
            capture output serviceWrite
            capture peer service
        )
        capture
    )

    // Everything the peer has received, one NDJSON event per entry.
    events := method(capture,
        text := capture peer inbox asString
        found := list()
        text split("\n") foreach(line, if(line size > 0, found append(line)))
        found
    )

    close := method(capture,
        capture stream close
        capture peer shutdown
    )

    // A large payload built by doubling, so the test does not spend its time
    // in an Io append loop.
    padding := method(target,
        out := Sequence clone appendSeq("0123456789abcdef")
        while(out size < target, out appendSeq(out))
        out exSlice(0, target)
    )

    // The bounds tests need megabyte payloads, and the client's own JSON
    // encoder inspects every byte. These payloads are known to be plain
    // hexadecimal characters, so wrapping them in quotes is already valid JSON
    // and keeps the test fast without weakening what it proves.
    quotedPadding := method(target,
        out := Sequence clone
        out appendSeq("\"")
        out appendSeq(ConvexAdapterTest padding(target))
        out appendSeq("\"")
        out asSymbol
    )

    run := method(
        ConvexTest begin("adapter/event-shapes")
        capture := ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone

        ConvexAdapter respondReady("h1")
        ConvexAdapter respondAck("a1")
        ConvexAdapter respondResult("r1", "{\"count\":1}", "[]")
        ConvexAdapter respondResult("r2", "null", "[\"logged\"]")
        ConvexAdapter respondError("e1", "FunctionError", "boom", "{\"code\":\"X\"}", "[]")
        ConvexAdapter respondError(nil, "ProtocolError", "no id", nil, nil)
        ConvexAdapter respondClosed("c1")
        ConvexAdapterTest settle(capture, 400)

        lines := ConvexAdapterTest events(capture)
        ConvexTest equals(lines size, 7, "every control event reached the reader")
        ConvexTest equals(
            lines at(0),
            "{\"protocolVersion\":1,\"id\":\"h1\",\"type\":\"ready\",\"language\":\"io\"," .. \
                "\"implementation\":\"native-io-" .. System version .. "\"," .. \
                "\"runtime\":\"io-" .. System version .. "\"}",
            "the ready event reports version, language, provenance and runtime"
        )
        ConvexTest equals(lines at(1), "{\"id\":\"a1\",\"type\":\"ack\"}", "an ack carries only its id")
        ConvexTest equals(
            lines at(2),
            "{\"id\":\"r1\",\"type\":\"result\",\"value\":{\"count\":1}}",
            "an empty log array is omitted rather than serialized"
        )
        ConvexTest equals(
            lines at(3),
            "{\"id\":\"r2\",\"type\":\"result\",\"value\":null,\"logs\":[\"logged\"]}",
            "a real log array is included and a null value is preserved"
        )
        ConvexTest equals(
            lines at(4),
            "{\"id\":\"e1\",\"type\":\"error\",\"error\":{\"name\":\"FunctionError\"," .. \
                "\"message\":\"boom\",\"data\":{\"code\":\"X\"}}}",
            "a structured error keeps its raw data"
        )
        ConvexTest equals(
            lines at(5),
            "{\"type\":\"error\",\"error\":{\"name\":\"ProtocolError\",\"message\":\"no id\"}}",
            "an unknown id is omitted rather than serialized as null"
        )
        ConvexTest equals(lines at(6), "{\"id\":\"c1\",\"type\":\"closed\"}", "the closed event is exact")
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/subscription-shapes")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter subscriptions atPut("s1", 0)
        ConvexAdapter generations atPut("s1", 1)
        ConvexAdapter output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        ConvexAdapter deliver("s1", 1, "value", "{\"count\":0}", "[]")
        ConvexAdapter deliver("s1", 1, "error", Convex object(list(
            "name", Convex string("FunctionError"),
            "message", Convex string("nope"),
            "data", "{\"code\":\"E\"}"
        )), "[\"noted\"]")
        ConvexAdapterTest settle(capture, 400)
        lines = ConvexAdapterTest events(capture)
        ConvexTest equals(lines size, 2, "both subscription events reached the reader")
        ConvexTest equals(
            lines at(0),
            "{\"type\":\"subscription\",\"subscriptionId\":\"s1\",\"value\":{\"count\":0}}",
            "a subscription value carries no id and no empty logs"
        )
        ConvexTest equals(
            lines at(1),
            "{\"type\":\"subscription\",\"subscriptionId\":\"s1\"," .. \
                "\"error\":{\"name\":\"FunctionError\",\"message\":\"nope\",\"data\":{\"code\":\"E\"}}," .. \
                "\"logs\":[\"noted\"]}",
            "a subscription error keeps its structured data and logs"
        )
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/absent-error-data")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter subscriptions atPut("s1", 0)
        ConvexAdapter generations atPut("s1", 1)
        ConvexAdapter output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        // A transport or protocol failure carries no structured data. It
        // reaches the adapter either as nil or as the literal null the wire
        // spells it with, and both must produce an event with no data member:
        // absent is not the same claim as present-and-null.
        ConvexAdapter respondError("e1", "TransportError", "peer closed", nil, nil)
        ConvexAdapter respondError("e2", "ProtocolError", "bad envelope", "null", nil)
        ConvexAdapter deliver("s1", 1, "error", Convex object(list(
            "name", Convex string("TransportError"),
            "message", Convex string("peer closed")
        )), "[]")
        ConvexAdapterTest settle(capture, 400)
        lines = ConvexAdapterTest events(capture)
        ConvexTest equals(lines size, 3, "every event reached the reader")
        ConvexTest equals(
            lines at(0),
            "{\"id\":\"e1\",\"type\":\"error\",\"error\":{\"name\":\"TransportError\"," .. \
                "\"message\":\"peer closed\"}}",
            "absent data is omitted entirely"
        )
        ConvexTest equals(
            lines at(1),
            "{\"id\":\"e2\",\"type\":\"error\",\"error\":{\"name\":\"ProtocolError\"," .. \
                "\"message\":\"bad envelope\"}}",
            "a null data token is omitted rather than serialized"
        )
        ConvexTest equals(
            lines at(2),
            "{\"type\":\"subscription\",\"subscriptionId\":\"s1\"," .. \
                "\"error\":{\"name\":\"TransportError\",\"message\":\"peer closed\"}}",
            "a subscription failure with no data omits it too"
        )
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/generation-barrier")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter subscriptions atPut("s1", 0)
        ConvexAdapter generations atPut("s1", 1)
        ConvexAdapter output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        // An event from a generation that has already been replaced never
        // reaches the queue at all.
        ConvexAdapter generations atPut("s1", 2)
        ConvexAdapter deliver("s1", 1, "value", "{\"stale\":true}", "[]")
        ConvexAdapterTest settle(capture, 200)
        ConvexTest equals(
            ConvexAdapterTest events(capture) size,
            0,
            "an event from a retired generation is never emitted"
        )
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/barrier-after-dequeue")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter subscriptions atPut("s1", 0)
        ConvexAdapter generations atPut("s1", 1)
        ConvexAdapter output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        // Pause the queue after the entry has been dequeued but before it is
        // committed, and invalidate the subscription in that window. This is
        // the exact instant a naive implementation would publish a stale value
        // behind an acknowledgement.
        capture output pauseAfterDequeue = block(ConvexAdapter invalidate("s1"))
        ConvexAdapter deliver("s1", 1, "value", "{\"stale\":true}", "[]")
        ConvexAdapter respondAck("after")
        ConvexAdapterTest settle(capture, 400)
        lines = ConvexAdapterTest events(capture)
        ConvexTest equals(lines size, 1, "only the acknowledgement crosses the barrier")
        ConvexTest equals(
            lines at(0),
            "{\"id\":\"after\",\"type\":\"ack\"}",
            "the stale value is dropped at the barrier, not published"
        )
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/same-id-replacement")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter subscriptions atPut("s1", 0)
        ConvexAdapter generations atPut("s1", 1)
        ConvexAdapter output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        // A second subscribe on an id that is already in use retires the old
        // relay and installs a new generation. Doing that in the window after
        // the old value has been dequeued proves the invalidation really is a
        // barrier: the replacement's acknowledgement must not be able to
        // follow a value from the subscription it replaced.
        capture output pauseAfterDequeue = block(
            ConvexAdapter invalidate("s1")
            ConvexAdapter subscriptions atPut("s1", 1)
        )
        ConvexAdapter deliver("s1", 1, "value", "{\"fromTheOldQuery\":true}", "[]")
        ConvexAdapter respondAck("replaced")
        ConvexAdapter deliver(
            "s1", ConvexAdapter generationFor("s1"), "value", "{\"count\":5}", "[]"
        )
        ConvexAdapterTest settle(capture, 400)
        lines = ConvexAdapterTest events(capture)
        ConvexTest equals(lines size, 2, "the replaced query's value never reaches the reader")
        ConvexTest equals(
            lines at(0),
            "{\"id\":\"replaced\",\"type\":\"ack\"}",
            "the replacement acknowledgement comes first"
        )
        ConvexTest equals(
            lines at(1),
            "{\"type\":\"subscription\",\"subscriptionId\":\"s1\",\"value\":{\"count\":5}}",
            "only the new generation delivers after the acknowledgement"
        )
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/stopped-reader-bounds")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter subscriptions atPut("s1", 0)
        ConvexAdapter generations atPut("s1", 1)
        ConvexAdapter output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        // The peer is never serviced from here on, so the reader really has
        // stopped: the kernel buffer fills and stays full.
        big := ConvexAdapterTest quotedPadding(1500000)
        for(round, 1, 12,
            ConvexAdapter deliver("s1", 1, "value", big, "[]")
            capture output serviceWrite
        )
        ConvexTest ok(
            capture output droppedCount > 0,
            "a stopped reader causes deliveries to be dropped rather than queued forever"
        )
        ConvexTest ok(
            capture output pendingBytes <= capture output maxBytes,
            "the accounted byte budget is never exceeded"
        )
        ConvexTest ok(
            capture output queue size <= capture output maxEvents,
            "the queued event count stays bounded"
        )
        // Backpressure is not an error. An acknowledgement that cannot be
        // written yet waits behind the record already in flight; raising
        // instead would turn a stopped reader into a response the controller
        // can never receive, which is precisely the failure it is trying to
        // report.
        backpressured := try(
            for(round, 1, 20, ConvexAdapter respondAck("ack-" .. round asString))
        )
        ConvexTest ok(
            backpressured isNil,
            "control events queue under backpressure rather than raising"
        )
        ConvexTest equals(
            capture output droppedCount > 0 and capture output queue size >= 20,
            true,
            "every acknowledgement is kept while only deliveries are discarded"
        )
        // What keeps that queue bounded is the command side: while the output
        // is saturated the adapter stops reading commands at all, so it cannot
        // accumulate answers nobody is collecting.
        ConvexTest ok(
            capture output isBackpressured,
            "a saturated output reports backpressure to the command side"
        )
        pausedInput := ConvexAdapterInput clone attachStream(capture stream)
        pausedInput isPaused = block(capture output isBackpressured)
        ConvexTest ok(
            pausedInput wantsRead not,
            "no further command is read while the output is saturated"
        )
        // Even under all that pressure a control event must still be accepted,
        // which is what the reserved slice of the budget exists for.
        ConvexAdapter respondClosed("c-final")
        ConvexTest ok(
            capture output queue size > 0,
            "a control event is still admitted while deliveries are being dropped"
        )
        ConvexTest ok(
            capture output pendingBytes <= capture output maxBytes,
            "admitting the control event keeps the budget"
        )
        // Draining proves the control event survived the pressure intact.
        drained := false
        for(round, 1, 4000,
            capture output serviceWrite
            capture peer service
            if(capture output isDrained, drained = true; break)
        )
        ConvexTest ok(drained, "the backlog drains once the reader resumes")
        lines = ConvexAdapterTest events(capture)
        ConvexTest ok(lines size > 0, "events reach the reader after it resumes")
        ConvexTest equals(
            lines at(lines size - 1),
            "{\"id\":\"c-final\",\"type\":\"closed\"}",
            "the reserved control event is the last thing written"
        )
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/oversized-control-event")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        // A control event larger than the entire budget is a programming
        // error, and must be raised rather than silently truncated.
        raised := try(
            capture output emit(ConvexAdapterTest quotedPadding(7000000), false, nil, 0)
        )
        ConvexTest ok(raised isNil not, "an oversized control event raises")
        ConvexAdapterTest close(capture)

        ConvexTest begin("adapter/command-handling")
        capture = ConvexAdapterTest openCapture
        ConvexAdapter output = capture output
        ConvexAdapter subscriptions = Map clone
        ConvexAdapter generations = Map clone
        ConvexAdapter handleLine("not json at all")
        ConvexAdapter handleLine("[1,2]")
        ConvexAdapter handleLine("{\"op\":\"hello\",\"protocolVersion\":1}")
        ConvexAdapter handleLine("{\"id\":\"x\",\"op\":\"nonsense\"}")
        ConvexAdapter handleLine("{\"protocolVersion\":2,\"id\":\"v\",\"op\":\"hello\"}")
        ConvexAdapterTest settle(capture, 400)
        lines = ConvexAdapterTest events(capture)
        ConvexTest equals(lines size, 5, "every malformed command produced exactly one response")
        ConvexTest ok(
            lines at(0) containsSeq("\"type\":\"error\"") and lines at(0) containsSeq("\"id\"") not,
            "a non-JSON line is answered without an id"
        )
        ConvexTest ok(
            lines at(1) containsSeq("command must be a JSON object"),
            "a JSON array is not a command"
        )
        ConvexTest ok(
            lines at(2) containsSeq("command omitted valid id"),
            "a command without an id is rejected"
        )
        ConvexTest ok(
            lines at(3) containsSeq("unknown adapter operation nonsense") and \
                lines at(3) containsSeq("\"id\":\"x\""),
            "an unknown operation is reported against its own id"
        )
        ConvexTest ok(
            lines at(4) containsSeq("unsupported adapter protocol version"),
            "a hello for another protocol version is refused"
        )
        ConvexAdapterTest close(capture)

        ConvexTest
    )
)
