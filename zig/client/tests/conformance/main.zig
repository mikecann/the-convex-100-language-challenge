//! Test-only NDJSON adapter. It calls the native Zig client for every HTTP
//! and Live operation and keeps stdout reserved for protocol events.

const std = @import("std");
const convex = @import("convex");

const max_command_bytes = 2 * 1024 * 1024;

const Adapter = struct {
    allocator: std.mem.Allocator,
    client: *convex.Client,
    output: convex.Output,

    fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter, writer_fd: ?std.posix.fd_t, fd_kind: convex.Output.FdKind) !Adapter {
        const url = std.process.getEnvVarOwned(allocator, "CONVEX_URL") catch return error.MissingConvexUrl;
        defer allocator.free(url);
        return .{
            .allocator = allocator,
            .client = try convex.Client.init(allocator, url),
            .output = convex.Output.init(allocator, writer, writer_fd, fd_kind),
        };
    }

    fn deinit(self: *Adapter) void {
        self.client.deinit();
        self.output.deinit();
    }

    fn emit(self: *Adapter, object: std.json.ObjectMap) !void {
        var mutable_object = object;
        try self.output.send(self.allocator, .{ .object = mutable_object });
        mutable_object.deinit();
    }

    fn emitError(self: *Adapter, id: ?[]const u8, name: []const u8, message: []const u8, data: ?convex.JsonValue) !void {
        var error_object = std.json.ObjectMap.init(self.allocator);
        try error_object.put("name", .{ .string = name });
        try error_object.put("message", .{ .string = message });
        try error_object.put("data", data orelse .null);
        var object = std.json.ObjectMap.init(self.allocator);
        try object.put("type", .{ .string = "error" });
        if (id) |request_id| try object.put("id", .{ .string = request_id });
        try object.put("error", .{ .object = error_object });
        self.output.send(self.allocator, .{ .object = object }) catch |err| {
            error_object.deinit();
            object.deinit();
            return err;
        };
        error_object.deinit();
        object.deinit();
    }

    fn handle(self: *Adapter, line: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(convex.JsonValue, arena.allocator(), line, .{}) catch {
            try self.emitError(null, "ProtocolError", "malformed adapter command", null);
            return true;
        };
        const command = parsed.value.object;
        const op = command.get("op") orelse {
            try self.emitError(null, "ProtocolError", "adapter command is missing op", null);
            return true;
        };
        const id = command.get("id");
        const request_id: ?[]const u8 = if (id) |value| value.string else null;

        if (std.mem.eql(u8, op.string, "hello")) {
            const protocol_version: i64 = if (command.get("protocolVersion")) |version| version.integer else 0;
            if (protocol_version != 1) {
                try self.emitError(request_id, "ProtocolError", "unsupported adapter protocol version", null);
                return true;
            }
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("protocolVersion", .{ .integer = 1 });
            try object.put("id", .{ .string = request_id orelse "hello" });
            try object.put("type", .{ .string = "ready" });
            try object.put("language", .{ .string = "zig" });
            try object.put("implementation", .{ .string = "native-zig-std-http-websocket-0.1.0" });
            try object.put("runtime", .{ .string = "zig 0.14.1" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op.string, "close")) {
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id orelse "close" });
            try object.put("type", .{ .string = "closed" });
            try self.emit(object);
            return false;
        }

        if (std.mem.eql(u8, op.string, "setAuth")) {
            const token: []const u8 = if (command.get("token")) |token_value| token_value.string else "";
            self.client.setAuth(token) catch |err| {
                try self.emitError(request_id, "TransportError", @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id orelse "setAuth" });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op.string, "debugDisconnect")) {
            self.client.debugDisconnect() catch |err| {
                try self.emitError(request_id, "TransportError", @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id orelse "debugDisconnect" });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op.string, "unsubscribe")) {
            const subscription_id = (command.get("subscriptionId") orelse return error.InvalidCommand).string;
            self.client.unsubscribe(subscription_id) catch |err| {
                try self.emitError(request_id, "TransportError", @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id orelse "unsubscribe" });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op.string, "subscribe")) {
            const subscription_id = (command.get("subscriptionId") orelse return error.InvalidCommand).string;
            const path = (command.get("path") orelse return error.InvalidCommand).string;
            const args: convex.JsonValue = if (command.get("args")) |value| value else .{ .object = std.json.ObjectMap.init(arena.allocator()) };
            self.client.subscribe(subscription_id, path, args, &self.output) catch |err| {
                try self.emitError(request_id, "TransportError", @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id orelse "subscribe" });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op.string, "query") or
            std.mem.eql(u8, op.string, "mutation") or
            std.mem.eql(u8, op.string, "action"))
        {
            const path = (command.get("path") orelse return error.InvalidCommand).string;
            const args: convex.JsonValue = if (command.get("args")) |value| value else .{ .object = std.json.ObjectMap.init(arena.allocator()) };
            const result = self.client.call(arena.allocator(), op.string, path, args) catch |err| {
                try self.emitError(request_id, if (err == error.FunctionFailed) "FunctionError" else "TransportError", @errorName(err), null);
                return true;
            };
            if (result.function_error) |function_error| {
                try self.emitError(request_id, "FunctionError", function_error.message, function_error.data);
                return true;
            }
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id orelse op.string });
            try object.put("type", .{ .string = "result" });
            try object.put("value", result.value orelse return error.InvalidCommand);
            try object.put("logs", result.logs);
            try self.emit(object);
            return true;
        }

        try self.emitError(request_id, "ProtocolError", "unknown adapter operation", null);
        return true;
    }
};

fn run(reader: std.io.AnyReader, writer: std.io.AnyWriter, writer_fd: ?std.posix.fd_t, fd_kind: convex.Output.FdKind) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var adapter = try Adapter.init(allocator, writer, writer_fd, fd_kind);
    defer adapter.deinit();
    while (true) {
        const line = reader.readUntilDelimiterAlloc(allocator, '\n', max_command_bytes) catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };
        defer allocator.free(line);
        if (line.len == 0) continue;
        if (!try adapter.handle(std.mem.trimRight(u8, line, "\r"))) return;
    }
}

pub fn main() !void {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ADAPTER_LISTEN")) |address_text| {
        defer std.heap.page_allocator.free(address_text);
        const separator = std.mem.lastIndexOfScalar(u8, address_text, ':') orelse return error.InvalidCommand;
        const port = std.fmt.parseInt(u16, address_text[separator + 1 ..], 10) catch return error.InvalidCommand;
        const address = try std.net.Address.parseIp4(address_text[0..separator], port);
        var server = try std.net.Address.listen(address, .{ .reuse_address = true });
        defer server.deinit();
        const connection = try server.accept();
        defer connection.stream.close();
        return run(connection.stream.reader().any(), connection.stream.writer().any(), connection.stream.handle, .socket);
    } else |_| {
        return run(std.io.getStdIn().reader().any(), std.io.getStdOut().writer().any(), std.io.getStdOut().handle, .pipe);
    }
}
