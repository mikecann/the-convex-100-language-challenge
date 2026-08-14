<img src="logo.png" alt="D programming language logo" width="125">
<!-- Logo source: https://dlang.org/images/dlogo.png -->

# D

[D](https://dlang.org/) is a statically typed, general-purpose systems and applications language. Walter Bright started it as a "better C++", and its syntax is intentionally familiar to C, C++, and Java programmers. It compiles to native code, offers low-level access when needed, and also includes higher-level tools such as garbage collection, associative arrays, and compile-time programming. The official [overview](https://dlang.org/overview.html), [history](https://dlang.org/foundation/about.html), and [usage survey](https://dlang.org/areas-of-d-usage.html) place it in a smaller modern niche spanning systems software, compilers, web applications, and numerical work.

This client is an educational, unofficial demonstration. It is not a production SDK or an officially supported Convex client.

## Getting Started

The canonical [`examples/basics/main.d`](examples/basics/main.d) program queries a fresh counter, opens a Live subscription before changing it, applies one idempotent mutation, and checks that the reactive update agrees with the HTTP result.

From the repository root, run:

```sh
./run verify-example d
```

That command builds and runs the exact example below inside Docker against a unique room on the approved test deployment. It proves the example journey, not the full shared conformance suite.

## Interesting Parts

### `scope (exit)` is the unmount your program doesn't have

In React, `useQuery` tears down its Convex subscription when the component unmounts. A command-line D program has no unmount, so this client hands you the handle, and D hands you the [scope guard statement](https://dlang.org/spec/statement.html#ScopeGuardStatement) — an idea Andrei Alexandrescu popularized in C++, built straight into D years before Go's `defer`. Cleanup sits beside acquisition and runs on every exit path, exceptions included.

```d
auto client = new ConvexClient(url);
scope (exit)
    client.close(); // runs on normal return *and* when an exception unwinds

auto live = client.subscribe("demo:state", JSONValue(["room": JSONValue(room)]));
scope (exit)
    live.close(); // guards fire in reverse order: subscription, then client
```

### Argument objects are built-in hash-map literals

D put associative arrays in the language itself rather than a library, so a Convex argument object is just a `["key": value]` literal wrapped in Phobos's `JSONValue`. And strings concatenate with `~`, because Walter Bright kept `+` strictly arithmetic.

```d
// TypeScript: await client.mutation(api.demo.increment, { room, language, runId })
auto result = client.mutation("demo:increment", JSONValue([
    "room": JSONValue(room),
    "language": JSONValue("d"),
    "runId": JSONValue(room ~ "-once")
]));
assert(result.value.object["applied"].type == JSONType.true_);
```

The client does its own bookkeeping with the same feature — every Live subscription lives in a `SubscriptionState[uint]` keyed by query id.

### The reactive update is a value you pull with `next`

Live here is the real `/api/sync` WebSocket protocol, run by a worker thread that feeds each subscription's mailbox. Instead of a component re-rendering, you ask for the next update — blocking with a deadline that D lets you write as `10_000`, digit separators included.

```d
auto live = client.subscribe("demo:state", JSONValue(["room": JSONValue(room)]));
auto initial = live.next(10_000); // blocks up to 10s; null on timeout or close

// ...one idempotent demo:increment mutation over HTTP later...

// TypeScript: useQuery would simply re-render <Counter /> with the new count
auto updated = live.next(10_000);
assert(updated !is null && updated.hasValue); // the push agrees with HTTP
```

### `unittest` is a keyword, and the example ships its own tests

D has had `unittest` blocks since its earliest releases: drop one into any module, compile with `-unittest`, and the asserts run before `main`. The basics example uses one to prove its counter decoder, while a `version (ExampleUnitTest)` block — conditional compilation without a preprocessor — swaps in an empty `main` for the test build.

```d
unittest
{
    assert(wholeCounter(JSONValue(0.0), "zero") == 0);
    assert(wholeCounter(JSONValue(1.0), "one") == 1);
    // ...and it rejects 0.5, "1", NaN, infinity, and negatives.
}
```

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, auth replacement, errors, and logs | Verified by shared local and hosted conformance |
| Live subscriptions, unsubscribe, failures, recovery, and reconnect | Verified by shared local and hosted conformance |

Clean parent commit `305e9a4` passed all 31 local and all 31 hosted checks from
the same built image. This prose-only reconciliation does not change those
verified build inputs.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.d -->
```d
module basics_main;

import convex : ConvexClient;
import std.json : JSONType, JSONValue;
import std.math : isFinite;
import std.process : environment;
import std.stdio : writeln;

/* Convex may encode a whole counter as either 1 or 1.0. Accept both JSON
 * spellings, but reject fractions and out-of-range values. */
long wholeCounter(JSONValue value, string operation)
{
    if (value.type == JSONType.integer)
    {
        if (value.integer >= 0)
            return value.integer;
    }
    if (value.type == JSONType.float_)
    {
        auto number = value.floating;
        /* long.max rounds up when converted to double, so compare against the
         * first unrepresentable integer instead of casting before the guard. */
        if (number.isFinite && number >= 0 && number < 9_223_372_036_854_775_808.0)
        {
            auto integer = cast(long) number;
            if (number == integer)
                return integer;
        }
    }
    throw new Exception(operation ~ " count is not a whole nonnegative integer");
}

version (ExampleUnitTest)
{
    void main()
    {
    }
}
else
    void main(string[] arguments)
{
    // Read the dedicated verification deployment and unique room supplied by
    // the shared example runner.
    auto url = environment.get("CONVEX_URL", "");
    if (url.length == 0)
        throw new Exception("CONVEX_URL is required");
    auto room = arguments.length > 1 ? arguments[1] : "d-basic-example";

    // Create the native D client and guarantee cleanup on every failure path.
    auto client = new ConvexClient(url);
    scope (exit)
        client.close();

    // Query the current counter over Convex's documented HTTP endpoint.
    auto query = client.query("demo:state", JSONValue(["room": JSONValue(room)]));
    // Decode the JSON response into the integer compared by the journey.
    auto before = wholeCounter(query.value.object["count"], "query");
    if (before != 0)
        throw new Exception("expected a fresh room to start at zero");
    writeln("current count: 0");

    // Start Live before mutating, so the initial snapshot and later change
    // prove a reactive WebSocket subscription rather than HTTP polling.
    auto live = client.subscribe("demo:state", JSONValue([
        "room": JSONValue(room)
    ]));
    scope (exit)
        live.close();
    auto initial = live.next(10_000);
    if (initial is null || initial.error !is null || !initial.hasValue
            || wholeCounter(initial.value.object["count"], "initial Live") != before)
        throw new Exception("unexpected initial Live value");
    writeln("live initial count: 0");

    // The unique room also makes this idempotency key safe if verification is
    // retried after the mutation response was lost.
    auto mutation = client.mutation("demo:increment", JSONValue([
        "room": JSONValue(room),
        "language": JSONValue("d"),
        "runId": JSONValue(room ~ "-once")
    ]));
    if (mutation.value.object["applied"].type != JSONType.true_)
        throw new Exception("mutation was not applied");
    auto after = wholeCounter(mutation.value.object["state"].object["count"], "mutation");
    if (after != before + 1)
        throw new Exception("mutation did not increment once");
    writeln("mutation applied: true");
    writeln("mutation count: 1");

    // Read the resulting Live update and fail if it disagrees with HTTP.
    auto updated = live.next(10_000);
    if (updated is null || updated.error !is null || !updated.hasValue
            || wholeCounter(updated.value.object["count"], "updated Live") != after)
        throw new Exception("unexpected updated Live value");
    writeln("live updated count: 1");

    // Print verification only after HTTP and Live agree on the 0 -> 1 journey.
    writeln("verified count: 0 -> 1");
}

unittest
{
    assert(wholeCounter(JSONValue(0.0), "zero") == 0);
    assert(wholeCounter(JSONValue(1.0), "one") == 1);
    foreach (invalid; [
        JSONValue(0.5), JSONValue("1"), JSONValue(double.nan),
        JSONValue(double.infinity), JSONValue(9_223_372_036_854_775_808.0),
        JSONValue(-1L)
    ])
    {
        bool rejected;
        try
            wholeCounter(invalid, "invalid");
        catch (Exception)
            rejected = true;
        assert(rejected);
    }
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public [`client/convex.d`](client/convex.d) implementation is native D. Phobos supplies JSON and HTTP support, while libcurl and OpenSSL handle network transport, TLS, and the WebSocket upgrade. The client itself owns the Convex request envelopes, Live state, reconnect behavior, and WebSocket framing. It does not delegate Convex behavior to another SDK. The Docker build pins LDC 1.40.0, the LLVM-based D compiler described on D's official [compiler page](https://dlang.org/download.html), and produces a `linux/amd64` runtime.

The HTTP API is deliberately small: `query`, `mutation`, and `action` take a Convex function path plus a JSON object and return a value with captured logs. `setAuth` replaces or clears the bearer token between calls. Function failures, malformed responses, and transport failures stay distinct instead of becoming successful JSON values.

Live work belongs to one D owner thread. Subscription handles send it commands and read from bounded mailboxes rather than touching the socket themselves. Each subscription retains the newest 16 updates, all subscriptions share an 8 MiB encoded-value budget, and oversized messages are rejected at 2 MiB. The adapter-only `debugDisconnect` hook is test infrastructure, not part of the educational client API.

The full Docker gates remain separate: `./run test d` checks formatting, unit behavior, compilation, and language-local fixtures; `./run verify d` exercises local example and conformance behavior; `./run verify-hosted d` checks the hosted drift target; and `./run verify-all d` runs both deployment profiles serially. Only the shared evaluator awards capabilities.

## Known Issues

1. Live uses the pinned experimental `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`, not a documented compatibility promise.
2. Live authentication, optimistic updates, mutations over WebSocket, and `TransitionChunk` assembly are deferred.
3. Values are limited to the JSON-safe format covered by the documented HTTP API, so tagged non-JSON Convex values are not supported.
4. The blocking `next` API suits this teaching client, but an application-facing D library would likely want a higher-level callback, range, or stream abstraction.
