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

### Record literals fit Convex arguments, but results stay honest JSON

Ballerina's [records](https://ballerina.io/learn/by-example/records/) look at
home beside JavaScript object literals. Its [union types and `is`
narrowing](https://ballerina.io/learn/by-example/unions/) are especially useful
when Convex JSON numbers may decode as `int`, `float`, or `decimal`.

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  async function handleClick() {
    const result = await increment({
      room: "readme-ballerina-records",
      language: "typescript",
      runId: crypto.randomUUID(), // A fresh key makes this attempt idempotent.
    });
    console.log(result.state.count); // Generated API types make count a number.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Ballerina**

```ballerina
import ballerina/io;
import ballerina/os;
import ballerina/uuid;

function wholeCount(json value) returns int|error {
    if value is int {
        return value; // The `is` check narrows value to int in this branch.
    }
    if value is float && value == value.floor() {
        return <int>value;
    }
    if value is decimal && value == value.floor() {
        return <int>value;
    }
    return error("count was not a whole number");
}

public function main() returns error? {
    string deploymentUrl = os:getEnv("CONVEX_URL");
    if deploymentUrl.length() == 0 {
        return error("CONVEX_URL is required");
    }
    Client client = check new (deploymentUrl);
    string room = "readme-ballerina-records";
    CallResult result = check client.mutation("demo:increment", {
        room, // Record shorthand builds the same Convex argument object.
        language: "ballerina",
        runId: uuid:createType1AsString()
    });
    int count = check wholeCount(check result.value.state.count);
    io:println(count); // count is type-safe only after explicit JSON narrowing.
    ConvexError? closeError = client.close();
}
```

The TypeScript client is generated from the Convex API, so it knows the
function's argument and return types. This Ballerina client intentionally
exposes `json`; the record literal is convenient, but the caller must validate
returned fields. The full example also rejects fractional and overflowing
counters.

### Live updates have an explicit lifecycle

React owns the `useQuery` subscription while the component is mounted. This
command-line client instead returns a `Subscription`, and the caller receives
updates from its mailbox and closes it directly.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const room = "readme-ballerina-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <p>Loading...</p>;

  async function handleIncrement() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    console.log(result.applied); // The mutation result is generated and typed.
  }

  return (
    <button
      onClick={() => void handleIncrement()}
    >
      Count: {state.count}
    </button>
  ); // React rerenders this component when the query result changes.
}
```

**Ballerina**

```ballerina
import ballerina/os;
import ballerina/uuid;

function nextUpdate(Subscription live) returns Update|ConvexError {
    Update|ClosedError|TransportError delivery =
        live.updates().recvTimeout(10.0); // This client chooses a blocking read.
    if delivery is ClosedError|TransportError {
        return delivery; // The union is narrowed before Update fields are used.
    }
    ConvexError? updateError = delivery.err;
    if updateError is ConvexError {
        return updateError;
    }
    return delivery;
}

public function main() returns error? {
    string deploymentUrl = os:getEnv("CONVEX_URL");
    if deploymentUrl.length() == 0 {
        return error("CONVEX_URL is required");
    }
    Client client = check new (deploymentUrl);
    string room = "readme-ballerina-live";
    Subscription live = check client.subscribe("demo:state", {room});
    Update initial = check nextUpdate(live); // First delivery is the current value.

    CallResult result = check client.mutation("demo:increment", {
        room,
        language: "ballerina",
        runId: uuid:createType1AsString()
    });
    if (check result.value.applied) != true {
        return error("mutation was not applied"); // Validate the HTTP result.
    }
    Update changed = check nextUpdate(live); // Next delivery is the reactive update.

    ConvexError? liveCloseError = live.close(); // Stop this query explicitly.
    ConvexError? clientCloseError = client.close(); // Stop the shared Live owner.
}
```

Ballerina supports streams and asynchronous concurrency, but this client's
blocking `recvTimeout` mailbox is an API decision, not a language limitation.
It keeps the newest 16 deliveries for each subscription and drops older
intermediate states when a consumer falls behind.

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
