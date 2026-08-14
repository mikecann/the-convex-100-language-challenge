<img src="logo.png" alt="Ballerina logo" width="320">
<!-- Logo source: https://ballerina.io/img/branding/ballerina_logo_dgrey_png.png -->

# Ballerina

[Ballerina](https://ballerina.io/) is a statically typed language built for
networked applications and integration work. Its syntax is deliberately
familiar to Java, C#, and JavaScript developers, while records, JSON, errors,
and concurrency are designed around data crossing service boundaries. The
current [jBallerina implementation compiles to JVM
bytecode](https://ballerina.io/learn/ballerina-specifications/).

WSO2 began developing Ballerina in 2016 and [released 1.0 in
2019](https://blog.ballerina.io/posts/2019-09-09-annoucing-1.0.0/), then followed
it with the substantially revised [Swan Lake release in
2022](https://blog.ballerina.io/posts/2022-02-01-announcing-ballerina-2201.0.0-swan-lake/).
Its present-day niche is APIs, integrations, and cloud services. This
repository's client is an educational, unofficial demonstration, not a
production SDK or an official Convex client.

## Getting Started

Start with the [canonical example](examples/basics/main.bal). It makes a
one-off HTTP query, opens a Live subscription, applies a mutation with a fresh
idempotency key, receives the reactive update, and then closes both handles.
From the repository root, run:

```sh
./run verify-example ballerina
```

That command builds and runs the exact example in Docker against a unique room.
You do not need Ballerina installed on your machine.

## Interesting Parts

### `check` makes a Convex call one honest line

Ballerina has no exceptions for ordinary failure: a function that can fail
*returns* its error, and the `check` keyword either unwraps the success value
or hands the error straight back to the caller. Add record literals — same
braces, same field shorthand as JavaScript — and a mutation stays compact
without hiding its failure path.

```ballerina
Client convexClient = check new (url);

// TypeScript: const result = await increment({ room, language, runId });
CallResult result = check convexClient.mutation("demo:increment", {
    room, // Field shorthand, straight out of a JS object literal.
    language: "ballerina",
    runId: uuid:createType1AsString()
});
```

Every `check` marks a spot where the compiler knows the call can go wrong.

### `json` is a language type, and `is` carves it up

Ballerina grew up at WSO2 doing integration work, so JSON is not a library —
`json` is a built-in union of nil, booleans, strings, numbers, arrays, and
maps. Convex may spell a whole counter as `1`, `1.0`, or a decimal on the
wire, and the canonical example narrows all three with `is` type tests:

```ballerina
function wholeCounter(json value, string operation) returns int {
    if value is int {
        return value; // Narrowed: a plain int from here on, no cast.
    }
    if value is float && value == value.floor() {
        return <int>value;
    }
    if value is decimal && value == value.floor() {
        return <int>value;
    }
    panic error(operation + " count is not a whole number");
}
```

Type tests are control flow: inside the branch, `value` simply *is* an `int`.

### Four kinds of failure, four distinct error types

The client models Convex's failure shapes as separate `distinct error` types —
the function itself failing, a protocol violation, a transport fault, and a
call on an already-closed client — unioned into one `ConvexError`. Call sites
narrow with `is`, and the compiler checks every branch is handled.

```ballerina
public type ConvexError FunctionError|ProtocolError|TransportError|ClosedError;

CallResult|ConvexError result = convexClient.query("demo:state", {room});
if result is FunctionError {
    // The Convex function reported failure: an expected outcome, with logs.
    io:println(result.detail().logs);
}
```

A failed Convex function is data you branch on, not a stack trace you catch.

### Live updates land in a mailbox, not a callback

Where React's `useQuery` rerenders your component, this command-line client
hands you a `Subscription` you read like a channel. One background strand —
Ballerina's lightweight thread — owns the WebSocket, and each subscription
gets an isolated, bounded mailbox holding the newest 16 deliveries.

```ballerina
// TypeScript: const state = useQuery(api.demo.state, { room });
Subscription live = check convexClient.subscribe("demo:state", {room});
Update|ClosedError|TransportError initial = live.updates().recvTimeout(10.0);

// ...increment the counter...

Update|ClosedError|TransportError updated = live.updates().recvTimeout(10.0);
if updated is Update {
    io:println(updated.value); // The reactive update, pushed by Convex.
}
ConvexError? liveCloseErr = live.close(); // Unsubscribing is explicit here.
```

The union return type means you cannot touch `updated.value` before deciding
what a timeout or a closed client should mean.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and bearer-token replacement | Verified by shared local and hosted conformance |
| Live query snapshots, updates, unsubscribe, reconnect | Verified by shared local and hosted conformance |
| Live authentication and optimistic writes | Deferred |

## Example

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

## Implementation Notes

This is a native Ballerina implementation. HTTP queries, mutations, and
actions use the standard `ballerina/http` client and Convex's documented JSON
HTTP endpoints. Results use a small structural `CallResult` record whose value
remains `json`, so applications decide which endpoint-specific shape to decode.

Live is more custom. The implementation does not use `ballerina/websocket`
because a language-local regression test found that library corrupting a
multi-byte UTF-8 character split across continuation frames. The client instead
implements the RFC 6455 handshake and framing itself. Plain local connections
use `ballerina/tcp`; hosted TLS connections use the JDK's `SSLSocketFactory`
through Java interop because the pinned `ballerina/tcp` TLS client does not send
the SNI host required by the hosted endpoint.

One owner strand controls WebSocket reads, writes, subscriptions, and
reconnects. Other strands send it commands, while each public subscription
receives values through an isolated, bounded mailbox. Open records accept
additional server fields that this pinned client does not read, and distinct
error types keep function, protocol, transport, and closed-client failures
separate. The Docker build pins Ballerina 2201.13.5 and runs the resulting JVM
application on Eclipse Temurin JRE 21.0.8+9.

The lower-level conformance adapter speaks NDJSON protocol v1 over standard I/O
or its requested TCP address. Its `debugDisconnect` operation is test-only and
forces the normal reconnect path; it is not part of the educational client API.

## Known Issues

1. The client supports only Convex's JSON-safe value subset. `TransitionChunk`
   assembly, Live authentication, optimistic updates, and Live mutations or
   actions are deferred.
2. Each Live subscription retains the newest 16 updates. A slow consumer can
   miss older intermediate states, though it still receives the newest state.
3. Reconnect dialing runs on the owner strand. A command queued during a dial
   can wait up to the connection deadline before the owner handles it.
