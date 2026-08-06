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
const output_deadline_ms = 250;
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
        self.next_generation += 1;
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
                // A new connection replays every active Add itself.  Sending
                // another Add here used to duplicate the first subscription.
                if (self.socket == null) {
                    try self.ensureConnected();
                } else {
                    try self.sendModify(.{query.id}, true);
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
        if (self.socket != null) try self.sendModify(.{id}, false);
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
        const conn = try self.manager.client.http.connectTcp(host_raw, port, protocol);
        errdefer self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
        const path = try uri.path.toRawMaybeAlloc(uri_arena.allocator());
        try websocketHandshake(self.manager.allocator, conn, host_raw, port, path);
        self.socket = conn;
        self.generation += 1;
        self.query_set_version = 0;
        self.remote_query_set_version = 0;
        try self.sendConnect();
        self.connection_count += 1;
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
                var error_value: JsonValue = .{ .object = blk: {
                    var error_object = std.json.ObjectMap.init(self.manager.allocator);
                    try error_object.put("name", .{ .string = "FunctionError" });
                    try error_object.put("message", modification.get("errorMessage") orelse .{ .string = "query failed" });
                    try error_object.put("data", modification.get("errorData") orelse .null);
                    break :blk error_object;
                } };
                defer deinitValue(&error_value, self.manager.allocator);
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

test "whole JSON numbers accept decimal integral values" {
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "1.0", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), parsed.value.float);
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

fn testReadHandshake(stream: std.net.Stream) !void {
    var buffer: [8192]u8 = undefined;
    var used: usize = 0;
    while (used < buffer.len) {
        try testReadExact(stream, buffer[used .. used + 1]);
        used += 1;
        if (used >= 4 and std.mem.eql(u8, buffer[used - 4 .. used], "\r\n\r\n")) return;
    }
    return error.ProtocolFailure;
}

fn testAcceptWebSocket(stream: std.net.Stream) !void {
    try testReadHandshake(stream);
    try stream.writer().writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: test\r\n\r\n");
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
    replacement_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *BarrierFixture) void {
        const connection = self.listener.accept() catch @panic("barrier fixture accept failed");
        defer connection.stream.close();
        testAcceptWebSocket(connection.stream) catch @panic("barrier fixture handshake failed");
        const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("barrier Connect read failed");
        std.heap.page_allocator.free(connect.payload);
        const first_add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("barrier Add read failed");
        defer std.heap.page_allocator.free(first_add.payload);
        testExpectContains(first_add.payload, "\"type\":\"Add\"");
        testSendTransition(connection.stream, 0, 1, 1, 0, 1) catch @panic("old transition write failed");

        const remove = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("barrier Remove read failed");
        defer std.heap.page_allocator.free(remove.payload);
        testExpectContains(remove.payload, "\"type\":\"Remove\"");
        if (self.mode == .replace) {
            const replacement_add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("replacement Add read failed");
            defer std.heap.page_allocator.free(replacement_add.payload);
            testExpectContains(replacement_add.payload, "\"type\":\"Add\"");
            testExpectContains(replacement_add.payload, "\"queryId\":1");
            testSendTransition(connection.stream, 1, 3, 2, 1, 2) catch @panic("replacement transition write failed");
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
