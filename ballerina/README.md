# Convex from Ballerina

This educational Ballerina demonstration calls Convex over its documented
JSON HTTP endpoints and keeps one query updated through the pinned
`/api/sync` WebSocket profile. It is unofficial and is not a production SDK.

## Start here

The [canonical basic example](examples/basics/main.bal) creates a client,
reads a counter, starts Live, mutates the counter, and proves the Live update
agrees.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and bearer-token replacement | Verified by shared local and hosted conformance |
| Live query snapshots, updates, unsubscribe, reconnect | Verified by shared local and hosted conformance |
| Live authentication and optimistic writes | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.bal -->
```ballerina
import ballerina/io;
import ballerina/os;
import ballerina/uuid;

// Convex may encode a whole counter as `1`, `1.0`, or (as Ballerina's own
// JSON decoder represents a fractional literal like the wire's `0.0`) a
// `decimal`. Accept all three spellings, but reject a genuine fraction so
// the example never hides a bad response.
function wholeCounter(json value, string operation) returns int {
    if value is int {
        return value;
    }
    if value is float && value == value.floor() {
        return <int>value;
    }
    if value is decimal && value == value.floor() {
        return <int>value;
    }
    panic error(operation + " count is not a whole number");
}

public function main(string room = "ballerina-example") returns error? {
    // Read the dedicated verification deployment supplied by the shared
    // example runner.
    string url = os:getEnv("CONVEX_URL");
    if url.length() == 0 {
        return error("CONVEX_URL is required");
    }

    // Create the native Ballerina client for the configured Convex deployment.
    Client convexClient = check new (url);

    // Query the counter over Convex's documented HTTP endpoint.
    CallResult current = check convexClient.query("demo:state", {room});
    // Decode the JSON response into the integer this example compares below.
    int before = wholeCounter(check current.value.count, "query");
    io:println("current count: " + before.toString());

    // Start Live before mutating, so the initial snapshot and the later
    // change prove this is a real reactive subscription rather than HTTP
    // polling.
    Subscription live = check convexClient.subscribe("demo:state", {room});
    Update|ClosedError|TransportError initial = live.updates().recvTimeout(10.0);
    if !(initial is Update) {
        panic error("initial Live value: " + initial.message());
    }
    ConvexError? initialError = initial.err;
    if initialError is ConvexError {
        panic error("initial Live error: " + initialError.message());
    }
    int initialCount = wholeCounter(check initial.value.count, "initial Live");
    if initialCount != before {
        panic error("initial Live count disagreed with the query");
    }
    io:println("live initial count: " + before.toString());

    // Use a unique idempotency key so this mutation is safe if the example
    // is retried.
    CallResult mutationResult = check convexClient.mutation("demo:increment", {
        room,
        language: "ballerina",
        runId: uuid:createType1AsString()
    });
    if (check mutationResult.value.applied) != true {
        panic error("mutation was not applied");
    }
    int after = wholeCounter(check mutationResult.value.state.count, "mutation");
    if after != before + 1 {
        panic error("mutation count did not advance by one");
    }
    io:println("mutation applied: true");
    io:println("mutation count: " + after.toString());

    // Read the resulting Live update and fail if it disagrees with the mutation.
    Update|ClosedError|TransportError updated = live.updates().recvTimeout(10.0);
    if !(updated is Update) {
        panic error("updated Live value: " + updated.message());
    }
    ConvexError? updatedError = updated.err;
    if updatedError is ConvexError {
        panic error("updated Live error: " + updatedError.message());
    }
    int updatedCount = wholeCounter(check updated.value.count, "updated Live");
    if updatedCount != after {
        panic error("updated Live count disagreed with the mutation");
    }
    io:println("live updated count: " + after.toString());
    io:println("verified count: " + before.toString() + " -> " + after.toString());

    // Remove the Live query before closing the shared client and its owner loop.
    ConvexError? liveCloseErr = live.close();
    ConvexError? clientCloseErr = convexClient.close();
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test ballerina` formats, tests, and compiles the adapter and example
binaries inside Docker. `./run verify-example ballerina` executes the exact
example. `./run verify ballerina` runs the shared black-box adapter
conformance profile.

## Protocol notes

`ballerina/websocket`, Ballerina's own WebSocket library, corrupts a
multi-byte UTF-8 character split across a continuation-frame boundary - a
fault reproduced and diagnosed by elimination against the platform library
itself, documented in this repository's `LESSONS.md`. This client never uses
that module for Live. Instead it hand-rolls RFC 6455: the handshake, frame
masking and unmasking, fragmentation reassembly across continuation frames
with control frames interleaved mid-message, and UTF-8 validation performed
exactly once on the fully reassembled message rather than per frame. Plain
HTTP `query`/`mutation`/`action` calls still use `ballerina/http`, which is
not implicated in the defect.

The raw byte transport underneath that framing is `ballerina/tcp` for a
plaintext `ws://` connection (the local self-hosted deployment), but not for
`wss://`. Disassembling `ballerina/tcp` 1.13.8's own native jar
(`javap -c io/ballerina/stdlib/tcp/TcpClient.class`) shows its handshake
calling Netty's single-argument `SslContext.newHandler(ByteBufAllocator)`,
never the overload that also takes the remote host - so it never sends SNI.
Every TLS-terminating CDN a real deployment sits behind (Convex's hosted
deployment is fronted by Cloudflare) needs SNI to select a certificate, so
the handshake fails outright with a fatal `handshake_failure` alert; the
otherwise-identical `ballerina/http` client is unaffected, because its Netty
wiring does pass the host through. The workaround reaches the JDK's own
`SSLSocketFactory` directly through `ballerina/jballerina.java` interop -
its `createSocket(host, port)` sets SNI correctly by design - and moves
bytes across that boundary as Base64 text rather than as a Ballerina
`byte[]`, because the interop compiler's array-parameter matching rejects
both `"byte[]"` and `"[B"` as a `paramTypes` entry whenever the Ballerina
side of the call is itself typed `byte[]` (confirmed by exhausting the
combinations directly). See `client/raw_socket.bal`.

The adapter speaks NDJSON v1 over stdin/stdout or the exact `ADAPTER_LISTEN`
TCP address. `debugDisconnect` is adapter-only and deliberately forces the
ordinary reconnect path. One owner strand serializes every Live query-set
change and acknowledges removal, disconnect, and close only after the state
transition completes. The adapter serializes subscription generations with
its NDJSON writer so stale relays cannot cross an acknowledgement.

Live delivery has a per-subscription newest-16 mailbox, dropping the oldest
intermediate value for a slow consumer. Reconnect backoff resets only after a
valid server message, and the client carries the newest observed timestamp
into the next `Connect` message. A reconnect dial itself runs inline on the
owner strand rather than on a separate connector strand, so a queued command
can be delayed by up to the connect deadline while a reconnect is in flight -
a deliberate simplification, not a bound violation, since every owner command
still completes within a fixed deadline.

## Limitations

This only implements the JSON-safe value subset. `TransitionChunk`, Live
auth, optimistic updates, and WebSocket mutations/actions are explicitly
deferred.
