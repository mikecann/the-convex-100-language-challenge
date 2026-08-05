using System.Text.Json.Nodes;
using Convex;

static int Count(JsonNode state, string operation) => state["count"]?.GetValue<int>() ?? throw new InvalidOperationException(operation + " did not return a whole count");

// Read configuration from the verifier rather than baking a deployment into the image.
var url = Environment.GetEnvironmentVariable("CONVEX_URL") ?? throw new InvalidOperationException("CONVEX_URL is required");
// A unique room means other example runs cannot change this counter.
var room = args.Length == 0 ? "csharp-example" : args[0];
var roomArgs = new JsonObject { ["room"] = room };
// One native HTTP client and one Live connection are cleaned up even when a check fails.
using var client = new ConvexClient(url);
using var live = new LiveClient(url);
// Read the documented JSON HTTP query and decode the idiomatic JSON value.
var before = Count((await client.Query("demo:state", roomArgs)).Value ?? throw new InvalidOperationException("current query returned null"), "current query");
// Start Live before the mutation so this first value establishes our observation point.
using var subscription = await live.Subscribe("demo:state", roomArgs);
var initial = Count(subscription.Next(TimeSpan.FromSeconds(10)), "initial Live value");
if (initial != before) throw new InvalidOperationException("Live initial value disagreed");
// runId is the mutation's idempotency key, avoiding a double increment after a retry.
var mutation = await client.Mutation("demo:increment", new JsonObject { ["room"] = room, ["language"] = "csharp", ["runId"] = Guid.NewGuid().ToString() });
var mutationValue = mutation.Value ?? throw new InvalidOperationException("mutation returned null");
var applied = mutationValue["applied"]?.GetValue<bool>() ?? false;
if (!applied) throw new InvalidOperationException("mutation was not applied");
var after = Count(mutationValue["state"]!, "mutation");
if (after != before + 1) throw new InvalidOperationException("mutation count was unexpected");
// Consume the corresponding Live update, then print only when every observation agrees.
var updated = Count(subscription.Next(TimeSpan.FromSeconds(10)), "updated Live value");
if (updated != after) throw new InvalidOperationException("Live update disagreed");
Console.WriteLine($"current count: {before}");
Console.WriteLine($"live initial count: {initial}");
Console.WriteLine($"mutation applied: {applied.ToString().ToLowerInvariant()}");
Console.WriteLine($"mutation count: {after}");
Console.WriteLine($"live updated count: {updated}");
Console.WriteLine($"verified count: {before} -> {updated}");
