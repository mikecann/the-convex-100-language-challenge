//
// Live behaviour against a deliberately hostile loopback peer.
//
// Every scenario here is one an ordinary happy-path test never reaches: a peer
// that stalls halfway through a frame, one that fragments a multi-byte message
// around a control frame, one that answers the upgrade incorrectly, and one
// that keeps talking while the client is trying to shut down.
//

ConvexLivePeerTest := Object clone do(
    // A recorder shaped like the client's subscription callback, so a test can
    // assert on what a real consumer would have observed and in what order.
    recorder := method(
        seen := Object clone
        seen events := list()
        seen values := list()
        seen errors := list()
        seen relay := block(kind, payload, logs,
            seen events append(list(kind, payload, logs))
            if(kind == "value", seen values append(payload), seen errors append(payload))
        )
        seen
    )

    // Bring a peer and a client to the point where one subscription is active
    // and the server has seen the Connect and Add messages.
    openLive := method(room,
        session := Object clone
        session peer := ConvexTestPeer clone start
        session peer onRequest = block(p, p acceptUpgrade)
        session client := Convex clientForUrl(session peer url)
        session watcher := ConvexLivePeerTest recorder
        session arguments := Convex object(list("room", Convex string(room)))
        session queryId := session client subscribe(
            "demo:state", session arguments, session watcher relay
        )
        session messages := ConvexTest collect(session peer, session client, 2, 1500)
        session
    )

    envelopeType := method(frame, Convex text(Convex field(frame payload, "type")))

    close := method(session,
        session client close
        session peer shutdown
    )

    run := method(
        ConvexTest begin("live/handshake-and-add")
        session := ConvexLivePeerTest openLive("alpha")
        ConvexTest equals(session messages size, 2, "Connect and ModifyQuerySet are both sent")
        ConvexTest ok(
            session messages at(0) masked,
            "client frames are masked as RFC 6455 requires"
        )
        ConvexTest equals(
            ConvexLivePeerTest envelopeType(session messages at(0)),
            "Connect",
            "the first message is Connect"
        )
        connect := session messages at(0) payload
        ConvexTest equals(
            Convex field(connect, "connectionCount"),
            "0",
            "the first connection reports count zero"
        )
        ConvexTest equals(
            Convex text(Convex field(connect, "lastCloseReason")),
            "InitialConnect",
            "the first connection reports InitialConnect"
        )
        ConvexTest equals(
            Convex text(Convex field(connect, "sessionId")) size,
            32,
            "the session id is 32 hex characters"
        )
        ConvexTest ok(
            ConvexJson field(connect, "maxObservedTimestamp") isNil,
            "a first connection carries no observed timestamp"
        )

        modify := session messages at(1) payload
        ConvexTest equals(
            ConvexLivePeerTest envelopeType(session messages at(1)),
            "ModifyQuerySet",
            "the second message is ModifyQuerySet"
        )
        ConvexTest equals(Convex field(modify, "baseVersion"), "0", "the base version starts at zero")
        ConvexTest equals(Convex field(modify, "newVersion"), "1", "the new version is one higher")
        addition := ConvexJson elements(Convex field(modify, "modifications")) at(0)
        ConvexTest equals(Convex text(Convex field(addition, "type")), "Add", "the modification is an Add")
        ConvexTest equals(
            Convex text(Convex field(addition, "udfPath")),
            "demo:state",
            "the Add carries the function path"
        )
        ConvexTest equals(
            Convex field(addition, "args"),
            "[{\"room\":\"alpha\"}]",
            "the Add wraps the arguments in the protocol's single element array"
        )

        // An initial Transition publishes the first value.
        first := ConvexTest timestamp(1000)
        session peer sendText(ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, first),
            list(ConvexTest queryUpdated(session queryId, ConvexTest stateValue("alpha", 0)))
        ))
        ConvexTest drive(session peer, session client,
            block(session watcher values size > 0), 1500)
        ConvexTest equals(session watcher values size, 1, "the initial value is published once")
        ConvexTest equals(
            Convex field(session watcher values at(0), "count"),
            "0",
            "the initial value carries the room's count"
        )
        ConvexTest equals(
            session client maxObservedTimestamp,
            first,
            "the observed timestamp is recorded"
        )

        // An external write produces a second Transition on the same socket.
        second := ConvexTest timestamp(2000)
        session peer sendText(ConvexTest transition(
            ConvexTest version(1, first),
            ConvexTest version(1, second),
            list(ConvexTest queryUpdated(session queryId, ConvexTest stateValue("alpha", 1)))
        ))
        ConvexTest drive(session peer, session client,
            block(session watcher values size > 1), 1500)
        ConvexTest equals(session watcher values size, 2, "the external update is published")
        ConvexTest equals(
            Convex field(session watcher values at(1), "count"),
            "1",
            "the external update carries the new count"
        )

        // An unchanged repeat of the same value must not reach the consumer.
        third := ConvexTest timestamp(3000)
        session peer sendText(ConvexTest transition(
            ConvexTest version(1, second),
            ConvexTest version(1, third),
            list(ConvexTest queryUpdated(session queryId, ConvexTest stateValue("alpha", 1)))
        ))
        ConvexTest spin(session peer, session client, 200)
        ConvexTest equals(
            session watcher values size,
            2,
            "an unchanged value is suppressed rather than republished"
        )

        ConvexTest begin("live/unsubscribe")
        session client unsubscribe(session queryId)
        removals := ConvexTest collect(session peer, session client, 1, 500)
        ConvexTest equals(removals size, 1, "unsubscribe sends one message")
        removal := ConvexJson elements(
            Convex field(removals at(0) payload, "modifications")
        ) at(0)
        ConvexTest equals(
            Convex text(Convex field(removal, "type")),
            "Remove",
            "unsubscribe sends a Remove modification"
        )
        // A value that arrives after Remove belongs to a subscription the
        // consumer has already let go, so it must never be delivered.
        fourth := ConvexTest timestamp(4000)
        session peer sendText(ConvexTest transition(
            ConvexTest version(1, third),
            ConvexTest version(2, fourth),
            list(ConvexTest queryUpdated(session queryId, ConvexTest stateValue("alpha", 9)))
        ))
        ConvexTest spin(session peer, session client, 200)
        ConvexTest equals(
            session watcher values size,
            2,
            "no value is delivered after unsubscribe"
        )
        ConvexLivePeerTest close(session)

        ConvexTest begin("live/query-failure-and-recovery")
        failing := ConvexLivePeerTest openLive("bravo")
        start := ConvexTest timestamp(1000)
        failing peer sendText(ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, start),
            list(ConvexTest queryFailed(
                failing queryId, "Increment the room", "{\"code\":\"ROOM_EMPTY\"}"
            ))
        ))
        ConvexTest drive(failing peer, failing client,
            block(failing watcher errors size > 0), 1500)
        ConvexTest equals(failing watcher errors size, 1, "a QueryFailed reaches the consumer")
        failure := failing watcher errors at(0)
        ConvexTest equals(
            Convex text(Convex field(failure, "name")),
            "FunctionError",
            "a failed query is a FunctionError, not a transport problem"
        )
        ConvexTest equals(
            Convex field(failure, "data"),
            "{\"code\":\"ROOM_EMPTY\"}",
            "the structured errorData survives"
        )
        // The same subscription must recover in place once the query succeeds.
        repaired := ConvexTest timestamp(2000)
        failing peer sendText(ConvexTest transition(
            ConvexTest version(1, start),
            ConvexTest version(1, repaired),
            list(ConvexTest queryUpdated(failing queryId, ConvexTest stateValue("bravo", 1)))
        ))
        ConvexTest drive(failing peer, failing client,
            block(failing watcher values size > 0), 1500)
        ConvexTest equals(failing watcher values size, 1, "the subscription recovers in place")
        ConvexLivePeerTest close(failing)

        ConvexTest begin("live/fragments-and-control-frames")
        fragmented := ConvexLivePeerTest openLive("charlie")
        // A room name with a multi-byte character, split so the character
        // straddles the fragment boundary, and with a ping delivered between
        // the fragments the way RFC 6455 permits.
        message := ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, ConvexTest timestamp(1000)),
            list(ConvexTest queryUpdated(fragmented queryId, ConvexTest stateValue("charlie-👋", 0)))
        )
        split := (message size / 2) floor
        fragmented peer send(fragmented peer frameBytes(1, message exSlice(0, split), false))
        fragmented peer send(fragmented peer frameBytes(9, "ping-payload", true))
        fragmented peer send(fragmented peer frameBytes(0, message exSlice(split), true))
        ConvexTest drive(fragmented peer, fragmented client,
            block(fragmented watcher values size > 0), 1500)
        ConvexTest equals(
            fragmented watcher values size,
            1,
            "a fragmented message is reassembled and published"
        )
        ConvexTest equals(
            Convex text(Convex field(fragmented watcher values at(0), "room")),
            "charlie-👋",
            "the multi-byte character survives the fragment boundary"
        )
        pongs := fragmented peer drainClientMessages select(frame, frame opcode == 10)
        ConvexTest equals(pongs size, 1, "a ping between fragments is answered")
        ConvexTest equals(
            pongs at(0) payload,
            "ping-payload",
            "the pong echoes the ping payload"
        )
        ConvexLivePeerTest close(fragmented)

        ConvexTest begin("live/partial-frame-deadline")
        stalled := ConvexLivePeerTest openLive("delta")
        stalled client partialFrameTimeoutMs = 150
        // Send a frame header and part of its payload, then stop. A parser
        // that resynchronised at a convenient byte would silently corrupt the
        // stream; the only correct outcomes are waiting or abandoning.
        stalled peer sendPartialText(
            ConvexTest transition(
                ConvexTest version(0, Convex initialTimestamp),
                ConvexTest version(1, ConvexTest timestamp(1000)),
                list(ConvexTest queryUpdated(stalled queryId, ConvexTest stateValue("delta", 0)))
            ),
            12
        )
        ConvexTest drive(stalled peer, stalled client,
            block(stalled watcher errors size > 0), 2000)
        ConvexTest equals(
            stalled watcher errors size,
            1,
            "a frame that stalls part way through retires the connection"
        )
        ConvexTest equals(
            Convex text(Convex field(stalled watcher errors at(0), "name")),
            "TransportError",
            "a stalled frame is reported as a transport error"
        )
        ConvexTest ok(
            stalled client connectionCount > 0,
            "the retired connection is counted"
        )
        // The subscription must still be able to deliver a later valid value.
        stalled client reconnectDelayMs = 5
        recovered := ConvexTest drive(stalled peer, stalled client,
            block(stalled peer upgraded), 3000)
        ConvexTest ok(recovered, "the client reconnects after a transport failure")
        ConvexTest collect(stalled peer, stalled client, 2, 1500)
        stalled peer sendText(ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, ConvexTest timestamp(5000)),
            list(ConvexTest queryUpdated(stalled queryId, ConvexTest stateValue("delta", 3)))
        ))
        ConvexTest drive(stalled peer, stalled client,
            block(stalled watcher values size > 0), 2000)
        ConvexTest equals(
            stalled watcher values size,
            1,
            "a valid value still arrives after the transport failure"
        )
        ConvexLivePeerTest close(stalled)

        ConvexTest begin("live/protocol-failure-and-recovery")
        broken := ConvexLivePeerTest openLive("echo")
        broken peer sendText("{\"type\":\"SomethingElse\"}")
        ConvexTest drive(broken peer, broken client,
            block(broken watcher errors size > 0), 1500)
        ConvexTest equals(
            Convex text(Convex field(broken watcher errors at(0), "name")),
            "ProtocolError",
            "an unknown envelope is a protocol error"
        )
        broken client reconnectDelayMs = 5
        ConvexTest drive(broken peer, broken client, block(broken peer upgraded), 3000)
        ConvexTest collect(broken peer, broken client, 2, 1500)
        broken peer sendText(ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, ConvexTest timestamp(7000)),
            list(ConvexTest queryUpdated(broken queryId, ConvexTest stateValue("echo", 2)))
        ))
        ConvexTest drive(broken peer, broken client,
            block(broken watcher values size > 0), 2000)
        ConvexTest equals(
            broken watcher values size,
            1,
            "a subscription is not stranded by a protocol failure"
        )
        ConvexLivePeerTest close(broken)

        ConvexTest begin("live/consumer-failure-isolation")
        // A consumer that raises - an adapter whose controller channel has just
        // died, for instance - is a failure of that consumer and not of the
        // socket. Retiring the connection here would misreport a controller
        // problem as Convex transport drift, and would then hand that invented
        // failure straight back to the same broken callback.
        rude := ConvexTestPeer clone start
        rude onRequest = block(p, p acceptUpgrade)
        rudeClient := Convex clientForUrl(rude url)
        rudeWatch := Object clone
        rudeWatch deliveries := 0
        rudeQuery := rudeClient subscribe("demo:state", "{}", block(kind, payload, logs,
            rudeWatch deliveries = rudeWatch deliveries + 1
            Exception raise("this consumer is broken")
        ))
        ConvexTest collect(rude, rudeClient, 2, 1500)
        rude sendText(ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, ConvexTest timestamp(1000)),
            list(ConvexTest queryUpdated(rudeQuery, ConvexTest stateValue("kilo", 0)))
        ))
        ConvexTest drive(rude, rudeClient, block(rudeWatch deliveries > 0), 1500)
        ConvexTest equals(rudeWatch deliveries, 1, "the consumer received the value")
        ConvexTest equals(
            rudeClient connectionCount,
            0,
            "a raising consumer does not retire the Live connection"
        )
        ConvexTest ok(
            rudeClient socket isNil not and rudeClient socket isOpen,
            "the Live socket is still open after the consumer raised"
        )
        rudeClient close
        rude shutdown

        ConvexTest begin("live/transition-validation")
        strict := ConvexLivePeerTest openLive("foxtrot")
        // A transition whose start version does not match what the client
        // believes is the current server state must be refused, because
        // applying it would silently desynchronise the query set.
        strict peer sendText(ConvexTest transition(
            ConvexTest version(1, ConvexTest timestamp(9)),
            ConvexTest version(2, ConvexTest timestamp(10)),
            list(ConvexTest queryUpdated(strict queryId, ConvexTest stateValue("foxtrot", 4)))
        ))
        ConvexTest drive(strict peer, strict client,
            block(strict watcher errors size > 0), 1500)
        ConvexTest equals(
            Convex text(Convex field(strict watcher errors at(0), "name")),
            "ProtocolError",
            "a mismatched start version is refused"
        )
        ConvexTest equals(strict watcher values size, 0, "no value is published from a refused transition")
        ConvexLivePeerTest close(strict)

        ConvexTest begin("live/upgrade-verification")
        wrong := ConvexTestPeer clone start
        wrong onRequest = block(p, p rejectUpgrade)
        wrongClient := Convex clientForUrl(wrong url)
        wrongWatcher := ConvexLivePeerTest recorder
        wrongClient subscribe("demo:state", "{}", wrongWatcher relay)
        ConvexTest drive(wrong, wrongClient, block(wrongWatcher errors size > 0), 1500)
        ConvexTest equals(
            wrongWatcher errors size > 0,
            true,
            "an incorrect Sec-WebSocket-Accept is rejected"
        )
        ConvexTest equals(
            Convex text(Convex field(wrongWatcher errors at(0), "name")),
            "ProtocolError",
            "a failed upgrade verification is a protocol error"
        )
        wrongClient close
        wrong shutdown

        ConvexTest begin("live/backoff")
        // With nothing listening the client must back off rather than spin,
        // and the delay must grow between attempts.
        idle := ConvexTestPeer clone start
        idlePort := idle port
        idle shutdown
        backoffClient := Convex clientForUrl("http://127.0.0.1:" .. idlePort asString)
        backoffWatcher := ConvexLivePeerTest recorder
        backoffClient subscribe("demo:state", "{}", backoffWatcher relay)
        for(round, 1, 200, backoffClient pumpOnce(2))
        ConvexTest ok(
            backoffClient reconnectDelayMs > Convex initialReconnectMs,
            "a failing reconnect grows its delay"
        )
        backoffClient close

        ConvexTest begin("live/reconnect-five-times")
        previousInitial := Convex initialReconnectMs
        // Shorten only the delay, not the mechanism: these are five genuine
        // socket close and reconnect cycles.
        Convex initialReconnectMs = 5
        reconnecting := ConvexLivePeerTest openLive("golf")
        stamp := 1000
        reconnecting peer sendText(ConvexTest transition(
            ConvexTest version(0, Convex initialTimestamp),
            ConvexTest version(1, ConvexTest timestamp(stamp)),
            list(ConvexTest queryUpdated(reconnecting queryId, ConvexTest stateValue("golf", 0)))
        ))
        ConvexTest drive(reconnecting peer, reconnecting client,
            block(reconnecting watcher values size > 0), 1500)
        ConvexTest equals(reconnecting watcher values size, 1, "the first value arrives")

        allReconnected := true
        for(attempt, 1, 5,
            expectedCount := attempt
            reconnecting client debugDisconnect
            ConvexTest equals(
                reconnecting client lastCloseReason,
                "DebugDisconnect",
                "attempt " .. attempt asString .. " records the close reason"
            )
            reachedPeer := ConvexTest drive(reconnecting peer, reconnecting client,
                block(reconnecting peer upgraded), 4000)
            if(reachedPeer not, allReconnected = false)
            resent := ConvexTest collect(reconnecting peer, reconnecting client, 2, 2000)
            if(resent size < 2) then(
                allReconnected = false
            ) else(
                ConvexTest equals(
                    ConvexLivePeerTest envelopeType(resent at(0)),
                    "Connect",
                    "attempt " .. attempt asString .. " opens with Connect"
                )
                ConvexTest equals(
                    Convex field(resent at(0) payload, "connectionCount"),
                    attempt asString,
                    "attempt " .. attempt asString .. " reports the connection count"
                )
                ConvexTest ok(
                    ConvexJson field(resent at(0) payload, "maxObservedTimestamp") isNil not,
                    "attempt " .. attempt asString .. " carries the observed timestamp"
                )
                resentAdd := ConvexJson elements(
                    Convex field(resent at(1) payload, "modifications")
                ) at(0)
                ConvexTest equals(
                    Convex text(Convex field(resentAdd, "type")),
                    "Add",
                    "attempt " .. attempt asString .. " resends the active Add"
                )
            )
            // A reconnect rehydrates the unchanged value. Republishing it would
            // make the exact 0, disconnect, 1 sequence impossible to observe.
            beforeRehydration := reconnecting watcher values size
            stamp = stamp + 1000
            reconnecting peer sendText(ConvexTest transition(
                ConvexTest version(0, Convex initialTimestamp),
                ConvexTest version(1, ConvexTest timestamp(stamp)),
                list(ConvexTest queryUpdated(
                    reconnecting queryId,
                    ConvexTest stateValue("golf", expectedCount - 1)
                ))
            ))
            ConvexTest spin(reconnecting peer, reconnecting client, 150)
            ConvexTest equals(
                reconnecting watcher values size,
                beforeRehydration,
                "attempt " .. attempt asString .. " suppresses the unchanged rehydration"
            )
            // Now a genuine external change must come through.
            stamp = stamp + 1000
            reconnecting peer sendText(ConvexTest transition(
                ConvexTest version(1, ConvexTest timestamp(stamp - 1000)),
                ConvexTest version(1, ConvexTest timestamp(stamp)),
                list(ConvexTest queryUpdated(
                    reconnecting queryId,
                    ConvexTest stateValue("golf", expectedCount)
                ))
            ))
            ConvexTest drive(reconnecting peer, reconnecting client,
                block(reconnecting watcher values size > beforeRehydration), 2000)
            ConvexTest equals(
                reconnecting watcher values size,
                beforeRehydration + 1,
                "attempt " .. attempt asString .. " delivers the external update"
            )
            // A healthy connection must not inherit the previous failure's
            // backoff maximum.
            ConvexTest equals(
                reconnecting client reconnectDelayMs,
                Convex initialReconnectMs,
                "attempt " .. attempt asString .. " resets the backoff"
            )
        )
        ConvexTest ok(allReconnected, "all five reconnects completed")
        ConvexLivePeerTest close(reconnecting)
        Convex initialReconnectMs = previousInitial

        ConvexTest begin("live/peer-close-frame")
        // RFC 6455 says a client that receives Close answers with Close. The
        // reply must be a single bounded control frame written without waiting,
        // because a peer that has stopped reading must not gain a way to hold
        // this client open.
        closingPeer := ConvexLivePeerTest openLive("lima")
        closingPeer peer send(
            closingPeer peer frameBytes(8, Sequence clone append(3) append(233), true)
        )
        ConvexTest drive(closingPeer peer, closingPeer client,
            block(closingPeer watcher errors size > 0), 1500)
        ConvexTest equals(
            Convex text(Convex field(closingPeer watcher errors at(0), "name")),
            "TransportError",
            "a peer close frame retires the connection as a transport failure"
        )
        ConvexTest ok(
            Convex text(Convex field(closingPeer watcher errors at(0), "message")) \
                containsSeq("1001"),
            "the peer's close status reaches the consumer"
        )
        farewells := closingPeer peer drainClientMessages select(frame, frame opcode == 8)
        ConvexTest equals(farewells size, 1, "the close is answered with exactly one close frame")
        ConvexTest ok(farewells at(0) masked, "the close reply is masked as RFC 6455 requires")
        ConvexTest ok(
            farewells at(0) payload size <= 125,
            "the close payload stays inside the control frame bound"
        )
        ConvexLivePeerTest close(closingPeer)

        ConvexTest begin("live/bounded-shutdown")
        // A peer that is stalled halfway through a frame must not be able to
        // hold teardown open. The stall budget is raised far above the assertion
        // below on purpose: if unsubscribe or close waited on this connection at
        // all, the elapsed time would have to reach that budget instead. The
        // handle count then proves the socket was genuinely released rather than
        // abandoned early to make the deadline.
        holding := ConvexLivePeerTest openLive("hotel")
        holding client partialFrameTimeoutMs = 30000
        holding peer sendPartialText("{\"type\":\"Ping\"}", 4)
        ConvexTest spin(holding peer, holding client, 20)
        before := Lobby ConvexIO openHandleCount
        started := Lobby ConvexIO monotonicMs
        holding client unsubscribe(holding queryId)
        holding client close
        elapsed := Lobby ConvexIO monotonicMs - started
        ConvexTest ok(elapsed < 250, "unsubscribe and close are bounded against a stalled peer")
        ConvexTest ok(
            Lobby ConvexIO openHandleCount < before,
            "the stalled connection is released rather than left behind"
        )
        holding peer shutdown

        // A peer that keeps talking must not be able to hold close open either.
        chatty := ConvexLivePeerTest openLive("india")
        for(round, 1, 40, chatty peer sendText("{\"type\":\"Ping\"}"))
        ConvexTest spin(chatty peer, chatty client, 20)
        before = Lobby ConvexIO openHandleCount
        started = Lobby ConvexIO monotonicMs
        chatty client close
        elapsed = Lobby ConvexIO monotonicMs - started
        ConvexTest ok(elapsed < 250, "close is bounded against a continuously sending peer")
        ConvexTest ok(
            Lobby ConvexIO openHandleCount < before,
            "the chatty connection is released rather than left behind"
        )
        chatty peer shutdown

        // And a completely idle peer must not either. This one is frozen, so it
        // never reads the courtesy close frame: writing it must not wait.
        quiet := ConvexLivePeerTest openLive("juliett")
        quiet peer freeze
        before = Lobby ConvexIO openHandleCount
        started = Lobby ConvexIO monotonicMs
        quiet client close
        elapsed = Lobby ConvexIO monotonicMs - started
        ConvexTest ok(elapsed < 250, "close is bounded against an idle peer")
        ConvexTest ok(
            Lobby ConvexIO openHandleCount < before,
            "the idle connection is released rather than left behind"
        )
        quiet peer thaw
        quiet peer shutdown

        ConvexTest begin("live/frame-budget")
        oversized := ConvexLivePeerTest openLive("kilo")
        previousFrame := Convex maximumFrameBytes
        // Shrink the budget instead of moving megabytes, so the bound is
        // proved deterministically.
        Convex maximumFrameBytes = 512
        padding := Sequence clone
        while(padding size < 2048, padding appendSeq("0123456789"))
        oversized peer sendText("{\"type\":\"Ping\",\"pad\":\"" .. padding .. "\"}")
        ConvexTest drive(oversized peer, oversized client,
            block(oversized watcher errors size > 0), 1500)
        Convex maximumFrameBytes = previousFrame
        ConvexTest equals(
            Convex text(Convex field(oversized watcher errors at(0), "name")),
            "ProtocolError",
            "a frame beyond the byte budget is refused rather than buffered"
        )
        ConvexLivePeerTest close(oversized)

        ConvexTest
    )
)
