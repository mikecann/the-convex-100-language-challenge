//! A small native Zig client for Convex's JSON HTTP API and the pinned
//! convex-rs 0.10.4 `/api/sync` Live profile.
//!
//! The client deliberately keeps the JSON-safe demonstration surface small.
//! Convex-specific request envelopes, sync versions, timestamp ordering, and
//! WebSocket frames are implemented here rather than delegated to another
//! Convex client or command-line tool.

const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const JsonValue = std.json.Value;

pub const Error = error{
    InvalidDeploymentUrl,
    InvalidFunctionPath,
    InvalidArguments,
    InvalidResponse,
    FunctionFailed,
    ProtocolFailure,
    TransportFailure,
    Closed,
    Timeout,
    MessageTooBig,
    WebSocketClosed,
};

pub const CallResult = struct {
    value: ?JsonValue = null,
    logs: JsonValue,
    function_error: ?FunctionError = null,
};

pub const FunctionError = struct {
    name: []const u8 = "FunctionError",
    message: []const u8,
    data: JsonValue,
    logs: JsonValue,
};

const max_http_body = 2 * 1024 * 1024;
const max_websocket_message = 2 * 1024 * 1024;
const max_live_subscriptions = 16;
const max_live_queue_bytes = 8 * 1024 * 1024;
const client_version = "zig-0.1.0";

pub const Client = struct {
    allocator: Allocator,
    deployment_url: []const u8,
    http: std.http.Client,
    auth_token: ?[]u8 = null,
    live: ?*LiveManager = null,
    closed: bool = false,

    pub fn init(allocator: Allocator, deployment_url: []const u8) !*Client {
        const uri = std.Uri.parse(deployment_url) catch return error.InvalidDeploymentUrl;
        if (uri.host == null or
            (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
                !std.ascii.eqlIgnoreCase(uri.scheme, "https")))
        {
            return error.InvalidDeploymentUrl;
        }

        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .deployment_url = try allocator.dupe(u8, deployment_url),
            .http = .{ .allocator = allocator },
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (!self.closed) self.close() catch {};
        if (self.auth_token) |token| self.allocator.free(token);
        self.http.deinit();
        self.allocator.free(self.deployment_url);
        self.allocator.destroy(self);
    }

    pub fn close(self: *Client) !void {
        if (self.closed) return;
        self.closed = true;
        if (self.live) |manager| {
            manager.stop();
            self.live = null;
            self.allocator.destroy(manager);
        }
    }

    pub fn setAuth(self: *Client, token: []const u8) !void {
        if (self.closed) return error.Closed;
        if (self.auth_token) |old| self.allocator.free(old);
        self.auth_token = if (token.len == 0) null else try self.allocator.dupe(u8, token);
    }

    pub fn call(self: *Client, allocator: Allocator, operation: []const u8, path: []const u8, args: JsonValue) !CallResult {
        if (self.closed) return error.Closed;
        if (path.len < 3) return error.InvalidFunctionPath;
        if (!std.mem.eql(u8, operation, "query") and
            !std.mem.eql(u8, operation, "mutation") and
            !std.mem.eql(u8, operation, "action"))
        {
            return error.InvalidResponse;
        }

        var request_value = JsonValue{ .object = blk: {
            var object = std.json.ObjectMap.init(allocator);
            try object.put("path", .{ .string = path });
            try object.put("args", args);
            try object.put("format", .{ .string = "json" });
            break :blk object;
        } };
        defer request_value.object.deinit();

        const payload = try std.json.stringifyAlloc(allocator, request_value, .{});
        defer allocator.free(payload);
        const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/{s}", .{ std.mem.trimRight(u8, self.deployment_url, "/"), operation });
        defer allocator.free(endpoint);

        var response_body = std.ArrayList(u8).init(allocator);
        defer response_body.deinit();
        var headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "convex-client", .value = client_version },
        };
        var privileged: [1]std.http.Header = undefined;
        var privileged_headers: []const std.http.Header = &.{};
        if (self.auth_token) |token| {
            const value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            privileged[0] = .{ .name = "authorization", .value = value };
            privileged_headers = &privileged;
            defer allocator.free(value);
        }
        const result = std.http.Client.fetch(&self.http, .{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = &headers,
            .privileged_headers = privileged_headers,
            .response_storage = .{ .dynamic = &response_body },
            .max_append_size = max_http_body,
        }) catch return error.TransportFailure;
        _ = result;

        const parsed = std.json.parseFromSlice(JsonValue, allocator, response_body.items, .{}) catch return error.InvalidResponse;
        const response = parsed.value;
        const status = response.object.get("status") orelse return error.InvalidResponse;
        if (!std.mem.eql(u8, status.string, "success") and !std.mem.eql(u8, status.string, "error")) return error.InvalidResponse;

        const logs: JsonValue = if (response.object.get("logLines")) |value| value else .{ .array = std.json.Array.init(allocator) };
        if (std.mem.eql(u8, status.string, "error")) {
            const message: []const u8 = if (response.object.get("errorMessage")) |value| value.string else "Convex function failed";
            return .{
                .logs = logs,
                .function_error = .{
                    .message = message,
                    .data = response.object.get("errorData") orelse .null,
                    .logs = logs,
                },
            };
        }
        const value = response.object.get("value") orelse return error.InvalidResponse;
        return .{ .value = value, .logs = logs };
    }

    pub fn subscribe(self: *Client, subscription_id: []const u8, path: []const u8, args: JsonValue, output: *Output) !void {
        if (self.closed) return error.Closed;
        if (self.live == null) {
            const manager = try self.allocator.create(LiveManager);
            manager.* = try LiveManager.init(self.allocator, self, output);
            self.live = manager;
        }
        try self.live.?.add(subscription_id, path, args);
    }

    pub fn unsubscribe(self: *Client, subscription_id: []const u8) !void {
        if (self.live) |manager| try manager.remove(subscription_id);
    }

    pub fn debugDisconnect(self: *Client) !void {
        if (self.live) |manager| try manager.debugDisconnect();
    }
};

pub const Output = struct {
    mutex: std.Thread.Mutex = .{},
    writer: std.io.AnyWriter,
    capture: ?*Capture = null,
    queued_bytes: usize = 0,

    pub fn send(self: *Output, allocator: Allocator, value: JsonValue) !void {
        const encoded = try std.json.stringifyAlloc(allocator, value, .{});
        defer allocator.free(encoded);
        if (encoded.len > 1024 * 1024) return error.MessageTooBig;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queued_bytes + encoded.len > max_live_queue_bytes) return error.MessageTooBig;
        self.queued_bytes += encoded.len;
        defer self.queued_bytes -= encoded.len;
        try self.writer.writeAll(encoded);
        try self.writer.writeByte('\n');
    }
};

/// A bounded in-process Live mailbox used by the canonical example. The
/// adapter leaves capture null and writes subscription events as NDJSON.
pub const Capture = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    values: std.ArrayList([]u8),
    bytes: usize = 0,

    pub fn init(allocator: Allocator) Capture {
        return .{ .allocator = allocator, .values = std.ArrayList([]u8).init(allocator) };
    }

    pub fn deinit(self: *Capture) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.deinit();
    }

    fn record(self: *Capture, value: JsonValue) !void {
        const encoded = try std.json.stringifyAlloc(self.allocator, value, .{});
        if (encoded.len > 1024 * 1024) {
            self.allocator.free(encoded);
            return error.MessageTooBig;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.values.items.len >= 16 or self.bytes + encoded.len > max_live_queue_bytes) {
            const oldest = self.values.orderedRemove(0);
            self.bytes -= oldest.len;
            self.allocator.free(oldest);
        }
        try self.values.append(encoded);
        self.bytes += encoded.len;
        self.condition.signal();
    }

    pub fn next(self: *Capture, allocator: Allocator, timeout_ns: u64) !JsonValue {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
        while (self.values.items.len == 0) {
            const remaining = deadline - std.time.nanoTimestamp();
            if (remaining <= 0) return error.Timeout;
            self.condition.timedWait(&self.mutex, @intCast(remaining)) catch return error.Timeout;
        }
        const encoded = self.values.orderedRemove(0);
        self.bytes -= encoded.len;
        defer self.allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(JsonValue, allocator, encoded, .{});
        return parsed.value;
    }
};

const ActiveQuery = struct {
    id: u32,
    subscription_id: []u8,
    path: []u8,
    args: []u8,
    last_value: ?[]u8 = null,
    last_success: bool = false,
    awaiting_rehydration: bool = false,

    fn deinit(self: *ActiveQuery, allocator: Allocator) void {
        allocator.free(self.subscription_id);
        allocator.free(self.path);
        allocator.free(self.args);
        if (self.last_value) |value| allocator.free(value);
    }
};

const Command = struct {
    kind: enum { add, remove, disconnect, stop },
    subscription_id: []const u8 = "",
    path: []const u8 = "",
    args: []const u8 = "",
    done: bool = false,
    result: ?anyerror = null,
};

const LiveManager = struct {
    allocator: Allocator,
    client: *Client,
    output: *Output,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    commands: std.ArrayList(*Command),
    active: std.ArrayList(ActiveQuery),
    thread: ?std.Thread = null,
    stopping: bool = false,

    fn init(allocator: Allocator, client: *Client, output: *Output) !LiveManager {
        return .{
            .allocator = allocator,
            .client = client,
            .output = output,
            .commands = std.ArrayList(*Command).init(allocator),
            .active = std.ArrayList(ActiveQuery).init(allocator),
        };
    }

    fn start(self: *LiveManager) !void {
        if (self.thread == null) self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn submit(self: *LiveManager, command: *Command) !void {
        try self.start();
        self.mutex.lock();
        try self.commands.append(command);
        self.condition.signal();
        while (!command.done) self.condition.wait(&self.mutex);
        const result = command.result;
        self.mutex.unlock();
        if (result) |err| return err;
    }

    fn add(self: *LiveManager, subscription_id: []const u8, path: []const u8, args: JsonValue) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const args_json = try std.json.stringifyAlloc(arena.allocator(), args, .{});
        var command = Command{ .kind = .add, .subscription_id = subscription_id, .path = path, .args = args_json };
        try self.submit(&command);
    }

    fn remove(self: *LiveManager, subscription_id: []const u8) !void {
        var command = Command{ .kind = .remove, .subscription_id = subscription_id };
        try self.submit(&command);
    }

    fn debugDisconnect(self: *LiveManager) !void {
        var command = Command{ .kind = .disconnect };
        try self.submit(&command);
    }

    fn stop(self: *LiveManager) void {
        if (self.thread) |_| {
            var command = Command{ .kind = .stop };
            self.submit(&command) catch {};
            self.thread.?.join();
            self.thread = null;
        }
        for (self.active.items) |*query| query.deinit(self.allocator);
        self.active.deinit();
        self.commands.deinit();
    }

    fn run(self: *LiveManager) void {
        var owner = LiveOwner.init(self);
        defer owner.deinit();
        while (true) {
            owner.serviceCommands() catch |err| owner.failPending(err);
            if (self.stopping) break;
            owner.readOne() catch |err| {
                if (owner.socket != null) owner.closeConnection(@errorName(err));
                std.time.sleep(10 * std.time.ns_per_ms);
            };
        }
    }

    fn failPending(self: *LiveManager, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.commands.items) |command| {
            if (!command.done) {
                command.result = err;
                command.done = true;
            }
        }
        self.condition.broadcast();
    }
};

const LiveOwner = struct {
    manager: *LiveManager,
    socket: ?*std.http.Client.Connection = null,
    query_set_version: u32 = 0,
    remote_query_set_version: u32 = 0,
    next_query_id: u32 = 0,
    connection_count: u32 = 0,
    last_close_reason: []const u8 = "InitialConnect",
    max_timestamp: ?[8]u8 = null,
    generation: u64 = 0,

    fn init(manager: *LiveManager) LiveOwner {
        return .{ .manager = manager };
    }

    fn deinit(self: *LiveOwner) void {
        self.closeConnection("closed");
        for (self.manager.active.items) |*query| query.deinit(self.manager.allocator);
        self.manager.active.clearRetainingCapacity();
    }

    fn serviceCommands(self: *LiveOwner) !void {
        while (true) {
            self.manager.mutex.lock();
            if (self.manager.commands.items.len == 0) {
                self.manager.mutex.unlock();
                return;
            }
            const command = self.manager.commands.orderedRemove(0);
            self.manager.mutex.unlock();
            const result: ?anyerror = blk: {
                self.handleCommand(command) catch |err| break :blk err;
                break :blk null;
            };
            self.manager.mutex.lock();
            command.result = result;
            command.done = true;
            self.manager.condition.broadcast();
            self.manager.mutex.unlock();
            if (command.kind == .stop) return;
        }
    }

    fn handleCommand(self: *LiveOwner, command: *Command) anyerror!void {
        switch (command.kind) {
            .add => {
                if (self.manager.active.items.len >= max_live_subscriptions) return error.MessageTooBig;
                const args = try self.manager.allocator.dupe(u8, command.args);
                errdefer self.manager.allocator.free(args);
                const query = ActiveQuery{
                    .id = self.next_query_id,
                    .subscription_id = try self.manager.allocator.dupe(u8, command.subscription_id),
                    .path = try self.manager.allocator.dupe(u8, command.path),
                    .args = args,
                };
                self.next_query_id += 1;
                try self.manager.active.append(query);
                errdefer _ = self.manager.active.pop();
                try self.ensureConnected();
                try self.sendModify(.{query.id}, true);
            },
            .remove => {
                for (self.manager.active.items, 0..) |*query, index| {
                    if (std.mem.eql(u8, query.subscription_id, command.subscription_id)) {
                        const id = query.id;
                        query.deinit(self.manager.allocator);
                        _ = self.manager.active.orderedRemove(index);
                        if (self.socket != null) try self.sendModify(.{id}, false);
                        break;
                    }
                }
            },
            .disconnect => {
                if (self.socket == null) return error.WebSocketClosed;
                self.closeConnection("DebugDisconnect");
                try self.ensureConnected();
            },
            .stop => {
                self.manager.stopping = true;
                self.closeConnection("closed");
            },
        }
        return;
    }

    fn ensureConnected(self: *LiveOwner) !void {
        if (self.socket != null) return;
        const uri_text = try std.fmt.allocPrint(self.manager.allocator, "{s}/api/sync", .{std.mem.trimRight(u8, self.manager.client.deployment_url, "/")});
        defer self.manager.allocator.free(uri_text);
        const uri = std.Uri.parse(uri_text) catch return error.InvalidDeploymentUrl;
        const protocol: std.http.Client.Connection.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "wss") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) .tls else .plain;
        const host = uri.host orelse return error.InvalidDeploymentUrl;
        const host_raw = try host.toRawMaybeAlloc(self.manager.allocator);
        defer self.manager.allocator.free(host_raw);
        const port: u16 = uri.port orelse if (protocol == .tls) @as(u16, 443) else @as(u16, 80);
        const conn = try self.manager.client.http.connectTcp(host_raw, port, protocol);
        errdefer self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
        const path = try uri.path.toRawMaybeAlloc(self.manager.allocator);
        try websocketHandshake(self.manager.allocator, conn, host_raw, port, path);
        self.socket = conn;
        self.generation += 1;
        self.connection_count += 1;
        self.query_set_version = 0;
        self.remote_query_set_version = 0;
        try self.sendConnect();
        for (self.manager.active.items) |*query| {
            query.awaiting_rehydration = query.last_success;
            try self.sendModify(.{query.id}, true);
        }
    }

    fn sendConnect(self: *LiveOwner) !void {
        var object = std.json.ObjectMap.init(self.manager.allocator);
        defer object.deinit();
        try object.put("type", .{ .string = "Connect" });
        try object.put("sessionId", .{ .string = "zig-session" });
        try object.put("connectionCount", .{ .integer = self.connection_count - 1 });
        try object.put("lastCloseReason", .{ .string = self.last_close_reason });
        try object.put("clientTs", .{ .integer = 0 });
        if (self.max_timestamp) |timestamp| {
            var encoded: [12]u8 = undefined;
            const text = std.base64.standard.Encoder.encode(&encoded, &timestamp);
            try object.put("maxObservedTimestamp", .{ .string = text });
        }
        try self.sendJson(.{ .object = object });
    }

    fn sendModify(self: *LiveOwner, ids: [1]u32, add: bool) !void {
        var modifications = std.json.Array.init(self.manager.allocator);
        defer modifications.deinit();
        const query = for (self.manager.active.items) |*candidate| {
            if (candidate.id == ids[0]) break candidate;
        } else null;
        var modification = std.json.ObjectMap.init(self.manager.allocator);
        try modification.put("type", .{ .string = if (add) "Add" else "Remove" });
        try modification.put("queryId", .{ .integer = ids[0] });
        if (add) {
            const selected = query orelse return error.InvalidResponse;
            try modification.put("udfPath", .{ .string = selected.path });
            var args = std.json.Array.init(self.manager.allocator);
            const parsed = std.json.parseFromSlice(JsonValue, self.manager.allocator, selected.args, .{}) catch return error.InvalidArguments;
            try args.append(parsed.value);
            try modification.put("args", .{ .array = args });
        }
        try modifications.append(.{ .object = modification });
        var message = std.json.ObjectMap.init(self.manager.allocator);
        try message.put("type", .{ .string = "ModifyQuerySet" });
        try message.put("baseVersion", .{ .integer = self.query_set_version });
        try message.put("newVersion", .{ .integer = self.query_set_version + 1 });
        try message.put("modifications", .{ .array = modifications });
        try self.sendJson(.{ .object = message });
        self.query_set_version += 1;
    }

    fn sendJson(self: *LiveOwner, value: JsonValue) !void {
        const encoded = try std.json.stringifyAlloc(self.manager.allocator, value, .{});
        defer self.manager.allocator.free(encoded);
        try writeWebSocket(self.socket orelse return error.WebSocketClosed, encoded, self.manager.allocator, .text);
    }

    fn readOne(self: *LiveOwner) !void {
        if (self.socket == null) {
            if (self.manager.active.items.len == 0) {
                self.manager.mutex.lock();
                self.manager.condition.timedWait(&self.manager.mutex, 100 * std.time.ns_per_ms) catch {};
                self.manager.mutex.unlock();
                return;
            }
            try self.ensureConnected();
            return;
        }
        const message = try readWebSocket(self.socket.?, self.manager.allocator);
        defer self.manager.allocator.free(message);
        var parsed = std.json.parseFromSlice(JsonValue, self.manager.allocator, message, .{}) catch return error.ProtocolFailure;
        defer parsed.deinit();
        const object = parsed.value.object;
        const kind = (object.get("type") orelse return error.ProtocolFailure).string;
        if (std.mem.eql(u8, kind, "Ping")) {
            try writeWebSocket(self.socket.?, "", self.manager.allocator, .pong);
            return;
        }
        if (!std.mem.eql(u8, kind, "Transition")) return error.ProtocolFailure;
        try self.handleTransition(object);
    }

    fn handleTransition(self: *LiveOwner, object: std.json.ObjectMap) !void {
        const start = (object.get("startVersion") orelse return error.ProtocolFailure).object;
        const end = (object.get("endVersion") orelse return error.ProtocolFailure).object;
        const start_query_set = (start.get("querySet") orelse return error.ProtocolFailure).integer;
        if (start_query_set != self.remote_query_set_version) return error.ProtocolFailure;
        const end_query_set = (end.get("querySet") orelse return error.ProtocolFailure).integer;
        const timestamp_text = (end.get("ts") orelse return error.ProtocolFailure).string;
        const timestamp = decodeTimestamp(timestamp_text) catch return error.ProtocolFailure;
        self.remote_query_set_version = @intCast(end_query_set);
        if (self.max_timestamp == null or compareTimestamp(timestamp, self.max_timestamp.?) > 0) self.max_timestamp = timestamp;
        const modifications = (object.get("modifications") orelse return error.ProtocolFailure).array;
        for (modifications.items) |modification_value| {
            const modification = modification_value.object;
            const id: u32 = @intCast((modification.get("queryId") orelse return error.ProtocolFailure).integer);
            const query = for (self.manager.active.items) |*candidate| {
                if (candidate.id == id) break candidate;
            } else continue;
            const modification_type = (modification.get("type") orelse return error.ProtocolFailure).string;
            if (std.mem.eql(u8, modification_type, "QueryUpdated")) {
                const value = modification.get("value") orelse return error.ProtocolFailure;
                const encoded = try std.json.stringifyAlloc(self.manager.allocator, value, .{});
                defer self.manager.allocator.free(encoded);
                if (query.awaiting_rehydration and query.last_success and query.last_value != null and std.mem.eql(u8, encoded, query.last_value.?)) {
                    query.awaiting_rehydration = false;
                    continue;
                }
                query.awaiting_rehydration = false;
                if (query.last_value) |old| self.manager.allocator.free(old);
                query.last_value = try self.manager.allocator.dupe(u8, encoded);
                query.last_success = true;
                try self.emitSubscription(query, value, null);
            } else if (std.mem.eql(u8, modification_type, "QueryFailed")) {
                query.awaiting_rehydration = false;
                query.last_success = false;
                const error_value: JsonValue = .{ .object = blk: {
                    var error_object = std.json.ObjectMap.init(self.manager.allocator);
                    try error_object.put("name", .{ .string = "FunctionError" });
                    try error_object.put("message", modification.get("errorMessage") orelse .{ .string = "query failed" });
                    try error_object.put("data", modification.get("errorData") orelse .null);
                    break :blk error_object;
                } };
                try self.emitSubscription(query, null, error_value);
            } else if (!std.mem.eql(u8, modification_type, "QueryRemoved")) return error.ProtocolFailure;
        }
    }

    fn emitSubscription(self: *LiveOwner, query: *ActiveQuery, value: ?JsonValue, error_value: ?JsonValue) !void {
        if (self.manager.output.capture) |capture| {
            if (value) |live_value| {
                try capture.record(live_value);
            } else if (error_value) |live_error| {
                try capture.record(live_error);
            }
            return;
        }
        var object = std.json.ObjectMap.init(self.manager.allocator);
        try object.put("type", .{ .string = "subscription" });
        try object.put("subscriptionId", .{ .string = query.subscription_id });
        if (value) |v| try object.put("value", v);
        if (error_value) |e| try object.put("error", e);
        try self.manager.output.send(self.manager.allocator, .{ .object = object });
        object.deinit();
    }

    fn closeConnection(self: *LiveOwner, reason: []const u8) void {
        if (self.socket) |conn| {
            conn.closing = true;
            self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
            self.socket = null;
            self.connection_count += 1;
        }
        self.last_close_reason = reason;
        self.query_set_version = 0;
        self.remote_query_set_version = 0;
    }
};

fn decodeTimestamp(value: []const u8) ![8]u8 {
    var decoded: [8]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, value) catch return error.ProtocolFailure;
    return decoded;
}

fn compareTimestamp(left: [8]u8, right: [8]u8) i8 {
    var index: usize = 8;
    while (index > 0) {
        index -= 1;
        if (left[index] > right[index]) return 1;
        if (left[index] < right[index]) return -1;
    }
    return 0;
}

fn websocketHandshake(allocator: Allocator, conn: *std.http.Client.Connection, host: []const u8, port: u16, path: []const u8) !void {
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &random);
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();
    try request.writer().print("GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nConvex-Client: {s}\r\n\r\n", .{ if (path.len == 0) "/api/sync" else path, host, port, key, client_version });
    try conn.writer().writeAll(request.items);
    try conn.flush();
    var response: [8192]u8 = undefined;
    var used: usize = 0;
    while (used + 1 < response.len) {
        _ = try conn.read(response[used .. used + 1]);
        used += 1;
        if (used >= 4 and std.mem.eql(u8, response[used - 4 .. used], "\r\n\r\n")) break;
    }
    if (!std.mem.startsWith(u8, response[0..used], "HTTP/1.1 101")) return error.TransportFailure;
}

fn writeWebSocket(conn: *std.http.Client.Connection, payload: []const u8, allocator: Allocator, opcode: enum { text, continuation, pong }) !void {
    if (payload.len > max_websocket_message) return error.MessageTooBig;
    var header: [14]u8 = undefined;
    header[0] = switch (opcode) {
        .text => 0x81,
        .continuation => 0x80,
        .pong => 0x8a,
    };
    var header_len: usize = 2;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len | 0x80);
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 126 | 0x80;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127 | 0x80;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    @memcpy(header[header_len..][0..4], &mask);
    header_len += 4;
    var masked = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked);
    for (payload, 0..) |byte, index| masked[index] = byte ^ mask[index % 4];
    try conn.writer().writeAll(header[0..header_len]);
    try conn.writer().writeAll(masked);
    try conn.flush();
}

fn readWebSocket(conn: *std.http.Client.Connection, allocator: Allocator) ![]u8 {
    var header: [2]u8 = undefined;
    try readExact(conn, &header);
    const fin = header[0] & 0x80 != 0;
    const opcode = header[0] & 0x0f;
    if (!fin or opcode == 0) return error.ProtocolFailure;
    if (opcode == 8) return error.WebSocketClosed;
    const masked = header[1] & 0x80 != 0;
    if (masked) return error.ProtocolFailure;
    var length: u64 = header[1] & 0x7f;
    if (length == 126) {
        var bytes: [2]u8 = undefined;
        try readExact(conn, &bytes);
        length = std.mem.readInt(u16, &bytes, .big);
    } else if (length == 127) {
        var bytes: [8]u8 = undefined;
        try readExact(conn, &bytes);
        length = std.mem.readInt(u64, &bytes, .big);
    }
    if (length > max_websocket_message) return error.MessageTooBig;
    const payload = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(payload);
    try readExact(conn, payload);
    if (opcode == 9) {
        try writeWebSocket(conn, payload, allocator, .pong);
        allocator.free(payload);
        return readWebSocket(conn, allocator);
    }
    if (opcode != 1) return error.ProtocolFailure;
    return payload;
}

fn readExact(conn: *std.http.Client.Connection, buffer: []u8) !void {
    var used: usize = 0;
    while (used < buffer.len) {
        const amount = try conn.read(buffer[used..]);
        if (amount == 0) return error.WebSocketClosed;
        used += amount;
    }
}

fn deinitValue(value: *JsonValue, allocator: Allocator) void {
    switch (value.*) {
        .object => |*object| object.deinit(),
        .array => |*array| array.deinit(),
        else => {},
    }
    _ = allocator;
}

test "timestamps compare as little-endian uint64 values" {
    try std.testing.expectEqual(@as(i8, 1), compareTimestamp(.{ 0, 1, 0, 0, 0, 0, 0, 0 }, .{ 255, 0, 0, 0, 0, 0, 0, 0 }));
}

test "whole JSON numbers accept decimal integral values" {
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "1.0", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), parsed.value.float);
}
