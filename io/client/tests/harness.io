//
// Language-local test harness.
//
// Two pieces: a very small assertion recorder, and a loopback peer built
// directly on the transport boundary. The peer is deliberately hostile - it
// can stall mid-frame, fragment a UTF-8 message, send control frames at
// awkward moments, or answer an upgrade incorrectly - because those are the
// failure modes an ordinary happy-path test never reaches.
//
// Everything runs in one process and one loop. The test drives the peer and
// the client alternately, so each scenario is deterministic rather than timing
// dependent.
//

ConvexTest := Object clone do(
    checks := 0
    failures := 0
    currentName := ""

    begin := method(name, ConvexTest currentName = name; ConvexTest)

    record := method(passed, label,
        ConvexTest checks = ConvexTest checks + 1
        if(passed not,
            ConvexTest failures = ConvexTest failures + 1
            // See Convex writeDiagnostic in convex.io: retried rather than a
            // bare File write, so a transient hiccup in whatever is capturing
            // this process's stderr cannot turn a real, reportable test
            // failure into an unrelated fatal exception here instead.
            Convex writeDiagnostic(
                File standardError,
                "FAIL " .. ConvexTest currentName .. ": " .. label .. "\n"
            )
        )
        passed
    )

    ok := method(condition, label, ConvexTest record(condition == true, label))

    equals := method(actual, expected, label,
        ConvexTest record(
            actual == expected,
            label .. " (expected " .. expected asString .. ", got " .. actual asString .. ")"
        )
    )

    // Assert that BODY raises, and that the exception carries the expected
    // Convex error name. Anything that succeeds is a failure.
    raisesNamed := method(name, label,
        problem := try(call evalArgAt(2))
        if(problem isNil,
            return ConvexTest record(false, label .. " (nothing was raised)")
        )
        ConvexTest record(
            Convex errorName(problem) == name,
            label .. " (expected " .. name .. ", got " .. Convex errorName(problem) .. ")"
        )
    )

    report := method(
        Convex writeDiagnostic(
            File standardError,
            "ran " .. ConvexTest checks asString .. " checks, " .. \
            ConvexTest failures asString .. " failures\n"
        )
        ConvexTest failures
    )
)

// One descriptor of the loopback peer, shaped like the pollables the client's
// event loop already understands.
ConvexTestChannel := Object clone do(
    peer ::= nil
    mode ::= "listen"

    handle := method(if(self mode == "listen", self peer listener, self peer connection))
    wantsRead := method(self handle >= 0)
    wantsWrite := method(self mode == "connection" and self peer outbox size > 0)
    hasBufferedInput := method(false)
    serviceRead := method(self peer service)
    serviceWrite := method(self peer service)
)

//
// A loopback TCP peer. It never blocks: `service` moves whatever bytes are
// available in either direction, and the test decides when to call it.
//
ConvexTestPeer := Object clone do(
    init := method(
        self io := Convex loadTransport
        self listener := -1
        self connection := -1
        self inbox := Sequence clone
        self outbox := Sequence clone
        self port := 0
        self atEnd := false
        self upgraded := false
        self frozen := false
        // Invoked with the peer whenever a complete request head (plus its
        // declared body) has arrived and the connection has not yet upgraded.
        // The handler is what makes a blocking client call answerable from
        // inside the client's own event loop.
        self onRequest := nil
        // Recycle the connection when the client closes its end, so a
        // reconnect scenario does not need the test to intervene.
        self autoRecycle := true
    )

    start := method(
        self listener = self io listen("127.0.0.1", 0)
        if(self listener < 0,
            Exception raise("test peer could not listen: " .. self io errorText)
        )
        self port = self io localPort(self listener)
        self
    )

    url := method("http://127.0.0.1:" .. self port asString)

    // A frozen peer accepts the connection but moves no bytes at all, which is
    // how the tests reproduce a stalled deployment.
    freeze := method(self frozen = true; self)
    thaw := method(self frozen = false; self)

    service := method(
        if(self connection < 0 and self listener >= 0,
            accepted := self io accept(self listener)
            if(accepted isNil not and accepted >= 0,
                self connection = accepted
                // A reconnect gets a genuinely fresh connection: no leftover
                // bytes and no memory of the previous upgrade.
                self inbox = Sequence clone
                self outbox = Sequence clone
                self atEnd = false
                self upgraded = false
            )
        )
        if(self connection < 0 or self frozen, return self)
        if(self outbox size > 0,
            sent := self io write(self connection, self outbox)
            if(sent > 0, self outbox = self outbox exSlice(sent))
        )
        chunk := self io read(self connection, 65536)
        if(chunk isNil) then(
            self atEnd = true
            // When the client drops its end, drop ours too so the listener is
            // ready for the reconnect that follows.
            if(self autoRecycle, self hangUp; return self)
        ) else(
            if(chunk size > 0, self inbox appendSeq(chunk))
        )
        if(self onRequest and self upgraded not and self requestReady,
            self onRequest call(self)
        )
        self
    )

    // Pollable views the client can wait on, so a blocking client call still
    // lets this peer answer from inside the same loop. Two views are needed
    // because the listener and the accepted connection are separate
    // descriptors and either may be absent.
    channels := method(
        if(self hasLocalSlot("listenChannel") not,
            self listenChannel := ConvexTestChannel clone setPeer(self) setMode("listen")
            self connectionChannel := ConvexTestChannel clone setPeer(self) setMode("connection")
        )
        list(self listenChannel, self connectionChannel)
    )

    attachTo := method(client,
        self channels foreach(channel, client extraPollables append(channel))
        self
    )

    send := method(bytes, self outbox appendSeq(bytes); self)

    // Drop the connection without any WebSocket close frame, the way a real
    // network failure behaves.
    hangUp := method(
        if(self connection >= 0, self io close(self connection); self connection = -1)
        self
    )

    // Stop listening so the client's next reconnect attempt cannot succeed.
    stopListening := method(
        if(self listener >= 0, self io close(self listener); self listener = -1)
        self
    )

    shutdown := method(
        self hangUp
        self stopListening
        self
    )

    // Wait until the peer has read a complete HTTP request head plus its
    // declared body, so a test can respond deterministically.
    requestReady := method(
        marker := self inbox findSeq("\r\n\r\n")
        if(marker isNil, return false)
        headers := self inbox exSlice(0, marker) asString
        declared := 0
        headers split("\r\n") foreach(line,
            if(line asLowercase beginsWithSeq("content-length:"),
                declared = line exSlice(15) asMutable strip asNumber
            )
        )
        self inbox size - (marker + 4) >= declared
    )

    requestHead := method(
        marker := self inbox findSeq("\r\n\r\n")
        if(marker isNil, return nil)
        self inbox exSlice(0, marker) asString
    )

    requestBody := method(
        marker := self inbox findSeq("\r\n\r\n")
        if(marker isNil, return nil)
        self inbox exSlice(marker + 4) asString
    )

    forget := method(self inbox = Sequence clone; self)

    // ---------- HTTP ----------

    respond := method(status, body,
        payload := body asString
        head := Sequence clone
        head appendSeq("HTTP/1.1 " .. status .. "\r\n")
        head appendSeq("Content-Type: application/json\r\n")
        head appendSeq("Content-Length: " .. payload size asString .. "\r\n")
        head appendSeq("Connection: close\r\n\r\n")
        head appendSeq(payload)
        self send(head)
    )

    // The hosted deployment sits behind a proxy that may answer in chunks, so
    // the reader has to handle both framings.
    respondChunked := method(status, chunks,
        head := Sequence clone
        head appendSeq("HTTP/1.1 " .. status .. "\r\n")
        head appendSeq("Content-Type: application/json\r\n")
        head appendSeq("Transfer-Encoding: chunked\r\n\r\n")
        chunks foreach(chunk,
            head appendSeq(chunk size asString toBase(16))
            head appendSeq("\r\n")
            head appendSeq(chunk)
            head appendSeq("\r\n")
        )
        head appendSeq("0\r\n\r\n")
        self send(head)
    )

    // ---------- WebSocket ----------

    upgradeKey := method(
        head := self requestHead
        if(head isNil, return nil)
        found := nil
        head split("\r\n") foreach(line,
            if(line asLowercase beginsWithSeq("sec-websocket-key:"),
                found = line exSlice(18) asMutable strip asSymbol
            )
        )
        found
    )

    acceptUpgrade := method(
        key := self upgradeKey
        if(key isNil, return false)
        accepted := Convex base64(
            ConvexSha1 digest(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        )
        head := Sequence clone
        head appendSeq("HTTP/1.1 101 Switching Protocols\r\n")
        head appendSeq("Upgrade: websocket\r\n")
        head appendSeq("Connection: Upgrade\r\n")
        head appendSeq("Sec-WebSocket-Accept: " .. accepted .. "\r\n\r\n")
        self send(head)
        self forget
        self upgraded = true
        true
    )

    // Answer the upgrade with a digest that does not match the key, which a
    // correct client must reject.
    rejectUpgrade := method(
        head := Sequence clone
        head appendSeq("HTTP/1.1 101 Switching Protocols\r\n")
        head appendSeq("Upgrade: websocket\r\n")
        head appendSeq("Connection: Upgrade\r\n")
        head appendSeq("Sec-WebSocket-Accept: bm90LXRoZS1yaWdodC1kaWdlc3Q=\r\n\r\n")
        self send(head)
        self forget
        true
    )

    // Server frames are unmasked, so the encoder here is intentionally not the
    // client's own ConvexFrame encode.
    frameBytes := method(opcode, payload, final,
        body := payload asString
        length := body size
        out := Sequence clone
        out append(if(final, 128, 0) + opcode)
        if(length < 126) then(
            out append(length)
        ) elseif(length <= 65535) then(
            out append(126)
            out append((length / 256) floor)
            out append(length % 256)
        ) else(
            out append(127)
            for(unused, 0, 3, out append(0))
            out append((length / 16777216) floor % 256)
            out append((length / 65536) floor % 256)
            out append((length / 256) floor % 256)
            out append(length % 256)
        )
        out appendSeq(body)
        out
    )

    sendFrame := method(opcode, payload, self send(self frameBytes(opcode, payload, true)))
    sendText := method(text, self sendFrame(1, text))

    // Send only the first COUNT bytes of a frame and stop, leaving the client
    // holding a genuinely partial frame.
    sendPartialText := method(text, count,
        whole := self frameBytes(1, text, true)
        self send(whole exSlice(0, count))
        self
    )

    // ---------- reading client frames ----------
    //
    // Client frames are masked, so the test peer has to unmask them. That is
    // also how the tests confirm the client really masked its own output.

    nextClientFrame := method(
        if(self inbox size < 2, return nil)
        first := self inbox at(0)
        second := self inbox at(1)
        masked := second bitwiseAnd(128) != 0
        length := second bitwiseAnd(127)
        offset := 2
        if(length == 126,
            if(self inbox size < 4, return nil)
            length = self inbox at(2) * 256 + self inbox at(3)
            offset = 4
        )
        if(length == 127,
            if(self inbox size < 10, return nil)
            length = 0
            for(index, 2, 9, length = length * 256 + self inbox at(index))
            offset = 10
        )
        maskKey := nil
        if(masked,
            if(self inbox size < offset + 4, return nil)
            maskKey = self inbox exSlice(offset, offset + 4)
            offset = offset + 4
        )
        if(self inbox size < offset + length, return nil)
        raw := self inbox exSlice(offset, offset + length)
        body := Sequence clone
        if(masked) then(
            index := 0
            while(index < length,
                body append(raw at(index) bitwiseXor(maskKey at(index % 4)))
                index = index + 1
            )
        ) else(
            body appendSeq(raw)
        )
        self inbox = self inbox exSlice(offset + length)
        frame := Object clone
        frame opcode := first bitwiseAnd(15)
        frame masked := masked
        frame payload := body asString
        frame
    )

    // Collect client messages of a given Convex envelope type.
    drainClientMessages := method(
        found := list()
        reading := true
        while(reading,
            frame := self nextClientFrame
            if(frame isNil) then(reading = false) else(found append(frame))
        )
        found
    )
)

//
// Drive the peer and the client alternately until CONDITION holds. Returns
// false when the bounded number of rounds runs out, which keeps a broken test
// from hanging the suite.
//
ConvexTest drive := method(peer, client, condition, rounds,
    index := 0
    while(index < rounds,
        peer service
        client pumpOnce(2)
        peer service
        if(condition isNil not and condition call, return true)
        index = index + 1
    )
    condition isNil
)

// Drive until COUNT client-to-server WebSocket messages have been collected,
// returning whatever arrived. Bounded so a stuck client fails rather than
// hangs.
ConvexTest collect := method(peer, client, count, rounds,
    found := list()
    index := 0
    while(index < rounds and found size < count,
        peer service
        client pumpOnce(2)
        peer service
        found appendSeq(peer drainClientMessages)
        index = index + 1
    )
    found
)

// Advance a fixed number of rounds without any completion condition.
ConvexTest spin := method(peer, client, rounds,
    for(index, 1, rounds,
        peer service
        client pumpOnce(2)
        peer service
    )
    true
)

// A canned demo:state document, so the Live tests assert on a realistic value.
ConvexTest stateValue := method(room, count,
    Convex object(list(
        "room", Convex string(room),
        "count", count asString,
        "lastLanguage", "null",
        "latestRunId", "null",
        "updatedAt", "null"
    ))
)

ConvexTest version := method(querySet, timestamp,
    Convex object(list(
        "querySet", querySet asString,
        "identity", "0",
        "ts", Convex string(timestamp)
    ))
)

// A Transition carrying one QueryUpdated for QUERYID.
ConvexTest transition := method(startVersion, endVersion, modifications,
    Convex object(list(
        "type", Convex string("Transition"),
        "startVersion", startVersion,
        "endVersion", endVersion,
        "modifications", Convex array(modifications)
    ))
)

ConvexTest queryUpdated := method(queryId, value,
    Convex object(list(
        "type", Convex string("QueryUpdated"),
        "queryId", queryId asString,
        "value", value,
        "logLines", "[]"
    ))
)

ConvexTest queryFailed := method(queryId, message, data,
    Convex object(list(
        "type", Convex string("QueryFailed"),
        "queryId", queryId asString,
        "errorMessage", Convex string(message),
        "errorData", data,
        "logLines", "[]"
    ))
)

// Convex timestamps are eight little-endian bytes in base64. Building them
// here keeps the ordering assertions readable.
ConvexTest timestamp := method(value,
    bytes := Sequence clone
    remaining := value
    for(index, 0, 7,
        bytes append(remaining % 256)
        remaining = (remaining / 256) floor
    )
    Convex base64(bytes)
)
