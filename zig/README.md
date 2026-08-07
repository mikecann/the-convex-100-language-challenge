# Convex from Zig

This educational client calls Convex functions over HTTP and follows one
reactive query through the pinned `/api/sync` WebSocket profile. The canonical
example checks the counter's `0 -> 1` journey.

This is unofficial teaching material, not a production SDK.

## Start here

Read [`examples/basics/main.zig`](examples/basics/main.zig). It configures the
deployment, performs an HTTP query, starts Live before the mutation, applies an
idempotent mutation, and checks the resulting Live value.

## What works

| Capability | Status |
| --- | --- |
| Native implementation | Verified by shared local and hosted conformance at this exact head |
| HTTP query, mutation, and action | Verified by shared local and hosted conformance |
| Bearer-token lifecycle | Verified by shared local and hosted conformance |
| Live initial values, updates, recovery, and reconnect hook | Verified by shared local and hosted conformance |
| Convex tagged values | Deferred, JSON-safe values only |

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

## Docker verification

```sh
./run test zig
./run build zig
```

The first command formats, unit-tests, and compiles the adapter and canonical
example inside a pinned `linux/amd64` Zig 0.14.1 image. The second produces the
minimal non-root example and adapter images. The root integration owner must
run `verify-example`, local conformance, and hosted conformance before any
capability badge is earned.

## Protocol notes

The adapter speaks NDJSON protocol v1 over stdin/stdout or one
`ADAPTER_LISTEN` TCP connection. A single Live owner handles WebSocket
connection state, query-set versions, reconnects, and writes. WebSocket frames
are masked on client writes, control frames are answered, timestamps are
compared as little-endian `uint64` values, and rehydration suppresses an
unchanged value.

Live output uses a two-phase delivery token. Dequeue keeps the event charged
to the sixteen-event and eight MiB budgets, unsubscribe or replacement revokes
the old generation, and the output worker checks that generation immediately
before writing. A stopped reader therefore retains bounded recent state without
letting an old relay cross its acknowledgement.

Each adapter event is one NDJSON record: its JSON text and the newline that
ends it are reserved and written together under a single deadline. A record
abandoned after its first byte makes the stream terminal, so a truncated line
is never followed by another event. One record may carry a whole two MiB sync
message plus a 64 KiB envelope allowance, which is how a near-maximum Convex
value reaches the controller while the count and byte budgets still keep the
process far below the shared 128 MiB limit.

Every network wait is an absolute deadline rather than a per-syscall timer, so
a peer that trickles bytes cannot extend it. One deadline covers a whole Live
bring-up — name lookup, connect, TLS, the 101 upgrade, and the first Connect
frame — and `close` cancels it instead of waiting it out, which is why control
commands stay bounded against a silent peer. Name lookups cannot be
interrupted, so they run on their own thread; the caller leaves with its own
copy of the addresses, and a lookup it has stopped waiting for owns and frees
everything it produced from process-lifetime memory rather than from the
caller's allocator, which it may outlive.

Once connected, every complete incoming WebSocket message has one absolute
five-second deadline. Progress cannot restart that clock, but a healthy hosted
deployment still has enough time to publish the initial transition.

The Live profile is the unversioned `convex-rs` 0.10.4 sync shape at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It is a protocol experiment, not
an official compatibility promise.

## Limitations

Live authentication, optimistic updates, WebSocket mutations/actions, and
`TransitionChunk` assembly remain deferred. The language-local fixtures cover
fragmented UTF-8 data, interleaved control frames, non-minimal frame lengths,
malformed Close frames, partial-frame deadlines, a stalled name lookup, a
silent upgrade peer, a peer that drains part of a frame and then stops,
structured recovery, five reconnects, stale-generation barriers, bounded close,
an abandoned partial record, near-maximum values, and stopped-reader memory.
Rejected HTTP replies — oversized chunked bodies, success-shaped bodies behind
a failing status, malformed JSON, and failures without an `errorMessage` — are
protocol failures the client recovers from, never invented function errors.
Only the JSON-safe subset is decoded. The shared
evaluator recorded clean local and hosted evidence (31/31 on both profiles)
from this reviewed head, and the manifest records the http and live award.
