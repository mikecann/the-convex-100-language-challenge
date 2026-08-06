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

/// The shared schema bounds `id` and `subscriptionId` at one to 128
/// characters, and JSON Schema measures a string in Unicode scalar values
/// rather than bytes. Counting bytes would reject a legal multi-byte id and
/// accept one that is too long, so the count is by code point and invalid
/// UTF-8 is a protocol violation rather than a length answer.
fn scalarLength(value: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(value) catch error.InvalidCommand;
}

fn validId(value: []const u8) bool {
    const length = scalarLength(value) catch return false;
    return length >= 1 and length <= 128;
}

/// The schema's optional `path` and `args` are legal on both `subscribe` and
/// `unsubscribe`. Accept them wherever the schema allows them, but hold them
/// to the declared types instead of ignoring them.
fn optionalPath(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("path") orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidCommand,
    };
}

fn optionalArgs(object: std.json.ObjectMap) !?convex.JsonValue {
    const value = object.get("args") orelse return null;
    if (value != .object) return error.InvalidCommand;
    return value;
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
        defer mutable_object.deinit();
        try self.output.send(self.allocator, .{ .object = mutable_object });
    }

    fn emitError(self: *Adapter, id: ?[]const u8, name: []const u8, message: []const u8, data: ?convex.JsonValue, logs: ?convex.JsonValue) !void {
        var error_object = std.json.ObjectMap.init(self.allocator);
        try error_object.put("name", .{ .string = name });
        try error_object.put("message", .{ .string = message });
        if (data) |error_data| try error_object.put("data", error_data);
        var object = std.json.ObjectMap.init(self.allocator);
        try object.put("type", .{ .string = "error" });
        if (id) |request_id| try object.put("id", .{ .string = request_id });
        try object.put("error", .{ .object = error_object });
        if (logs) |log_lines| try object.put("logs", log_lines);
        self.output.send(self.allocator, .{ .object = object }) catch |err| {
            error_object.deinit();
            object.deinit();
            return err;
        };
        error_object.deinit();
        object.deinit();
    }

    fn protocolError(self: *Adapter, id: ?[]const u8, message: []const u8) !bool {
        try self.emitError(id, "ProtocolError", message, null, null);
        return true;
    }

    fn handle(self: *Adapter, line: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(convex.JsonValue, arena.allocator(), line, .{}) catch {
            try self.emitError(null, "ProtocolError", "malformed adapter command", null, null);
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
            try self.client.close();
            self.output.finishLive();
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "closed" });
            self.emit(object) catch |err| {
                // A record abandoned part way through left the controller's
                // last NDJSON line truncated. Appending `closed` to that line
                // would corrupt it, so the stream stays terminal and the
                // abandonment is reported on stderr instead.
                if (err != error.StreamTerminal) return err;
                std.debug.print("adapter output abandoned a partial record; closing without a closed event\n", .{});
            };
            return false;
        }

        if (std.mem.eql(u8, op, "setAuth")) {
            const allowed = [_][]const u8{ "id", "op", "token" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "setAuth contains unknown fields");
            const token = stringField(command, "token") catch return self.protocolError(request_id, "setAuth token must be a string");
            self.client.setAuth(token) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null, null);
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
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null, null);
                return true;
            };
            var object = std.json.ObjectMap.init(self.allocator);
            try object.put("id", .{ .string = request_id });
            try object.put("type", .{ .string = "ack" });
            try self.emit(object);
            return true;
        }

        if (std.mem.eql(u8, op, "unsubscribe")) {
            // The schema shares one definition with `subscribe`, so a
            // controller may repeat the path and args it subscribed with.
            // Validate them and then unsubscribe by ID as usual.
            const allowed = [_][]const u8{ "id", "op", "subscriptionId", "path", "args" };
            if (!onlyFields(command, &allowed)) return self.protocolError(request_id, "unsubscribe contains unknown fields");
            const subscription_id = stringField(command, "subscriptionId") catch return self.protocolError(request_id, "subscriptionId must be a string");
            if (!validId(subscription_id)) return self.protocolError(request_id, "subscriptionId is out of range");
            _ = optionalPath(command) catch return self.protocolError(request_id, "unsubscribe path must be a string");
            _ = optionalArgs(command) catch return self.protocolError(request_id, "unsubscribe args must be an object");
            self.client.unsubscribe(subscription_id) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null, null);
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
            // The schema leaves both optional, but this client cannot open a
            // subscription without them, so their absence is reported as the
            // protocol problem it is rather than guessed at.
            const path = (optionalPath(command) catch return self.protocolError(request_id, "subscribe path must be a string")) orelse
                return self.protocolError(request_id, "subscribe is missing path");
            const args = (optionalArgs(command) catch return self.protocolError(request_id, "subscribe args must be an object")) orelse
                return self.protocolError(request_id, "subscribe is missing args");
            self.client.subscribe(subscription_id, path, args, &self.output) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null, null);
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
            const path_length = scalarLength(path) catch return self.protocolError(request_id, "call path is not valid UTF-8");
            if (path_length < 3) return self.protocolError(request_id, "call path is too short");
            const args = objectField(command, "args") catch return self.protocolError(request_id, "call args must be an object");
            const result = self.client.call(arena.allocator(), op, path, args) catch |err| {
                try self.emitError(request_id, clientErrorName(err), @errorName(err), null, null);
                return true;
            };
            if (result.function_error) |function_error| {
                try self.emitError(request_id, "FunctionError", function_error.message, function_error.data, function_error.logs);
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
        if (std.mem.indexOf(u8, line, "\"name\":\"ProtocolError\"") != null) {
            protocol_errors += 1;
            try std.testing.expect(std.mem.indexOf(u8, line, "\"data\"") == null);
            try std.testing.expect(std.mem.indexOf(u8, line, "\"logs\"") == null);
        }
    }
    try std.testing.expectEqual(malformed.len, protocol_errors);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"close\",\"type\":\"closed\"") != null);
}

test "adapter identifiers and optional fields follow the shared schema" {
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var adapter = Adapter{
        .allocator = std.testing.allocator,
        .client = try convex.Client.init(std.testing.allocator, "http://127.0.0.1:9"),
        .output = convex.Output.init(std.testing.allocator, bytes.writer().any(), null, .none),
    };
    defer adapter.deinit();

    // The schema's 128-character bound is 128 Unicode scalar values, not 128
    // bytes: this id is 384 bytes long and entirely legal.
    const long_id = "€" ** 128;
    try std.testing.expect(try adapter.handle("{\"protocolVersion\":1,\"id\":\"" ++ long_id ++ "\",\"op\":\"hello\"}"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"" ++ long_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"type\":\"ready\"") != null);

    // One scalar value past the bound, and an id that is not valid UTF-8 at
    // all, are both protocol violations rather than length questions.
    const over_long_id = "€" ** 129;
    const rejected = [_][]const u8{
        "{\"protocolVersion\":1,\"id\":\"" ++ over_long_id ++ "\",\"op\":\"hello\"}",
        "{\"protocolVersion\":1,\"id\":\"\xff\xfe\",\"op\":\"hello\"}",
        // `path` and `args` are optional on unsubscribe, but they still have
        // declared types.
        "{\"id\":\"u1\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s\",\"path\":1}",
        "{\"id\":\"u2\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s\",\"args\":[]}",
        // Subscribing needs both, so their absence is reported plainly.
        "{\"id\":\"s1\",\"op\":\"subscribe\",\"subscriptionId\":\"s\"}",
        "{\"id\":\"s2\",\"op\":\"subscribe\",\"subscriptionId\":\"s\",\"path\":\"demo:state\"}",
    };
    const before = bytes.items.len;
    for (rejected) |line| try std.testing.expect(try adapter.handle(line));
    var protocol_errors: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes.items[before..], '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"name\":\"ProtocolError\"") != null) protocol_errors += 1;
    }
    try std.testing.expectEqual(rejected.len, protocol_errors);

    // A controller may repeat the path and args it subscribed with; the schema
    // allows it, so the adapter accepts and validates them.
    const accepted = bytes.items.len;
    try std.testing.expect(try adapter.handle("{\"id\":\"u3\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s\",\"path\":\"demo:state\",\"args\":{\"room\":\"r\"}}"));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items[accepted..], "\"id\":\"u3\",\"type\":\"ack\"") != null);
    try std.testing.expect(!(try adapter.handle("{\"id\":\"close\",\"op\":\"close\"}")));
}

/// Long enough that no healthy client misses it, short enough that a stranded
/// fixture reports a failure instead of hanging the run: a fixture thread
/// blocked in `accept` can never be joined, so an unrelated assertion failure
/// would hang the whole test binary rather than report itself.
const fixture_accept_timeout_ms = 15_000;

fn acceptWithin(listener: *std.net.Server, timeout_ms: i32) !std.net.Server.Connection {
    var poll_fds = [_]std.posix.pollfd{.{ .fd = listener.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&poll_fds, timeout_ms) == 0) return error.Timeout;
    return listener.accept();
}

/// Read one whole request, including the body its `Content-Length` declares.
/// Draining the body is not politeness: replying and closing while the
/// client's body is still queued makes the kernel answer with RST, which
/// discards the reply the client has not read yet and turns a deliberate
/// protocol fixture into a random transport failure.
fn readHttpRequest(stream: std.net.Stream, buffer: []u8) !void {
    var used: usize = 0;
    var header_end: ?usize = null;
    while (header_end == null) {
        if (used == buffer.len) return error.MessageTooBig;
        const amount = try stream.read(buffer[used..]);
        if (amount == 0) return error.EndOfStream;
        used += amount;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |end| header_end = end + 4;
    }
    var remaining: usize = 0;
    var lines = std.mem.splitSequence(u8, buffer[0..header_end.?], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..separator], " \t"), "content-length")) continue;
        remaining = try std.fmt.parseInt(usize, std.mem.trim(u8, line[separator + 1 ..], " \t"), 10);
        break;
    }
    remaining -= @min(remaining, used - header_end.?);
    var discard: [4096]u8 = undefined;
    while (remaining > 0) {
        const amount = try stream.read(discard[0..@min(discard.len, remaining)]);
        if (amount == 0) return error.EndOfStream;
        remaining -= amount;
    }
}

const MalformedHttpFixture = struct {
    listener: *std.net.Server,

    fn run(self: *MalformedHttpFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("adapter HTTP fixture accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        readHttpRequest(connection.stream, &request) catch @panic("adapter HTTP request read failed");
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
    // Joined by defer so a failing assertion below reports itself instead of
    // abandoning a live thread that still points at this stack frame.
    defer thread.join();
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
    try std.testing.expect(!(try adapter.handle("{\"id\":\"close\",\"op\":\"close\"}")));
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"bad-http\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"name\":\"ProtocolError\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"id\":\"close\",\"type\":\"closed\"") != null);
}

const FunctionErrorFixture = struct {
    listener: *std.net.Server,

    fn run(self: *FunctionErrorFixture) void {
        const replies = [_][]const u8{
            "{\"status\":\"error\",\"errorMessage\":\"no data\",\"logLines\":[\"before failure\"]}",
            "{\"status\":\"error\",\"errorMessage\":\"explicit null\",\"errorData\":null,\"logLines\":[]}",
        };
        for (replies) |body| {
            const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("FunctionError fixture accept failed");
            defer connection.stream.close();
            var request: [8192]u8 = undefined;
            readHttpRequest(connection.stream, &request) catch @panic("FunctionError request read failed");
            connection.stream.writer().print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch @panic("FunctionError response failed");
        }
    }
};

fn adapterEventById(allocator: std.mem.Allocator, bytes: []const u8, id: []const u8) !convex.JsonValue {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(convex.JsonValue, allocator, line, .{});
        const object = try objectValue(parsed.value);
        const event_id = object.get("id") orelse continue;
        if (event_id == .string and std.mem.eql(u8, event_id.string, id)) return parsed.value;
    }
    return error.InvalidCommand;
}

test "FunctionError serialization omits absent data and preserves logs" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var listener = try std.net.Address.listen(address, .{ .reuse_address = true });
    defer listener.deinit();
    var fixture = FunctionErrorFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, FunctionErrorFixture.run, .{&fixture});
    defer thread.join();
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
    try std.testing.expect(try adapter.handle("{\"id\":\"absent\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}"));
    try std.testing.expect(try adapter.handle("{\"id\":\"null\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}"));
    try std.testing.expect(!(try adapter.handle("{\"id\":\"close\",\"op\":\"close\"}")));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const absent = try objectValue(try adapterEventById(arena.allocator(), bytes.items, "absent"));
    const absent_error = try objectValue(absent.get("error") orelse return error.InvalidCommand);
    try std.testing.expect(absent_error.get("data") == null);
    const logs = switch (absent.get("logs") orelse return error.InvalidCommand) {
        .array => |array| array,
        else => return error.InvalidCommand,
    };
    try std.testing.expectEqual(@as(usize, 1), logs.items.len);
    try std.testing.expectEqualStrings("before failure", logs.items[0].string);
    const explicit_null = try objectValue(try adapterEventById(arena.allocator(), bytes.items, "null"));
    const explicit_error = try objectValue(explicit_null.get("error") orelse return error.InvalidCommand);
    try std.testing.expect(explicit_error.get("data") != null and explicit_error.get("data").? == .null);
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
