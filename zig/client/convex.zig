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
const max_live_queue_events = 16;
const max_adapter_event_bytes = 1024 * 1024;
const socket_poll_ms = 50;
const frame_deadline_ms = 250;
const handshake_deadline_ms = 2000;
const output_deadline_ms = 250;
const socket_send_buffer_bytes: c_int = 64 * 1024;
const client_version = "zig-0.1.0";

fn protocolObject(value: JsonValue) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ProtocolFailure,
    };
}

fn protocolArray(value: JsonValue) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.ProtocolFailure,
    };
}

fn protocolString(value: JsonValue) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.ProtocolFailure,
    };
}

fn protocolU32(value: JsonValue) !u32 {
    return switch (value) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u32)) @intCast(integer) else error.ProtocolFailure,
        else => error.ProtocolFailure,
    };
}

fn validateProtocolLogLines(value: JsonValue) !void {
    const lines = try protocolArray(value);
    for (lines.items) |line| _ = try protocolString(line);
}

fn httpObject(value: JsonValue) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidResponse,
    };
}

fn httpString(value: JsonValue) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidResponse,
    };
}

fn validateHttpLogLines(value: JsonValue) !void {
    const lines = switch (value) {
        .array => |array| array,
        else => return error.InvalidResponse,
    };
    for (lines.items) |line| _ = try httpString(line);
}

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
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "convex-client", .value = client_version },
        };
        var request_headers = std.http.Client.Request.Headers{
            .authorization = .omit,
            // Hosted edges may negotiate compression by default. Convex's
            // JSON bodies are small enough that deterministic identity bytes
            // are preferable, while std.http still decodes an unexpected
            // supported Content-Encoding response correctly.
            .accept_encoding = .{ .override = "identity" },
            .content_type = .{ .override = "application/json" },
        };
        var authorization: ?[]u8 = null;
        defer if (authorization) |value| allocator.free(value);
        if (self.auth_token) |token| {
            authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            // Zig 0.14.1 stores privileged_headers but Request.send never
            // writes them. The standard override is emitted, and keeping
            // redirects unhandled below prevents forwarding this credential.
            request_headers.authorization = .{ .override = authorization.? };
        }
        const result = std.http.Client.fetch(&self.http, .{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = payload,
            .redirect_behavior = .unhandled,
            .headers = request_headers,
            .extra_headers = &headers,
            .response_storage = .{ .dynamic = &response_body },
            .max_append_size = max_http_body,
        }) catch return error.TransportFailure;
        if (result.status != .ok) return error.InvalidResponse;

        const parsed = std.json.parseFromSlice(JsonValue, allocator, response_body.items, .{}) catch return error.InvalidResponse;
        const response = try httpObject(parsed.value);
        const status = try httpString(response.get("status") orelse return error.InvalidResponse);
        if (!std.mem.eql(u8, status, "success") and !std.mem.eql(u8, status, "error")) return error.InvalidResponse;

        const logs: JsonValue = if (response.get("logLines")) |value| blk: {
            try validateHttpLogLines(value);
            break :blk value;
        } else .{ .array = std.json.Array.init(allocator) };
        if (std.mem.eql(u8, status, "error")) {
            const message: []const u8 = if (response.get("errorMessage")) |value| try httpString(value) else "Convex function failed";
            return .{
                .logs = logs,
                .function_error = .{
                    .message = message,
                    .data = response.get("errorData") orelse .null,
                    .logs = logs,
                },
            };
        }
        const value = response.get("value") orelse return error.InvalidResponse;
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
    pub const FdKind = enum { none, pipe, socket };
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    write_mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    writer: std.io.AnyWriter,
    /// The adapter gives us its stdout or controller socket.  Keeping this
    /// descriptor nonblocking means a stopped controller never stalls the
    /// sole Live owner while it is trying to report a subscription update.
    fd: ?std.posix.fd_t = null,
    fd_kind: FdKind = .none,
    capture: ?*Capture = null,
    reserved_bytes: usize = 0,
    reserved_count: usize = 0,
    queue: std.ArrayList(QueuedEvent),
    worker: ?std.Thread = null,
    stopping: bool = false,
    next_generation: u64 = 1,
    test_pause_after_dequeue: ?*DeliveryPause = null,

    const QueuedEvent = struct {
        subscription_id: []u8,
        token: *DeliveryToken,
        encoded: []u8,
    };

    pub const DeliveryToken = struct {
        generation: u64,
        valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

        fn retain(self: *DeliveryToken) void {
            _ = self.references.fetchAdd(1, .monotonic);
        }

        fn release(self: *DeliveryToken, allocator: Allocator) void {
            if (self.references.fetchSub(1, .acq_rel) == 1) allocator.destroy(self);
        }
    };

    pub fn init(allocator: Allocator, writer: std.io.AnyWriter, fd: ?std.posix.fd_t, fd_kind: FdKind) Output {
        // A blocking stdout pipe is safe for ordinary command responses but
        // not for Live.  The worker below polls before each bounded write.
        if (fd_kind == .pipe) {
            if (fd) |descriptor| {
                const flags = std.posix.fcntl(descriptor, std.posix.F.GETFL, 0) catch 0;
                var open_flags: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
                open_flags.NONBLOCK = true;
                _ = std.posix.fcntl(descriptor, std.posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(open_flags))))) catch {};
            }
        }
        return .{
            .allocator = allocator,
            .writer = writer,
            .fd = fd,
            .fd_kind = fd_kind,
            .queue = std.ArrayList(QueuedEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Output) void {
        self.mutex.lock();
        self.stopping = true;
        self.condition.broadcast();
        self.mutex.unlock();
        if (self.worker) |thread| thread.join();
        for (self.queue.items) |event| self.completeEvent(event);
        self.queue.deinit();
    }

    pub fn newDeliveryToken(self: *Output) !*DeliveryToken {
        self.mutex.lock();
        defer self.mutex.unlock();
        const token = try self.allocator.create(DeliveryToken);
        token.* = .{ .generation = self.next_generation };
        self.next_generation +%= 1;
        return token;
    }

    pub fn revokeDeliveryToken(self: *Output, token: *DeliveryToken) void {
        token.valid.store(false, .release);
        token.release(self.allocator);
    }

    pub fn send(self: *Output, allocator: Allocator, value: JsonValue) !void {
        const encoded = try std.json.stringifyAlloc(allocator, value, .{});
        defer allocator.free(encoded);
        if (encoded.len > max_adapter_event_bytes) return error.MessageTooBig;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.writeEncodedUnlocked(encoded);
    }

    /// Queue a Live event instead of letting the socket owner write into an
    /// arbitrary pipe.  The queue deliberately drops the oldest update when
    /// the controller is stopped: it retains the newest state, stays below
    /// both its 16-event and 8 MiB budgets, and never lets memory grow with a
    /// peer that has stopped reading.
    pub fn enqueueSubscription(self: *Output, subscription_id: []const u8, token: *DeliveryToken, value: JsonValue) !void {
        const encoded = try std.json.stringifyAlloc(self.allocator, value, .{});
        errdefer self.allocator.free(encoded);
        if (encoded.len > max_adapter_event_bytes) return error.MessageTooBig;
        token.retain();
        errdefer token.release(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.reserved_count >= max_live_queue_events or self.reserved_bytes + encoded.len > max_live_queue_bytes) {
            if (self.queue.items.len == 0) return error.MessageTooBig;
            const oldest = self.queue.orderedRemove(0);
            self.completeEventLocked(oldest);
        }
        try self.startLocked();
        try self.queue.append(.{
            .subscription_id = try self.allocator.dupe(u8, subscription_id),
            .token = token,
            .encoded = encoded,
        });
        self.reserved_count += 1;
        self.reserved_bytes += encoded.len;
        self.condition.signal();
    }

    /// The worker dequeues under the queue mutex, then rechecks the delivery
    /// token only after it owns the output lock.  Revocation can therefore
    /// invalidate an in-flight event without waiting for a paused relay, while
    /// the output lock still gives events and acknowledgements a total order.
    fn startLocked(self: *Output) !void {
        if (self.worker == null) self.worker = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Output) void {
        while (true) {
            self.mutex.lock();
            while (self.queue.items.len == 0 and !self.stopping) self.condition.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const event = self.queue.orderedRemove(0);
            self.mutex.unlock();

            if (self.test_pause_after_dequeue) |pause| pause.waitAfterDequeue(event.token.generation);
            self.write_mutex.lock();
            if (event.token.valid.load(.acquire)) self.writeLiveEventUnlocked(event) catch {};
            self.write_mutex.unlock();
            self.completeEvent(event);
        }
    }

    /// A Live event is one NDJSON record. Before its first byte reaches the
    /// controller, generation revocation may drop it. After a partial write we
    /// must retain the offset and finish the record; starting another event at
    /// that point would permanently corrupt the controller's NDJSON stream.
    fn writeLiveEventUnlocked(self: *Output, event: QueuedEvent) !void {
        if (self.fd) |descriptor| {
            var committed = false;
            try self.writeLivePart(descriptor, event.encoded, event.token, &committed);
            try self.writeLivePart(descriptor, "\n", event.token, &committed);
            return;
        }
        try self.writer.writeAll(event.encoded);
        try self.writer.writeByte('\n');
    }

    fn writeLivePart(self: *Output, descriptor: std.posix.fd_t, bytes: []const u8, token: *DeliveryToken, committed: *bool) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            self.mutex.lock();
            const stopping = self.stopping;
            self.mutex.unlock();
            if (stopping) return error.Closed;
            if (!committed.* and !token.valid.load(.acquire)) return error.Revoked;

            var poll_fds = [_]std.posix.pollfd{.{
                .fd = descriptor,
                .events = std.posix.POLL.OUT,
                .revents = 0,
            }};
            if (try std.posix.poll(&poll_fds, socket_poll_ms) == 0) continue;
            const amount = (if (self.fd_kind == .socket)
                std.posix.send(descriptor, bytes[written..], std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL)
            else
                std.posix.write(descriptor, bytes[written..])) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (amount == 0) return error.Closed;
            committed.* = true;
            written += amount;
        }
    }

    fn writeEncodedUnlocked(self: *Output, encoded: []const u8) !void {
        if (self.fd) |descriptor| {
            try writeFdWithDeadline(descriptor, encoded, output_deadline_ms, self.fd_kind);
            try writeFdWithDeadline(descriptor, "\n", output_deadline_ms, self.fd_kind);
            return;
        }
        try self.writer.writeAll(encoded);
        try self.writer.writeByte('\n');
    }

    fn completeEvent(self: *Output, event: QueuedEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.completeEventLocked(event);
        self.condition.broadcast();
    }

    fn completeEventLocked(self: *Output, event: QueuedEvent) void {
        self.reserved_count -= 1;
        self.reserved_bytes -= event.encoded.len;
        self.allocator.free(event.subscription_id);
        self.allocator.free(event.encoded);
        event.token.release(self.allocator);
    }
};

const DeliveryPause = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    armed: bool = true,
    dequeued: bool = false,
    release: bool = false,
    generation: u64 = 0,

    fn waitAfterDequeue(self: *DeliveryPause, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.armed) return;
        self.armed = false;
        self.dequeued = true;
        self.generation = generation;
        self.condition.broadcast();
        while (!self.release) self.condition.wait(&self.mutex);
    }

    fn waitUntilDequeued(self: *DeliveryPause, timeout_ns: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
        while (!self.dequeued) {
            const remaining = deadline - std.time.nanoTimestamp();
            if (remaining <= 0) return error.Timeout;
            self.condition.timedWait(&self.mutex, @intCast(remaining)) catch return error.Timeout;
        }
    }

    fn releaseWriter(self: *DeliveryPause) void {
        self.mutex.lock();
        self.release = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

fn waitForOutputIdle(output: *Output, timeout_ns: u64) !void {
    output.mutex.lock();
    defer output.mutex.unlock();
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
    while (output.reserved_count != 0) {
        const remaining = deadline - std.time.nanoTimestamp();
        if (remaining <= 0) return error.Timeout;
        output.condition.timedWait(&output.mutex, @intCast(remaining)) catch return error.Timeout;
    }
}

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
    delivery_token: *Output.DeliveryToken,

    fn deinit(self: *ActiveQuery, allocator: Allocator) void {
        allocator.free(self.subscription_id);
        allocator.free(self.path);
        allocator.free(self.args);
        if (self.last_value) |value| allocator.free(value);
    }
};

fn writeFdWithDeadline(fd: std.posix.fd_t, bytes: []const u8, timeout_ms: u64, fd_kind: Output.FdKind) !void {
    var written: usize = 0;
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (written < bytes.len) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const polled = try std.posix.poll(&poll_fds, @intCast(@min(remaining, socket_poll_ms)));
        if (polled == 0) continue;
        const amount = (if (fd_kind == .socket)
            std.posix.send(fd, bytes[written..], std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL)
        else
            std.posix.write(fd, bytes[written..])) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (amount == 0) return error.Closed;
        written += amount;
    }
}

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
        self.commands.append(command) catch |err| {
            self.mutex.unlock();
            return err;
        };
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
                if (!owner.failure_published) {
                    owner.publishOwnerError(err);
                    owner.failure_published = true;
                }
                owner.closeConnection(@errorName(err));
                std.time.sleep(owner.retry_delay_ms * std.time.ns_per_ms);
                owner.retry_delay_ms = @min(owner.retry_delay_ms * 2, 1000);
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
    retry_delay_ms: u64 = 10,
    failure_published: bool = false,

    fn init(manager: *LiveManager) LiveOwner {
        return .{ .manager = manager };
    }

    fn deinit(self: *LiveOwner) void {
        self.closeConnection("closed");
        for (self.manager.active.items) |*query| {
            self.manager.output.revokeDeliveryToken(query.delivery_token);
            query.deinit(self.manager.allocator);
        }
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
                // A subscription ID names one adapter relay.  Retire a prior
                // relay before publishing the replacement acknowledgement so
                // queued updates for the old query cannot leak across it.
                if (self.findActive(command.subscription_id)) |index| {
                    try self.retireActive(index);
                } else if (self.manager.active.items.len >= max_live_subscriptions) {
                    return error.MessageTooBig;
                }
                if (self.next_query_id == std.math.maxInt(u32)) return error.MessageTooBig;
                const args = try self.manager.allocator.dupe(u8, command.args);
                errdefer self.manager.allocator.free(args);
                const query = ActiveQuery{
                    .id = self.next_query_id,
                    .subscription_id = try self.manager.allocator.dupe(u8, command.subscription_id),
                    .path = try self.manager.allocator.dupe(u8, command.path),
                    .args = args,
                    .delivery_token = try self.manager.output.newDeliveryToken(),
                };
                errdefer self.manager.output.revokeDeliveryToken(query.delivery_token);
                self.next_query_id += 1;
                try self.manager.active.append(query);
                errdefer _ = self.manager.active.pop();
                // Connection establishment belongs to the owner loop, not the
                // controller acknowledgement. Existing-socket writes have a
                // hard deadline; on failure the whole connection is abandoned
                // and the next loop replays every active Add.
                if (self.socket != null) {
                    self.sendModify(.{query.id}, true) catch |err| self.closeConnection(@errorName(err));
                }
            },
            .remove => {
                if (self.findActive(command.subscription_id)) |index| try self.retireActive(index);
            },
            .disconnect => {
                if (self.socket == null) return error.WebSocketClosed;
                self.closeConnection("DebugDisconnect");
                // The command has retired the old socket.  The owner loop
                // schedules the reconnect immediately after this ack instead
                // of keeping the controller blocked in a handshake.
            },
            .stop => {
                self.manager.stopping = true;
                self.closeConnection("closed");
            },
        }
        return;
    }

    fn findActive(self: *LiveOwner, subscription_id: []const u8) ?usize {
        for (self.manager.active.items, 0..) |*query, index| {
            if (std.mem.eql(u8, query.subscription_id, subscription_id)) return index;
        }
        return null;
    }

    fn retireActive(self: *LiveOwner, index: usize) !void {
        const query = &self.manager.active.items[index];
        const id = query.id;
        self.manager.output.revokeDeliveryToken(query.delivery_token);
        query.deinit(self.manager.allocator);
        _ = self.manager.active.orderedRemove(index);
        if (self.socket != null) self.sendModify(.{id}, false) catch |err| self.closeConnection(@errorName(err));
    }

    fn ensureConnected(self: *LiveOwner) !void {
        if (self.socket != null) return;
        const uri_text = try std.fmt.allocPrint(self.manager.allocator, "{s}/api/sync", .{std.mem.trimRight(u8, self.manager.client.deployment_url, "/")});
        defer self.manager.allocator.free(uri_text);
        const uri = std.Uri.parse(uri_text) catch return error.InvalidDeploymentUrl;
        const protocol: std.http.Client.Connection.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "wss") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) .tls else .plain;
        const host = uri.host orelse return error.InvalidDeploymentUrl;
        // Uri components borrow their original bytes unless percent-decoding
        // is needed, so they must use an arena rather than unconditional free.
        var uri_arena = std.heap.ArenaAllocator.init(self.manager.allocator);
        defer uri_arena.deinit();
        const host_raw = try host.toRawMaybeAlloc(uri_arena.allocator());
        const port: u16 = uri.port orelse if (protocol == .tls) @as(u16, 443) else @as(u16, 80);
        if (protocol == .tls and @atomicLoad(bool, &self.manager.client.http.next_https_rescan_certs, .acquire)) {
            // connectTcp is lower level than std.http.Client.request and does
            // not populate the CA bundle itself. Live owns this direct TLS
            // connection, so perform the same one-time guarded rescan first.
            self.manager.client.http.ca_bundle_mutex.lock();
            defer self.manager.client.http.ca_bundle_mutex.unlock();
            if (self.manager.client.http.next_https_rescan_certs) {
                self.manager.client.http.ca_bundle.rescan(self.manager.allocator) catch return error.TransportFailure;
                @atomicStore(bool, &self.manager.client.http.next_https_rescan_certs, false, .release);
            }
        }
        const conn = try self.manager.client.http.connectTcp(host_raw, port, protocol);
        errdefer {
            // Once self.socket points at conn, a later send failure still
            // belongs to this setup scope. Clear the owner reference before
            // releasing so the outer recovery path cannot release it twice.
            if (self.socket == conn) self.socket = null;
            conn.closing = true;
            self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
        }
        try configureSocketDeadlines(conn);
        const path = try uri.path.toRawMaybeAlloc(uri_arena.allocator());
        try websocketHandshake(self.manager.allocator, conn, host_raw, port, path);
        self.retry_delay_ms = 10;
        self.socket = conn;
        self.generation += 1;
        self.query_set_version = 0;
        self.remote_query_set_version = 0;
        try self.sendConnect();
        if (self.connection_count < std.math.maxInt(u32)) self.connection_count += 1;
        for (self.manager.active.items) |*query| {
            query.awaiting_rehydration = query.last_success;
            try self.sendModify(.{query.id}, true);
        }
    }

    fn sendConnect(self: *LiveOwner) !void {
        const session_id = newSessionId();
        var object = std.json.ObjectMap.init(self.manager.allocator);
        defer object.deinit();
        try object.put("type", .{ .string = "Connect" });
        try object.put("sessionId", .{ .string = &session_id });
        try object.put("connectionCount", .{ .integer = self.connection_count });
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
        if (self.query_set_version == std.math.maxInt(u32)) return error.ProtocolFailure;
        const query = for (self.manager.active.items) |*candidate| {
            if (candidate.id == ids[0]) break candidate;
        } else null;
        const encoded: []u8 = if (add) blk: {
            const selected = query orelse return error.InvalidResponse;
            const quoted_path = try std.json.stringifyAlloc(self.manager.allocator, selected.path, .{});
            defer self.manager.allocator.free(quoted_path);
            break :blk try std.fmt.allocPrint(self.manager.allocator, "{{\"type\":\"ModifyQuerySet\",\"baseVersion\":{d},\"newVersion\":{d},\"modifications\":[{{\"type\":\"Add\",\"queryId\":{d},\"udfPath\":{s},\"args\":[{s}]}}]}}", .{ self.query_set_version, self.query_set_version + 1, ids[0], quoted_path, selected.args });
        } else try std.fmt.allocPrint(self.manager.allocator, "{{\"type\":\"ModifyQuerySet\",\"baseVersion\":{d},\"newVersion\":{d},\"modifications\":[{{\"type\":\"Remove\",\"queryId\":{d}}}]}}", .{ self.query_set_version, self.query_set_version + 1, ids[0] });
        defer self.manager.allocator.free(encoded);
        try writeWebSocket(self.socket orelse return error.WebSocketClosed, encoded, self.manager.allocator, .text);
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
        // Do not enter a blocking frame read for an idle peer.  This short
        // poll gives commands a deterministic chance to interrupt close,
        // unsubscribe, and debugDisconnect even when the server says nothing.
        if (!try socketReadable(self.socket.?, socket_poll_ms)) return;
        const message = try readWebSocket(self.socket.?, self.manager.allocator);
        defer self.manager.allocator.free(message);
        var parsed = std.json.parseFromSlice(JsonValue, self.manager.allocator, message, .{}) catch return error.ProtocolFailure;
        defer parsed.deinit();
        const object = try protocolObject(parsed.value);
        const kind = try protocolString(object.get("type") orelse return error.ProtocolFailure);
        if (std.mem.eql(u8, kind, "Ping")) {
            try writeWebSocket(self.socket.?, "", self.manager.allocator, .pong);
            return;
        }
        if (!std.mem.eql(u8, kind, "Transition")) return error.ProtocolFailure;
        try self.handleTransition(object);
    }

    fn handleTransition(self: *LiveOwner, object: std.json.ObjectMap) !void {
        const start = try protocolObject(object.get("startVersion") orelse return error.ProtocolFailure);
        const end = try protocolObject(object.get("endVersion") orelse return error.ProtocolFailure);
        const start_query_set = try protocolU32(start.get("querySet") orelse return error.ProtocolFailure);
        if (start_query_set != self.remote_query_set_version) return error.ProtocolFailure;
        const end_query_set = try protocolU32(end.get("querySet") orelse return error.ProtocolFailure);
        if (end_query_set < start_query_set) return error.ProtocolFailure;
        _ = try protocolU32(start.get("identity") orelse return error.ProtocolFailure);
        _ = try protocolU32(end.get("identity") orelse return error.ProtocolFailure);
        _ = try decodeTimestamp(try protocolString(start.get("ts") orelse return error.ProtocolFailure));
        const timestamp_text = try protocolString(end.get("ts") orelse return error.ProtocolFailure);
        const timestamp = decodeTimestamp(timestamp_text) catch return error.ProtocolFailure;
        const modifications = try protocolArray(object.get("modifications") orelse return error.ProtocolFailure);

        // Validate the entire server transition before changing any owner
        // state. A malformed later modification must not partially apply the
        // earlier ones or advance the query-set barrier.
        for (modifications.items) |modification_value| {
            const modification = try protocolObject(modification_value);
            _ = try protocolU32(modification.get("queryId") orelse return error.ProtocolFailure);
            const modification_type = try protocolString(modification.get("type") orelse return error.ProtocolFailure);
            if (std.mem.eql(u8, modification_type, "QueryUpdated")) {
                _ = modification.get("value") orelse return error.ProtocolFailure;
                if (modification.get("logLines")) |logs| try validateProtocolLogLines(logs);
            } else if (std.mem.eql(u8, modification_type, "QueryFailed")) {
                if (modification.get("errorMessage")) |message| _ = try protocolString(message);
            } else if (!std.mem.eql(u8, modification_type, "QueryRemoved")) return error.ProtocolFailure;
        }

        self.remote_query_set_version = end_query_set;
        self.retry_delay_ms = 10;
        self.failure_published = false;
        if (self.max_timestamp == null or compareTimestamp(timestamp, self.max_timestamp.?) > 0) self.max_timestamp = timestamp;
        for (modifications.items) |modification_value| {
            const modification = try protocolObject(modification_value);
            const id = try protocolU32(modification.get("queryId") orelse return error.ProtocolFailure);
            const query = for (self.manager.active.items) |*candidate| {
                if (candidate.id == id) break candidate;
            } else continue;
            const modification_type = try protocolString(modification.get("type") orelse return error.ProtocolFailure);
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
                var error_value: JsonValue = .{ .object = blk: {
                    var error_object = std.json.ObjectMap.init(self.manager.allocator);
                    try error_object.put("name", .{ .string = "FunctionError" });
                    try error_object.put("message", .{ .string = if (modification.get("errorMessage")) |message| try protocolString(message) else "query failed" });
                    try error_object.put("data", modification.get("errorData") orelse .null);
                    break :blk error_object;
                } };
                defer deinitValue(&error_value, self.manager.allocator);
                try self.emitSubscription(query, null, error_value);
            } else if (!std.mem.eql(u8, modification_type, "QueryRemoved")) return error.ProtocolFailure;
        }
    }

    fn publishOwnerError(self: *LiveOwner, err: anyerror) void {
        if (self.manager.active.items.len == 0) return;
        const name = switch (err) {
            error.ProtocolFailure, error.InvalidResponse, error.MessageTooBig => "ProtocolError",
            else => "TransportError",
        };
        for (self.manager.active.items) |*query| {
            var error_value: JsonValue = .{ .object = blk: {
                var object = std.json.ObjectMap.init(self.manager.allocator);
                object.put("name", .{ .string = name }) catch continue;
                object.put("message", .{ .string = @errorName(err) }) catch {
                    object.deinit();
                    continue;
                };
                break :blk object;
            } };
            defer deinitValue(&error_value, self.manager.allocator);
            self.emitSubscription(query, null, error_value) catch {};
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
        try self.manager.output.enqueueSubscription(query.subscription_id, query.delivery_token, .{ .object = object });
        object.deinit();
    }

    fn closeConnection(self: *LiveOwner, reason: []const u8) void {
        if (self.socket) |conn| {
            conn.closing = true;
            self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
            self.socket = null;
        }
        self.last_close_reason = reason;
        self.query_set_version = 0;
        self.remote_query_set_version = 0;
    }
};

fn decodeTimestamp(value: []const u8) ![8]u8 {
    if (value.len != 12) return error.ProtocolFailure;
    var decoded: [8]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, value) catch return error.ProtocolFailure;
    return decoded;
}

fn newSessionId() [36]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var result: [36]u8 = undefined;
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < bytes.len) : (input_index += 1) {
        if (input_index == 4 or input_index == 6 or input_index == 8 or input_index == 10) {
            result[output_index] = '-';
            output_index += 1;
        }
        result[output_index] = hex[bytes[input_index] >> 4];
        result[output_index + 1] = hex[bytes[input_index] & 0x0f];
        output_index += 2;
    }
    return result;
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

fn configureSocketDeadlines(conn: *std.http.Client.Connection) !void {
    const timeout = std.posix.timeval{
        .sec = 0,
        .usec = output_deadline_ms * 1000,
    };
    try std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&socket_send_buffer_bytes));
}

fn websocketAccept(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    var encoded: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    return encoded;
}

fn headerHasToken(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), expected)) return true;
    }
    return false;
}

fn validateWebSocketResponse(response: []const u8, expected_accept: []const u8) !void {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    const status_line = lines.next() orelse return error.TransportFailure;
    var status_parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    if (!std.mem.eql(u8, status_parts.next() orelse return error.TransportFailure, "HTTP/1.1")) return error.TransportFailure;
    if (!std.mem.eql(u8, status_parts.next() orelse return error.TransportFailure, "101")) return error.TransportFailure;

    var upgrade = false;
    var connection = false;
    var accept = false;
    var accept_seen = false;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse return error.TransportFailure;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
            upgrade = upgrade or headerHasToken(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            connection = connection or headerHasToken(value, "upgrade");
        } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) {
            if (accept_seen) return error.TransportFailure;
            accept_seen = true;
            accept = std.mem.eql(u8, value, expected_accept);
        }
    }
    if (!upgrade or !connection or !accept) return error.TransportFailure;
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
    const deadline = std.time.milliTimestamp() + handshake_deadline_ms;
    while (used + 1 < response.len) {
        try readExactUntil(conn, response[used .. used + 1], deadline);
        used += 1;
        if (used >= 4 and std.mem.eql(u8, response[used - 4 .. used], "\r\n\r\n")) break;
    }
    if (used < 4 or !std.mem.eql(u8, response[used - 4 .. used], "\r\n\r\n")) return error.TransportFailure;
    const expected_accept = websocketAccept(&key);
    try validateWebSocketResponse(response[0..used], &expected_accept);
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

fn socketReadable(conn: *std.http.Client.Connection, timeout_ms: u64) !bool {
    if (conn.peek().len > 0) return true;
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = conn.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return try std.posix.poll(&poll_fds, @intCast(timeout_ms)) > 0;
}

fn readWebSocket(conn: *std.http.Client.Connection, allocator: Allocator) ![]u8 {
    const deadline = std.time.milliTimestamp() + frame_deadline_ms;
    var fragments = std.ArrayList(u8).init(allocator);
    errdefer fragments.deinit();
    var awaiting_continuation = false;

    while (true) {
        var header: [2]u8 = undefined;
        try readExactUntil(conn, &header, deadline);
        const fin = header[0] & 0x80 != 0;
        const opcode = header[0] & 0x0f;
        const masked = header[1] & 0x80 != 0;
        if (masked) return error.ProtocolFailure;
        var length: u64 = header[1] & 0x7f;
        if (length == 126) {
            var bytes: [2]u8 = undefined;
            try readExactUntil(conn, &bytes, deadline);
            length = std.mem.readInt(u16, &bytes, .big);
        } else if (length == 127) {
            var bytes: [8]u8 = undefined;
            try readExactUntil(conn, &bytes, deadline);
            length = std.mem.readInt(u64, &bytes, .big);
        }
        if (length > max_websocket_message or fragments.items.len + length > max_websocket_message) return error.MessageTooBig;
        const payload = try allocator.alloc(u8, @intCast(length));
        defer allocator.free(payload);
        try readExactUntil(conn, payload, deadline);

        // WebSocket control frames may appear in the middle of a fragmented
        // UTF-8 message.  They are complete frames by definition and must not
        // reset the data-frame parser.
        if (opcode == 8) return error.WebSocketClosed;
        if (opcode == 9) {
            if (!fin or payload.len > 125) return error.ProtocolFailure;
            try writeWebSocket(conn, payload, allocator, .pong);
            continue;
        }
        if (opcode == 10) {
            if (!fin or payload.len > 125) return error.ProtocolFailure;
            continue;
        }
        if (opcode == 1) {
            if (awaiting_continuation) return error.ProtocolFailure;
            try fragments.appendSlice(payload);
            if (fin) break;
            awaiting_continuation = true;
            continue;
        }
        if (opcode == 0) {
            if (!awaiting_continuation) return error.ProtocolFailure;
            try fragments.appendSlice(payload);
            if (fin) break;
            continue;
        }
        return error.ProtocolFailure;
    }

    if (!std.unicode.utf8ValidateSlice(fragments.items)) return error.ProtocolFailure;
    return fragments.toOwnedSlice();
}

fn readExactUntil(conn: *std.http.Client.Connection, buffer: []u8, deadline: i64) !void {
    var used: usize = 0;
    while (used < buffer.len) {
        const remaining = deadline - std.time.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        if (conn.peek().len == 0) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = conn.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const polled = try std.posix.poll(&poll_fds, @intCast(@min(remaining, socket_poll_ms)));
            if (polled == 0) continue;
        }
        const amount = try conn.read(buffer[used..]);
        if (amount == 0) return error.WebSocketClosed;
        used += amount;
    }
}

fn deinitValue(value: *JsonValue, allocator: Allocator) void {
    switch (value.*) {
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| deinitValue(entry.value_ptr, allocator);
            object.deinit();
        },
        .array => |*array| {
            for (array.items) |*item| deinitValue(item, allocator);
            array.deinit();
        },
        else => {},
    }
}

test "timestamps compare as little-endian uint64 values" {
    try std.testing.expectEqual(@as(i8, 1), compareTimestamp(.{ 0, 1, 0, 0, 0, 0, 0, 0 }, .{ 255, 0, 0, 0, 0, 0, 0, 0 }));
}

test "Live session IDs are RFC 4122 version 4 UUIDs" {
    const session = newSessionId();
    try std.testing.expectEqual(@as(usize, 36), session.len);
    try std.testing.expectEqual(@as(u8, '-'), session[8]);
    try std.testing.expectEqual(@as(u8, '-'), session[13]);
    try std.testing.expectEqual(@as(u8, '-'), session[18]);
    try std.testing.expectEqual(@as(u8, '-'), session[23]);
    try std.testing.expectEqual(@as(u8, '4'), session[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", session[19]) != null);
}

test "whole JSON numbers accept decimal integral values" {
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "1.0", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), parsed.value.float);
}

const HttpFixture = struct {
    listener: *std.net.Server,
    body: []const u8,

    fn run(self: *HttpFixture) void {
        const connection = self.listener.accept() catch @panic("HTTP fixture accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        _ = readHttpHeaders(connection.stream, &request) catch @panic("HTTP request read failed");
        connection.stream.writer().print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.body.len, self.body }) catch @panic("HTTP response write failed");
    }
};

fn readHttpHeaders(stream: std.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const amount = try stream.read(buffer[used..]);
        if (amount == 0) return error.EndOfStream;
        used += amount;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |end| return buffer[0 .. end + 4];
    }
    return error.MessageTooBig;
}

fn httpHeaderCount(headers: []const u8, name: []const u8, expected_value: ?[]const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..separator], " \t"), name)) continue;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (expected_value == null or std.ascii.eqlIgnoreCase(value, expected_value.?)) count += 1;
    }
    return count;
}

const HostedBoundaryReply = enum { chunked, unexpected_gzip, bad_status };

const HostedBoundaryFixture = struct {
    listener: *std.net.Server,
    reply: HostedBoundaryReply,

    fn run(self: *HostedBoundaryFixture) void {
        const connection = self.listener.accept() catch @panic("hosted boundary accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        const headers = readHttpHeaders(connection.stream, &request) catch @panic("hosted boundary request failed");
        if (httpHeaderCount(headers, "content-type", "application/json") != 1) @panic("content-type must be emitted exactly once");
        if (httpHeaderCount(headers, "accept-encoding", "identity") != 1) @panic("hosted request must ask for identity encoding");
        if (httpHeaderCount(headers, "authorization", null) != 0) @panic("anonymous request unexpectedly carried authorization");

        const body = "{\"status\":\"success\",\"value\":{\"count\":0.0}}";
        switch (self.reply) {
            .chunked => {
                const split = 19;
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{x}\r\n{s}\r\n{x}\r\n{s}\r\n0\r\n\r\n",
                    .{ split, body[0..split], body.len - split, body[split..] },
                ) catch @panic("chunked hosted response failed");
            },
            .unexpected_gzip => {
                const gzip_body = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\x56\x2a\x2e\x49\x2c\x29\x2d\x56\xb2\x52\x2a\x2e\x4d\x4e\x4e\x2d\x2e\x56\xd2\x51\x2a\x4b\xcc\x29\x4d\x55\xb2\xaa\x56\x4a\xce\x2f\xcd\x2b\x51\xb2\x32\xd0\x33\xa8\xad\x05\x00\x48\x20\x9c\xda\x2a\x00\x00\x00";
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{gzip_body.len},
                ) catch @panic("gzip hosted headers failed");
                connection.stream.writer().writeAll(gzip_body) catch @panic("gzip hosted body failed");
            },
            .bad_status => connection.stream.writer().writeAll(
                "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/html\r\nContent-Length: 11\r\nConnection: close\r\n\r\nunavailable",
            ) catch @panic("hosted status response failed"),
        }
    }
};

test "hosted HTTP boundary is deterministic across transfer, encoding, storage, and status" {
    for ([_]HostedBoundaryReply{ .chunked, .unexpected_gzip, .bad_status }) |reply| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = HostedBoundaryFixture{ .listener = &listener, .reply = reply };
        const thread = try std.Thread.spawn(.{}, HostedBoundaryFixture.run, .{&fixture});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
        defer std.testing.allocator.free(url);
        var client = try Client.init(std.testing.allocator, url);
        defer client.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const args = JsonValue{ .object = std.json.ObjectMap.init(arena.allocator()) };
        if (reply == .bad_status) {
            try std.testing.expectError(error.InvalidResponse, client.call(arena.allocator(), "query", "demo:state", args));
        } else {
            const result = try client.call(arena.allocator(), "query", "demo:state", args);
            const value = try httpObject(result.value orelse return error.InvalidResponse);
            try std.testing.expectEqual(@as(f64, 0.0), value.get("count").?.float);
        }
        thread.join();
    }
}

const AuthLifecycleFixture = struct {
    listener: *std.net.Server,

    fn run(self: *AuthLifecycleFixture) void {
        const replies = [_][]const u8{
            "{\"status\":\"error\",\"errorMessage\":\"Invalid authentication token\",\"errorData\":{\"code\":\"InvalidAuth\"}}",
            "{\"status\":\"success\",\"value\":{\"count\":0.0}}",
        };
        for (replies, 0..) |body, index| {
            const connection = self.listener.accept() catch @panic("auth lifecycle accept failed");
            defer connection.stream.close();
            var request: [8192]u8 = undefined;
            const headers = readHttpHeaders(connection.stream, &request) catch @panic("auth lifecycle request failed");
            if (index == 0) {
                if (httpHeaderCount(headers, "authorization", "Bearer invalid-token-one") != 1) @panic("bearer token was not emitted");
            } else if (httpHeaderCount(headers, "authorization", null) != 0) {
                @panic("cleared bearer token was still emitted");
            }
            connection.stream.writer().print(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ body.len, body },
            ) catch @panic("auth lifecycle response failed");
        }
    }
};

test "invalid bearer token is sent and clearing it restores anonymous calls" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = AuthLifecycleFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, AuthLifecycleFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = JsonValue{ .object = std.json.ObjectMap.init(arena.allocator()) };

    try client.setAuth("invalid-token-one");
    const denied = try client.call(arena.allocator(), "query", "demo:state", args);
    try std.testing.expect(denied.function_error != null);
    try std.testing.expectEqualStrings("Invalid authentication token", denied.function_error.?.message);

    try client.setAuth("");
    const recovered = try client.call(arena.allocator(), "query", "demo:state", args);
    const value = try httpObject(recovered.value orelse return error.InvalidResponse);
    try std.testing.expectEqual(@as(f64, 0.0), value.get("count").?.float);
    thread.join();
}

test "HTTP peer JSON shapes are validated before union access" {
    const malformed = [_][]const u8{
        "[]",
        "{\"status\":1,\"value\":{}}",
        "{\"status\":\"success\",\"logLines\":{},\"value\":{}}",
        "{\"status\":\"success\",\"logLines\":[1],\"value\":{}}",
        "{\"status\":\"error\",\"errorMessage\":1}",
    };
    for (malformed) |body| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = HttpFixture{ .listener = &listener, .body = body };
        const thread = try std.Thread.spawn(.{}, HttpFixture.run, .{&fixture});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
        defer std.testing.allocator.free(url);
        var client = try Client.init(std.testing.allocator, url);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const args = JsonValue{ .object = std.json.ObjectMap.init(arena.allocator()) };
        try std.testing.expectError(error.InvalidResponse, client.call(arena.allocator(), "query", "demo:state", args));
        client.deinit();
        thread.join();
    }
}

// The Live tests intentionally use raw loopback sockets.  They exercise the
// exact parser and owner path that goes into the final static adapter without
// borrowing a WebSocket server implementation from another runtime.
fn testListener() !std.net.Server {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    return std.net.Address.listen(address, .{ .reuse_address = true });
}

fn testPlainConnection(stream: std.net.Stream) std.http.Client.Connection {
    return .{
        .stream = stream,
        .tls_client = undefined,
        .protocol = .plain,
        .host = &.{},
        .port = 0,
    };
}

fn testReadExact(stream: std.net.Stream, bytes: []u8) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        const amount = try stream.read(bytes[used..]);
        if (amount == 0) return error.EndOfStream;
        used += amount;
    }
}

fn testWriteFrame(stream: std.net.Stream, final: bool, opcode: u8, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    header[0] = opcode | if (final) @as(u8, 0x80) else @as(u8, 0);
    var header_len: usize = 2;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }
    try stream.writer().writeAll(header[0..header_len]);
    try stream.writer().writeAll(payload);
}

fn testReadClientFrame(allocator: Allocator, stream: std.net.Stream) !struct { opcode: u8, payload: []u8 } {
    var header: [2]u8 = undefined;
    try testReadExact(stream, &header);
    if (header[1] & 0x80 == 0) return error.ProtocolFailure;
    var length: u64 = header[1] & 0x7f;
    if (length == 126) {
        var encoded: [2]u8 = undefined;
        try testReadExact(stream, &encoded);
        length = std.mem.readInt(u16, &encoded, .big);
    } else if (length == 127) {
        var encoded: [8]u8 = undefined;
        try testReadExact(stream, &encoded);
        length = std.mem.readInt(u64, &encoded, .big);
    }
    if (length > max_websocket_message) return error.MessageTooBig;
    var mask: [4]u8 = undefined;
    try testReadExact(stream, &mask);
    const payload = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(payload);
    try testReadExact(stream, payload);
    for (payload, 0..) |*byte, index| byte.* ^= mask[index % mask.len];
    return .{ .opcode = header[0] & 0x0f, .payload = payload };
}

fn testReadHandshake(stream: std.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        try testReadExact(stream, buffer[used .. used + 1]);
        used += 1;
        if (used >= 4 and std.mem.eql(u8, buffer[used - 4 .. used], "\r\n\r\n")) return buffer[0..used];
    }
    return error.ProtocolFailure;
}

fn testAcceptWebSocket(stream: std.net.Stream) !void {
    var buffer: [8192]u8 = undefined;
    const request = try testReadHandshake(stream, &buffer);
    const key_prefix = "Sec-WebSocket-Key:";
    const key_start = std.mem.indexOf(u8, request, key_prefix) orelse return error.ProtocolFailure;
    const value_start = key_start + key_prefix.len;
    const value_end = std.mem.indexOfPos(u8, request, value_start, "\r\n") orelse return error.ProtocolFailure;
    const key = std.mem.trim(u8, request[value_start..value_end], " \t");
    const accept = websocketAccept(key);
    try stream.writer().print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
}

const HandshakeReply = enum { valid, wrong_status, missing_upgrade, missing_connection, missing_accept, wrong_accept };

const HandshakeFixture = struct {
    listener: *std.net.Server,
    reply: HandshakeReply,

    fn run(self: *HandshakeFixture) void {
        const connection = self.listener.accept() catch @panic("handshake fixture accept failed");
        defer connection.stream.close();
        var buffer: [8192]u8 = undefined;
        const request = testReadHandshake(connection.stream, &buffer) catch @panic("handshake fixture read failed");
        const prefix = "Sec-WebSocket-Key:";
        const start = (std.mem.indexOf(u8, request, prefix) orelse @panic("missing request key")) + prefix.len;
        const end = std.mem.indexOfPos(u8, request, start, "\r\n") orelse @panic("unterminated request key");
        const accept = websocketAccept(std.mem.trim(u8, request[start..end], " \t"));
        const status = if (self.reply == .wrong_status) "200 OK" else "101 Switching Protocols";
        connection.stream.writer().print("HTTP/1.1 {s}\r\n", .{status}) catch @panic("status write failed");
        if (self.reply != .missing_upgrade) connection.stream.writer().writeAll("uPgRaDe: WebSocket\r\n") catch @panic("upgrade write failed");
        if (self.reply != .missing_connection) connection.stream.writer().writeAll("cOnNeCtIoN: keep-alive, UpGrAdE\r\n") catch @panic("connection write failed");
        if (self.reply != .missing_accept) {
            if (self.reply == .wrong_accept) {
                connection.stream.writer().writeAll("Sec-WebSocket-Accept: wrong\r\n") catch @panic("wrong accept write failed");
            } else {
                connection.stream.writer().print("Sec-WebSocket-Accept: {s}\r\n", .{accept}) catch @panic("accept write failed");
            }
        }
        connection.stream.writer().writeAll("\r\n") catch {};
    }
};

test "WebSocket handshake verifies status, token headers, and RFC accept" {
    const rfc_accept = websocketAccept("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &rfc_accept);
    for ([_]HandshakeReply{ .valid, .wrong_status, .missing_upgrade, .missing_connection, .missing_accept, .wrong_accept }) |reply| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = HandshakeFixture{ .listener = &listener, .reply = reply };
        const thread = try std.Thread.spawn(.{}, HandshakeFixture.run, .{&fixture});
        const stream = try std.net.tcpConnectToAddress(listener.listen_address);
        var connection = testPlainConnection(stream);
        try configureSocketDeadlines(&connection);
        if (reply == .valid) {
            try websocketHandshake(std.testing.allocator, &connection, "127.0.0.1", listener.listen_address.getPort(), "/api/sync");
        } else {
            try std.testing.expectError(error.TransportFailure, websocketHandshake(std.testing.allocator, &connection, "127.0.0.1", listener.listen_address.getPort(), "/api/sync"));
        }
        connection.stream.close();
        thread.join();
    }
}

const StoppedWriteMode = enum { unsubscribe, replace };

const StoppedWriteFixture = struct {
    listener: *std.net.Server,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    advertised: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *StoppedWriteFixture) void {
        const connection = self.listener.accept() catch @panic("stopped-write fixture accept failed");
        defer connection.stream.close();
        testAcceptWebSocket(connection.stream) catch @panic("stopped-write handshake failed");
        const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("stopped-write Connect failed");
        std.heap.page_allocator.free(connect.payload);

        // Consume only the Add frame header. The kernel receive window then
        // fills while the owner writes the large payload, which exercises the
        // production socket timeout rather than a cooperative fake writer.
        var header: [2]u8 = undefined;
        testReadExact(connection.stream, &header) catch @panic("stopped-write Add header failed");
        var length: u64 = header[1] & 0x7f;
        if (length == 126) {
            var encoded: [2]u8 = undefined;
            testReadExact(connection.stream, &encoded) catch @panic("stopped-write length failed");
            length = std.mem.readInt(u16, &encoded, .big);
        } else if (length == 127) {
            var encoded: [8]u8 = undefined;
            testReadExact(connection.stream, &encoded) catch @panic("stopped-write length failed");
            length = std.mem.readInt(u64, &encoded, .big);
        }
        var mask: [4]u8 = undefined;
        testReadExact(connection.stream, &mask) catch @panic("stopped-write mask failed");
        self.advertised.store(length, .release);
        self.started.store(true, .release);
        while (!self.release.load(.acquire)) std.time.sleep(std.time.ns_per_ms);

        var total: u64 = 0;
        var discard: [16 * 1024]u8 = undefined;
        while (true) {
            const amount = connection.stream.read(&discard) catch 0;
            if (amount == 0) break;
            total += amount;
        }
        self.received.store(total, .release);
    }
};

test "unsubscribe and replacement acknowledgements are bounded when the peer stops reading" {
    for ([_]StoppedWriteMode{ .unsubscribe, .replace }) |mode| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = StoppedWriteFixture{ .listener = &listener };
        const thread = try std.Thread.spawn(.{}, StoppedWriteFixture.run, .{&fixture});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
        defer std.testing.allocator.free(url);
        var client = try Client.init(std.testing.allocator, url);
        var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
        var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
        const blob = try std.testing.allocator.alloc(u8, 1700 * 1024);
        defer std.testing.allocator.free(blob);
        @memset(blob, 'x');
        try args.object.put("blob", .{ .string = blob });
        try client.subscribe("blocked", "demo:state", args, &output);
        try waitForFlag(&fixture.started, 2 * std.time.ns_per_s);

        const started = std.time.milliTimestamp();
        if (mode == .unsubscribe) {
            try client.unsubscribe("blocked");
        } else {
            try client.subscribe("blocked", "demo:replacement", args, &output);
        }
        try std.testing.expect(std.time.milliTimestamp() - started < 1000);
        fixture.release.store(true, .release);
        try client.close();
        thread.join();
        try std.testing.expect(fixture.received.load(.acquire) < fixture.advertised.load(.acquire));
        args.object.deinit();
        output.deinit();
        client.deinit();
    }
}

const ParserFixture = struct {
    listener: *std.net.Server,
    partial: bool,

    fn run(self: *ParserFixture) void {
        const connection = self.listener.accept() catch @panic("parser fixture accept failed");
        defer connection.stream.close();
        if (self.partial) {
            // The peer advertises a longer frame and then stops halfway.  The
            // client must abandon this connection rather than inventing a new
            // frame boundary after its deadline expires.
            connection.stream.writer().writeAll(&.{ 0x81, 0x08, '{' }) catch @panic("partial frame write failed");
            var discard: [32]u8 = undefined;
            while (connection.stream.read(&discard) catch 0 > 0) {}
            return;
        }
        // Split the UTF-8 e acute across a data-frame boundary and insert a
        // real WebSocket Ping between fragments.  The parser must retain the
        // first bytes, send Pong, then finish the JSON text message.
        testWriteFrame(connection.stream, false, 1, "{\"word\":\"caf\xc3") catch @panic("fragment one failed");
        testWriteFrame(connection.stream, true, 9, "keepalive") catch @panic("ping failed");
        testWriteFrame(connection.stream, true, 0, "\xa9\"}") catch @panic("fragment two failed");
        const pong = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("pong read failed");
        defer std.heap.page_allocator.free(pong.payload);
        if (pong.opcode != 10 or !std.mem.eql(u8, pong.payload, "keepalive")) @panic("missing pong");
    }
};

test "real sockets preserve fragmented UTF-8, control frames, and partial-frame abandonment" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = ParserFixture{ .listener = &listener, .partial = false };
    const thread = try std.Thread.spawn(.{}, ParserFixture.run, .{&fixture});
    var stream = try std.net.tcpConnectToAddress(listener.listen_address);
    var connection = testPlainConnection(stream);
    const message = try readWebSocket(&connection, std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"word\":\"caf\xc3\xa9\"}", message);
    connection.stream.close();
    thread.join();

    var partial_listener = try testListener();
    defer partial_listener.deinit();
    var partial_fixture = ParserFixture{ .listener = &partial_listener, .partial = true };
    const partial_thread = try std.Thread.spawn(.{}, ParserFixture.run, .{&partial_fixture});
    stream = try std.net.tcpConnectToAddress(partial_listener.listen_address);
    connection = testPlainConnection(stream);
    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.Timeout, readWebSocket(&connection, std.testing.allocator));
    try std.testing.expect(std.time.milliTimestamp() - started < frame_deadline_ms + 300);
    connection.stream.close();
    partial_thread.join();
}

fn testTimestamp(value: u64) [12]u8 {
    var decoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &decoded, value, .little);
    var encoded: [12]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &decoded);
    return encoded;
}

fn testSendTransition(stream: std.net.Stream, start_query_set: u32, end_query_set: u32, timestamp: u64, query_id: u32, count: u32) !void {
    const encoded_timestamp = testTimestamp(timestamp);
    var payload: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&payload, "{{\"type\":\"Transition\",\"startVersion\":{{\"querySet\":{d},\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}},\"endVersion\":{{\"querySet\":{d},\"identity\":0,\"ts\":\"{s}\"}},\"modifications\":[{{\"type\":\"QueryUpdated\",\"queryId\":{d},\"value\":{{\"count\":{d}}},\"logLines\":[]}}]}}", .{ start_query_set, end_query_set, encoded_timestamp, query_id, count });
    try testWriteFrame(stream, true, 1, json);
}

fn testSendFailure(stream: std.net.Stream, timestamp: u64, query_id: u32) !void {
    const encoded_timestamp = testTimestamp(timestamp);
    var payload: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&payload, "{{\"type\":\"Transition\",\"startVersion\":{{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}},\"endVersion\":{{\"querySet\":1,\"identity\":0,\"ts\":\"{s}\"}},\"modifications\":[{{\"type\":\"QueryFailed\",\"queryId\":{d},\"errorMessage\":\"empty room\",\"errorData\":{{\"code\":\"ROOM_EMPTY\"}}}}]}}", .{ encoded_timestamp, query_id });
    try testWriteFrame(stream, true, 1, json);
}

fn testExpectContains(haystack: []const u8, needle: []const u8) void {
    if (std.mem.indexOf(u8, haystack, needle) == null) @panic("unexpected client wire message");
}

test "Live transition tags and integer ranges are validated before access" {
    const malformed = [_][]const u8{
        "{\"startVersion\":[],\"endVersion\":{},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":-1,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":4294967296,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":4294967296,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":-1,\"value\":{}}]}",
        "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":4294967296,\"value\":{}}]}",
        "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"bad\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":1,\"queryId\":0}]}",
    };
    var client = try Client.init(std.testing.allocator, "http://127.0.0.1:9");
    defer client.deinit();
    var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
    defer output.deinit();
    var manager = try LiveManager.init(std.testing.allocator, client, &output);
    defer {
        manager.active.deinit();
        manager.commands.deinit();
    }
    var owner = LiveOwner.init(&manager);
    for (malformed) |json| {
        var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, json, .{});
        defer parsed.deinit();
        const object = try protocolObject(parsed.value);
        try std.testing.expectError(error.ProtocolFailure, owner.handleTransition(object));
        try std.testing.expectEqual(@as(u32, 0), owner.remote_query_set_version);
    }
    owner.remote_query_set_version = 1;
    var backward = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "{\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[]}", .{});
    defer backward.deinit();
    try std.testing.expectError(error.ProtocolFailure, owner.handleTransition(try protocolObject(backward.value)));
    try std.testing.expectEqual(@as(u32, 1), owner.remote_query_set_version);
}

const MalformedRecoveryFixture = struct {
    listener: *std.net.Server,

    fn run(self: *MalformedRecoveryFixture) void {
        var first = self.listener.accept() catch @panic("malformed fixture first accept failed");
        testAcceptWebSocket(first.stream) catch @panic("malformed fixture handshake failed");
        var frame = testReadClientFrame(std.heap.page_allocator, first.stream) catch @panic("malformed fixture Connect failed");
        std.heap.page_allocator.free(frame.payload);
        frame = testReadClientFrame(std.heap.page_allocator, first.stream) catch @panic("malformed fixture Add failed");
        std.heap.page_allocator.free(frame.payload);
        testWriteFrame(first.stream, true, 1, "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":4294967296,\"value\":{}}]}") catch @panic("malformed transition write failed");
        var discard: [64]u8 = undefined;
        while (first.stream.read(&discard) catch 0 > 0) {}
        first.stream.close();

        const second = self.listener.accept() catch @panic("malformed fixture reconnect failed");
        defer second.stream.close();
        testAcceptWebSocket(second.stream) catch @panic("malformed fixture reconnect handshake failed");
        frame = testReadClientFrame(std.heap.page_allocator, second.stream) catch @panic("reconnect Connect failed");
        std.heap.page_allocator.free(frame.payload);
        frame = testReadClientFrame(std.heap.page_allocator, second.stream) catch @panic("reconnect Add failed");
        std.heap.page_allocator.free(frame.payload);
        testSendTransition(second.stream, 0, 1, 2, 0, 7) catch @panic("recovery transition write failed");
        while (second.stream.read(&discard) catch 0 > 0) {}
    }
};

test "malformed Live transition emits ProtocolError and reconnects to a valid value" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = MalformedRecoveryFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, MalformedRecoveryFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    var capture = Capture.init(std.testing.allocator);
    var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
    output.capture = &capture;
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    try args.object.put("room", .{ .string = "malformed-recovery" });
    try client.subscribe("malformed", "demo:state", args, &output);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const protocol_error = try capture.next(arena.allocator(), 2 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("ProtocolError", try protocolString((try protocolObject(protocol_error)).get("name") orelse return error.ProtocolFailure));
    const recovered = try capture.next(arena.allocator(), 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(i64, 7), (try protocolObject(recovered)).get("count").?.integer);
    try client.close();
    thread.join();
    arena.deinit();
    args.object.deinit();
    output.deinit();
    capture.deinit();
    client.deinit();
}

const ReconnectFixture = struct {
    listener: *std.net.Server,
    connections: u32 = 0,

    fn run(self: *ReconnectFixture) void {
        var number: u32 = 0;
        while (number < 6) : (number += 1) {
            const connection = self.listener.accept() catch @panic("reconnect fixture accept failed");
            defer connection.stream.close();
            testAcceptWebSocket(connection.stream) catch @panic("websocket handshake failed");

            const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("Connect read failed");
            defer std.heap.page_allocator.free(connect.payload);
            if (connect.opcode != 1) @panic("Connect was not a text frame");
            var expected_count: [32]u8 = undefined;
            const count_text = std.fmt.bufPrint(&expected_count, "\"connectionCount\":{d}", .{number}) catch @panic("count format failed");
            testExpectContains(connect.payload, count_text);
            if (number > 0) {
                const prior_timestamp = testTimestamp(255 + (@as(u64, number) - 1) * 2);
                var expected_timestamp: [64]u8 = undefined;
                const timestamp_text = std.fmt.bufPrint(&expected_timestamp, "\"maxObservedTimestamp\":\"{s}\"", .{prior_timestamp}) catch @panic("timestamp format failed");
                testExpectContains(connect.payload, timestamp_text);
            }

            const add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("Add read failed");
            defer std.heap.page_allocator.free(add.payload);
            testExpectContains(add.payload, "\"type\":\"ModifyQuerySet\"");
            testExpectContains(add.payload, "\"type\":\"Add\"");

            // The initial Add must be sent once.  A short poll before the
            // server starts transitions catches a duplicate replay without
            // racing a later debugDisconnect command.
            var poll_fds = [_]std.posix.pollfd{.{ .fd = connection.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&poll_fds, 100) catch 0) != 0) @panic("duplicate Add replayed");

            if (number == 0) {
                // A structured function failure must reach the relay but must
                // not strand it: the later QueryUpdated is still delivered.
                testSendFailure(connection.stream, 254, 0) catch @panic("failure write failed");
                testSendTransition(connection.stream, 1, 1, 255, 0, 0) catch @panic("recovery write failed");
            } else {
                const rehydrated_count = number - 1;
                const rehydrated_timestamp = 255 + (@as(u64, number) - 1) * 2 + 1;
                testSendTransition(connection.stream, 0, 1, rehydrated_timestamp, 0, rehydrated_count) catch @panic("rehydration write failed");
                testSendTransition(connection.stream, 1, 1, rehydrated_timestamp + 1, 0, number) catch @panic("changed update write failed");
            }

            // The client owns teardown.  It may send Remove first, but the
            // loop exits only when the exact retired socket reaches EOF.
            var discard: [256]u8 = undefined;
            while (connection.stream.read(&discard) catch 0 > 0) {}
            self.connections += 1;
        }
    }
};

test "Live owner replays one Add across five reconnects and suppresses only unchanged rehydration" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = ReconnectFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, ReconnectFixture.run, .{&fixture});

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
    defer output.deinit();
    output.capture = &capture;
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    defer args.object.deinit();
    try args.object.put("room", .{ .string = "live-fixture" });

    try client.subscribe("fixture", "demo:state", args, &output);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failure = try capture.next(arena.allocator(), 2 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("FunctionError", failure.object.get("name").?.string);
    try std.testing.expectEqualStrings("ROOM_EMPTY", failure.object.get("data").?.object.get("code").?.string);
    const initial = try capture.next(arena.allocator(), 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(i64, 0), initial.object.get("count").?.integer);

    var reconnect: u32 = 1;
    while (reconnect <= 5) : (reconnect += 1) {
        try client.debugDisconnect();
        const update = try capture.next(arena.allocator(), 2 * std.time.ns_per_s);
        try std.testing.expectEqual(@as(i64, @intCast(reconnect)), update.object.get("count").?.integer);
    }
    try client.close();
    thread.join();
    try std.testing.expectEqual(@as(u32, 6), fixture.connections);
}

const BarrierMode = enum { unsubscribe, replace };

const BarrierFixture = struct {
    listener: *std.net.Server,
    mode: BarrierMode,
    active_count: u32 = 1,
    replacement_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *BarrierFixture) void {
        const connection = self.listener.accept() catch @panic("barrier fixture accept failed");
        defer connection.stream.close();
        testAcceptWebSocket(connection.stream) catch @panic("barrier fixture handshake failed");
        const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("barrier Connect read failed");
        std.heap.page_allocator.free(connect.payload);
        var add_index: u32 = 0;
        while (add_index < self.active_count) : (add_index += 1) {
            const add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("barrier Add read failed");
            defer std.heap.page_allocator.free(add.payload);
            testExpectContains(add.payload, "\"type\":\"Add\"");
        }
        testSendTransition(connection.stream, 0, self.active_count, 1, 0, 1) catch @panic("old transition write failed");

        const remove = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("barrier Remove read failed");
        defer std.heap.page_allocator.free(remove.payload);
        testExpectContains(remove.payload, "\"type\":\"Remove\"");
        if (self.mode == .replace) {
            const replacement_add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("replacement Add read failed");
            defer std.heap.page_allocator.free(replacement_add.payload);
            testExpectContains(replacement_add.payload, "\"type\":\"Add\"");
            var query_id_text: [32]u8 = undefined;
            const expected_query_id = std.fmt.bufPrint(&query_id_text, "\"queryId\":{d}", .{self.active_count}) catch @panic("replacement query id format failed");
            testExpectContains(replacement_add.payload, expected_query_id);
            testSendTransition(connection.stream, self.active_count, self.active_count + 2, 2, self.active_count, 2) catch @panic("replacement transition write failed");
            self.replacement_sent.store(true, .release);
        }

        var discard: [256]u8 = undefined;
        while (connection.stream.read(&discard) catch 0 > 0) {}
    }
};

fn waitForFlag(flag: *std.atomic.Value(bool), timeout_ns: u64) !void {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
    while (!flag.load(.acquire)) {
        if (std.time.nanoTimestamp() >= deadline) return error.Timeout;
        std.time.sleep(std.time.ns_per_ms);
    }
}

fn waitForOutputContains(output: *Output, bytes: *std.ArrayList(u8), needle: []const u8, timeout_ns: u64) !void {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
    while (true) {
        output.write_mutex.lock();
        const found = std.mem.indexOf(u8, bytes.items, needle) != null;
        output.write_mutex.unlock();
        if (found) return;
        if (std.time.nanoTimestamp() >= deadline) return error.Timeout;
        std.time.sleep(std.time.ns_per_ms);
    }
}

test "unsubscribe revokes an in-flight generation before acknowledgement" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = BarrierFixture{ .listener = &listener, .mode = .unsubscribe };
    const thread = try std.Thread.spawn(.{}, BarrierFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    try args.object.put("room", .{ .string = "barrier" });

    try client.subscribe("same", "demo:state", args, &output);
    try pause.waitUntilDequeued(std.time.ns_per_s);
    // The production owner revokes the old generation before this returns,
    // which is the exact point where the adapter may publish its ack.
    try client.unsubscribe("same");
    pause.releaseWriter();
    try waitForOutputIdle(&output, std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
    try client.close();
    thread.join();
    args.object.deinit();
    output.deinit();
    bytes.deinit();
    client.deinit();
}

test "same-ID replacement revokes old in-flight generation before acknowledgement" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = BarrierFixture{ .listener = &listener, .mode = .replace };
    const thread = try std.Thread.spawn(.{}, BarrierFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    try args.object.put("room", .{ .string = "barrier" });

    try client.subscribe("same", "demo:state", args, &output);
    try pause.waitUntilDequeued(std.time.ns_per_s);
    // This second production Add retires the old token before it returns.
    try client.subscribe("same", "demo:state", args, &output);
    try waitForFlag(&fixture.replacement_sent, std.time.ns_per_s);
    pause.releaseWriter();
    try waitForOutputContains(&output, &bytes, "\"count\":2", std.time.ns_per_s);
    try waitForOutputIdle(&output, std.time.ns_per_s);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":2") != null);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
    try client.close();
    thread.join();
    args.object.deinit();
    output.deinit();
    bytes.deinit();
    client.deinit();
}

test "same-ID replacement succeeds at the sixteen-subscription ceiling with a paused old relay" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = BarrierFixture{ .listener = &listener, .mode = .replace, .active_count = max_live_subscriptions };
    const thread = try std.Thread.spawn(.{}, BarrierFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    try args.object.put("room", .{ .string = "capacity-barrier" });

    try client.subscribe("same", "demo:state", args, &output);
    var slot: u32 = 1;
    while (slot < max_live_subscriptions) : (slot += 1) {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "slot-{d}", .{slot});
        try client.subscribe(id, "demo:state", args, &output);
    }
    try pause.waitUntilDequeued(2 * std.time.ns_per_s);
    try client.subscribe("same", "demo:state", args, &output);
    try waitForFlag(&fixture.replacement_sent, 2 * std.time.ns_per_s);
    pause.releaseWriter();
    try waitForOutputContains(&output, &bytes, "\"count\":2", 2 * std.time.ns_per_s);
    try waitForOutputIdle(&output, 2 * std.time.ns_per_s);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":2") != null);
    try std.testing.expectEqual(@as(usize, max_live_subscriptions), client.live.?.active.items.len);
    try client.close();
    thread.join();
    args.object.deinit();
    output.deinit();
    bytes.deinit();
    client.deinit();
}

const CloseMode = enum { idle, flood, half_frame };

const CloseFixture = struct {
    listener: *std.net.Server,
    mode: CloseMode,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    peer_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *CloseFixture) void {
        const connection = self.listener.accept() catch @panic("close fixture accept failed");
        defer connection.stream.close();
        testAcceptWebSocket(connection.stream) catch @panic("close fixture handshake failed");
        const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("close fixture Connect failed");
        std.heap.page_allocator.free(connect.payload);
        const add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("close fixture Add failed");
        std.heap.page_allocator.free(add.payload);
        self.ready.store(true, .release);

        switch (self.mode) {
            .flood => {
                while (true) testWriteFrame(connection.stream, true, 9, "flood") catch break;
            },
            .half_frame => {
                connection.stream.writer().writeAll(&.{ 0x81, 0x7d, '{' }) catch {};
                var discard: [256]u8 = undefined;
                while (connection.stream.read(&discard) catch 0 > 0) {}
            },
            .idle => {
                var discard: [256]u8 = undefined;
                while (connection.stream.read(&discard) catch 0 > 0) {}
            },
        }
        self.peer_closed.store(true, .release);
    }
};

test "close is bounded for idle, flooding, and half-frame peers" {
    for ([_]CloseMode{ .idle, .flood, .half_frame }) |mode| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = CloseFixture{ .listener = &listener, .mode = mode };
        const thread = try std.Thread.spawn(.{}, CloseFixture.run, .{&fixture});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
        defer std.testing.allocator.free(url);
        var client = try Client.init(std.testing.allocator, url);
        var capture = Capture.init(std.testing.allocator);
        var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
        output.capture = &capture;
        var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
        try args.object.put("room", .{ .string = "close-fixture" });
        try client.subscribe("close", "demo:state", args, &output);
        const ready_deadline = std.time.milliTimestamp() + 1000;
        while (!fixture.ready.load(.acquire)) {
            if (std.time.milliTimestamp() > ready_deadline) return error.Timeout;
            std.time.sleep(std.time.ns_per_ms);
        }
        if (mode == .half_frame) std.time.sleep(20 * std.time.ns_per_ms);
        const started = std.time.milliTimestamp();
        try client.close();
        try std.testing.expect(std.time.milliTimestamp() - started < 1000);
        thread.join();
        try std.testing.expect(fixture.peer_closed.load(.acquire));
        args.object.deinit();
        output.deinit();
        capture.deinit();
        client.deinit();
    }
}

test "stopped reader keeps exact count and encoded-byte budgets" {
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    const token = try output.newDeliveryToken();
    const blob = try std.testing.allocator.alloc(u8, 900 * 1024);
    defer std.testing.allocator.free(blob);
    @memset(blob, 'x');

    var sequence: i64 = 0;
    while (sequence < 40) : (sequence += 1) {
        var event = std.json.ObjectMap.init(std.testing.allocator);
        defer event.deinit();
        try event.put("type", .{ .string = "subscription" });
        try event.put("subscriptionId", .{ .string = "memory" });
        var state = std.json.ObjectMap.init(std.testing.allocator);
        defer state.deinit();
        try state.put("sequence", .{ .integer = sequence });
        try state.put("blob", .{ .string = blob });
        try event.put("value", .{ .object = state });
        try output.enqueueSubscription("memory", token, .{ .object = event });
        if (sequence == 0) try pause.waitUntilDequeued(std.time.ns_per_s);
    }

    output.mutex.lock();
    const reserved_count = output.reserved_count;
    const reserved_bytes = output.reserved_bytes;
    const retained_count = output.queue.items.len;
    const newest = if (retained_count == 0) "" else output.queue.items[retained_count - 1].encoded;
    output.mutex.unlock();
    try std.testing.expect(reserved_count <= max_live_queue_events);
    try std.testing.expect(reserved_bytes <= max_live_queue_bytes);
    try std.testing.expectEqual(reserved_count - 1, retained_count);
    try std.testing.expect(std.mem.indexOf(u8, newest, "\"sequence\":39") != null);

    pause.releaseWriter();
    try waitForOutputIdle(&output, 5 * std.time.ns_per_s);
    output.revokeDeliveryToken(token);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
}
