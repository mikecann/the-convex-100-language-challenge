# Zig

[Zig](https://ziglang.org/) is a general-purpose language and toolchain created
by Andrew Kelley for robust, low-level software. It sits near C in the systems
programming world, with direct C interoperability, first-class cross-compiling,
explicit memory allocation, and no hidden control flow or allocation. Its
present-day niche includes command-line tools, servers, embedded software,
operating-system work, and WebAssembly. Zig is still pre-1.0, so language and
standard-library APIs can change between releases.

This repository uses Zig 0.14.1 to build a native Convex client with Zig's
standard HTTP, TLS, JSON, networking, and threading facilities. It is
educational and unofficial, not a production SDK or an officially supported
Convex package.

## Getting Started

Start with the runnable [`examples/basics/main.zig`](examples/basics/main.zig).
From the repository root, Docker builds its pinned `linux/amd64` environment and
runs the exact example against a fresh counter room:

```sh
./run verify-example zig
```

The program queries `api.demo.state`, starts a Live subscription, calls
`api.demo.increment`, and checks that both the mutation result and reactive
update move the count from `0` to `1`.

## Interesting Parts

### A Rejected Mutation Is Data, a Dead Socket Is an Error

Zig has no exceptions. Every fallible function returns an error union spelled
`!T`, and `try` forwards a failure to the caller instead of unwinding a hidden
stack. Convex gives that split a nice, concrete use: a legitimate Convex
function rejection is not a Zig error at all, it comes back as ordinary data
in `CallResult.function_error`, while only a broken connection or a malformed
reply reaches for the error union.

```zig
const result = try client.call(allocator, "mutation", "demo:increment", args);
if (result.function_error) |failure| {
    // TypeScript: catch (e) { if (e instanceof ConvexError) ... }
    std.debug.print("rejected: {s}\n", .{failure.message});
    return;
}
const applied = result.value.?.object.get("applied").?.bool;
```

`try` only fires here for a transport or protocol failure; a round trip that
Convex completed but chose to reject still lands on the next line.

### Building `{ room }` Takes Four Explicit Lines

Zig has no garbage collector and no implicit heap access anywhere in its
standard library, so every allocating call takes an `Allocator` argument you
supply. The JSON object TypeScript would write inline as `{ room }` means
asking `std.json.ObjectMap` for storage, filling it in, and owning its
lifetime with `defer` yourself.

```zig
var args_object = std.json.ObjectMap.init(allocator);
defer args_object.deinit(); // TypeScript: const args = { room };
try args_object.put("room", .{ .string = room });
const args = convex.JsonValue{ .object = args_object };
const result = try client.call(allocator, "query", "demo:state", args);
```

The `defer` is not ceremony: it is the only thing that frees `args_object`,
and it still runs if an earlier `try` above it had bailed out first.

### A Live Update Waits in a Mailbox Until You Ask

Live queries are verified here against both a local and a hosted Convex
deployment, but this client is a command-line program with no component tree
to rerender, so `subscribe` cannot hand values to a hook the way `useQuery`
does. Instead it deposits each one in a small bounded mailbox, and the caller
blocks on `Capture.next` whenever it is ready for the next value.

```zig
var capture = convex.Capture.init(allocator);
output.capture = &capture;
try client.subscribe("counter", "demo:state", query_args, &output);
const initial = try capture.next(allocator, 10 * std.time.ns_per_s);
// ...call demo:increment here...
// TypeScript: useQuery(api.demo.state, { room }) reruns the component for you
const updated = try capture.next(allocator, 10 * std.time.ns_per_s);
try client.unsubscribe("counter");
```

One owner thread drives every reconnect and delivery in the background;
`capture.next` just waits its turn at the mailbox door.

## Status

| Capability | Status |
| --- | --- |
| Native implementation | Verified by shared local and hosted conformance at this exact head |
| HTTP query, mutation, and action | Verified by shared local and hosted conformance |
| Bearer-token lifecycle | Verified by shared local and hosted conformance |
| Live initial values, updates, recovery, and reconnect hook | Verified by shared local and hosted conformance |
| Convex tagged values | Deferred, JSON-safe values only |

## Example

The full teaching example below is generated directly from the runnable source.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.zig -->
```zig
const std = @import("std");
const convex = @import("convex");

fn wholeCounter(value: convex.JsonValue) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        // Comparing with maxInt(i64) is unsafe here because converting that
        // boundary to f64 rounds it up to 2^63. Use an exclusive upper bound
        // so 9223372036854775808.0 can never reach @intFromFloat.
        .float => |float| if (std.math.isFinite(float) and
            @trunc(float) == float and
            float >= -9223372036854775808.0 and
            float < 9223372036854775808.0)
            @intFromFloat(float)
        else
            error.InvalidResponse,
        else => blk: {
            break :blk error.InvalidResponse;
        },
    };
}

fn countOf(value: convex.JsonValue) !i64 {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    return wholeCounter(object.get("count") orelse return error.InvalidResponse);
}

test "whole counters accept integral decimals without f64 boundary rounding" {
    try std.testing.expectEqual(@as(i64, 0), try wholeCounter(.{ .float = 0.0 }));
    try std.testing.expectEqual(@as(i64, 1), try wholeCounter(.{ .float = 1.0 }));
    try std.testing.expectEqual(std.math.minInt(i64), try wholeCounter(.{ .float = -9223372036854775808.0 }));
    try std.testing.expectEqual(@as(i64, 9223372036854774784), try wholeCounter(.{ .float = 9223372036854774784.0 }));
    try std.testing.expectError(error.InvalidResponse, wholeCounter(.{ .float = 1.5 }));
    try std.testing.expectError(error.InvalidResponse, wholeCounter(.{ .string = "1" }));
    try std.testing.expectError(error.InvalidResponse, wholeCounter(.{ .float = std.math.inf(f64) }));
    try std.testing.expectError(error.InvalidResponse, wholeCounter(.{ .float = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidResponse, wholeCounter(.{ .float = 9223372036854775808.0 }));
    var overflow = try std.json.parseFromSlice(convex.JsonValue, std.testing.allocator, "9223372036854775808.0", .{});
    defer overflow.deinit();
    try std.testing.expectError(error.InvalidResponse, wholeCounter(overflow.value));
}

fn makeArgs(allocator: std.mem.Allocator, room: []const u8) !convex.JsonValue {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("room", .{ .string = room });
    return .{ .object = object };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const url = try std.process.getEnvVarOwned(allocator, "CONVEX_URL");
    defer allocator.free(url);
    const room: []const u8 = if (std.os.argv.len > 1) std.mem.span(std.os.argv[1]) else "zig-basic-example";
    var client = try convex.Client.init(allocator, url);

    // Configure the deployment and create the native Zig client.
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const query_args = try makeArgs(query_arena.allocator(), room);
    // Query the counter through Convex's documented HTTP endpoint.
    const query = try client.call(query_arena.allocator(), "query", "demo:state", query_args);
    const before = try countOf(query.value orelse return error.InvalidResponse);
    std.debug.assert(before == 0);
    try std.io.getStdOut().writer().print("current count: {d}\n", .{before});

    // Start Live before the mutation so the initial snapshot cannot be missed.
    var capture = convex.Capture.init(allocator);
    var output = convex.Output.init(allocator, std.io.getStdErr().writer().any(), std.io.getStdErr().handle, .none);
    output.capture = &capture;
    // Stop the Live owner before freeing either delivery target. This order is
    // also safe when a later operation returns early, while a transition is
    // still in flight on the owner's thread.
    defer {
        client.deinit();
        output.deinit();
        capture.deinit();
    }
    try client.subscribe("example", "demo:state", query_args, &output);
    // Decode the actual initial Live value from the bounded mailbox.
    var live_arena = std.heap.ArenaAllocator.init(allocator);
    defer live_arena.deinit();
    const initial_live = try capture.next(live_arena.allocator(), 10 * std.time.ns_per_s);
    if (try countOf(initial_live) != before) return error.InvalidResponse;
    try std.io.getStdOut().writer().print("live initial count: {d}\n", .{before});

    var mutation_arena = std.heap.ArenaAllocator.init(allocator);
    defer mutation_arena.deinit();
    var mutation_args = try makeArgs(mutation_arena.allocator(), room);
    try mutation_args.object.put("language", .{ .string = "Zig" });
    try mutation_args.object.put("runId", .{ .string = "zig-basic-example-once" });
    // Use a stable idempotency key so retrying this demonstration is safe.
    const mutation = try client.call(mutation_arena.allocator(), "mutation", "demo:increment", mutation_args);
    const mutation_value = mutation.value orelse return error.InvalidResponse;
    const mutation_object = switch (mutation_value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    const applied = mutation_object.get("applied") orelse return error.InvalidResponse;
    if (applied != .bool or !applied.bool) return error.InvalidResponse;
    const after = try countOf(mutation_object.get("state") orelse return error.InvalidResponse);
    if (after != before + 1) return error.InvalidResponse;
    try std.io.getStdOut().writer().writeAll("mutation applied: true\n");
    try std.io.getStdOut().writer().print("mutation count: {d}\n", .{after});

    // Decode the actual resulting Live value before printing the verification.
    const updated_live = try capture.next(live_arena.allocator(), 10 * std.time.ns_per_s);
    if (try countOf(updated_live) != after) return error.InvalidResponse;
    try std.io.getStdOut().writer().print("live updated count: {d}\n", .{after});
    try std.io.getStdOut().writer().print("verified count: {d} -> {d}\n", .{ before, after });
    try client.unsubscribe("example");
}
```
<!-- END GENERATED EXAMPLE -->

Its expected stdout transcript is:

```text
current count: 0
live initial count: 0
mutation applied: true
mutation count: 1
live updated count: 1
verified count: 0 -> 1
```

## Implementation Notes

- This is a native Zig implementation. `std.http.Client` handles HTTP and TLS,
  `std.json` handles JSON, and the client implements its own small WebSocket
  framing and Live owner layer. It does not delegate Convex behavior to Node,
  Python, `curl`, the Convex CLI, or another Convex client.
- The public API is intentionally small: `Client.call` handles query, mutation,
  and action requests; `subscribe` and `unsubscribe` manage Live queries; and
  `setAuth` replaces or clears a copied bearer token. The adapter-only
  `debugDisconnect` hook exists for reconnect testing, not application code.
- Allocation is visible. The caller supplies allocators, the example uses short
  lived arenas for decoded responses, and `defer` releases values in a safe
  order. Transport and malformed-response failures use Zig's error union.
  Valid Convex function failures remain data in `CallResult.function_error`, so
  callers can distinguish an application error from a broken connection or
  response.
- One owner thread serializes WebSocket reads, writes, reconnects, and active
  subscriptions. Live delivery is bounded to sixteen queued or in-flight
  events and eight MiB, dropping the oldest queued state under pressure. This
  avoids an unbounded queue if the consumer stops reading.
- Docker pins Zig 0.14.1 and builds `ReleaseSafe` static musl executables for
  `linux/amd64`. The final non-root images contain the executable, CA
  certificates, and only the small POSIX command surface required by the
  shared verifier.

For language details, Zig's official [overview](https://ziglang.org/learn/overview/)
explains allocators, error handling, C interoperability, and cross-compiling.
The [0.14.1 download page](https://ziglang.org/download/#release-0.14.1) records
the toolchain release used here.

## Known Issues

1. Live follows an unversioned sync shape pinned to `convex-rs` 0.10.4 at
   commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`. It is an experiment, not an
   official Convex compatibility promise.
2. Only JSON-safe Convex values are decoded. Tagged Convex values are deferred.
3. Live authentication, optimistic updates, WebSocket mutations and actions,
   and `TransitionChunk` assembly are not implemented.
4. The Live API exposes a blocking bounded mailbox rather than a React-like
   callback or hook abstraction. Slow consumers may lose older queued states,
   while the newest state is retained within the count and byte budgets.
5. Each HTTP operation has a ten-second absolute deadline. Live connection
   setup also has a ten-second absolute deadline, and each complete incoming
   WebSocket message has a five-second deadline.
