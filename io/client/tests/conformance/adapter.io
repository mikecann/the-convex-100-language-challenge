#!/usr/local/bin/io
//
// Test-only NDJSON adapter protocol v1 executable.
//
// This is harness infrastructure, not public client code. It exists so the
// shared controller can drive client/convex.io as a black box, and it owns two
// things the educational client deliberately does not: the adapter-only
// debugDisconnect command, and a bounded output queue with a generation
// barrier so a stale subscription value can never cross an acknowledgement.
//
// stdout is reserved for protocol events. Every diagnostic goes to stderr.
//

ConvexAdapterBoot := Object clone do(
    clientPath := method(
        installed := "/opt/convex/client/convex.io"
        if(File with(installed) exists, return installed)
        // A source checkout runs this file from client/tests/conformance/.
        script := System launchScript
        if(script isNil, return installed)
        script pathComponent .. "/../../convex.io"
    )
)

if(Lobby hasLocalSlot("Convex") not, Lobby doFile(ConvexAdapterBoot clientPath))

// ------------------------------------------------------------------
// Bounded output
// ------------------------------------------------------------------
//
// The shared runtime is capped at 128 MiB and the controller may stop reading
// at any moment, so delivery events are bounded by both a count and an encoded
// byte budget. Control responses - acks, results, errors, closed - are never
// dropped: a reserved slice of both budgets is kept for them, and subscription
// values are discarded oldest-first to make room.
//
// Backpressure is not a failure. A control event that arrives while the reader
// has stopped waits in the queue behind the one record already handed to the
// transport; it is never dropped, and it never raises, because raising would
// turn a stalled controller into a lost acknowledgement. Only an event too
// large to represent at all - bigger than the whole budget - is an error.
//

ConvexAdapterOutput := Object clone do(
    init := method(
        self stream := nil
        self queue := list()
        self queuedBytes := 0
        self maxEvents := 16
        self controlReserveEvents := 4
        self maxBytes := 6291456
        self controlReserve := 65536
        // A conservative per-entry allowance covering the NDJSON newline, the
        // Io list record and the transport's own copy of the bytes, so
        // queuedBytes is a genuine upper bound and not a payload total.
        self entryOverhead := 1024
        // Supplied by the adapter so a queued delivery can be re-checked
        // against the live subscription generation at the last moment.
        self isCurrent := nil
        // Test-only hook. A test pauses the loop after an entry leaves the
        // queue but before it is committed, to prove the barrier really is
        // re-checked at that instant.
        self pauseAfterDequeue := nil
        self committedCount := 0
        self droppedCount := 0
    )

    attach := method(descriptor, self stream = ConvexStream clone adopt(descriptor); self)
    attachStream := method(existing, self stream = existing; self)

    handle := method(if(self stream, self stream handle, -1))
    wantsRead := method(false)
    wantsWrite := method(
        if(self stream isNil, return false)
        self stream outgoing size > 0 or self queue size > 0
    )
    hasBufferedInput := method(false)
    serviceRead := method(self)

    entryCost := method(raw, raw size + 1 + self entryOverhead)

    // Bytes this adapter is still accountable for: queued records plus the one
    // record the transport has accepted but not yet drained.
    pendingBytes := method(
        self queuedBytes + if(self stream, self stream outgoing size, 0)
    )

    dropOldestDelivery := method(
        index := 0
        while(index < self queue size,
            entry := self queue at(index)
            if(entry at(1),
                self queuedBytes = self queuedBytes - entry at(4)
                self queue removeAt(index)
                self droppedCount = self droppedCount + 1
                return true
            )
            index = index + 1
        )
        false
    )

    crowdedBy := method(cost, limit, eventLimit,
        self queue size >= eventLimit or self pendingBytes + cost > limit
    )

    emit := method(raw, droppable, subscriptionId, generation,
        cost := self entryCost(raw)
        limit := if(droppable, self maxBytes - self controlReserve, self maxBytes)
        eventLimit := if(droppable, self maxEvents - self controlReserveEvents, self maxEvents)
        if(cost > limit,
            if(droppable, self droppedCount = self droppedCount + 1; return self)
            Exception raise("adapter event exceeds the encoded output budget")
        )
        // Make room by discarding the oldest deliveries, which is the only
        // thing this adapter is ever allowed to lose.
        while(self crowdedBy(cost, limit, eventLimit) and self dropOldestDelivery, nil)
        if(self crowdedBy(cost, limit, eventLimit),
            // Nothing droppable is left. A delivery gives way; a control event
            // is queued anyway, because the record already in flight is bounded
            // and the reserve exists precisely so an acknowledgement can wait
            // behind it rather than be lost to a reader that stopped.
            if(droppable, self droppedCount = self droppedCount + 1; return self)
        )
        self queue append(list(raw, droppable, subscriptionId, generation, cost))
        self queuedBytes = self queuedBytes + cost
        self drain
        self
    )

    isStale := method(entry,
        if(entry at(1) not, return false)
        if(self isCurrent isNil, return false)
        self isCurrent call(entry at(2), entry at(3)) not
    )

    // Move whatever fits into the transport. Only one record is ever in
    // flight, so everything behind it stays droppable and, critically, is
    // re-checked against the live generation immediately before it is
    // committed. That is the adapter's acknowledgement barrier.
    drain := method(
        if(self stream isNil, return self)
        while(self stream outgoing size == 0 and self queue size > 0,
            entry := self queue removeFirst
            self queuedBytes = self queuedBytes - entry at(4)
            if(self pauseAfterDequeue,
                hook := self pauseAfterDequeue
                self pauseAfterDequeue = nil
                hook call
            )
            if(self isStale(entry)) then(
                self droppedCount = self droppedCount + 1
            ) else(
                record := Sequence clone
                record appendSeq(entry at(0))
                record appendSeq("\n")
                self stream enqueue(record)
                self stream flushOnce
                self committedCount = self committedCount + 1
            )
        )
        self
    )

    serviceWrite := method(
        if(self stream isNil, return self)
        self stream flushOnce
        self drain
        self
    )

    // Drop every queued delivery belonging to a subscription that has just
    // been replaced or removed.
    forget := method(subscriptionId,
        retained := list()
        self queue foreach(entry,
            if(entry at(1) and entry at(2) == subscriptionId) then(
                self queuedBytes = self queuedBytes - entry at(4)
                self droppedCount = self droppedCount + 1
            ) else(
                retained append(entry)
            )
        )
        self queue = retained
        self
    )

    isDrained := method(
        self queue size == 0 and (self stream isNil or self stream outgoing size == 0)
    )

    // Bytes of queued control responses. Deliveries are droppable and so are
    // never a reason to stop reading commands.
    controlBytes := method(
        total := 0
        self queue foreach(entry, if(entry at(1) not, total = total + entry at(4)))
        total
    )

    // True once the reader is far enough behind that the never-dropped control
    // responses have taken their whole reserve, or the queue has reached its
    // count bound. The adapter stops reading commands while this holds, which
    // is what keeps that queue bounded: a controller that has stopped
    // collecting stops being answered rather than accumulating answers.
    //
    // Written as two sequential returns rather than one `or`-joined
    // expression on purpose: this method runs behind a stored block
    // (ConvexAdapterInput's `isPaused`, invoked through `paused` on every
    // `wantsRead`/`hasBufferedInput` check), and the pinned Io VM
    // (IoLanguage/io native @ 3d4bc9c) never returns once that exact
    // shape - two `self <method-or-slot> >= self <method-or-slot>`
    // comparisons joined by `or`, evaluated inside a block reached through
    // two or more layers of method indirection, repeated across loop
    // iterations - is evaluated a handful of times. Reproduced in complete
    // isolation with a 20 line script that has no Convex code in it at all
    // (Object clone, two comparisons joined by `or` inside a stored block,
    // a `while` loop); confirmed with gdb that the process is not stuck but
    // is genuinely still inside IoCoroutine_mark/Collector_collect each
    // time it is sampled seconds apart, so this is a VM-level pathology
    // (mark/collect cost that runs away for this exact call shape) rather
    // than a logic bug in this method. Splitting the `or` into two plain
    // `if`/`return` statements avoids the shape entirely while keeping the
    // exact same result.
    isBackpressured := method(
        if(self queue size >= self maxEvents, return true)
        self controlBytes >= self controlReserve
    )
)

// ------------------------------------------------------------------
// Line-oriented input
// ------------------------------------------------------------------

ConvexAdapterInput := Object clone do(
    init := method(
        self stream := nil
        self onLine := nil
        self finished := false
        self maxLineBytes := 1048576
        // Answers true while the output side is saturated. Reading another
        // command then would only produce a response nobody is collecting.
        self isPaused := nil
    )

    attach := method(descriptor, self stream = ConvexStream clone adopt(descriptor); self)
    attachStream := method(existing, self stream = existing; self)

    paused := method(self isPaused isNil not and self isPaused call)

    handle := method(if(self stream, self stream handle, -1))
    wantsRead := method(
        self stream isNil not and self finished not and self paused not and \
            self stream wantsRead
    )
    wantsWrite := method(false)
    hasBufferedInput := method(
        self paused not and self stream isNil not and self stream hasBufferedInput
    )
    serviceWrite := method(self)

    serviceRead := method(
        if(self stream isNil or self finished or self paused, return self)
        self stream fill
        parsing := true
        while(parsing,
            marker := self stream incoming findSeq("\n")
            if(marker isNil) then(
                if(self stream incoming size > self maxLineBytes,
                    Exception raise("adapter command exceeded the line budget")
                )
                parsing = false
            ) else(
                line := self stream incoming exSlice(0, marker) asString
                self stream incoming = self stream incoming exSlice(marker + 1)
                // Tolerate CRLF from a controller that writes Windows newlines.
                if(line size > 0 and line at(line size - 1) == 13,
                    line = line exSlice(0, line size - 1)
                )
                if(line asMutable strip size > 0 and self onLine, self onLine call(line))
            )
        )
        if(self stream atEnd and self stream incoming size == 0, self finished = true)
        self
    )
)

// ------------------------------------------------------------------
// The adapter
// ------------------------------------------------------------------
//
// A singleton: the slots are defined directly rather than through init,
// because nothing ever clones it.
//

ConvexAdapter := Object clone do(
    languageId := "io"

    client := nil
    input := nil
    output := nil
    listener := -1
    io := nil
    // subscriptionId -> the client's query id
    subscriptions := Map clone
    // subscriptionId -> generation counter, bumped on replace and on remove
    generations := Map clone
    closing := false
    done := false
    exitStatus := 0
    // Set when writing an event fails. The run loop turns it into an abandon on
    // its next pass, so the failure of the controller channel is reported as
    // exactly that and never as something the Convex connection did.
    outputFailure := nil
    // How long the adapter will keep pumping to get its close response out.
    closeDrainMs := 5000

    // ---------- event serialization ----------

    logsPresent := method(logs,
        logs isNil not and logs asString asMutable strip != "[]"
    )

    // Absent structured data is silence, not a JSON null. A Convex error that
    // genuinely carries no errorData reaches here either as nil or as the
    // literal "null" the wire uses for it, and both must produce an event with
    // no data member at all, because the shared controller validates every
    // event strictly.
    presentData := method(data,
        if(data isNil, return false)
        token := data asString asMutable strip
        token size > 0 and token != "null"
    )

    errorObject := method(name, message, data,
        fields := list("name", Convex string(name), "message", Convex string(message))
        if(self presentData(data), fields append("data"); fields append(data))
        Convex object(fields)
    )

    // The controller channel is not the Convex socket. A failure writing an
    // event says the controller went away, which must end this adapter with a
    // non-zero status rather than be reported as a Live transport failure or
    // swallowed by the callback that happened to trigger it.
    emitControl := method(raw, self output emit(raw, false, nil, 0))

    emitGuarded := method(raw, droppable, subscriptionId, generation,
        failure := try(self output emit(raw, droppable, subscriptionId, generation))
        if(failure and self outputFailure isNil,
            self outputFailure = Convex errorMessage(failure)
        )
        self
    )

    respondReady := method(id,
        self emitControl(Convex object(list(
            "protocolVersion", "1",
            "id", Convex string(id),
            "type", Convex string("ready"),
            "language", Convex string(ConvexAdapter languageId),
            "implementation", Convex string("native-io-" .. System version),
            "runtime", Convex string("io-" .. System version)
        )))
    )

    respondResult := method(id, value, logs,
        fields := list(
            "id", Convex string(id),
            "type", Convex string("result"),
            "value", value
        )
        if(self logsPresent(logs), fields append("logs"); fields append(logs))
        self emitControl(Convex object(fields))
    )

    respondAck := method(id,
        self emitControl(Convex object(list(
            "id", Convex string(id),
            "type", Convex string("ack")
        )))
    )

    respondClosed := method(id,
        self emitControl(Convex object(list(
            "id", Convex string(id),
            "type", Convex string("closed")
        )))
    )

    respondError := method(id, name, message, data, logs,
        fields := list()
        // A command whose own id could not be read gets a response with no id
        // at all, rather than an id serialized as null.
        if(id, fields append("id"); fields append(Convex string(id)))
        fields append("type")
        fields append(Convex string("error"))
        fields append("error")
        fields append(self errorObject(name, message, data))
        if(self logsPresent(logs), fields append("logs"); fields append(logs))
        self emitControl(Convex object(fields))
    )

    // ---------- subscription generations ----------

    generationFor := method(subscriptionId,
        if(self generations hasKey(subscriptionId) not,
            self generations atPut(subscriptionId, 1)
        )
        self generations at(subscriptionId)
    )

    deliveryCurrent := method(subscriptionId, generation,
        if(self subscriptions hasKey(subscriptionId) not, return false)
        if(self generations hasKey(subscriptionId) not, return false)
        self generations at(subscriptionId) == generation
    )

    invalidate := method(subscriptionId,
        current := self generationFor(subscriptionId)
        self generations atPut(subscriptionId, current + 1)
        if(self subscriptions hasKey(subscriptionId),
            self subscriptions removeAt(subscriptionId)
        )
        // Queued stale relays disappear now. Anything already committed to the
        // transport keeps its place ahead of the acknowledgement.
        self output forget(subscriptionId)
        self
    )

    relayFor := method(subscriptionId, generation,
        block(kind, payload, logs,
            ConvexAdapter deliver(subscriptionId, generation, kind, payload, logs)
        )
    )

    deliver := method(subscriptionId, generation, kind, payload, logs,
        if(self deliveryCurrent(subscriptionId, generation) not, return self)
        fields := list(
            "type", Convex string("subscription"),
            "subscriptionId", Convex string(subscriptionId)
        )
        if(kind == "value") then(
            fields append("value")
            fields append(payload)
        ) else(
            fields append("error")
            fields append(self errorObject(
                Convex text(Convex field(payload, "name")),
                Convex text(Convex field(payload, "message")),
                Convex optionalField(payload, "data")
            ))
        )
        if(self logsPresent(logs), fields append("logs"); fields append(logs))
        // This runs inside a subscription callback, so a write failure here
        // must be recorded rather than raised: the client deliberately refuses
        // to let a consumer's failure retire its Live connection.
        self emitGuarded(Convex object(fields), true, subscriptionId, generation)
        self
    )

    // ---------- commands ----------

    ensureClient := method(
        if(self client, return self client)
        url := System getEnvironmentVariable("CONVEX_URL")
        if(url isNil or url size == 0, Exception raise("CONVEX_URL is required"))
        self client = Convex clientForUrl(url)
        token := System getEnvironmentVariable("CONVEX_AUTH_TOKEN")
        if(token and token size > 0, self client setAuth(token))
        // The controller channel joins the client's single wait point, so the
        // adapter never needs a second loop or a second owner for the sockets.
        self client extraPollables append(self input)
        self client extraPollables append(self output)
        self output isCurrent = block(subscriptionId, generation,
            ConvexAdapter deliveryCurrent(subscriptionId, generation)
        )
        // Control responses are never dropped, so the only way to keep them
        // bounded is to stop accepting the commands that produce them while the
        // controller is not collecting what it already asked for.
        self input isPaused = block(ConvexAdapter output isBackpressured)
        self client
    )

    requiredString := method(line, name,
        raw := Convex optionalField(line, name)
        if(raw isNil, Convex protocolError("command omitted valid " .. name))
        value := ConvexJson decodeRequiredString(raw, "command " .. name)
        if(value size < 1 or value size > 128,
            Convex protocolError("command omitted valid " .. name)
        )
        value
    )

    handleLine := method(line,
        malformed := try(ConvexJson validate(line))
        if(malformed,
            self respondError(
                nil, "ProtocolError",
                "decode command: " .. Convex errorMessage(malformed), nil, nil
            )
            return self
        )
        if(ConvexJson isObject(line) not,
            self respondError(nil, "ProtocolError", "command must be a JSON object", nil, nil)
            return self
        )
        id := nil
        failure := try(id = self requiredString(line, "id"))
        if(failure,
            self respondError(nil, Convex errorName(failure), Convex errorMessage(failure), nil, nil)
            return self
        )
        operation := nil
        failure = try(operation = self requiredString(line, "op"))
        if(failure,
            self respondError(id, Convex errorName(failure), Convex errorMessage(failure), nil, nil)
            return self
        )
        failure = try(self dispatch(id, operation, line))
        if(failure,
            self respondError(
                id,
                Convex errorName(failure),
                Convex errorMessage(failure),
                Convex errorData(failure),
                Convex errorLogs(failure)
            )
        )
        self
    )

    dispatch := method(id, operation, line,
        if(operation == "hello",
            versionRaw := Convex optionalField(line, "protocolVersion")
            if(versionRaw isNil or versionRaw asString asMutable strip != "1",
                Convex protocolError("unsupported adapter protocol version")
            )
            return self respondReady(id)
        )
        if(operation == "query" or operation == "mutation" or operation == "action",
            path := Convex text(Convex field(line, "path"))
            args := Convex field(line, "args")
            answer := self ensureClient perform(operation, path, args)
            return self respondResult(id, answer value, answer logs)
        )
        if(operation == "setAuth",
            self ensureClient setAuth(Convex text(Convex field(line, "token")))
            return self respondAck(id)
        )
        if(operation == "subscribe",
            subscriptionId := self requiredString(line, "subscriptionId")
            path := Convex text(Convex field(line, "path"))
            args := Convex field(line, "args")
            if(self subscriptions hasKey(subscriptionId),
                // Invalidate before the replacement can expose its ack, so a
                // value from the previous subscription cannot follow it.
                self ensureClient unsubscribe(self subscriptions at(subscriptionId))
                self invalidate(subscriptionId)
            )
            generation := self generationFor(subscriptionId)
            queryId := self ensureClient subscribe(
                path, args, self relayFor(subscriptionId, generation)
            )
            self subscriptions atPut(subscriptionId, queryId)
            return self respondAck(id)
        )
        if(operation == "unsubscribe",
            subscriptionId := self requiredString(line, "subscriptionId")
            if(self subscriptions hasKey(subscriptionId),
                self ensureClient unsubscribe(self subscriptions at(subscriptionId))
                self invalidate(subscriptionId)
            )
            return self respondAck(id)
        )
        if(operation == "debugDisconnect",
            self ensureClient debugDisconnect
            return self respondAck(id)
        )
        if(operation == "close",
            self subscriptions keys foreach(subscriptionId,
                self ensureClient unsubscribe(self subscriptions at(subscriptionId))
            )
            self subscriptions keys foreach(subscriptionId, self invalidate(subscriptionId))
            self subscriptions = Map clone
            self ensureClient close
            self respondClosed(id)
            self closing = true
            return self
        )
        Convex protocolError("unknown adapter operation " .. operation)
    )

    // ---------- transport wiring ----------

    // Standard input and output, used when a human or the Docker smoke test
    // pipes NDJSON straight at the adapter.
    useStdio := method(
        self io = Convex loadTransport
        self input = ConvexAdapterInput clone attach(0)
        self output = ConvexAdapterOutput clone attach(1)
        self
    )

    // The shared harness connects over TCP instead, so the client image can be
    // a long-lived container with a network alias.
    useListener := method(address,
        self io = Convex loadTransport
        separator := address reverseFindSeq(":")
        if(separator isNil, Exception raise("ADAPTER_LISTEN must use host:port"))
        host := address exSlice(0, separator)
        port := address exSlice(separator + 1) asNumber
        self listener = self io listen(host, port)
        if(self listener < 0,
            Exception raise("adapter could not listen: " .. self io errorText)
        )
        accepted := nil
        // Bounded wait for the single controller connection.
        deadline := self io monotonicMs + 120000
        while(accepted isNil,
            if(self io monotonicMs > deadline,
                Exception raise("adapter timed out waiting for a controller connection")
            )
            self io wait(2 ** self listener, 0, 250)
            accepted = self io accept(self listener)
        )
        if(accepted < 0, Exception raise("adapter accept failed: " .. self io errorText))
        self io close(self listener)
        self listener = -1
        // One connection carries both commands and events, so the two ends
        // share a single stream object and therefore a single descriptor.
        shared := ConvexStream clone
        shared io = self io
        shared handle = accepted
        shared stage = "open"
        self input = ConvexAdapterInput clone attachStream(shared)
        self output = ConvexAdapterOutput clone attachStream(shared)
        self
    )

    // The event loop itself failing - a controller line beyond the budget, or
    // a bug here - must not leave the controller waiting on a stream that has
    // quietly died. Say so as a protocol event, then stop with a non-zero
    // status so the harness sees a failed client rather than a silent one.
    abandon := method(detail,
        // See Convex writeDiagnostic in convex.io: retried rather than a bare
        // File write, so a transient hiccup in whatever is capturing this
        // process's stderr cannot itself abort the loop that is already in
        // the middle of reporting a real failure to the controller.
        Convex writeDiagnostic(File standardError, "convex-io: adapter loop failed: " .. detail .. "\n")
        reported := try(
            self respondError(nil, "ProtocolError", "adapter loop failed: " .. detail, nil, nil)
            self output drain
        )
        if(reported,
            Convex writeDiagnostic(File standardError, "convex-io: the failure could not be reported\n")
        )
        self exitStatus = 1
        self done = true
        self
    )

    run := method(
        self input onLine = block(line,
            failure := try(ConvexAdapter handleLine(line))
            if(failure,
                Convex writeDiagnostic(
                    File standardError,
                    "convex-io: adapter command failed: " .. Convex errorMessage(failure) .. "\n"
                )
            )
        )
        // Building the client up front keeps the single wait point - and
        // therefore socket ownership - in exactly one place.
        self ensureClient
        closeDeadline := nil
        while(self done not,
            pumpFailure := try(self client pumpOnce(100))
            if(pumpFailure) then(
                self abandon(Convex errorMessage(pumpFailure))
            ) elseif(self outputFailure) then(
                self abandon("controller output failed: " .. self outputFailure)
            ) else(
                if(self closing,
                    // The close command is read by the pump above, so the drain
                    // deadline is armed here - after the observation that sets
                    // `closing` and before it can ever be compared against.
                    if(closeDeadline isNil,
                        closeDeadline = self io monotonicMs + ConvexAdapter closeDrainMs
                    )
                    if(self output isDrained) then(
                        self done = true
                    ) else(
                        if(self io monotonicMs > closeDeadline,
                            Convex writeDiagnostic(
                                File standardError,
                                "convex-io: adapter close response could not drain in time\n"
                            )
                            self exitStatus = 1
                            self done = true
                        )
                    )
                )
                if(self closing not and self input finished,
                    // The controller went away without sending close. Flush
                    // what is already queued, then stop.
                    self output drain
                    self done = true
                )
            )
        )
        // Closing the transport is what lets a TCP controller observe a clean
        // end of stream rather than a dropped connection.
        if(self output stream, self output stream close)
        self exitStatus
    )
)

// Only start when executed directly. Language-local tests load this file to
// exercise the queue and the command handlers without any deployment.
if(System getEnvironmentVariable("CONVEX_ADAPTER_TEST_ONLY") isNil,
    adapterListen := System getEnvironmentVariable("ADAPTER_LISTEN")
    if(adapterListen and adapterListen size > 0) then(
        ConvexAdapter useListener(adapterListen)
    ) else(
        ConvexAdapter useStdio
    )
    // ConvexAdapter run already converts every failure it anticipates into
    // self exitStatus by way of abandon() above, but try() plus an explicit
    // exit(1) on the caught branch guards against anything that still
    // escapes uncaught - a bug here, or the same class of pinned-VM defect
    // this client hit and fixed elsewhere (see the long comment on
    // ConvexClient ensureLive in convex.io). This VM's own default top-level
    // exception handler prints a backtrace and still exits 0 (proven
    // directly with `io -e 'Exception raise("boom")'` against this exact
    // build), which would otherwise report the real conformance executable -
    // the one the shared harness actually runs against a live deployment -
    // as having succeeded. try() itself always evaluates to nil on success
    // (confirmed directly against this build), not to the wrapped
    // expression's own value, so the exit status has to be captured into an
    // outer local from inside the try rather than read off its result.
    exitStatus := 1
    outcome := try(exitStatus = ConvexAdapter run)
    if(outcome,
        Convex writeDiagnostic(
            File standardError,
            "convex-io: adapter aborted on an uncaught exception: " .. \
            Convex errorMessage(outcome) .. "\n"
        )
        System exit(1)
    ,
        System exit(exitStatus)
    )
)
