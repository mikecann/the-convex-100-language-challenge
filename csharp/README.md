<img src="logo.png" alt="C# logo" width="128">
<!-- Logo source: https://github.com/dotnet/brand/blob/main/logo/language-icons/csharp-128.png -->

# C#

C# (pronounced “C sharp”) is a general-purpose, strongly typed language developed at Microsoft and [first released with the .NET initiative in 2000](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/introduction). Its braces and semicolons feel familiar if you know Java, C++, JavaScript, or TypeScript, while features such as garbage collection, records, pattern matching, and `async`/`await` give it a distinctly modern .NET shape.

Today C# is the main language of the cross-platform [.NET](https://dotnet.microsoft.com/en-us/languages/csharp) ecosystem. It is widely used for web services with ASP.NET Core, desktop and mobile applications, cloud systems, and games. Microsoft describes it as one of the five most-used languages in GitHub projects. This repository's client is an educational, unofficial demonstration, not a production SDK or an officially supported Convex client.

## Getting Started

Start with the [canonical basic example](examples/basics/Program.cs). It reads a counter, opens a Live subscription before changing that counter, performs an idempotent mutation, and checks that Live delivers the same new value.

From the repository root, run:

```sh
./run verify-example csharp
```

That command builds and runs the exact example in Docker against a unique room, so concurrent runs cannot interfere with its `0 -> 1` journey.

## Interesting Parts

### The `await` you type in TypeScript was born here

C# introduced `async`/`await` with C# 5 in 2012, and JavaScript adopted the keywords almost verbatim a few years later. Combined with top-level statements (no class, no `Main`) and JSON built through indexer initializers, a Convex query is just a few honest lines:

```csharp
var roomArgs = new JsonObject { ["room"] = "readme-csharp" };
using var client = new ConvexClient(url);

// TypeScript: const state = useQuery(api.demo.state, { room })
var result = await client.Query("demo:state", roomArgs);
Console.WriteLine(CountValue.Read(result.Value!, "demo:state"));
```

The difference hiding in that comment: `useQuery` is a live subscription, while `Query` is one HTTP round-trip.

### `using var` is the `useEffect` cleanup

`IDisposable` gives C# deterministic teardown: a `using var` declaration disposes its value when the scope ends, even on an exception. This client wires that into the Live protocol itself — disposing a subscription sends the `Remove` message over the WebSocket, and disposing the `LiveClient` closes the socket.

```csharp
using var live = new LiveClient(url);
using var subscription = await live.Subscribe("demo:state", roomArgs);

var initial = CountValue.Read(subscription.Next(TimeSpan.FromSeconds(10)), "initial Live value");
// ... increment over HTTP; Convex pushes the new count to the socket ...
var updated = CountValue.Read(subscription.Next(TimeSpan.FromSeconds(10)), "updated Live value");
// TypeScript: React's useEffect cleanup performs this unsubscribe for you.
```

The unsubscribe cannot be forgotten: leaving the scope is what sends it.

### Two `record` lines are the whole wire model

Records (C# 9, 2020) pack a constructor, read-only properties, value equality, and a printable `ToString` into a single line. The client's entire result model is two of them — and the `?` on `JsonNode?` is compiler-enforced nullability doing the same job as TypeScript's `strictNullChecks`.

```csharp
// ConvexClient.cs — what every query, mutation, and action returns:
public record Result(JsonNode? Value, IReadOnlyList<string> Logs);

// LiveClient.cs — what every Live push delivers to a subscription:
public record Update(JsonNode? Value, Exception? Error, IReadOnlyList<string> Logs);

// Since C# 12, even classes take primary constructors:
public sealed class LiveClient(string deployment) : IDisposable
```

### Pattern matching reads the sync protocol aloud

Pattern matching has grown steadily since C# 7, and the Live client's message pump uses it to sort Convex's WebSocket frames with code that reads like the sentence it replaces:

```csharp
var type = message["type"]?.GetValue<string>();
if (type is "Ping" or "MutationResponse" or "ActionResponse")
    return;                                     // heartbeats and echoes
if (type is not "Transition")
    throw new ConvexClient.ProtocolException("unsupported Live message: " + type);

// The example's decoder tests and binds in a single pattern:
if (state["count"] is not JsonValue value)
    throw Invalid(operation);
```

`is not`, `or` between constants, and declaration patterns turn protocol dispatch into something close to prose.

## Status

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Live query subscriptions | Verified by shared local and hosted conformance |
| Authentication | HTTP bearer tokens only |

The implementation is native C# on .NET 8. It uses .NET's HTTP, JSON, and WebSocket libraries, but implements the Convex-specific request and Live sync behavior itself.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Program.cs -->
```csharp
using System.Text.Json.Nodes;
using Convex;

// Read configuration from the verifier rather than baking a deployment into the image.
var url =
    Environment.GetEnvironmentVariable("CONVEX_URL")
    ?? throw new InvalidOperationException("CONVEX_URL is required");

// A unique room means other example runs cannot change this counter.
var room = args.Length == 0 ? "csharp-example" : args[0];
var roomArgs = new JsonObject { ["room"] = room };

// One native HTTP client and one Live connection are cleaned up even when a check fails.
using var client = new ConvexClient(url);
using var live = new LiveClient(url);

// Read the documented JSON HTTP query and decode the idiomatic JSON value.
var before = CountValue.Read(
    (await client.Query("demo:state", roomArgs)).Value
        ?? throw new InvalidOperationException("current query returned null"),
    "current query"
);

// Start Live before the mutation so this first value establishes our observation point.
using var subscription = await live.Subscribe("demo:state", roomArgs);
var initial = CountValue.Read(subscription.Next(TimeSpan.FromSeconds(10)), "initial Live value");
if (initial != before)
    throw new InvalidOperationException("Live initial value disagreed");

// runId is the mutation's idempotency key, avoiding a double increment after a retry.
var mutation = await client.Mutation(
    "demo:increment",
    new JsonObject
    {
        ["room"] = room,
        ["language"] = "csharp",
        ["runId"] = Guid.NewGuid().ToString(),
    }
);
var mutationValue = mutation.Value ?? throw new InvalidOperationException("mutation returned null");
var applied = mutationValue["applied"]?.GetValue<bool>() ?? false;
if (!applied)
    throw new InvalidOperationException("mutation was not applied");
var after = CountValue.Read(mutationValue["state"]!, "mutation");
if (after != before + 1)
    throw new InvalidOperationException("mutation count was unexpected");

// Consume the corresponding Live update, then print only when every observation agrees.
var updated = CountValue.Read(subscription.Next(TimeSpan.FromSeconds(10)), "updated Live value");
if (updated != after)
    throw new InvalidOperationException("Live update disagreed");
Console.WriteLine($"current count: {before}");
Console.WriteLine($"live initial count: {initial}");
Console.WriteLine($"mutation applied: {applied.ToString().ToLowerInvariant()}");
Console.WriteLine($"mutation count: {after}");
Console.WriteLine($"live updated count: {updated}");
Console.WriteLine($"verified count: {before} -> {updated}");
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

[`ConvexClient`](client/ConvexClient.cs) posts queries, mutations, and actions to the JSON HTTP API. It deep-clones each caller-owned `JsonObject`, so the same arguments can be safely reused, and separates function failures from transport and protocol failures. `SetAuth` adds a bearer token to HTTP calls only.

[`LiveClient`](client/LiveClient.cs) connects with `ClientWebSocket` to the pinned `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`. It tracks the active query set, validates transition versions, decodes fragmented UTF-8 messages, and reconnects with bounded exponential backoff. A single receive loop handles server messages, while a semaphore protects connection and subscription state.

Each subscription keeps only its newest 16 updates. A slow consumer can therefore miss intermediate values, but cannot grow the delivery queue without bound. The language-local tests cover queue overflow, UTF-8 fragmentation, structured errors, stale events after unsubscribe or replacement, and reconnecting with active subscriptions.

The Docker build pins .NET SDK 8.0.408 and the .NET 8.0.15 runtime for `linux/amd64`. The published images retain the .NET runtime but remove SDK, compiler, package-manager, Node.js, Python, and Convex CLI commands. Both the example and conformance adapter run as user `65532:65532`.

For the repository's evidence layers, `./run test csharp` compiles and exercises the language-local tests in Docker, while `./run verify csharp` and `./run verify-hosted csharp` are the separate shared conformance runs.

## Known Issues

1. Authentication is implemented for JSON HTTP calls only. Live authentication is deferred.
2. Mutations and actions use HTTP. Sending them over the Live WebSocket is not implemented.
3. Transition chunks, optimistic updates, journals, and replay are outside the pinned Live profile implemented here.
4. A slow Live consumer receives the newest 16 buffered updates and may miss older intermediate states.
