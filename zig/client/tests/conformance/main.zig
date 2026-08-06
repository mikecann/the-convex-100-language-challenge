//! Test-only NDJSON adapter. It calls the native Zig client for every HTTP
//! and Live operation and keeps stdout reserved for protocol events.

const std = @import("std");
const convex = @import("convex");

const max_command_bytes = 2 * 1024 * 1024;

fn objectValue(value: convex.JsonValue) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidCommand,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidCommand;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidCommand,
    };
}

fn objectField(object: std.json.ObjectMap, name: []const u8) !convex.JsonValue {
    const value = object.get(name) orelse return error.InvalidCommand;
    if (value != .object) return error.InvalidCommand;
    return value;
}

fn validId(value: []const u8) bool {
    return value.len >= 1 and value.len <= 128;
}

fn onlyFields(object: std.json.ObjectMap, allowed: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn clientErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidResponse, error.ProtocolFailure, error.MessageTooBig => "ProtocolError",
        error.FunctionFailed => "FunctionError",
        else => "TransportError",
    };
}

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

    fn protocolError(self: *Adapter, id: ?[]const u8, message: []const u8) !bool {
        try self.emitError(id, "ProtocolError", message, null);
        return true;
    }

    fn handle(self: *Adapter, line: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(convex.JsonValue, arena.allocator(), line, .{}) catch {
            try self.emitError(null, "ProtocolError", "malformed adapter command", null);
            return true;
        };
        const command = objectValue(parsed.value) catch return self.protocolError(null, "adapter command must be an object");
        const request_id = stringField(command, "id") catch return self.protocolError(null, "adapter command id must be a string");
        if (!validId(request_id)) return self.protocolError(null, "adapter command id is out of range");
        const op = stringField(command, "op") catch return self.protocolError(request_id, "adapter command op must be a string");

        if (std.mem.eql(u8, op, "hello")) {
            const allowed = [_][]const u8{ "protocolVersion", "id", "op" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "hello contains unknown fields");
            const version = command.get("protocolVersion") orelse return self.protocolError(request_id, "hello is missing protocolVersion");
            const protocol_version: i64 = switch (version) {
                .integer => |integer| integer,
                else => return self.protocolError(request_id, "protocolVersion must be an integer"),
            };
            if (protocol_version != 1) {
                return self.protocolError(request_id, "unsupported adapter protocol version");
            }
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("protocolVersion", .{ .integer = 1 });
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "ready" });
            try object.put("language", .{ .string = "zig" });
            try object.put("implementation", .{ .string = "native-zig-std-http-websocket-0.1.0" });
            try object.put("runtime", .{ .string = "zig 0.14.1" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op, "close")) {
            const allowed = [_][]const u8{ "id", "op" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "close contains unknown fields");
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "closed" });
            try self.emit(object);
            return false;
        }

        if (std.mem.eql(u8, op, "setAuth")) {
            const allowed = [_][]const u8{ "id", "op", "token" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "setAuth contains unknown fields");
            const token = stringField(command, "token") catch return self.protocolError(request_id, "setAuth token must be a string");
            self.client.setAuth(token) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op, "debugDisconnect")) {
            const allowed = [_][]const u8{ "id", "op" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "debugDisconnect contains unknown fields");
            self.client.debugDisconnect() catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op, "unsubscribe")) {
            const allowed = [_][]const u8{ "id", "op", "subscriptionId" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "unsubscribe contains unknown fields");
            const subscription_id = stringField(command, "subscriptionId") catch return self.protocolError(request_id, "subscriptionId must be a string");
            if (!validId(subscription_id)) return self.protocolError(request_id, "subscriptionId is out of range");
            self.client.unsubscribe(subscription_id) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op, "subscribe")) {
            const allowed = [_][]const u8{ "id", "op", "subscriptionId", "path", "args" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "subscribe contains unknown fields");
            const subscription_id = stringField(command, "subscriptionId") catch return self.protocolError(request_id, "subscriptionId must be a string");
            if (!validId(subscription_id)) return self.protocolError(request_id, "subscriptionId is out of range");
            const path = stringField(command, "path") catch return self.protocolError(request_id, "subscribe path must be a string");
            if (path.len < 3) return self.protocolError(request_id, "subscribe path is too short");
            const args = objectField(command, "args") catch return self.protocolError(request_id, "subscribe args must be an object");
            self.client.subscribe(subscription_id, path, args, &self.output) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op, "query") or
            std.mem.eql(u8, op, "mutation") or
            std.mem.eql(u8, op, "action"))
        {
            const allowed = [_][]const u8{ "id", "op", "path", "args" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "call contains unknown fields");
            const path = stringField(command, "path") catch return self.protocolError(request_id, "call path must be a string");
            if (path.len < 3) return self.protocolError(request_id, "call path is too short");
            const args = objectField(command, "args") catch return self.protocolError(request_id, "call args must be an object");
            const result = self.client.call(arena.allocator(), op, path, args) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null);
                return true;
            };
            if (result.function_error) |function_error| {
                try self.emitError(request_id, "FunctionError", function_error.message, function_error.data);
                return true;
            }
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "result" });
            try object.put("value", result.value orelse return error.InvalidCommand);
            try object.put("logs", result.logs);
            try self.emit(object);
            return true;
        }

        return self.protocolError(request_id, "unknown adapter operation");
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

test "malformed controller commands stay structured and recoverable" {
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var adapter = Adapter{
        .allocator = std.testing.allocator,
        .client = try convex.Client.init(std.testing.allocator, "http://127.0.0.1:9"),
        .output = convex.Output.init(std.testing.allocator, bytes.writer().any(), null, .none),
    };
    defer adapter.deinit();
    const malformed = [_][]const u8{
        "[]",
        "{\"id\":\"x\",\"op\":1}",
        "{\"id\":1,\"op\":\"close\"}",
        "{\"id\":\"x\",\"op\":\"hello\",\"protocolVersion\":\"1\"}",
        "{\"id\":\"x\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":[]}",
        "{\"id\":\"x\",\"op\":\"subscribe\",\"subscriptionId\":1,\"path\":\"demo:state\",\"args\":{}}",
        "{\"id\":\"x\",\"op\":\"setAuth\",\"token\":1}",
        "{\"id\":\"x\",\"op\":\"close\",\"extra\":true}",
    };
    for (malformed) |line| try std.testing.expect(try adapter.handle(line));
    try std.testing.expect(!(try adapter.handle("{\"id\":\"close\",\"op\":\"close\"}")));
    var protocol_errors: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes.items, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"name\":\"ProtocolError\"") != null) protocol_errors += 1;
    }
    try std.testing.expectEqual(malformed.len, protocol_errors);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"close\",\"type\":\"closed\"") != null);
}

const MalformedHttpFixture = struct {
    listener: *std.net.Server,

    fn run(self: *MalformedHttpFixture) void {
        const connection = self.listener.accept() catch @panic("adapter HTTP fixture accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        var used: usize = 0;
        while (used < request.len) {
            const amount = connection.stream.read(request[used..]) catch @panic("adapter HTTP request read failed");
            if (amount == 0) @panic("adapter HTTP request ended early");
            used += amount;
            if (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") != null) break;
        }
        const body = "{\"status\":1,\"value\":{}}";
        connection.stream.writer().print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch @panic("adapter HTTP response failed");
    }
};

test "malformed HTTP peer data becomes a recoverable adapter ProtocolError" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try std.net.Address.listen(address, .{ .reuse_address = true });
    defer listener.deinit();
    var fixture = MalformedHttpFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, MalformedHttpFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var adapter = Adapter{
        .allocator = std.testing.allocator,
        .client = try convex.Client.init(std.testing.allocator, url),
        .output = convex.Output.init(std.testing.allocator, bytes.writer().any(), null, .none),
    };
    defer adapter.deinit();
    try std.testing.expect(try adapter.handle("{\"id\":\"bad-http\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}"));
    thread.join();
    try std.testing.expect(!(try adapter.handle("{\"id\":\"close\",\"op\":\"close\"}")));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"bad-http\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"name\":\"ProtocolError\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"close\",\"type\":\"closed\"") != null);
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
