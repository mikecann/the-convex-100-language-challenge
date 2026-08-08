#!/usr/local/bin/io
//
// Test-only smoke check for the adapter's TCP mode.
//
// The shared harness never speaks to the adapter over stdin and stdout: it
// runs the client image as a long-lived container and connects to
// ADAPTER_LISTEN. This drives that exact path using the client's own transport
// boundary, so no extra tool has to exist in the test image.
//

if(Lobby hasLocalSlot("Convex") not,
    Lobby doFile(System launchScript pathComponent .. "/../../convex.io")
)

ConvexTcpSmoke := Object clone do(
    address := "127.0.0.1:45679"
    adapterPath := method(System launchScript pathComponent .. "/adapter.io")

    run := method(
        transport := Convex loadTransport
        separator := ConvexTcpSmoke address reverseFindSeq(":")
        host := ConvexTcpSmoke address exSlice(0, separator)
        port := ConvexTcpSmoke address exSlice(separator + 1) asNumber

        // A bogus deployment URL is enough: hello and close never touch it.
        command := Sequence clone
        command appendSeq("ADAPTER_LISTEN=" .. ConvexTcpSmoke address)
        command appendSeq(" CONVEX_URL=http://example.invalid")
        command appendSeq(" /usr/local/bin/io " .. ConvexTcpSmoke adapterPath .. " &")
        System system(command)

        // The adapter is still booting its VM, so the first attempts are
        // refused. A refusal can surface either straight from connect or later
        // from handshake, so each attempt is driven to a verdict and its handle
        // released before the next one starts. Retrying without releasing would
        // leak handles and could sit on one dead socket until the deadline.
        deadline := transport monotonicMs + 30000
        handle := -1
        while(handle < 0,
            if(transport monotonicMs > deadline,
                Exception raise("adapter never accepted a connection on " .. ConvexTcpSmoke address)
            )
            attempt := transport connect(host, port, 0)
            if(attempt < 0) then(
                transport wait(0, 0, 200)
            ) else(
                attemptDeadline := transport monotonicMs + 1000
                progress := transport handshake(attempt)
                while(progress > 0 and transport monotonicMs < attemptDeadline,
                    transport wait(2 ** attempt, 2 ** attempt, 100)
                    progress = transport handshake(attempt)
                )
                if(progress == 0) then(
                    handle = attempt
                ) else(
                    transport close(attempt)
                    transport wait(0, 0, 200)
                )
            )
        )

        request := Sequence clone
        request appendSeq("{\"protocolVersion\":1,\"id\":\"h\",\"op\":\"hello\"}\n")
        request appendSeq("{\"id\":\"c\",\"op\":\"close\"}\n")
        while(request size > 0,
            sent := transport write(handle, request)
            if(sent < 0, Exception raise("write failed: " .. transport errorText))
            if(sent > 0, request = request exSlice(sent))
            if(request size > 0, transport wait(0, 2 ** handle, 200))
        )

        seen := Sequence clone
        while(seen containsSeq("\"type\":\"closed\"") not,
            if(transport monotonicMs > deadline,
                Exception raise("no closed event over TCP, saw: " .. seen)
            )
            transport wait(2 ** handle, 0, 200)
            chunk := transport read(handle, 65536)
            if(chunk isNil, Exception raise("adapter closed early, saw: " .. seen))
            seen appendSeq(chunk)
        )
        if(seen containsSeq("\"language\":\"io\"") not,
            Exception raise("no ready event over TCP, saw: " .. seen)
        )
        transport close(handle)
        "tcp adapter mode ok" println
        0
    )
)

// try() plus an explicit exit(1) on the caught branch, not a bare
// `System exit(ConvexTcpSmoke run)`: this pinned Io VM's own default
// top-level exception handler prints a backtrace and still exits 0 (proven
// directly with `io -e 'Exception raise("boom")'` against this exact build),
// so any of the Exception raise() calls above escaping uncaught - which is
// their only way of reporting a failure - would otherwise report this smoke
// check as passing. See the identical fix and its comment in run.io.
outcome := try(ConvexTcpSmoke run)
if(outcome,
    Convex writeDiagnostic(
        File standardError,
        "convex-io: tcp smoke check aborted on an uncaught exception: " .. \
        Convex errorMessage(outcome) .. "\n"
    )
    System exit(1)
)
System exit(0)
