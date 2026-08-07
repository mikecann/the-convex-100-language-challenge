//! A small native Zig client for Convex's JSON HTTP API and the pinned
//! convex-rs 0.10.4 `/api/sync` Live profile.
//!
//! The client deliberately keeps the JSON-safe demonstration surface small.
//! Convex-specific request envelopes, sync versions, timestamp ordering, and
//! WebSocket frames are implemented here rather than delegated to another
//! Convex client or command-line tool.

const std = @import("std");
const builtin = @import("builtin");

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
    /// A record was abandoned after its first byte reached the controller, so
    /// the NDJSON stream can never carry another event.
    StreamTerminal,
};

pub const CallResult = struct {
    value: ?JsonValue = null,
    logs: JsonValue,
    function_error: ?FunctionError = null,
};

pub const FunctionError = struct {
    name: []const u8 = "FunctionError",
    message: []const u8,
    data: ?JsonValue,
    logs: JsonValue,
};

const max_http_body = 2 * 1024 * 1024;
// Hosted TLS and amd64 emulation can legitimately spend several seconds in
// DNS, handshake, or the first response byte. Ten seconds is still a strict
// absolute production deadline, but it does not turn ordinary scheduler
// contention into a false transport failure. Fixtures use the same mechanism
// with a shorter clock so their drip response cannot race the deadline.
const http_deadline_ms = if (builtin.is_test) 2000 else 10_000;
const max_websocket_message = 2 * 1024 * 1024;
const max_live_subscriptions = 16;
const max_live_queue_bytes = 8 * 1024 * 1024;
const max_live_queue_events = 16;
/// A schema-valid Convex value may fill an entire incoming sync message, so
/// the adapter event ceiling is derived from the frame ceiling instead of
/// being guessed. Re-encoding a parsed value cannot outgrow the JSON text it
/// came from, and the envelope adds only the event type, the subscription ID,
/// and the log lines already counted inside that message, so one frame's worth
/// of headroom is enough to deliver a near-maximum value rather than rejecting
/// it. The count and byte budgets below still bound the process: at most
/// sixteen events and eight MiB of encoded output may be reserved at once,
/// which keeps the real adapter far below the shared 128 MiB gate even when
/// the controller has stopped reading.
const max_adapter_event_overhead = 64 * 1024;
const max_adapter_event_bytes = max_websocket_message + max_adapter_event_overhead;
const socket_poll_ms = 50;
const close_grace_ms = 1000;
// Hosted Convex can legitimately take more than a scheduler tick to publish
// the first transition, especially under the final image's half-CPU limit.
// Tests use a shorter value to prove the same absolute-deadline mechanism
// without adding five seconds to every hostile-peer fixture.
const frame_deadline_ms = if (builtin.is_test) 250 else 5000;
const handshake_deadline_ms = 10_000;
const output_deadline_ms = 250;
/// Absolute limits for the Live socket. `connect_deadline_ms` covers one whole
/// bring-up (name lookup, TCP connect, TLS, the 101 upgrade, the first Connect
/// frame, and the replayed Add frames); `socket_write_deadline_ms` covers one
/// outbound frame, so a peer that drains a trickle cannot hold the sole owner.
const connect_deadline_ms = 10_000;
const socket_write_deadline_ms = 250;
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

/// One absolute, cancellable deadline for a whole operation rather than a
/// per-syscall timer. A peer that accepts or delivers a trickle of bytes can
/// restart a per-write timer forever; it cannot move this limit, because the
/// watchdog shuts the registered descriptor down when the limit passes. The
/// same object is what lets `close` cancel an in-flight connect or handshake,
/// so the sole Live owner always returns to its command queue.
const Deadline = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    timer: std.time.Timer,
    limit_ns: u64,
    fd: ?std.posix.fd_t = null,
    done: bool = false,
    expired: bool = false,
    thread: ?std.Thread = null,

    fn init(timeout_ms: u64) !Deadline {
        return Deadline{
            .timer = try std.time.Timer.start(),
            .limit_ns = timeout_ms * std.time.ns_per_ms,
        };
    }

    fn start(self: *Deadline) !void {
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn watch(self: *Deadline) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.done) {
            const elapsed = self.timer.read();
            if (elapsed >= self.limit_ns) {
                self.expired = true;
                if (self.fd) |descriptor| std.posix.shutdown(descriptor, .both) catch {};
                return;
            }
            self.condition.timedWait(&self.mutex, self.limit_ns - elapsed) catch {};
        }
    }

    fn remainingPollMs(self: *Deadline) !i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.expired) return error.Timeout;
        const elapsed = self.timer.read();
        if (elapsed >= self.limit_ns) return error.Timeout;
        const remaining_ns = self.limit_ns - elapsed;
        const rounded_ms = (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        return @intCast(@min(rounded_ms, std.math.maxInt(i32)));
    }

    fn setFd(self: *Deadline, descriptor: std.posix.fd_t) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.expired) return error.Timeout;
        self.fd = descriptor;
    }

    fn clearFd(self: *Deadline, descriptor: std.posix.fd_t) void {
        self.mutex.lock();
        if (self.fd != null and self.fd.? == descriptor) self.fd = null;
        self.mutex.unlock();
    }

    fn timedOut(self: *Deadline) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.expired or self.timer.read() >= self.limit_ns;
    }

    /// Expire the deadline now. A control command such as `close` uses this to
    /// interrupt a connect, TLS, or upgrade attempt against an unresponsive
    /// peer instead of waiting the attempt out. The watchdog is retired in the
    /// same critical section, so it can never shut down a descriptor that the
    /// abandoning operation has already closed and the process has reused.
    fn cancel(self: *Deadline) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.expired = true;
        if (self.fd) |descriptor| std.posix.shutdown(descriptor, .both) catch {};
        self.fd = null;
        self.done = true;
        self.condition.broadcast();
    }

    fn finish(self: *Deadline) void {
        self.mutex.lock();
        self.done = true;
        self.fd = null;
        self.condition.broadcast();
        self.mutex.unlock();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

/// Test-only gate that holds a name lookup open. Production builds compile the
/// branch that reads it away, so the client always calls the resolver directly.
const ResolveGate = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    released: bool = false,
    finished: bool = false,

    fn waitUntilReleased(self: *ResolveGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.released) self.condition.wait(&self.mutex);
    }

    fn release(self: *ResolveGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.released = true;
        self.condition.broadcast();
    }

    fn markFinished(self: *ResolveGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.finished = true;
        self.condition.broadcast();
    }

    fn waitUntilFinished(self: *ResolveGate, timeout_ns: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const limit = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
        while (!self.finished) {
            const remaining = limit - std.time.nanoTimestamp();
            if (remaining <= 0) return error.Timeout;
            self.condition.timedWait(&self.mutex, @intCast(remaining)) catch return error.Timeout;
        }
    }
};

var test_resolve_gate: ?*ResolveGate = null;

fn resolveHost(allocator: Allocator, host: []const u8, port: u16) !*std.net.AddressList {
    if (builtin.is_test) {
        if (test_resolve_gate) |gate| gate.waitUntilReleased();
    }
    return std.net.getAddressList(allocator, host, port);
}

/// Test-only census of resolution boxes a detached lookup may still own. It
/// returns to zero only when every lookup has dropped its reference, which is
/// what proves an abandoned lookup really did release rather than merely stop
/// being waited on.
var live_resolutions: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// A name lookup cannot be interrupted, so it runs on its own detached thread
/// and the caller waits only until the shared deadline. Everything that thread
/// can still touch after the caller has moved on — this box, its copy of the
/// host, and whatever the lookup produced — belongs to the process-lifetime
/// page allocator rather than the caller's allocator. A straggling lookup
/// therefore cannot free into an allocator that has already been torn down,
/// which is precisely what happens to a test allocator between tests and to a
/// client's allocator at shutdown. The caller copies the addresses it needs
/// while it still holds a reference and owns only that copy.
const Resolution = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(2),
    host: []u8,
    port: u16,
    done: bool = false,
    addresses: ?*std.net.AddressList = null,
    failure: ?anyerror = null,

    fn release(self: *Resolution) void {
        // The last reference wins, so nothing else can observe these fields.
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        if (self.addresses) |addresses| addresses.deinit();
        std.heap.page_allocator.free(self.host);
        std.heap.page_allocator.destroy(self);
        if (builtin.is_test) _ = live_resolutions.fetchSub(1, .acq_rel);
    }

    fn run(self: *Resolution) void {
        const resolved = resolveHost(std.heap.page_allocator, self.host, self.port);
        self.mutex.lock();
        if (resolved) |addresses| {
            self.addresses = addresses;
        } else |err| {
            self.failure = err;
        }
        self.done = true;
        self.condition.signal();
        self.mutex.unlock();
        self.release();
        // Announced only after this thread has dropped every reference, so a
        // fixture can prove the abandoned lookup released its memory.
        if (builtin.is_test) {
            if (test_resolve_gate) |gate| gate.markFinished();
        }
    }
};

fn resolveUntil(allocator: Allocator, host: []const u8, port: u16, deadline: *Deadline) ![]std.net.Address {
    const resolution = try std.heap.page_allocator.create(Resolution);
    resolution.* = .{
        .host = std.heap.page_allocator.dupe(u8, host) catch |err| {
            std.heap.page_allocator.destroy(resolution);
            return err;
        },
        .port = port,
    };
    if (builtin.is_test) _ = live_resolutions.fetchAdd(1, .acq_rel);
    const thread = std.Thread.spawn(.{}, Resolution.run, .{resolution}) catch |err| {
        std.heap.page_allocator.free(resolution.host);
        std.heap.page_allocator.destroy(resolution);
        if (builtin.is_test) _ = live_resolutions.fetchSub(1, .acq_rel);
        return err;
    };
    thread.detach();

    resolution.mutex.lock();
    while (!resolution.done) {
        const remaining_ms = deadline.remainingPollMs() catch {
            resolution.mutex.unlock();
            resolution.release();
            return error.Timeout;
        };
        resolution.condition.timedWait(&resolution.mutex, @as(u64, @intCast(remaining_ms)) * std.time.ns_per_ms) catch {};
    }
    // Addresses are plain values, so the caller leaves with a copy it owns
    // outright instead of a handle into a box the detached lookup still holds.
    var copied: []std.net.Address = &[_]std.net.Address{};
    var copy_failure: ?anyerror = null;
    if (resolution.addresses) |addresses| {
        if (allocator.dupe(std.net.Address, addresses.addrs)) |slice| {
            copied = slice;
        } else |err| {
            copy_failure = err;
        }
    }
    const failure = resolution.failure;
    resolution.mutex.unlock();
    resolution.release();
    if (copy_failure) |err| return err;
    if (failure) |err| return err;
    if (copied.len == 0) return error.UnknownHostName;
    return copied;
}

fn connectStreamUntil(allocator: Allocator, host: []const u8, port: u16, deadline: *Deadline) !std.net.Stream {
    const addresses = try resolveUntil(allocator, host, port, deadline);
    defer allocator.free(addresses);
    if (addresses.len == 0) return error.UnknownHostName;

    for (addresses) |address| {
        const descriptor = std.posix.socket(address.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP) catch continue;
        var keep = false;
        defer if (!keep) {
            deadline.clearFd(descriptor);
            std.posix.close(descriptor);
        };
        try deadline.setFd(descriptor);
        std.posix.connect(descriptor, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {
                var poll_fds = [_]std.posix.pollfd{.{ .fd = descriptor, .events = std.posix.POLL.OUT, .revents = 0 }};
                if (try std.posix.poll(&poll_fds, try deadline.remainingPollMs()) == 0) return error.Timeout;
                std.posix.getsockoptError(descriptor) catch continue;
            },
            else => continue,
        };
        const flags = try std.posix.fcntl(descriptor, std.posix.F.GETFL, 0);
        var open_flags: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        open_flags.NONBLOCK = false;
        _ = try std.posix.fcntl(descriptor, std.posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(open_flags)))));
        keep = true;
        return .{ .handle = descriptor };
    }
    return error.ConnectionRefused;
}

fn connectHttpUntil(client: *std.http.Client, allocator: Allocator, uri: std.Uri, deadline: *Deadline) !*std.http.Client.Connection {
    const protocol: std.http.Client.Connection.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) .tls else .plain;
    var uri_arena = std.heap.ArenaAllocator.init(allocator);
    defer uri_arena.deinit();
    const host = try (uri.host orelse return error.InvalidDeploymentUrl).toRawMaybeAlloc(uri_arena.allocator());
    const port: u16 = uri.port orelse if (protocol == .tls) 443 else 80;

    if (protocol == .tls and @atomicLoad(bool, &client.next_https_rescan_certs, .acquire)) {
        client.ca_bundle_mutex.lock();
        defer client.ca_bundle_mutex.unlock();
        if (client.next_https_rescan_certs) {
            client.ca_bundle.rescan(allocator) catch return error.CertificateBundleLoadFailure;
            @atomicStore(bool, &client.next_https_rescan_certs, false, .release);
        }
    }

    const stream = try connectStreamUntil(allocator, host, port, deadline);
    errdefer {
        deadline.clearFd(stream.handle);
        stream.close();
    }
    const node = try allocator.create(std.http.Client.ConnectionPool.Node);
    errdefer allocator.destroy(node);
    const owned_host = try allocator.dupe(u8, host);
    errdefer allocator.free(owned_host);
    node.* = .{ .data = .{
        .stream = stream,
        .tls_client = undefined,
        .protocol = protocol,
        .host = owned_host,
        .port = port,
    } };
    if (protocol == .tls) {
        const tls_client = try allocator.create(std.crypto.tls.Client);
        errdefer allocator.destroy(tls_client);
        tls_client.* = try std.crypto.tls.Client.init(stream, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = client.ca_bundle },
        });
        tls_client.allow_truncation_attacks = true;
        node.data.tls_client = tls_client;
    }
    client.connection_pool.addUsed(node);
    return &node.data;
}

fn classifyHttpError(err: anyerror, timed_out: bool) anyerror {
    if (timed_out) return error.Timeout;
    return switch (err) {
        error.Timeout, error.ConnectionTimedOut, error.WouldBlock => error.Timeout,
        error.StreamTooLong, error.HttpHeadersOversize, error.MessageTooLong => error.MessageTooBig,
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => err,
        error.CompressionUnsupported,
        error.DecompressionFailure,
        error.InvalidTrailers,
        error.InvalidContentLength,
        error.UnsupportedTransferEncoding,
        error.HttpChunkInvalid,
        => error.InvalidResponse,
        else => error.TransportFailure,
    };
}

fn replaceOwnedBytes(allocator: Allocator, destination: *?[]u8, source: ?[]const u8) !void {
    // The source may alias destination.*, so it must be copied before the old
    // allocation is released. A failed copy leaves destination unchanged.
    const replacement: ?[]u8 = if (source) |bytes| try allocator.dupe(u8, bytes) else null;
    const old = destination.*;
    destination.* = replacement;
    if (old) |value| allocator.free(value);
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
        const source: ?[]const u8 = if (token.len == 0) null else token;
        try replaceOwnedBytes(self.allocator, &self.auth_token, source);
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
        const uri = std.Uri.parse(endpoint) catch return error.InvalidDeploymentUrl;
        var deadline = try Deadline.init(http_deadline_ms);
        try deadline.start();
        const connection = connectHttpUntil(&self.http, self.allocator, uri, &deadline) catch |err| {
            const classified = classifyHttpError(err, deadline.timedOut());
            deadline.finish();
            return classified;
        };
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var request = self.http.open(.POST, uri, .{
            .connection = connection,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .server_header_buffer = &server_header_buffer,
            .headers = request_headers,
            .extra_headers = &headers,
        }) catch |err| {
            const classified = classifyHttpError(err, deadline.timedOut());
            deadline.finish();
            connection.closing = true;
            self.http.connection_pool.release(self.allocator, connection);
            return classified;
        };
        defer {
            // Stop the watchdog before Request.deinit can close and recycle
            // the descriptor. This prevents a late deadline from touching an
            // unrelated fd that happens to reuse the same integer.
            deadline.finish();
            request.deinit();
        }
        request.transfer_encoding = .{ .content_length = payload.len };
        request.send() catch |err| return classifyHttpError(err, deadline.timedOut());
        request.writeAll(payload) catch |err| return classifyHttpError(err, deadline.timedOut());
        request.finish() catch |err| return classifyHttpError(err, deadline.timedOut());
        request.wait() catch |err| return classifyHttpError(err, deadline.timedOut());
        if (request.response.status != .ok) return error.InvalidResponse;
        if (request.response.content_length) |content_length| {
            if (content_length > max_http_body) return error.MessageTooBig;
        }
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const amount = request.read(&buffer) catch |err| return classifyHttpError(err, deadline.timedOut());
            if (amount == 0) break;
            if (amount > max_http_body - response_body.items.len) return error.MessageTooBig;
            try response_body.appendSlice(buffer[0..amount]);
        }
        if (deadline.timedOut()) return error.Timeout;

        const parsed = std.json.parseFromSlice(JsonValue, allocator, response_body.items, .{}) catch return error.InvalidResponse;
        const response = try httpObject(parsed.value);
        const status = try httpString(response.get("status") orelse return error.InvalidResponse);
        if (!std.mem.eql(u8, status, "success") and !std.mem.eql(u8, status, "error")) return error.InvalidResponse;

        const logs: JsonValue = if (response.get("logLines")) |value| blk: {
            try validateHttpLogLines(value);
            break :blk value;
        } else .{ .array = std.json.Array.init(allocator) };
        if (std.mem.eql(u8, status, "error")) {
            // A failure envelope without a string `errorMessage` is not a
            // Convex function failure we can report; inventing a message would
            // turn a broken peer into a plausible FunctionError. Report the
            // protocol violation instead and let the caller retry.
            const message = try httpString(response.get("errorMessage") orelse return error.InvalidResponse);
            return .{
                .logs = logs,
                .function_error = .{
                    .message = message,
                    .data = response.get("errorData"),
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
    /// Set before `finishLive` takes the output lock so a relay that is part
    /// way through a record can observe the pending close without that lock.
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when a record was abandoned after its first byte reached the
    /// controller. The controller's last NDJSON line is then truncated, so no
    /// later event may be appended to it: the stream is terminal and every
    /// further send fails instead of corrupting it.
    poisoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next_generation: u64 = 1,
    test_pause_after_dequeue: ?*DeliveryPause = null,

    const QueuedEvent = struct {
        subscription_id: []u8,
        token: *DeliveryToken,
        /// The complete NDJSON record: the encoded event and the newline that
        /// terminates it. They are one logical unit, reserved together and
        /// written together, so a delivery can never leave a JSON line without
        /// its terminator while a later event follows.
        record: []u8,
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
        self.finishLive();
        self.queue.deinit();
    }

    /// Stop the Live relay under the same ordering lock used by ordinary
    /// adapter responses. Once this returns, no queued or in-flight
    /// subscription can be written after a later terminal `closed` record.
    pub fn finishLive(self: *Output) void {
        // Announce the close before contending for the output lock. A relay
        // that already committed bytes of a record still keeps its offset and
        // finishes that record, but only inside a bounded grace period, so a
        // peer that has stopped reading cannot hold the output lock and stall
        // this close forever.
        self.closing.store(true, .release);
        self.write_mutex.lock();
        self.mutex.lock();
        self.stopping = true;
        while (self.queue.items.len != 0) self.completeEventLocked(self.queue.orderedRemove(0));
        self.condition.broadcast();
        self.mutex.unlock();
        self.write_mutex.unlock();
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
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

    /// Build the complete NDJSON record for an encoded event. The newline is
    /// part of the record rather than a second write, so one deadline and one
    /// commit flag cover the whole line.
    fn recordAlloc(allocator: Allocator, encoded: []const u8) ![]u8 {
        const record = try allocator.alloc(u8, encoded.len + 1);
        @memcpy(record[0..encoded.len], encoded);
        record[encoded.len] = '\n';
        return record;
    }

    /// Decide what a failed write means for the stream. Nothing committed is
    /// recoverable: the controller never saw a partial line. Anything else
    /// truncated the current line, so the stream becomes terminal and every
    /// later event is refused instead of being appended to that line.
    fn abandonRecord(self: *Output, committed: bool, err: anyerror) anyerror {
        if (!committed) return err;
        self.poisoned.store(true, .release);
        return error.StreamTerminal;
    }

    pub fn send(self: *Output, allocator: Allocator, value: JsonValue) !void {
        const encoded = try std.json.stringifyAlloc(allocator, value, .{});
        defer allocator.free(encoded);
        if (encoded.len > max_adapter_event_bytes) return error.MessageTooBig;
        const record = try recordAlloc(allocator, encoded);
        defer allocator.free(record);
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.poisoned.load(.acquire)) return error.StreamTerminal;
        try self.writeRecordUnlocked(record);
    }

    /// Queue a Live event instead of letting the socket owner write into an
    /// arbitrary pipe.  The queue deliberately drops the oldest update when
    /// the controller is stopped: it retains the newest state, stays below
    /// both its 16-event and 8 MiB budgets, and never lets memory grow with a
    /// peer that has stopped reading.
    pub fn enqueueSubscription(self: *Output, subscription_id: []const u8, token: *DeliveryToken, value: JsonValue) !void {
        if (self.poisoned.load(.acquire)) return error.StreamTerminal;
        const encoded = try std.json.stringifyAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        if (encoded.len > max_adapter_event_bytes) return error.MessageTooBig;
        const record = try recordAlloc(self.allocator, encoded);
        errdefer self.allocator.free(record);
        token.retain();
        errdefer token.release(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping) return error.Closed;
        while (self.reserved_count >= max_live_queue_events or self.reserved_bytes + record.len > max_live_queue_bytes) {
            if (self.queue.items.len == 0) return error.MessageTooBig;
            const oldest = self.queue.orderedRemove(0);
            self.completeEventLocked(oldest);
        }
        try self.startLocked();
        try self.queue.append(.{
            .subscription_id = try self.allocator.dupe(u8, subscription_id),
            .token = token,
            .record = record,
        });
        self.reserved_count += 1;
        self.reserved_bytes += record.len;
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
            const delivery: ?anyerror = if (event.token.valid.load(.acquire)) blk: {
                self.writeLiveRecordUnlocked(event) catch |err| break :blk err;
                break :blk null;
            } else null;
            self.write_mutex.unlock();
            // The event's reservation is released exactly once here, whether it
            // was written, revoked, or abandoned part way through.
            self.completeEvent(event);
            // An abandoned record truncated the controller's last line, so this
            // relay must stop rather than append the next queued event to it.
            if (delivery) |err| {
                if (err == error.StreamTerminal) {
                    self.discardQueue();
                    return;
                }
            }
        }
    }

    /// Drop every queued event after the stream has become terminal, releasing
    /// each reservation exactly once, and refuse further deliveries.
    fn discardQueue(self: *Output) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        while (self.queue.items.len != 0) self.completeEventLocked(self.queue.orderedRemove(0));
        self.condition.broadcast();
    }

    /// A Live event is one NDJSON record: its JSON text and the newline that
    /// terminates it. Before its first byte reaches the controller, generation
    /// revocation may still drop it. After that first byte the record must be
    /// finished, because starting another event at that point would corrupt the
    /// controller's stream; if it cannot be finished inside the close grace the
    /// stream is abandoned as terminal instead.
    fn writeLiveRecordUnlocked(self: *Output, event: QueuedEvent) !void {
        if (self.fd) |descriptor| return self.writeLiveRecordFd(descriptor, event);
        try self.writer.writeAll(event.record);
    }

    fn writeLiveRecordFd(self: *Output, descriptor: std.posix.fd_t, event: QueuedEvent) !void {
        var written: usize = 0;
        var committed = false;
        // One cumulative grace for the whole record, so a peer that accepts the
        // JSON text but not its newline cannot earn a second grace period.
        var grace_deadline: ?i64 = null;
        while (written < event.record.len) {
            self.mutex.lock();
            const stopping = self.stopping;
            self.mutex.unlock();
            if (stopping) return self.abandonRecord(committed, error.Closed);
            if (!committed and !event.token.valid.load(.acquire)) return error.Revoked;
            // A draining peer finishes the record well inside the grace
            // period. A peer that never drains is abandoned instead of
            // holding the output lock against a pending close.
            if (self.closing.load(.acquire)) {
                const now = std.time.milliTimestamp();
                if (grace_deadline) |limit| {
                    if (now >= limit) return self.abandonRecord(committed, error.Closed);
                } else grace_deadline = now + close_grace_ms;
            }

            var poll_fds = [_]std.posix.pollfd{.{
                .fd = descriptor,
                .events = std.posix.POLL.OUT,
                .revents = 0,
            }};
            if (try std.posix.poll(&poll_fds, socket_poll_ms) == 0) continue;
            const amount = (if (self.fd_kind == .socket)
                std.posix.send(descriptor, event.record[written..], std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL)
            else
                std.posix.write(descriptor, event.record[written..])) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return self.abandonRecord(committed, err),
            };
            if (amount == 0) return self.abandonRecord(committed, error.Closed);
            committed = true;
            written += amount;
        }
    }

    /// Ordinary adapter responses share the same rule: one record, one
    /// cumulative deadline, and a partial write makes the stream terminal.
    fn writeRecordUnlocked(self: *Output, record: []const u8) !void {
        if (self.fd) |descriptor| {
            var written: usize = 0;
            var committed = false;
            const limit = std.time.milliTimestamp() + @as(i64, output_deadline_ms);
            while (written < record.len) {
                const remaining = limit - std.time.milliTimestamp();
                if (remaining <= 0) return self.abandonRecord(committed, error.Timeout);
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = descriptor,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                const polled = try std.posix.poll(&poll_fds, @intCast(@min(remaining, socket_poll_ms)));
                if (polled == 0) continue;
                const amount = (if (self.fd_kind == .socket)
                    std.posix.send(descriptor, record[written..], std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL)
                else
                    std.posix.write(descriptor, record[written..])) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return self.abandonRecord(committed, err),
                };
                if (amount == 0) return self.abandonRecord(committed, error.Closed);
                committed = true;
                written += amount;
            }
            return;
        }
        try self.writer.writeAll(record);
    }

    fn completeEvent(self: *Output, event: QueuedEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.completeEventLocked(event);
        self.condition.broadcast();
    }

    fn completeEventLocked(self: *Output, event: QueuedEvent) void {
        self.reserved_count -= 1;
        self.reserved_bytes -= event.record.len;
        self.allocator.free(event.subscription_id);
        self.allocator.free(event.record);
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

const CloseOutputContext = struct {
    output: *Output,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *CloseOutputContext) void {
        self.started.store(true, .release);
        self.output.finishLive();
        var object = std.json.ObjectMap.init(std.testing.allocator);
        object.put("id", .{ .string = "close" }) catch {
            self.failed.store(true, .release);
            return;
        };
        object.put("type", .{ .string = "closed" }) catch {
            object.deinit();
            self.failed.store(true, .release);
            return;
        };
        defer object.deinit();
        self.output.send(std.testing.allocator, .{ .object = object }) catch self.failed.store(true, .release);
    }
};

test "terminal close drains a paused revoked relay before publishing closed" {
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    // Every exit path must release the paused worker before `output.deinit`
    // tries to join it, including one taken by a failing assertion below.
    defer pause.releaseWriter();
    const token = try output.newDeliveryToken();
    var event = std.json.ObjectMap.init(std.testing.allocator);
    defer event.deinit();
    try event.put("type", .{ .string = "subscription" });
    try event.put("subscriptionId", .{ .string = "old" });
    try event.put("value", .{ .integer = 1 });
    try output.enqueueSubscription("old", token, .{ .object = event });
    try pause.waitUntilDequeued(fixture_rendezvous_ns);

    // Client.close revokes every active token before Adapter.handle joins the
    // relay. Reproduce that exact barrier with the worker paused after dequeue.
    output.revokeDeliveryToken(token);
    var context = CloseOutputContext{ .output = &output };
    const thread = try std.Thread.spawn(.{}, CloseOutputContext.run, .{&context});
    // The closing thread points at `context` and `output` on this frame, so it
    // is released and joined before the rendezvous result is propagated. A
    // timeout that returned early here would leave it writing into a dead
    // stack frame rather than reporting itself.
    const started = waitForFlag(&context.started, fixture_rendezvous_ns);
    pause.releaseWriter();
    thread.join();
    try started;
    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expectEqualStrings("{\"id\":\"close\",\"type\":\"closed\"}\n", bytes.items);
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
        // The in-process mailbox honours the same per-event ceiling and the
        // same byte budget as the adapter relay, so a near-maximum Convex
        // value reaches the example instead of being rejected here.
        if (encoded.len > max_adapter_event_bytes) {
            self.allocator.free(encoded);
            return error.MessageTooBig;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.values.items.len >= max_live_queue_events or self.bytes + encoded.len > max_live_queue_bytes) {
            if (self.values.items.len == 0) break;
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

const StateVersion = struct {
    query_set: u32 = 0,
    identity: u32 = 0,
    timestamp: [8]u8 = [_]u8{0} ** 8,

    fn eql(left: StateVersion, right: StateVersion) bool {
        return left.query_set == right.query_set and
            left.identity == right.identity and
            std.mem.eql(u8, &left.timestamp, &right.timestamp);
    }
};

fn protocolStateVersion(value: JsonValue) !StateVersion {
    const object = try protocolObject(value);
    return .{
        .query_set = try protocolU32(object.get("querySet") orelse return error.ProtocolFailure),
        .identity = try protocolU32(object.get("identity") orelse return error.ProtocolFailure),
        .timestamp = try decodeTimestamp(try protocolString(object.get("ts") orelse return error.ProtocolFailure)),
    };
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
    /// The bring-up deadline of the owner's current connection attempt, or
    /// null when the owner is not connecting. It is published and cleared
    /// under this mutex, and `close` cancels through it, so a control command
    /// never waits out a peer that accepted a socket and then went silent.
    connect_deadline: ?*Deadline = null,
    /// The interrupt channel for the owner's current established connection,
    /// or null when no connection is up. Unlike `connect_deadline` this
    /// carries no timeout of its own — readWebSocket's own frame deadline
    /// still bounds a stalled peer. `submit` cancels it for remove,
    /// disconnect, and stop so those commands do not ride out a peer that is
    /// mid-frame and stalled on an already-established socket: cancelling
    /// only shuts the descriptor down, and the owner's next read already
    /// turns that into the ordinary close-and-reconnect recovery path.
    read_interrupt: ?*Deadline = null,

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
        // A close must not wait for an in-flight bring-up. Cancelling the
        // deadline expires it now, which shuts the attempted socket down and
        // returns the owner to this queue. Other commands leave a healthy
        // attempt alone; they are already bounded by that same deadline.
        if (command.kind == .stop) {
            if (self.connect_deadline) |deadline| deadline.cancel();
        }
        // Remove, debugDisconnect, and stop must not wait out a peer that is
        // mid-frame and stalled on an already-established connection. Add
        // only ever writes over the existing socket once serviceCommands
        // reaches it, so it stays behind the normal draining order instead
        // of forcing an otherwise-unnecessary reconnect.
        if (command.kind == .remove or command.kind == .disconnect or command.kind == .stop) {
            if (self.read_interrupt) |deadline| deadline.cancel();
        }
        self.condition.signal();
        while (!command.done) self.condition.wait(&self.mutex);
        const result = command.result;
        self.mutex.unlock();
        if (result) |err| return err;
    }

    /// Publish the owner's current bring-up deadline, or clear it. Both the
    /// publish and the cancel happen under this mutex, so a cancelling thread
    /// can never touch a deadline whose owning scope has already returned.
    fn publishConnectDeadline(self: *LiveManager, deadline: ?*Deadline) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connect_deadline = deadline;
        if (deadline) |pending| {
            for (self.commands.items) |command| {
                if (command.kind == .stop) pending.cancel();
            }
        }
    }

    /// Publish the owner's per-connection read-interrupt channel, or clear
    /// it. `submit` cancels a live one for remove, debugDisconnect, and stop
    /// so those commands can shut the socket down instead of waiting out an
    /// in-progress frame read from a peer that is mid-frame and stalled.
    fn publishReadInterrupt(self: *LiveManager, deadline: ?*Deadline) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_interrupt = deadline;
    }

    /// Back off after a failed connection without stranding the owner: a
    /// command queued during the wait wakes it immediately.
    fn waitForRetry(self: *LiveManager, delay_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.commands.items.len != 0) return;
        self.condition.timedWait(&self.mutex, delay_ms * std.time.ns_per_ms) catch {};
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
            owner.serviceCommands() catch |err| self.failPending(err);
            if (self.stopping) break;
            owner.readOne() catch |err| {
                if (!owner.failure_published) {
                    owner.publishOwnerError(err);
                    owner.failure_published = true;
                }
                owner.closeConnection(@errorName(err));
                self.waitForRetry(owner.retry_delay_ms);
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
    remote_version: StateVersion = .{},
    next_query_id: u32 = 0,
    connection_count: u32 = 0,
    last_close_reason: []const u8 = "InitialConnect",
    max_timestamp: ?[8]u8 = null,
    generation: u64 = 0,
    retry_delay_ms: u64 = 10,
    failure_published: bool = false,
    /// The interrupt channel published to the manager while `socket` is up.
    /// It never runs its own watchdog thread; `submit` cancels it directly
    /// to shut the socket down out from under a stalled read.
    read_watch: ?Deadline = null,

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

        // One absolute deadline covers the whole bring-up: the name lookup,
        // the TCP connect, the TLS handshake, the 101 upgrade, the first
        // Connect frame, and the replayed Add frames. `connectHttpUntil`
        // registers the socket with it, so every one of those steps is
        // interruptible, and `close` can expire it early rather than letting a
        // silent peer hold the sole owner. Each individual frame below still
        // carries its own tighter write deadline.
        var deadline = try Deadline.init(connect_deadline_ms);
        try deadline.start();
        self.manager.publishConnectDeadline(&deadline);
        defer {
            self.manager.publishConnectDeadline(null);
            deadline.finish();
        }
        const conn = connectHttpUntil(&self.manager.client.http, self.manager.allocator, uri, &deadline) catch |err| {
            if (deadline.timedOut() or err == error.Timeout) return error.LiveConnectTimeout;
            return if (err == error.InvalidResponse) error.LiveConnectInvalidResponse else err;
        };
        errdefer {
            // Retire the watchdog before the descriptor is closed and recycled,
            // then release. Once self.socket points at conn, a later send
            // failure still belongs to this setup scope, so clear the owner
            // reference first and the outer recovery path cannot release twice.
            deadline.finish();
            if (self.socket == conn) self.socket = null;
            conn.closing = true;
            self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
        }
        configureSocketDeadlines(conn) catch |err| {
            return if (err == error.InvalidResponse) error.LiveSocketInvalidResponse else err;
        };
        const path = try uri.path.toRawMaybeAlloc(uri_arena.allocator());
        websocketHandshake(self.manager.allocator, conn, host_raw, port, path) catch |err| {
            if (deadline.timedOut() or err == error.Timeout) return error.LiveHandshakeTimeout;
            return if (err == error.InvalidResponse) error.LiveHandshakeInvalidResponse else err;
        };
        if (deadline.timedOut()) return error.Timeout;
        self.retry_delay_ms = 10;
        self.socket = conn;
        self.generation += 1;
        self.query_set_version = 0;
        self.remote_version = .{};
        self.sendConnect() catch |err| {
            if (deadline.timedOut() or err == error.Timeout) return error.LiveConnectFrameTimeout;
            return if (err == error.InvalidResponse) error.LiveConnectFrameInvalidResponse else err;
        };
        if (self.connection_count < std.math.maxInt(u32)) self.connection_count += 1;
        for (self.manager.active.items) |*query| {
            query.awaiting_rehydration = query.last_success;
            self.sendModify(.{query.id}, true) catch |err| {
                if (deadline.timedOut() or err == error.Timeout) return error.LiveAddTimeout;
                return if (err == error.InvalidResponse) error.LiveAddInvalidResponse else err;
            };
        }
        // The bring-up as a whole must fit the deadline, not merely each of
        // its steps, so a peer that keeps every individual step just inside
        // its own limit still loses the connection here.
        if (deadline.timedOut()) return error.Timeout;
        // Publish this connection's read-interrupt channel only once bring-up
        // has fully succeeded: every earlier error path above still runs the
        // errdefer that releases `conn`, and this deadline must never outlive
        // (or shut down) a socket that scope has already handed back.
        self.read_watch = try Deadline.init(frame_deadline_ms);
        try self.read_watch.?.setFd(self.socket.?.stream.handle);
        self.manager.publishReadInterrupt(&self.read_watch.?);
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
        const message = readWebSocket(self.socket.?, self.manager.allocator) catch |err| {
            if (err == error.Timeout) return error.LiveFrameTimeout;
            return if (err == error.InvalidResponse) error.LiveFrameInvalidResponse else err;
        };
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
        const start = try protocolStateVersion(object.get("startVersion") orelse return error.ProtocolFailure);
        const end = try protocolStateVersion(object.get("endVersion") orelse return error.ProtocolFailure);
        if (!StateVersion.eql(start, self.remote_version)) return error.ProtocolFailure;
        if (end.query_set < start.query_set or end.query_set > self.query_set_version) return error.ProtocolFailure;
        if (end.identity < start.identity or compareTimestamp(end.timestamp, start.timestamp) < 0) return error.ProtocolFailure;
        const modifications = try protocolArray(object.get("modifications") orelse return error.ProtocolFailure);

        const PendingModification = struct {
            id: u32,
            object: std.json.ObjectMap,

            fn lessThan(_: void, left: @This(), right: @This()) bool {
                return left.id < right.id;
            }
        };
        var pending = std.ArrayList(PendingModification).init(self.manager.allocator);
        defer pending.deinit();

        // Validate the entire server transition before changing any owner
        // state. Repeated changes for one query collapse to the last server
        // change, then apply in query-id order so one transition has one
        // deterministic final result per query.
        for (modifications.items) |modification_value| {
            const modification = try protocolObject(modification_value);
            const id = try protocolU32(modification.get("queryId") orelse return error.ProtocolFailure);
            const modification_type = try protocolString(modification.get("type") orelse return error.ProtocolFailure);
            if (std.mem.eql(u8, modification_type, "QueryUpdated")) {
                _ = modification.get("value") orelse return error.ProtocolFailure;
                if (modification.get("logLines")) |logs| try validateProtocolLogLines(logs);
            } else if (std.mem.eql(u8, modification_type, "QueryFailed")) {
                if (modification.get("errorMessage")) |message| _ = try protocolString(message);
                if (modification.get("logLines")) |logs| try validateProtocolLogLines(logs);
            } else if (!std.mem.eql(u8, modification_type, "QueryRemoved")) return error.ProtocolFailure;
            for (pending.items) |*prior| {
                if (prior.id == id) {
                    prior.object = modification;
                    break;
                }
            } else try pending.append(.{ .id = id, .object = modification });
        }
        std.mem.sort(PendingModification, pending.items, {}, PendingModification.lessThan);

        self.remote_version = end;
        self.retry_delay_ms = 10;
        self.failure_published = false;
        if (self.max_timestamp == null or compareTimestamp(end.timestamp, self.max_timestamp.?) > 0) self.max_timestamp = end.timestamp;
        for (pending.items) |pending_modification| {
            const modification = pending_modification.object;
            const id = pending_modification.id;
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
                try replaceOwnedBytes(self.manager.allocator, &query.last_value, encoded);
                query.last_success = true;
                try self.emitSubscription(query, value, null, modification.get("logLines"));
            } else if (std.mem.eql(u8, modification_type, "QueryFailed")) {
                query.awaiting_rehydration = false;
                query.last_success = false;
                var error_value: JsonValue = .{ .object = blk: {
                    var error_object = std.json.ObjectMap.init(self.manager.allocator);
                    try error_object.put("name", .{ .string = "FunctionError" });
                    try error_object.put("message", .{ .string = if (modification.get("errorMessage")) |message| try protocolString(message) else "query failed" });
                    if (modification.get("errorData")) |error_data| try error_object.put("data", error_data);
                    break :blk error_object;
                } };
                defer deinitValue(&error_value, self.manager.allocator);
                try self.emitSubscription(query, null, error_value, modification.get("logLines"));
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
            self.emitSubscription(query, null, error_value, null) catch {};
        }
    }

    fn emitSubscription(self: *LiveOwner, query: *ActiveQuery, value: ?JsonValue, error_value: ?JsonValue, logs: ?JsonValue) !void {
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
        if (logs) |log_lines| try object.put("logs", log_lines);
        try self.manager.output.enqueueSubscription(query.subscription_id, query.delivery_token, .{ .object = object });
        object.deinit();
    }

    fn closeConnection(self: *LiveOwner, reason: []const u8) void {
        // Retire the read-interrupt channel before the descriptor is closed
        // and recycled, exactly like the connect-phase watchdog below: once
        // this is unpublished and finished, a racing `submit` can no longer
        // reach it, so it can never shut down a socket this scope has
        // already released back to the pool and the process has reused.
        if (self.read_watch) |*watch| {
            self.manager.publishReadInterrupt(null);
            watch.finish();
            self.read_watch = null;
        }
        if (self.socket) |conn| {
            conn.closing = true;
            self.manager.client.http.connection_pool.release(self.manager.allocator, conn);
            self.socket = null;
        }
        self.last_close_reason = reason;
        self.query_set_version = 0;
        self.remote_version = .{};
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

fn writeWebSocket(conn: *std.http.Client.Connection, payload: []const u8, allocator: Allocator, opcode: enum { text, continuation, close, pong }) !void {
    if (payload.len > max_websocket_message) return error.MessageTooBig;
    var header: [14]u8 = undefined;
    header[0] = switch (opcode) {
        .text => 0x81,
        .continuation => 0x80,
        .close => 0x88,
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

    // One absolute deadline covers the whole frame. A socket send timeout
    // restarts every time the peer accepts a few bytes, so a peer that drains
    // a trickle could hold the sole Live owner indefinitely; expiring this
    // deadline shuts the socket down instead, and the owner abandons the
    // connection and returns to its command queue.
    var deadline = try Deadline.init(socket_write_deadline_ms);
    try deadline.start();
    defer deadline.finish();
    try deadline.setFd(conn.stream.handle);
    conn.writer().writeAll(header[0..header_len]) catch |err| return classifyWriteError(err, &deadline);
    conn.writer().writeAll(masked) catch |err| return classifyWriteError(err, &deadline);
    conn.flush() catch |err| return classifyWriteError(err, &deadline);
    // The watchdog may have shut the socket down after the last successful
    // write, so the frame only counts as sent if the deadline still holds.
    if (deadline.timedOut()) return error.Timeout;
}

fn classifyWriteError(err: anyerror, deadline: *Deadline) anyerror {
    if (deadline.timedOut()) return error.Timeout;
    return switch (err) {
        error.WouldBlock, error.ConnectionTimedOut => error.Timeout,
        else => err,
    };
}

fn socketReadable(conn: *std.http.Client.Connection, timeout_ms: u64) !bool {
    if (connectionHasBufferedCleartext(conn)) return true;
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = conn.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return try std.posix.poll(&poll_fds, @intCast(timeout_ms)) > 0;
}

/// `std.http.Client.Connection.peek` only exposes the HTTP connection buffer.
/// After the 101 upgrade, Zig's TLS client may also hold decrypted application
/// bytes in its own record buffer while the raw socket is no longer readable.
/// Polling only the descriptor would then sleep forever over already available
/// plaintext, so both buffers are part of the readiness decision.
fn connectionHasBufferedCleartext(conn: *std.http.Client.Connection) bool {
    if (conn.peek().len > 0) return true;
    if (conn.protocol != .tls) return false;
    return conn.tls_client.partial_cleartext_idx < conn.tls_client.partial_ciphertext_idx;
}

/// Read through the connection without erasing `WouldBlock`. Zig 0.14.1's
/// `std.http.Client.Connection.readvDirectTls` deliberately collapses an
/// underlying `WouldBlock` into `UnexpectedReadFailure`, which prevents a
/// bounded WebSocket reader from distinguishing a 250 ms socket tick from a
/// real TLS failure. Once the HTTP read buffer is empty, reading the pinned TLS
/// client directly preserves that distinction and still consumes its buffered
/// cleartext before touching the descriptor.
fn readConnection(conn: *std.http.Client.Connection, buffer: []u8) !usize {
    if (conn.peek().len > 0) return conn.read(buffer);
    if (conn.protocol == .tls) return conn.tls_client.read(conn.stream, buffer);
    return conn.stream.read(buffer);
}

fn readWebSocket(conn: *std.http.Client.Connection, allocator: Allocator) ![]u8 {
    const deadline = std.time.milliTimestamp() + frame_deadline_ms;
    var fragments = std.ArrayList(u8).init(allocator);
    errdefer fragments.deinit();
    var awaiting_continuation = false;

    while (true) {
        var header: [2]u8 = undefined;
        try readExactUntil(conn, &header, deadline);
        if (header[0] & 0x70 != 0) return error.ProtocolFailure;
        const fin = header[0] & 0x80 != 0;
        const opcode = header[0] & 0x0f;
        const masked = header[1] & 0x80 != 0;
        if (masked) return error.ProtocolFailure;
        const control = opcode & 0x08 != 0;
        if (control and (!fin or (header[1] & 0x7f) > 125)) return error.ProtocolFailure;
        if (control and opcode != 8 and opcode != 9 and opcode != 10) return error.ProtocolFailure;
        var length: u64 = header[1] & 0x7f;
        if (length == 126) {
            var bytes: [2]u8 = undefined;
            try readExactUntil(conn, &bytes, deadline);
            length = std.mem.readInt(u16, &bytes, .big);
            // RFC 6455 requires the minimal length encoding. Accepting a
            // padded form would let a peer describe the same frame two ways
            // and disagree with any strict intermediary about where the next
            // frame begins.
            if (length <= 125) return error.ProtocolFailure;
        } else if (length == 127) {
            var bytes: [8]u8 = undefined;
            try readExactUntil(conn, &bytes, deadline);
            length = std.mem.readInt(u64, &bytes, .big);
            if (length <= std.math.maxInt(u16)) return error.ProtocolFailure;
            // The most significant bit of a 64-bit length must be zero.
            if (length > std.math.maxInt(i64)) return error.ProtocolFailure;
        }
        if (length > max_websocket_message or fragments.items.len + length > max_websocket_message) return error.MessageTooBig;
        const payload = try allocator.alloc(u8, @intCast(length));
        defer allocator.free(payload);
        try readExactUntil(conn, payload, deadline);

        // WebSocket control frames may appear in the middle of a fragmented
        // UTF-8 message.  They are complete frames by definition and must not
        // reset the data-frame parser.
        if (opcode == 8) {
            if (payload.len == 1) return error.ProtocolFailure;
            if (payload.len >= 2) {
                const code = std.mem.readInt(u16, payload[0..2], .big);
                if (code < 1000 or code >= 5000 or code == 1004 or code == 1005 or code == 1006 or code == 1015 or (code >= 1016 and code < 3000)) return error.ProtocolFailure;
                if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.ProtocolFailure;
            }
            // A valid peer Close gets exactly one masked reply before the owner
            // retires the TCP connection. `writeWebSocket` gives the complete
            // reply one absolute deadline, so a peer that stops reading cannot
            // turn the close handshake into an unbounded owner stall.
            try writeWebSocket(conn, payload, allocator, .close);
            return error.WebSocketClosed;
        }
        if (opcode == 9) {
            try writeWebSocket(conn, payload, allocator, .pong);
            continue;
        }
        if (opcode == 10) {
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
        if (!connectionHasBufferedCleartext(conn)) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = conn.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const polled = try std.posix.poll(&poll_fds, @intCast(@min(remaining, socket_poll_ms)));
            if (polled == 0) continue;
        }
        const amount = readConnection(conn, buffer[used..]) catch |err| switch (err) {
            // SO_RCVTIMEO deliberately wakes the owner every 250 ms. Preserve
            // the partially decoded frame and keep checking the one absolute
            // frame deadline instead of treating that wake-up as corruption.
            error.WouldBlock, error.ConnectionTimedOut => continue,
            else => return err,
        };
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
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("HTTP fixture accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        _ = readHttpRequest(connection.stream, &request) catch @panic("HTTP request read failed");
        connection.stream.writer().print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.body.len, self.body }) catch @panic("HTTP response write failed");
    }
};

/// Read one whole request: the header block, and then the body its
/// `Content-Length` declares. Draining the body is not politeness. A fixture
/// that replies and closes while the client's body is still queued makes the
/// kernel answer with RST, which discards the reply the client has not read
/// yet and turns a deliberate protocol fixture into a random transport
/// failure. The returned slice is the header block only.
fn readHttpRequest(stream: std.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    var header_end: ?usize = null;
    while (header_end == null) {
        if (used == buffer.len) return error.MessageTooBig;
        const amount = try stream.read(buffer[used..]);
        if (amount == 0) return error.EndOfStream;
        used += amount;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |end| header_end = end + 4;
    }
    const headers = buffer[0..header_end.?];
    var remaining = try declaredContentLength(headers);
    // Bytes of the body that already arrived with the header block.
    const carried = used - header_end.?;
    remaining -= @min(remaining, carried);
    var discard: [4096]u8 = undefined;
    while (remaining > 0) {
        const amount = try stream.read(discard[0..@min(discard.len, remaining)]);
        if (amount == 0) return error.EndOfStream;
        remaining -= amount;
    }
    return headers;
}

fn declaredContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..separator], " \t"), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[separator + 1 ..], " \t"), 10) catch error.InvalidResponse;
    }
    return 0;
}

/// Accept one connection, but never wait forever for a client that decided not
/// to connect. A fixture thread blocked in `accept` cannot be joined, so an
/// unrelated assertion failure would hang the whole test binary instead of
/// reporting itself.
fn acceptWithin(listener: *std.net.Server, timeout_ms: i32) !std.net.Server.Connection {
    var poll_fds = [_]std.posix.pollfd{.{ .fd = listener.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&poll_fds, timeout_ms) == 0) return error.Timeout;
    return listener.accept();
}

/// Long enough that no healthy client misses it, short enough that a stranded
/// fixture reports a failure instead of hanging the run.
const fixture_accept_timeout_ms = 15_000;

/// How long a test waits for another thread to reach a rendezvous. This bounds
/// a hang; it is never the property under test, so it is generous enough that
/// a loaded, emulated builder cannot turn CPU contention into a false failure.
/// The barrier assertions that follow each wait are what actually decide
/// whether the owner behaved correctly.
const fixture_rendezvous_ns = 15 * std.time.ns_per_s;

/// Wait, bounded, for every detached lookup to have dropped its reference.
/// Earlier tests may still have a lookup in flight, so this polls rather than
/// reading once; a lookup that never releases keeps the count above zero and
/// fails here instead of corrupting a later test's allocator.
fn expectNoLiveResolutions(timeout_ns: u64) !void {
    const limit = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
    while (live_resolutions.load(.acquire) != 0) {
        if (std.time.nanoTimestamp() >= limit) return error.ResolutionStillLive;
        std.time.sleep(5 * std.time.ns_per_ms);
    }
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
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("hosted boundary accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        const headers = readHttpRequest(connection.stream, &request) catch @panic("hosted boundary request failed");
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
            const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("auth lifecycle accept failed");
            defer connection.stream.close();
            var request: [8192]u8 = undefined;
            const headers = readHttpRequest(connection.stream, &request) catch @panic("auth lifecycle request failed");
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

test "setAuth preserves the current token on allocation failure and accepts its stored slice" {
    var client = try Client.init(std.testing.allocator, "http://127.0.0.1:9");
    defer client.deinit();
    try client.setAuth("token-that-must-survive");

    const original = client.auth_token.?;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    client.allocator = failing_allocator.allocator();
    // Restore the allocator before Client.deinit even if an assertion fails.
    // The token itself was allocated by std.testing.allocator.
    defer client.allocator = std.testing.allocator;

    try std.testing.expectError(error.OutOfMemory, client.setAuth("replacement"));
    try std.testing.expectEqual(original.ptr, client.auth_token.?.ptr);
    try std.testing.expectEqualStrings("token-that-must-survive", client.auth_token.?);

    client.allocator = std.testing.allocator;
    const stored_token = client.auth_token.?;
    try client.setAuth(stored_token);
    try std.testing.expectEqualStrings("token-that-must-survive", client.auth_token.?);

    try client.setAuth("");
    try std.testing.expect(client.auth_token == null);
}

test "invalid bearer token is sent and clearing it restores anonymous calls" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = AuthLifecycleFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, AuthLifecycleFixture.run, .{&fixture});
    // Joined by defer so a failing assertion above reports itself instead of
    // abandoning a live thread that still points at this stack frame.
    defer thread.join();
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

/// Peer replies that must never become a value or an invented function
/// failure. Each one is followed by a healthy reply in the test below, so the
/// client has to prove it stays usable after rejecting them.
const HttpRejectCase = enum {
    oversized_chunked,
    non_2xx_success_body,
    malformed_json,
    missing_error_message,
};

const HttpRejectFixture = struct {
    listener: *std.net.Server,

    fn run(self: *HttpRejectFixture) void {
        for ([_]HttpRejectCase{ .oversized_chunked, .non_2xx_success_body, .malformed_json, .missing_error_message }) |reply| {
            self.serve(reply);
        }
        // The healthy reply that proves each rejection above was recoverable.
        const body = "{\"status\":\"success\",\"value\":{\"count\":5}}";
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("reject fixture recovery accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        _ = readHttpRequest(connection.stream, &request) catch @panic("reject fixture recovery request failed");
        connection.stream.writer().print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        ) catch @panic("reject fixture recovery response failed");
    }

    fn serve(self: *HttpRejectFixture, reply: HttpRejectCase) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("reject fixture accept failed");
        defer connection.stream.close();
        var request: [8192]u8 = undefined;
        _ = readHttpRequest(connection.stream, &request) catch @panic("reject fixture request failed");
        switch (reply) {
            .oversized_chunked => {
                // Chunked replies declare no length up front, so only the
                // running body limit can stop this one. The client closes the
                // connection as soon as it does, which fails the writes below;
                // that is the expected end of this exchange.
                connection.stream.writer().writeAll(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                ) catch return;
                const chunk = std.heap.page_allocator.alloc(u8, 512 * 1024) catch @panic("oversize chunk allocation failed");
                defer std.heap.page_allocator.free(chunk);
                @memset(chunk, 'x');
                var written: usize = 0;
                while (written <= max_http_body) : (written += chunk.len) {
                    connection.stream.writer().print("{x}\r\n", .{chunk.len}) catch return;
                    connection.stream.writer().writeAll(chunk) catch return;
                    connection.stream.writer().writeAll("\r\n") catch return;
                }
                connection.stream.writer().writeAll("0\r\n\r\n") catch return;
            },
            .non_2xx_success_body => {
                // A success-shaped body behind a failing status must not be
                // decoded as a value.
                const body = "{\"status\":\"success\",\"value\":{\"count\":99}}";
                connection.stream.writer().print(
                    "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch @panic("non-2xx response failed");
            },
            .malformed_json => {
                const body = "{\"status\":\"success\",\"value\":";
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch @panic("malformed JSON response failed");
            },
            .missing_error_message => {
                const body = "{\"status\":\"error\",\"errorData\":{\"code\":\"NO_MESSAGE\"},\"logLines\":[]}";
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch @panic("missing errorMessage response failed");
            },
        }
    }
};

test "rejected HTTP replies stay protocol failures and the client recovers" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = HttpRejectFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, HttpRejectFixture.run, .{&fixture});
    // Joined by defer so a failing assertion above reports itself instead of
    // abandoning a live thread that still points at this stack frame.
    defer thread.join();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = JsonValue{ .object = std.json.ObjectMap.init(arena.allocator()) };

    // A chunked body without a declared length obeys the same body limit.
    try std.testing.expectError(error.MessageTooBig, client.call(arena.allocator(), "query", "demo:state", args));
    try std.testing.expectError(error.InvalidResponse, client.call(arena.allocator(), "query", "demo:state", args));
    try std.testing.expectError(error.InvalidResponse, client.call(arena.allocator(), "query", "demo:state", args));
    // A failure envelope with no string errorMessage is a protocol violation,
    // never a FunctionError carrying a message this client invented.
    try std.testing.expectError(error.InvalidResponse, client.call(arena.allocator(), "query", "demo:state", args));

    const recovered = try client.call(arena.allocator(), "query", "demo:state", args);
    try std.testing.expect(recovered.function_error == null);
    try std.testing.expectEqual(@as(i64, 5), (try httpObject(recovered.value orelse return error.InvalidResponse)).get("count").?.integer);
}

test "a stalled name lookup expires on the HTTP deadline and a later call recovers" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = HttpFixture{ .listener = &listener, .body = "{\"status\":\"success\",\"value\":{\"count\":3}}" };
    const thread = try std.Thread.spawn(.{}, HttpFixture.run, .{&fixture});
    // Joined by defer so a failing assertion above reports itself instead of
    // abandoning a live thread that still points at this stack frame.
    defer thread.join();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = JsonValue{ .object = std.json.ObjectMap.init(arena.allocator()) };

    // A name lookup cannot be interrupted, so the call must return on its own
    // deadline while the lookup is still held open, not when it finally ends.
    var gate = ResolveGate{};
    test_resolve_gate = &gate;
    defer test_resolve_gate = null;
    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.Timeout, client.call(arena.allocator(), "query", "demo:state", args));
    const elapsed = std.time.milliTimestamp() - started;
    try std.testing.expect(elapsed >= http_deadline_ms - 300 and elapsed < http_deadline_ms + 1000);

    // The abandoned lookup owns its own box and whatever it produced, and it
    // frees both from the page allocator rather than from the caller's. The
    // census below is what proves the release actually happened: the testing
    // allocator cannot see it, and a lookup that merely stopped being waited
    // on would leave the count above zero forever.
    gate.release();
    try gate.waitUntilFinished(fixture_rendezvous_ns);
    test_resolve_gate = null;
    try expectNoLiveResolutions(fixture_rendezvous_ns);

    const recovered = try client.call(arena.allocator(), "query", "demo:state", args);
    try std.testing.expectEqual(@as(i64, 3), (try httpObject(recovered.value orelse return error.InvalidResponse)).get("count").?.integer);
}

const HttpDripFixture = struct {
    listener: *std.net.Server,

    fn run(self: *HttpDripFixture) void {
        var index: usize = 0;
        while (index < 3) : (index += 1) {
            const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("HTTP deadline fixture accept failed");
            defer connection.stream.close();
            var request: [8192]u8 = undefined;
            _ = readHttpRequest(connection.stream, &request) catch @panic("HTTP deadline request failed");
            if (index == 0) {
                const body = "{\"status\":\"success\",\"value\":{\"count\":1}}";
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{body.len},
                ) catch @panic("HTTP drip headers failed");
                for (body) |byte| {
                    connection.stream.writer().writeByte(byte) catch break;
                    std.time.sleep(250 * std.time.ns_per_ms);
                }
            } else if (index == 1) {
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{max_http_body + 1},
                ) catch @panic("HTTP oversize headers failed");
            } else {
                const body = "{\"status\":\"success\",\"value\":{\"count\":7}}";
                connection.stream.writer().print(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch @panic("HTTP recovery response failed");
            }
        }
    }
};

test "HTTP has one absolute drip deadline, preserves body limits, and later recovers" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = HttpDripFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, HttpDripFixture.run, .{&fixture});
    // Joined by defer so a failing assertion above reports itself instead of
    // abandoning a live thread that still points at this stack frame.
    defer thread.join();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = JsonValue{ .object = std.json.ObjectMap.init(arena.allocator()) };

    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.Timeout, client.call(arena.allocator(), "query", "demo:state", args));
    const elapsed = std.time.milliTimestamp() - started;
    try std.testing.expect(elapsed >= http_deadline_ms - 300 and elapsed < http_deadline_ms + 1000);
    try std.testing.expectError(error.MessageTooBig, client.call(arena.allocator(), "query", "demo:state", args));
    const recovered = try client.call(arena.allocator(), "query", "demo:state", args);
    try std.testing.expectEqual(@as(i64, 7), (try httpObject(recovered.value orelse return error.InvalidResponse)).get("count").?.integer);
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

test "real TLS exposes coalesced WebSocket plaintext without another socket edge" {
    const port_text = std.process.getEnvVarOwned(std.testing.allocator, "ZIG_TLS_FIXTURE_PORT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(port_text);
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://localhost:{d}/api/sync", .{port});
    defer std.testing.allocator.free(url);
    const uri = try std.Uri.parse(url);

    var http_client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer http_client.deinit();
    const ca_path = try std.process.getEnvVarOwned(std.testing.allocator, "ZIG_TLS_FIXTURE_CA");
    defer std.testing.allocator.free(ca_path);
    // Zig's certificate scanner intentionally uses only the platform trust
    // locations. Load this fixture's one-day CA directly, then suppress the
    // normal first-connect rescan so it is not immediately replaced.
    try http_client.ca_bundle.addCertsFromFilePathAbsolute(std.testing.allocator, ca_path);
    @atomicStore(bool, &http_client.next_https_rescan_certs, false, .release);
    var deadline = try Deadline.init(5000);
    try deadline.start();
    defer deadline.finish();
    const connection = try connectHttpUntil(&http_client, std.testing.allocator, uri, &deadline);
    defer {
        connection.closing = true;
        http_client.connection_pool.release(std.testing.allocator, connection);
    }
    try configureSocketDeadlines(connection);
    try websocketHandshake(std.testing.allocator, connection, "127.0.0.1", port, "/api/sync");

    // The fixture writes both frames in the same TLS application record. The
    // first one-byte handshake read therefore leaves plaintext inside Zig's
    // TLS client even after the raw descriptor has no new readability edge.
    try std.testing.expect(try socketReadable(connection, 1000));
    const first = try readWebSocket(connection, std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("one", first);
    try std.testing.expect(try socketReadable(connection, 1000));
    const second = try readWebSocket(connection, std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("two", second);
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
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("handshake fixture accept failed");
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

/// How much of the oversized frame the peer accepts before it stalls. A socket
/// send timeout would restart at this point; the frame's absolute deadline
/// must not, so the owner still abandons the write and services its commands.
const partial_drain_bytes = 32 * 1024;

const StoppedWriteFixture = struct {
    listener: *std.net.Server,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    advertised: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    drained: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *StoppedWriteFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("stopped-write fixture accept failed");
        defer connection.stream.close();
        testAcceptWebSocket(connection.stream) catch @panic("stopped-write handshake failed");
        const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("stopped-write Connect failed");
        std.heap.page_allocator.free(connect.payload);

        // Consume only the Add frame header. The kernel receive window then
        // fills while the owner writes the large payload, which exercises the
        // production frame deadline rather than a cooperative fake writer.
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

        // Accept a fixed prefix, then stop. The peer has made real progress,
        // so this distinguishes an absolute frame deadline from a per-write
        // socket timeout that a trickle of progress would keep resetting.
        var drained: u64 = 0;
        var prefix: [8 * 1024]u8 = undefined;
        while (drained < partial_drain_bytes) {
            const wanted = @min(prefix.len, partial_drain_bytes - drained);
            const amount = connection.stream.read(prefix[0..wanted]) catch break;
            if (amount == 0) break;
            drained += amount;
        }
        self.drained.store(drained, .release);
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
        try waitForFlag(&fixture.started, fixture_rendezvous_ns);

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
        try std.testing.expectEqual(@as(u64, partial_drain_bytes), fixture.drained.load(.acquire));
        try std.testing.expect(fixture.drained.load(.acquire) + fixture.received.load(.acquire) < fixture.advertised.load(.acquire));
        args.object.deinit();
        output.deinit();
        client.deinit();
    }
}

const ParserFixture = struct {
    listener: *std.net.Server,
    partial: bool,

    fn run(self: *ParserFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("parser fixture accept failed");
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

const InvalidFrameFixture = struct {
    listener: *std.net.Server,
    bytes: []const u8,

    fn run(self: *InvalidFrameFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("invalid-frame accept failed");
        defer connection.stream.close();
        connection.stream.writer().writeAll(self.bytes) catch @panic("invalid-frame write failed");
    }
};

test "WebSocket rejects RSV, non-minimal lengths, and malformed Close frames" {
    const malformed = [_][]const u8{
        &.{ 0xc1, 0x00 },
        &.{ 0x08, 0x00 },
        &.{ 0x88, 0x7e },
        &.{ 0x88, 0x01, 0x00 },
        &.{ 0x88, 0x02, 0x03, 0xe7 },
        // Close code 1005 is reserved and must never appear on the wire.
        &.{ 0x88, 0x02, 0x03, 0xed },
        // Close reason bytes must be valid UTF-8 even when the code is legal.
        &.{ 0x88, 0x04, 0x03, 0xe8, 0xff, 0xfe },
        // A two-byte length must not describe a payload that fits in seven
        // bits, and an eight-byte length must not describe one that fits in
        // sixteen; both leave a strict peer disagreeing about frame edges.
        &.{ 0x81, 0x7e, 0x00, 0x05, '{', '}', ' ', ' ', ' ' },
        &.{ 0x81, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 },
        // The most significant bit of a 64-bit length must be zero.
        &.{ 0x81, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    };
    for (malformed) |bytes| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = InvalidFrameFixture{ .listener = &listener, .bytes = bytes };
        const thread = try std.Thread.spawn(.{}, InvalidFrameFixture.run, .{&fixture});
        const stream = try std.net.tcpConnectToAddress(listener.listen_address);
        var connection = testPlainConnection(stream);
        try std.testing.expectError(error.ProtocolFailure, readWebSocket(&connection, std.testing.allocator));
        connection.stream.close();
        thread.join();
    }
}

fn testTimestamp(value: u64) [12]u8 {
    var decoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &decoded, value, .little);
    var encoded: [12]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &decoded);
    return encoded;
}

fn testSendTransition(stream: std.net.Stream, start_query_set: u32, end_query_set: u32, start_timestamp: u64, end_timestamp: u64, query_id: u32, count: u32) !void {
    const encoded_start_timestamp = testTimestamp(start_timestamp);
    const encoded_end_timestamp = testTimestamp(end_timestamp);
    var payload: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&payload, "{{\"type\":\"Transition\",\"startVersion\":{{\"querySet\":{d},\"identity\":0,\"ts\":\"{s}\"}},\"endVersion\":{{\"querySet\":{d},\"identity\":0,\"ts\":\"{s}\"}},\"modifications\":[{{\"type\":\"QueryUpdated\",\"queryId\":{d},\"value\":{{\"count\":{d}}},\"logLines\":[]}}]}}", .{ start_query_set, encoded_start_timestamp, end_query_set, encoded_end_timestamp, query_id, count });
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
        try std.testing.expect(StateVersion.eql(StateVersion{}, owner.remote_version));
    }
    var timestamp_two: [8]u8 = undefined;
    std.mem.writeInt(u64, &timestamp_two, 2, .little);
    owner.remote_version = .{ .query_set = 1, .identity = 2, .timestamp = timestamp_two };
    owner.query_set_version = 1;
    const expected = owner.remote_version;
    const mismatched = [_][]const u8{
        "{\"startVersion\":{\"querySet\":1,\"identity\":1,\"ts\":\"AgAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AQAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":1,\"ts\":\"AgAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":[]}",
        "{\"startVersion\":{\"querySet\":1,\"identity\":2,\"ts\":\"AgAAAAAAAAA=\"},\"endVersion\":{\"querySet\":2,\"identity\":2,\"ts\":\"AwAAAAAAAAA=\"},\"modifications\":[]}",
    };
    for (mismatched) |json| {
        var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.ProtocolFailure, owner.handleTransition(try protocolObject(parsed.value)));
        try std.testing.expect(StateVersion.eql(expected, owner.remote_version));
    }
}

fn testAppendActive(manager: *LiveManager, id: u32, subscription_id: []const u8) !void {
    try manager.active.append(.{
        .id = id,
        .subscription_id = try manager.allocator.dupe(u8, subscription_id),
        .path = try manager.allocator.dupe(u8, "demo:state"),
        .args = try manager.allocator.dupe(u8, "{}"),
        .delivery_token = try manager.output.newDeliveryToken(),
    });
}

test "ActiveQuery last_value replacement preserves ownership on failure and aliasing" {
    var query: ActiveQuery = undefined;
    query.last_value = try std.testing.allocator.dupe(u8, "cached-live-value");
    defer if (query.last_value) |value| std.testing.allocator.free(value);

    const original = query.last_value.?;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        replaceOwnedBytes(failing_allocator.allocator(), &query.last_value, "replacement"),
    );
    try std.testing.expectEqual(original.ptr, query.last_value.?.ptr);
    try std.testing.expectEqualStrings("cached-live-value", query.last_value.?);

    const stored_value = query.last_value.?;
    try replaceOwnedBytes(std.testing.allocator, &query.last_value, stored_value);
    try std.testing.expectEqualStrings("cached-live-value", query.last_value.?);
}

test "Live transition validation is atomic and duplicate changes collapse deterministically" {
    var client = try Client.init(std.testing.allocator, "http://127.0.0.1:9");
    defer client.deinit();
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
    defer output.deinit();
    output.capture = &capture;
    var manager = try LiveManager.init(std.testing.allocator, client, &output);
    defer {
        manager.active.deinit();
        manager.commands.deinit();
    }
    try testAppendActive(&manager, 2, "two");
    try testAppendActive(&manager, 1, "one");
    var owner = LiveOwner.init(&manager);
    defer owner.deinit();
    owner.query_set_version = 2;

    var malformed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":2,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":2,\"value\":{\"count\":1}},{\"type\":\"Unknown\",\"queryId\":1}]}", .{});
    defer malformed.deinit();
    try std.testing.expectError(error.ProtocolFailure, owner.handleTransition(try protocolObject(malformed.value)));
    try std.testing.expect(StateVersion.eql(StateVersion{}, owner.remote_version));
    try std.testing.expectEqual(@as(usize, 0), capture.values.items.len);
    try std.testing.expect(manager.active.items[0].last_value == null);

    var duplicate = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":2,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":2,\"value\":{\"count\":1}},{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":10}},{\"type\":\"QueryUpdated\",\"queryId\":2,\"value\":{\"count\":3}}]}", .{});
    defer duplicate.deinit();
    try owner.handleTransition(try protocolObject(duplicate.value));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try capture.next(arena.allocator(), fixture_rendezvous_ns);
    const second = try capture.next(arena.allocator(), fixture_rendezvous_ns);
    try std.testing.expectEqual(@as(i64, 10), (try protocolObject(first)).get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), (try protocolObject(second)).get("count").?.integer);
    try std.testing.expectEqual(@as(usize, 0), capture.values.items.len);
    try std.testing.expectEqual(@as(u32, 2), owner.remote_version.query_set);
}

test "Live FunctionError keeps logs and omits missing data in adapter NDJSON" {
    var client = try Client.init(std.testing.allocator, "http://127.0.0.1:9");
    defer client.deinit();
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    var manager = try LiveManager.init(std.testing.allocator, client, &output);
    defer {
        manager.active.deinit();
        manager.commands.deinit();
    }
    try testAppendActive(&manager, 0, "failure");
    var owner = LiveOwner.init(&manager);
    defer owner.deinit();
    owner.query_set_version = 1;
    var transition = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "{\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryFailed\",\"queryId\":0,\"errorMessage\":\"failed\",\"logLines\":[\"live failure\"]}]}", .{});
    defer transition.deinit();
    try owner.handleTransition(try protocolObject(transition.value));
    try waitForOutputIdle(&output, fixture_rendezvous_ns);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"logs\":[\"live failure\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"data\"") == null);
}

const RecoveryFailure = enum { transition, websocket, non_minimal_length, close_frame };

const MalformedRecoveryFixture = struct {
    listener: *std.net.Server,
    failure: RecoveryFailure,

    fn run(self: *MalformedRecoveryFixture) void {
        var first = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("malformed fixture first accept failed");
        testAcceptWebSocket(first.stream) catch @panic("malformed fixture handshake failed");
        var frame = testReadClientFrame(std.heap.page_allocator, first.stream) catch @panic("malformed fixture Connect failed");
        std.heap.page_allocator.free(frame.payload);
        frame = testReadClientFrame(std.heap.page_allocator, first.stream) catch @panic("malformed fixture Add failed");
        std.heap.page_allocator.free(frame.payload);
        switch (self.failure) {
            .transition => testWriteFrame(first.stream, true, 1, "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":4294967296,\"value\":{}}]}") catch @panic("malformed transition write failed"),
            .websocket => first.stream.writer().writeAll(&.{ 0xc1, 0x02, '{', '}' }) catch @panic("RSV frame write failed"),
            // A two-byte length describing four bytes is not the minimal
            // encoding, so the owner must abandon this connection rather than
            // guess where the next frame starts.
            .non_minimal_length => first.stream.writer().writeAll(&.{ 0x81, 0x7e, 0x00, 0x04, '{', '}', ' ', ' ' }) catch @panic("non-minimal frame write failed"),
            // A Close frame carrying a reserved code is a protocol error, not
            // an ordinary disconnect.
            .close_frame => first.stream.writer().writeAll(&.{ 0x88, 0x02, 0x03, 0xec }) catch @panic("invalid close write failed"),
        }
        var discard: [64]u8 = undefined;
        while (first.stream.read(&discard) catch 0 > 0) {}
        first.stream.close();

        const second = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("malformed fixture reconnect failed");
        defer second.stream.close();
        testAcceptWebSocket(second.stream) catch @panic("malformed fixture reconnect handshake failed");
        frame = testReadClientFrame(std.heap.page_allocator, second.stream) catch @panic("reconnect Connect failed");
        std.heap.page_allocator.free(frame.payload);
        frame = testReadClientFrame(std.heap.page_allocator, second.stream) catch @panic("reconnect Add failed");
        std.heap.page_allocator.free(frame.payload);
        testSendTransition(second.stream, 0, 1, 0, 2, 0, 7) catch @panic("recovery transition write failed");
        while (second.stream.read(&discard) catch 0 > 0) {}
    }
};

test "malformed Live transitions and frames emit ProtocolError then recover" {
    for ([_]RecoveryFailure{ .transition, .websocket, .non_minimal_length, .close_frame }) |failure| {
        var listener = try testListener();
        defer listener.deinit();
        var fixture = MalformedRecoveryFixture{ .listener = &listener, .failure = failure };
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
        const protocol_error = try capture.next(arena.allocator(), fixture_rendezvous_ns);
        try std.testing.expectEqualStrings("ProtocolError", try protocolString((try protocolObject(protocol_error)).get("name") orelse return error.ProtocolFailure));
        const recovered = try capture.next(arena.allocator(), fixture_rendezvous_ns);
        try std.testing.expectEqual(@as(i64, 7), (try protocolObject(recovered)).get("count").?.integer);
        try client.close();
        thread.join();
        arena.deinit();
        args.object.deinit();
        output.deinit();
        capture.deinit();
        client.deinit();
    }
}

const ReconnectFixture = struct {
    listener: *std.net.Server,
    connections: u32 = 0,

    fn run(self: *ReconnectFixture) void {
        var number: u32 = 0;
        while (number < 6) : (number += 1) {
            const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("reconnect fixture accept failed");
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
                testSendTransition(connection.stream, 1, 1, 254, 255, 0, 0) catch @panic("recovery write failed");
            } else {
                const rehydrated_count = number - 1;
                const rehydrated_timestamp = 255 + (@as(u64, number) - 1) * 2 + 1;
                testSendTransition(connection.stream, 0, 1, 0, rehydrated_timestamp, 0, rehydrated_count) catch @panic("rehydration write failed");
                testSendTransition(connection.stream, 1, 1, rehydrated_timestamp, rehydrated_timestamp + 1, 0, number) catch @panic("changed update write failed");
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
    const failure = try capture.next(arena.allocator(), fixture_rendezvous_ns);
    try std.testing.expectEqualStrings("FunctionError", failure.object.get("name").?.string);
    try std.testing.expectEqualStrings("ROOM_EMPTY", failure.object.get("data").?.object.get("code").?.string);
    const initial = try capture.next(arena.allocator(), fixture_rendezvous_ns);
    try std.testing.expectEqual(@as(i64, 0), initial.object.get("count").?.integer);

    var reconnect: u32 = 1;
    while (reconnect <= 5) : (reconnect += 1) {
        try client.debugDisconnect();
        const update = try capture.next(arena.allocator(), fixture_rendezvous_ns);
        try std.testing.expectEqual(@as(i64, @intCast(reconnect)), update.object.get("count").?.integer);
    }
    try client.close();
    thread.join();
    try std.testing.expectEqual(@as(u32, 6), fixture.connections);
}

/// A peer that completes the TCP connect, reads the upgrade request, and then
/// says nothing at all. Nothing here sleeps: every wait ends on a real socket
/// event or on the deadline under test.
const StalledHandshakeFixture = struct {
    listener: *std.net.Server,
    first_request_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    second_request_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    second_reached: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *StalledHandshakeFixture) void {
        var index: u32 = 0;
        while (index < 2) : (index += 1) {
            const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch return;
            defer connection.stream.close();
            var buffer: [8192]u8 = undefined;
            _ = testReadHandshake(connection.stream, &buffer) catch return;
            if (index == 0) {
                self.first_request_ms.store(std.time.milliTimestamp(), .release);
            } else {
                self.second_request_ms.store(std.time.milliTimestamp(), .release);
                self.second_reached.store(true, .release);
            }
            // Hold the socket open and silent until the client abandons it.
            var discard: [64]u8 = undefined;
            while (connection.stream.read(&discard) catch 0 > 0) {}
        }
    }
};

test "a silent upgrade peer expires on the bring-up deadline and close cancels it" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = StalledHandshakeFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, StalledHandshakeFixture.run, .{&fixture});
    // Joined by defer so a failing assertion above reports itself instead of
    // abandoning a live thread that still points at this stack frame.
    defer thread.join();
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
    try args.object.put("room", .{ .string = "stalled-handshake" });

    try client.subscribe("stalled", "demo:state", args, &output);
    try waitForFlag(&fixture.second_reached, fixture_rendezvous_ns);

    // The gap between the two upgrade requests is the first attempt's whole
    // life. It must be the handshake deadline plus a short backoff, not the
    // peer's own idea of how long to stay silent.
    const gap = fixture.second_request_ms.load(.acquire) - fixture.first_request_ms.load(.acquire);
    try std.testing.expect(gap >= handshake_deadline_ms - 300);
    try std.testing.expect(gap < handshake_deadline_ms + 2000);

    // Close arrives while the second attempt is still waiting for its 101.
    // Cancelling the bring-up deadline is what keeps this well inside the
    // deadline the attempt would otherwise run to.
    const started = std.time.milliTimestamp();
    try client.close();
    try std.testing.expect(std.time.milliTimestamp() - started < 1000);
}

test "a record abandoned part way through makes the adapter stream terminal" {
    var listener = try testListener();
    defer listener.deinit();
    const stream = try std.net.tcpConnectToAddress(listener.listen_address);
    defer stream.close();
    const peer = try listener.accept();
    defer peer.stream.close();
    // Small kernel buffers so one large record cannot be absorbed whole and
    // the relay really does stop with bytes already committed.
    const buffer_bytes: c_int = 8 * 1024;
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&buffer_bytes));
    try std.posix.setsockopt(peer.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&buffer_bytes));

    var output = Output.init(std.testing.allocator, std.io.null_writer.any(), stream.handle, .socket);
    defer output.deinit();
    const token = try output.newDeliveryToken();
    defer output.revokeDeliveryToken(token);

    const blob = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(blob);
    @memset(blob, 'x');
    var event = std.json.ObjectMap.init(std.testing.allocator);
    defer event.deinit();
    try event.put("type", .{ .string = "subscription" });
    try event.put("subscriptionId", .{ .string = "terminal" });
    try event.put("value", .{ .string = blob });
    try output.enqueueSubscription("terminal", token, .{ .object = event });

    // Reading a prefix proves the record committed bytes without finishing;
    // the controller then stops, exactly as a stalled reader would.
    var prefix: [1024]u8 = undefined;
    try testReadExact(peer.stream, &prefix);
    try std.testing.expect(std.mem.indexOfScalar(u8, &prefix, '\n') == null);

    const started = std.time.milliTimestamp();
    output.finishLive();
    try std.testing.expect(std.time.milliTimestamp() - started < close_grace_ms + 1000);
    try std.testing.expect(output.poisoned.load(.acquire));
    // Abandoning released the reservation exactly once, and the queue behind
    // it was discarded rather than delivered onto a truncated line.
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);

    // The terminal `closed` event must not be appended to that line either.
    var closed = std.json.ObjectMap.init(std.testing.allocator);
    defer closed.deinit();
    try closed.put("id", .{ .string = "close" });
    try closed.put("type", .{ .string = "closed" });
    try std.testing.expectError(error.StreamTerminal, output.send(std.testing.allocator, .{ .object = closed }));
}

test "a near-maximum sync value fits one adapter event and oversize is still refused" {
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    const token = try output.newDeliveryToken();
    defer output.revokeDeliveryToken(token);

    // A schema-valid Convex value may fill almost the whole incoming sync
    // message, so re-encoding it with the subscription envelope has to fit
    // one adapter event instead of being rejected as too big.
    const blob = try std.testing.allocator.alloc(u8, max_websocket_message - 4096);
    defer std.testing.allocator.free(blob);
    @memset(blob, 'x');
    var event = std.json.ObjectMap.init(std.testing.allocator);
    defer event.deinit();
    try event.put("type", .{ .string = "subscription" });
    try event.put("subscriptionId", .{ .string = "near-max" });
    try event.put("value", .{ .string = blob });
    try output.enqueueSubscription("near-max", token, .{ .object = event });
    try waitForOutputIdle(&output, fixture_rendezvous_ns);
    try std.testing.expect(bytes.items.len > blob.len);
    try std.testing.expectEqual(@as(u8, '\n'), bytes.items[bytes.items.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);

    // The ceiling itself still holds: anything larger than one frame plus the
    // envelope allowance is refused rather than queued.
    const oversize = try std.testing.allocator.alloc(u8, max_adapter_event_bytes + 1);
    defer std.testing.allocator.free(oversize);
    @memset(oversize, 'y');
    var oversize_event = std.json.ObjectMap.init(std.testing.allocator);
    defer oversize_event.deinit();
    try oversize_event.put("type", .{ .string = "subscription" });
    try oversize_event.put("subscriptionId", .{ .string = "near-max" });
    try oversize_event.put("value", .{ .string = oversize });
    try std.testing.expectError(error.MessageTooBig, output.enqueueSubscription("near-max", token, .{ .object = oversize_event }));
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
}

const BarrierMode = enum { unsubscribe, replace };

const BarrierFixture = struct {
    listener: *std.net.Server,
    mode: BarrierMode,
    active_count: u32 = 1,
    replacement_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *BarrierFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("barrier fixture accept failed");
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
        testSendTransition(connection.stream, 0, self.active_count, 0, 1, 0, 1) catch @panic("old transition write failed");

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
            testSendTransition(connection.stream, self.active_count, self.active_count + 2, 1, 2, self.active_count, 2) catch @panic("replacement transition write failed");
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
    // Teardown runs as defers, in this order, on every exit path: release the
    // paused worker, retire the Live owner, join the fixture, then free. A
    // failing assertion below used to skip all of it and leave live threads
    // pointing at this stack frame.
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    defer args.object.deinit();
    try args.object.put("room", .{ .string = "barrier" });
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    defer thread.join();
    defer client.close() catch {};
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    defer pause.releaseWriter();

    try client.subscribe("same", "demo:state", args, &output);
    try pause.waitUntilDequeued(fixture_rendezvous_ns);
    // The production owner revokes the old generation before this returns,
    // which is the exact point where the adapter may publish its ack.
    try client.unsubscribe("same");
    pause.releaseWriter();
    try waitForOutputIdle(&output, fixture_rendezvous_ns);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
    try client.close();
}

test "same-ID replacement revokes old in-flight generation before acknowledgement" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = BarrierFixture{ .listener = &listener, .mode = .replace };
    const thread = try std.Thread.spawn(.{}, BarrierFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    defer args.object.deinit();
    try args.object.put("room", .{ .string = "barrier" });
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    defer thread.join();
    defer client.close() catch {};
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    defer pause.releaseWriter();

    try client.subscribe("same", "demo:state", args, &output);
    try pause.waitUntilDequeued(fixture_rendezvous_ns);
    // This second production Add retires the old token before it returns.
    try client.subscribe("same", "demo:state", args, &output);
    try waitForFlag(&fixture.replacement_sent, fixture_rendezvous_ns);
    pause.releaseWriter();
    try waitForOutputContains(&output, &bytes, "\"count\":2", fixture_rendezvous_ns);
    try waitForOutputIdle(&output, fixture_rendezvous_ns);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":2") != null);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
    try client.close();
}

test "same-ID replacement succeeds at the sixteen-subscription ceiling with a paused old relay" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = BarrierFixture{ .listener = &listener, .mode = .replace, .active_count = max_live_subscriptions };
    const thread = try std.Thread.spawn(.{}, BarrierFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    defer client.deinit();
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    defer args.object.deinit();
    try args.object.put("room", .{ .string = "capacity-barrier" });
    var bytes = std.ArrayList(u8).init(std.testing.allocator);
    defer bytes.deinit();
    var output = Output.init(std.testing.allocator, bytes.writer().any(), null, .none);
    defer output.deinit();
    defer thread.join();
    defer client.close() catch {};
    var pause = DeliveryPause{};
    output.test_pause_after_dequeue = &pause;
    defer pause.releaseWriter();

    try client.subscribe("same", "demo:state", args, &output);
    var slot: u32 = 1;
    while (slot < max_live_subscriptions) : (slot += 1) {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "slot-{d}", .{slot});
        try client.subscribe(id, "demo:state", args, &output);
    }
    try pause.waitUntilDequeued(fixture_rendezvous_ns);
    try client.subscribe("same", "demo:state", args, &output);
    try waitForFlag(&fixture.replacement_sent, fixture_rendezvous_ns);
    pause.releaseWriter();
    try waitForOutputContains(&output, &bytes, "\"count\":2", fixture_rendezvous_ns);
    try waitForOutputIdle(&output, fixture_rendezvous_ns);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "\"count\":2") != null);
    try std.testing.expectEqual(@as(usize, max_live_subscriptions), client.live.?.active.items.len);
    try client.close();
}

const StalledFrameCommandFixture = struct {
    listener: *std.net.Server,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *StalledFrameCommandFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("stalled fixture accept failed");
        defer connection.stream.close();
        testAcceptWebSocket(connection.stream) catch @panic("stalled fixture handshake failed");
        const connect = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("stalled fixture Connect failed");
        std.heap.page_allocator.free(connect.payload);
        const add = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("stalled fixture Add failed");
        std.heap.page_allocator.free(add.payload);
        testSendTransition(connection.stream, 0, 1, 0, 1, 0, 0) catch @panic("stalled fixture initial transition failed");
        // Begin a second Transition frame and then go silent, as a peer that
        // has started sending but has stalled partway through the payload.
        connection.stream.writer().writeAll(&.{ 0x81, 0x7d, '{' }) catch {};
        self.ready.store(true, .release);
        var discard: [256]u8 = undefined;
        while (connection.stream.read(&discard) catch 0 > 0) {}
    }
};

test "unsubscribe stays bounded while the owner is reading a peer's stalled half-sent frame" {
    var listener = try testListener();
    defer listener.deinit();
    var fixture = StalledFrameCommandFixture{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, StalledFrameCommandFixture.run, .{&fixture});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{listener.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client = try Client.init(std.testing.allocator, url);
    var capture = Capture.init(std.testing.allocator);
    var output = Output.init(std.testing.allocator, std.io.null_writer.any(), null, .none);
    output.capture = &capture;
    var args = JsonValue{ .object = std.json.ObjectMap.init(std.testing.allocator) };
    try args.object.put("room", .{ .string = "stalled-frame" });
    try client.subscribe("stalled", "demo:state", args, &output);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    _ = try capture.next(arena.allocator(), fixture_rendezvous_ns);

    const ready_deadline = std.time.milliTimestamp() + 1000;
    while (!fixture.ready.load(.acquire)) {
        if (std.time.milliTimestamp() > ready_deadline) return error.Timeout;
        std.time.sleep(std.time.ns_per_ms);
    }
    // Give the owner a moment to start reading the half-sent second frame
    // before issuing the command that must interrupt it.
    std.time.sleep(20 * std.time.ns_per_ms);
    const started = std.time.milliTimestamp();
    try client.unsubscribe("stalled");
    const elapsed = std.time.milliTimestamp() - started;
    // The test-mode frame deadline alone is 250 ms. Completing well inside
    // that proves the socket shutdown interrupted the stalled read instead of
    // unsubscribe merely riding the frame deadline out.
    try std.testing.expect(elapsed < 150);
    try client.close();
    thread.join();
    arena.deinit();
    args.object.deinit();
    output.deinit();
    capture.deinit();
    client.deinit();
}

const CloseMode = enum { idle, flood, half_frame, peer_close };

const CloseFixture = struct {
    listener: *std.net.Server,
    mode: CloseMode,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    peer_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    close_reply_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    close_reply_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn run(self: *CloseFixture) void {
        const connection = acceptWithin(self.listener, fixture_accept_timeout_ms) catch @panic("close fixture accept failed");
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
            .peer_close => {
                const close_payload = [_]u8{ 0x03, 0xe8, 'b', 'y', 'e' };
                testWriteFrame(connection.stream, true, 8, &close_payload) catch @panic("peer Close write failed");
                var poll_fds = [_]std.posix.pollfd{.{ .fd = connection.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                if ((std.posix.poll(&poll_fds, 2000) catch 0) == 0) @panic("masked Close reply timed out");
                const reply = testReadClientFrame(std.heap.page_allocator, connection.stream) catch @panic("masked Close reply read failed");
                defer std.heap.page_allocator.free(reply.payload);
                if (reply.opcode != 8 or !std.mem.eql(u8, reply.payload, &close_payload)) @panic("invalid masked Close reply");
                _ = self.close_reply_count.fetchAdd(1, .acq_rel);
                self.close_reply_received.store(true, .release);

                // The owner must retire the same TCP connection immediately
                // after its one reply. Any further byte is a duplicate frame;
                // silence is also a failure because retirement is bounded.
                poll_fds[0].revents = 0;
                if ((std.posix.poll(&poll_fds, 2000) catch 0) == 0) @panic("connection remained open after Close reply");
                var extra: [1]u8 = undefined;
                if ((connection.stream.read(&extra) catch @panic("post-Close read failed")) != 0) @panic("duplicate frame after Close reply");
            },
        }
        self.peer_closed.store(true, .release);
    }
};

test "close is bounded and a valid peer Close gets one masked reply" {
    for ([_]CloseMode{ .idle, .flood, .half_frame, .peer_close }) |mode| {
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
        if (mode == .peer_close) try waitForFlag(&fixture.close_reply_received, fixture_rendezvous_ns);
        const started = std.time.milliTimestamp();
        try client.close();
        try std.testing.expect(std.time.milliTimestamp() - started < 1000);
        thread.join();
        try std.testing.expect(fixture.peer_closed.load(.acquire));
        try std.testing.expectEqual(@as(u32, if (mode == .peer_close) 1 else 0), fixture.close_reply_count.load(.acquire));
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
    // Every exit path must release the paused worker before `output.deinit`
    // tries to join it, including one taken by a failing assertion below.
    defer pause.releaseWriter();
    const token = try output.newDeliveryToken();
    // Near-maximum values, not comfortable ones: an event count alone is not a
    // memory bound when a single Convex value can fill an entire sync message.
    const blob = try std.testing.allocator.alloc(u8, max_websocket_message - 8192);
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
        if (sequence == 0) try pause.waitUntilDequeued(fixture_rendezvous_ns);
    }

    output.mutex.lock();
    const reserved_count = output.reserved_count;
    const reserved_bytes = output.reserved_bytes;
    const retained_count = output.queue.items.len;
    const newest = if (retained_count == 0) "" else output.queue.items[retained_count - 1].record;
    output.mutex.unlock();
    try std.testing.expect(reserved_count <= max_live_queue_events);
    try std.testing.expect(reserved_bytes <= max_live_queue_bytes);
    try std.testing.expectEqual(reserved_count - 1, retained_count);
    try std.testing.expect(std.mem.indexOf(u8, newest, "\"sequence\":39") != null);

    pause.releaseWriter();
    try waitForOutputIdle(&output, fixture_rendezvous_ns);
    output.revokeDeliveryToken(token);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_count);
    try std.testing.expectEqual(@as(usize, 0), output.reserved_bytes);
}
