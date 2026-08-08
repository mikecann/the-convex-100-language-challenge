# Convex from C#

This is a small native C# demonstration of Convex JSON HTTP functions and an
experimental implementation of the pinned Live sync profile. It is educational,
unofficial, and not a production SDK.

## Start here

[The canonical basic example](examples/basics/Program.cs) reads a counter,
starts Live before changing it, performs an idempotent mutation, and verifies
the Live update. This exact source is built into the example image.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Live query subscriptions | Verified by shared local and hosted conformance |
| Authentication | HTTP bearer tokens only |

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

## Docker verification

```sh
./run test csharp
./run build csharp
./run verify-example csharp
./run verify csharp
```

`test` compiles the C# sources inside Docker. `build` creates minimal amd64
runtime images. The latter commands are root-owned shared evidence runs and do
not award capabilities until they pass.

## Protocol notes

Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile at `/api/sync`.
The test-only adapter speaks NDJSON v1 and provides `debugDisconnect` so the
shared harness can prove real reconnects.

## Limitations

Live authentication, WebSocket mutations/actions, transition chunks, optimistic
updates, journals, and replay are intentionally deferred. Each subscription has
a bounded newest-16 delivery buffer, so a slow reader drops old intermediate
updates rather than consuming unbounded memory.
