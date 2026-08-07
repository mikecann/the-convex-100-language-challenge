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
