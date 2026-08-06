const std = @import("std");
const convex = @import("convex");

fn wholeCounter(value: convex.JsonValue) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| if (std.math.isFinite(float) and @trunc(float) == float and float >= std.math.minInt(i64) and float <= std.math.maxInt(i64)) @intFromFloat(float) else error.InvalidResponse,
        else => blk: {
            break :blk error.InvalidResponse;
        },
    };
}

fn countOf(value: convex.JsonValue) !i64 {
    return wholeCounter(value.object.get("count") orelse return error.InvalidResponse);
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
    defer client.deinit();

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
    defer capture.deinit();
    var output = convex.Output.init(allocator, std.io.getStdErr().writer().any(), std.io.getStdErr().handle, .none);
    output.capture = &capture;
    defer output.deinit();
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
    const applied = mutation_value.object.get("applied") orelse return error.InvalidResponse;
    if (applied != .bool or !applied.bool) return error.InvalidResponse;
    const after = try countOf(mutation_value.object.get("state") orelse return error.InvalidResponse);
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
