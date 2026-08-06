//! Raw Convex sync fixture for the final-adapter stopped-reader probe.
//! It is test infrastructure only and never enters either runtime image.

const std = @import("std");

fn readExact(stream: std.net.Stream, bytes: []u8) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        const amount = try stream.read(bytes[used..]);
        if (amount == 0) return error.EndOfStream;
        used += amount;
    }
}

fn readHandshake(stream: std.net.Stream) !void {
    var tail: [4]u8 = .{ 0, 0, 0, 0 };
    var count: usize = 0;
    while (count < 8192) : (count += 1) {
        var byte: [1]u8 = undefined;
        try readExact(stream, &byte);
        tail[0] = tail[1];
        tail[1] = tail[2];
        tail[2] = tail[3];
        tail[3] = byte[0];
        if (std.mem.eql(u8, &tail, "\r\n\r\n")) return;
    }
    return error.ProtocolFailure;
}

fn readClientFrame(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);
    var length: u64 = header[1] & 0x7f;
    if (length == 126) {
        var encoded: [2]u8 = undefined;
        try readExact(stream, &encoded);
        length = std.mem.readInt(u16, &encoded, .big);
    } else if (length == 127) {
        var encoded: [8]u8 = undefined;
        try readExact(stream, &encoded);
        length = std.mem.readInt(u64, &encoded, .big);
    }
    var mask: [4]u8 = undefined;
    try readExact(stream, &mask);
    const payload = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(payload);
    try readExact(stream, payload);
    for (payload, 0..) |*byte, index| byte.* ^= mask[index % 4];
    return payload;
}

fn timestamp(value: u64) [12]u8 {
    var decoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &decoded, value, .little);
    var encoded: [12]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &decoded);
    return encoded;
}

fn writeFrame(stream: std.net.Stream, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    header[0] = 0x81;
    header[1] = 127;
    std.mem.writeInt(u64, header[2..10], payload.len, .big);
    try stream.writer().writeAll(&header);
    try stream.writer().writeAll(payload);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const address = try std.net.Address.parseIp4("0.0.0.0", 32101);
    var server = try std.net.Address.listen(address, .{ .reuse_address = true });
    defer server.deinit();
    const connection = try server.accept();
    defer connection.stream.close();
    try readHandshake(connection.stream);
    try connection.stream.writer().writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: test\r\n\r\n");
    const connect = try readClientFrame(allocator, connection.stream);
    defer allocator.free(connect);
    const add = try readClientFrame(allocator, connection.stream);
    defer allocator.free(add);

    const blob = try allocator.alloc(u8, 900 * 1024);
    defer allocator.free(blob);
    @memset(blob, 'x');
    var sequence: u32 = 0;
    while (sequence < 40) : (sequence += 1) {
        const encoded_start_timestamp = timestamp(sequence);
        const encoded_timestamp = timestamp(sequence + 1);
        const payload = try std.fmt.allocPrint(allocator, "{{\"type\":\"Transition\",\"startVersion\":{{\"querySet\":{d},\"identity\":0,\"ts\":\"{s}\"}},\"endVersion\":{{\"querySet\":1,\"identity\":0,\"ts\":\"{s}\"}},\"modifications\":[{{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{{\"sequence\":{d},\"blob\":\"{s}\"}},\"logLines\":[]}}]}}", .{ if (sequence == 0) @as(u32, 0) else @as(u32, 1), encoded_start_timestamp, encoded_timestamp, sequence, blob });
        defer allocator.free(payload);
        try writeFrame(connection.stream, payload);
    }
    var discard: [256]u8 = undefined;
    while (connection.stream.read(&discard) catch 0 > 0) {}
}
