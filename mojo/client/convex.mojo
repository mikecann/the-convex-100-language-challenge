"""The Convex client: documented HTTP functions plus the pinned Live profile.

The client is single-threaded by design. One `pump` call owns the WebSocket
completely - it is the only code that reads it, writes it, reconnects it, or
advances the query-set version - so there is no second thread that could touch
the socket concurrently and no lock to get wrong. Callers ask for work through
`subscribe`, `unsubscribe` and `debug_disconnect`, which only record intent;
`pump` performs it.

Live values are handed back as serialized JSON text rather than as live nodes
into a parsed document. That makes the per-subscription queue bound exact: the
byte budget below counts the same bytes that will later be written out.
"""

from std.ffi import external_call, c_int

from http import Endpoint, parse_url, post_json
from json import J_ARRAY, J_NUMBER, J_OBJECT, J_STRING, Json, parse, quote
from net import Conn, connect, now_ms, random_bytes
from websocket import Message, WebSocket, handshake

comptime CLIENT_VERSION = "mojo-0.1.0"
comptime SYNC_PATH = "/api/sync"

# The zero timestamp the Convex sync profile starts from. The first Transition
# a fresh connection sends carries this as its start timestamp.
comptime INITIAL_TIMESTAMP = "AAAAAAAAAAA="

# Delivery bound. A slow consumer keeps the newest 16 updates per subscription
# and at most 256 KiB of encoded value text; whichever limit is reached first
# drops the oldest update. Both are needed: one 2 MiB value would otherwise sit
# inside a queue that is technically only "16 long".
comptime QUEUE_CAPACITY = 16
comptime QUEUE_BYTE_BUDGET = 256 * 1024

comptime RECONNECT_MIN_MS = 100
comptime RECONNECT_MAX_MS = 15000
comptime HTTP_TIMEOUT_MS = 30000
comptime DIAL_TIMEOUT_MS = 15000


fn default_ca_file() -> String:
    """Where the runtime image stages the CA bundle OpenSSL should trust."""
    return String("/etc/ssl/certs/ca-certificates.crt")


struct Update(Copyable, Movable):
    """One Live delivery: either a value or a structured failure."""

    var failed: Bool
    var value_json: String
    var logs_json: String
    var error_name: String
    var error_message: String
    var error_data_json: String

    fn __init__(out self):
        self.failed = False
        self.value_json = String()
        self.logs_json = String()
        self.error_name = String()
        self.error_message = String()
        self.error_data_json = String()

    fn size(self) -> Int:
        return (
            len(self.value_json.as_bytes())
            + len(self.logs_json.as_bytes())
            + len(self.error_message.as_bytes())
            + len(self.error_data_json.as_bytes())
        )


struct CallResult(Copyable, Movable):
    """The outcome of one HTTP query, mutation or action."""

    var ok: Bool
    var value_json: String
    var logs_json: String
    var error_name: String
    var error_message: String
    var error_data_json: String

    fn __init__(out self):
        self.ok = False
        self.value_json = String()
        self.logs_json = String()
        self.error_name = String()
        self.error_message = String()
        self.error_data_json = String()


struct Subscription(Copyable, Movable):
    """Server-side query registration plus this client's delivery state."""

    var id: String
    var query_id: Int
    var path: String
    var args_json: String
    var active: Bool
    var add_pending: Bool
    var remove_pending: Bool
    var rehydrating: Bool
    var has_last: Bool
    var last_value: String
    var queue: List[Update]
    var queue_bytes: Int
    var dropped: Int

    fn __init__(
        out self, id: String, query_id: Int, path: String, args_json: String
    ):
        self.id = id
        self.query_id = query_id
        self.path = path
        self.args_json = args_json
        self.active = True
        self.add_pending = True
        self.remove_pending = False
        self.rehydrating = False
        self.has_last = False
        self.last_value = String()
        self.queue = List[Update]()
        self.queue_bytes = 0
        self.dropped = 0

    fn enqueue(mut self, var update: Update):
        """Append one delivery, dropping the oldest to stay inside both bounds.
        """
        var incoming = update.size()
        self.queue.append(update^)
        self.queue_bytes += incoming
        while len(self.queue) > QUEUE_CAPACITY or (
            self.queue_bytes > QUEUE_BYTE_BUDGET and len(self.queue) > 1
        ):
            var oldest = self.queue.pop(0)
            self.queue_bytes -= oldest.size()
            self.dropped += 1

    fn take(mut self) -> Update:
        var head = self.queue.pop(0)
        self.queue_bytes -= head.size()
        return head^

    fn invalidate(mut self):
        """Drop everything queued so a retired relay cannot publish later."""
        self.queue.clear()
        self.queue_bytes = 0


fn error_name_of(message: String) -> String:
    """Split the `Name|text` convention the transport layers raise with."""
    var bar = message.find("|")
    if bar > 0:
        return String(message[byte=0:bar])
    return String("Error")


fn error_text_of(message: String) -> String:
    var bar = message.find("|")
    if bar > 0:
        return String(message[byte = bar + 1 : len(message.as_bytes())])
    return message


struct Client(Movable):
    """A Convex deployment client owning one optional Live connection."""

    var endpoint: Endpoint
    var url: String
    var token: String
    var ca_file: String
    var socket: WebSocket
    var connected: Bool
    var subs: List[Subscription]
    var next_query_id: Int
    var sent_version: Int
    var remote_query_set: Int
    var remote_identity: Int
    var remote_ts: String
    var max_observed_ts: String
    var connection_count: Int
    var last_close_reason: String
    var session_id: String
    var backoff_ms: Int
    var reconnect_at: Int
    var closed: Bool

    fn __init__(out self):
        """An inert client, so a caller can hold one before a URL is known.

        The conformance adapter answers `hello` before any deployment URL has
        been read, and this is what it holds until then.
        """
        self = Self(Endpoint(String(), 0, False), String(), default_ca_file())

    fn __init__(out self, url: String, ca_file: String) raises:
        self = Self(parse_url(url), url, ca_file)

    fn __init__(out self, var endpoint: Endpoint, url: String, ca_file: String):
        self.endpoint = endpoint^
        self.url = url
        self.token = String()
        self.ca_file = ca_file
        self.socket = WebSocket(Conn())
        self.connected = False
        self.subs = List[Subscription]()
        self.next_query_id = 0
        self.sent_version = 0
        self.remote_query_set = 0
        self.remote_identity = 0
        self.remote_ts = String(INITIAL_TIMESTAMP)
        self.max_observed_ts = String()
        self.connection_count = 0
        self.last_close_reason = String("InitialConnect")
        self.session_id = new_session_id()
        self.backoff_ms = RECONNECT_MIN_MS
        self.reconnect_at = 0
        self.closed = False

    # ----------------------------------------------------------------- HTTP

    fn set_auth(mut self, token: String):
        """Replace or clear the bearer token used by later HTTP calls."""
        self.token = token

    fn call(
        mut self, operation: String, path: String, args_json: String
    ) -> CallResult:
        """Run one Convex function over HTTP and decode its documented reply."""
        var result = CallResult()
        var body = String('{"path":')
        body += quote(path)
        body += ',"args":'
        body += args_json
        body += ',"format":"json"}'
        try:
            var response = post_json(
                self.endpoint,
                String("/api/") + operation,
                body,
                String(CLIENT_VERSION),
                self.token,
                self.ca_file,
                HTTP_TIMEOUT_MS,
            )
            return decode_call(response.status, response.body)
        except error:
            var text = String(error)
            result.error_name = error_name_of(text)
            result.error_message = error_text_of(text)
            return result^

    # ----------------------------------------------------------------- Live

    fn find(self, id: String) -> Int:
        for i in range(len(self.subs)):
            if self.subs[i].id == id:
                return i
        return -1

    fn subscribe(mut self, id: String, path: String, args_json: String) raises:
        """Register a Live query, replacing any earlier one with the same ID.

        The replaced subscription is invalidated here, before this call
        returns, so a value that was queued for the previous registration can
        never be delivered under the new one.
        """
        var existing = self.find(id)
        if existing >= 0:
            self.subs[existing].invalidate()
            self.subs[existing].active = False
            self.subs[existing].remove_pending = self.connected
            self.subs[existing].id = String("retired:") + id
        self.next_query_id += 1
        self.subs.append(Subscription(id, self.next_query_id, path, args_json))

    fn unsubscribe(mut self, id: String) raises:
        """Retire a Live query. Bounded: nothing here waits on the peer.

        The queue is cleared and the record is deactivated immediately, so the
        acknowledgement the caller publishes next cannot be overtaken by a
        value that was already in flight.
        """
        var index = self.find(id)
        if index < 0:
            return
        self.subs[index].invalidate()
        self.subs[index].active = False
        # A Remove is only worth sending while a connection that carried the
        # matching Add is still open. A fresh connection never registers it.
        self.subs[index].remove_pending = self.connected

    fn debug_disconnect(mut self) raises:
        """Adapter-only: retire the current connection and schedule a reconnect.

        Not part of the educational client API. The shared conformance
        controller uses it to prove five real reconnects.
        """
        if not self.connected:
            raise Error("Error|no active Live connection to disconnect")
        self.retire(String("DebugDisconnect"))
        self.reconnect_at = now_ms() + RECONNECT_MIN_MS

    fn has_update(self, id: String) -> Bool:
        var index = self.find(id)
        return index >= 0 and len(self.subs[index].queue) > 0

    fn take_update(mut self, id: String) raises -> Update:
        var index = self.find(id)
        if index < 0 or len(self.subs[index].queue) == 0:
            raise Error("Error|no Live update is ready")
        return self.subs[index].take()

    fn wait_update(mut self, id: String, timeout_ms: Int) raises -> Update:
        """Pump the connection until this subscription has a delivery."""
        var deadline = now_ms() + timeout_ms
        while True:
            if self.has_update(id):
                return self.take_update(id)
            if now_ms() >= deadline:
                raise Error(
                    "TransportError|timed out waiting for a Live update"
                )
            self.pump(25)

    fn active_count(self) -> Int:
        var count = 0
        for i in range(len(self.subs)):
            if self.subs[i].active:
                count += 1
        return count

    fn retire(mut self, reason: String):
        """Close the socket and reset every version the server owns.

        A new connection restarts the query-set and identity versions at zero,
        so any local view of them has to be reset at the same moment or the
        first Transition will look like drift.
        """
        if self.connected:
            self.socket.close(now_ms() + 1000)
        self.socket = WebSocket(Conn())
        self.connected = False
        self.connection_count += 1
        self.last_close_reason = reason
        self.sent_version = 0
        self.remote_query_set = 0
        self.remote_identity = 0
        self.remote_ts = String(INITIAL_TIMESTAMP)
        for i in range(len(self.subs)):
            if self.subs[i].active:
                self.subs[i].rehydrating = True
                self.subs[i].add_pending = True
            else:
                # A query the new connection never registers needs no Remove.
                self.subs[i].remove_pending = False

    fn pump(mut self, timeout_ms: Int) raises:
        """Advance the Live connection by one bounded step.

        This is the single owner of the socket: it dials, resubscribes, drains
        removals and decodes server messages. Every failure path retires the
        connection and schedules a backed-off retry rather than raising into
        the caller, because a Live subscription is expected to survive a
        transport fault.
        """
        if self.closed:
            return
        self.reap()
        if not self.connected:
            if self.active_count() == 0:
                _ = sleep_ms(timeout_ms)
                return
            if now_ms() < self.reconnect_at:
                _ = sleep_ms(min(timeout_ms, self.reconnect_at - now_ms()))
                return
            try:
                self.dial()
                self.backoff_ms = RECONNECT_MIN_MS
            except error:
                self.note_failure(String(error))
                return
        try:
            self.flush_query_set()
            self.receive(timeout_ms)
        except error:
            var text = String(error)
            if error_name_of(text) == "ProtocolError":
                self.publish_failure(
                    String("ProtocolError"), error_text_of(text), False
                )
            else:
                self.publish_failure(
                    String("TransportError"), error_text_of(text), True
                )
            self.note_failure(text)

    fn reap(mut self):
        """Forget retired subscriptions once no connection can still name them.
        """
        var kept = List[Subscription]()
        for i in range(len(self.subs)):
            if self.subs[i].active or self.subs[i].remove_pending:
                kept.append(self.subs[i].copy())
        self.subs = kept^

    fn note_failure(mut self, reason: String):
        self.retire(error_text_of(reason))
        self.reconnect_at = now_ms() + self.backoff_ms
        # Exponential backoff, reset on the next successful handshake so a run
        # of healthy connections never inherits an old maximum delay.
        var next = self.backoff_ms * 2
        self.backoff_ms = next if next < RECONNECT_MAX_MS else RECONNECT_MAX_MS

    fn dial(mut self) raises:
        """Open the WebSocket, send `Connect`, then resend every active `Add`.
        """
        var deadline = now_ms() + DIAL_TIMEOUT_MS
        var conn = connect(
            self.endpoint.host,
            self.endpoint.port,
            self.endpoint.tls,
            self.ca_file,
            DIAL_TIMEOUT_MS,
        )
        self.socket = handshake(
            conn^,
            self.endpoint.host,
            self.endpoint.port,
            String(SYNC_PATH),
            String(CLIENT_VERSION),
            deadline,
        )
        self.connected = True

        var connect_message = String('{"type":"Connect","sessionId":')
        connect_message += quote(self.session_id)
        connect_message += ',"connectionCount":'
        connect_message += String(self.connection_count)
        connect_message += ',"lastCloseReason":'
        connect_message += quote(self.last_close_reason)
        if self.max_observed_ts:
            connect_message += ',"maxObservedTimestamp":'
            connect_message += quote(self.max_observed_ts)
        connect_message += ',"clientTs":0}'
        self.socket.send_text(connect_message, deadline)

        if self.active_count() > 0:
            var message = self.modify_message(True, -1)
            self.socket.send_text(message, deadline)
            self.sent_version = 1
            for i in range(len(self.subs)):
                if self.subs[i].active:
                    self.subs[i].add_pending = False

    fn modify_message(self, adding: Bool, only: Int) raises -> String:
        """Build one `ModifyQuerySet`, either for every active query or for one.
        """
        var base = 0 if only < 0 else self.sent_version
        var out = String('{"type":"ModifyQuerySet","baseVersion":')
        out += String(base)
        out += ',"newVersion":'
        out += String(base + 1)
        out += ',"modifications":['
        var written = 0
        for i in range(len(self.subs)):
            if only >= 0 and i != only:
                continue
            if adding and not self.subs[i].active:
                continue
            if written > 0:
                out += ","
            written += 1
            if adding:
                out += '{"type":"Add","queryId":'
                out += String(self.subs[i].query_id)
                out += ',"udfPath":'
                out += quote(self.subs[i].path)
                out += ',"args":['
                out += self.subs[i].args_json
                out += "]}"
            else:
                out += '{"type":"Remove","queryId":'
                out += String(self.subs[i].query_id)
                out += "}"
        out += "]}"
        return out

    fn flush_query_set(mut self) raises:
        """Send one pending add or removal per pump so each version is confirmed.
        """
        var deadline = now_ms() + 5000
        for i in range(len(self.subs)):
            if self.subs[i].active and self.subs[i].add_pending:
                var message = self.modify_message(True, i)
                self.socket.send_text(message, deadline)
                self.sent_version += 1
                self.subs[i].add_pending = False
                return
        for i in range(len(self.subs)):
            if self.subs[i].remove_pending:
                var message = self.modify_message(False, i)
                self.socket.send_text(message, deadline)
                self.sent_version += 1
                self.subs[i].remove_pending = False
                return

    fn receive(mut self, timeout_ms: Int) raises:
        """Decode whatever whole messages have arrived, then return."""
        var deadline = now_ms() + timeout_ms
        while True:
            var message = self.socket.poll_message(deadline)
            if not message.present:
                return
            self.handle_message(message.text)
            if now_ms() >= deadline:
                return

    fn handle_message(mut self, text: String) raises:
        var doc = parse(text)
        var kind_node = doc.member(doc.root, "type")
        if doc.kind(kind_node) != J_STRING:
            raise Error("ProtocolError|Live message omitted its type")
        var kind = doc.text(kind_node)
        if kind == "Transition":
            self.handle_transition(doc)
        elif (
            kind == "Ping"
            or kind == "MutationResponse"
            or kind == "ActionResponse"
        ):
            return
        else:
            var detail = String("Live server sent ") + kind
            var reported = doc.member(doc.root, "error")
            if reported >= 0:
                detail += ": "
                detail += doc.dump(reported)
            raise Error("ProtocolError|" + detail)

    fn handle_transition(mut self, doc: Json) raises:
        """Apply one `Transition` atomically after validating all of it.

        Nothing is published until every modification has been checked, so a
        malformed tail cannot leave half a transition applied to the queues.
        """
        var start = doc.member(doc.root, "startVersion")
        var end = doc.member(doc.root, "endVersion")
        var mods = doc.member(doc.root, "modifications")
        if doc.kind(start) != J_OBJECT or doc.kind(end) != J_OBJECT:
            raise Error("ProtocolError|Transition omitted its version fields")
        if doc.kind(mods) != J_ARRAY:
            raise Error("ProtocolError|Transition omitted its modifications")

        var start_query_set = doc.as_int(doc.member(start, "querySet"))
        var start_identity = doc.as_int(doc.member(start, "identity"))
        var start_ts_node = doc.member(start, "ts")
        if doc.kind(start_ts_node) != J_STRING:
            raise Error("ProtocolError|Transition omitted its start timestamp")
        if (
            start_query_set != self.remote_query_set
            or start_identity != self.remote_identity
            or doc.text(start_ts_node) != self.remote_ts
        ):
            raise Error("ProtocolError|Transition start version does not match")

        var end_query_set = doc.as_int(doc.member(end, "querySet"))
        var end_identity = doc.as_int(doc.member(end, "identity"))
        var end_ts_node = doc.member(end, "ts")
        if doc.kind(end_ts_node) != J_STRING:
            raise Error("ProtocolError|Transition omitted its end timestamp")

        var count = doc.count(mods)
        for n in range(count):
            validate_modification(doc, doc.item(mods, n))

        for n in range(count):
            self.apply_modification(doc, doc.item(mods, n))

        self.remote_query_set = end_query_set
        self.remote_identity = end_identity
        self.remote_ts = doc.text(end_ts_node)
        self.max_observed_ts = doc.text(end_ts_node)

    fn apply_modification(mut self, doc: Json, node: Int) raises:
        var kind = doc.text(doc.member(node, "type"))
        var query_id = doc.as_int(doc.member(node, "queryId"))
        var index = -1
        for i in range(len(self.subs)):
            if self.subs[i].query_id == query_id and self.subs[i].active:
                index = i
        if kind == "QueryRemoved" or index < 0:
            return
        var logs = doc.member(node, "logLines")
        var logs_json = doc.dump(logs) if logs >= 0 else String()

        if kind == "QueryUpdated":
            var value = doc.member(node, "value")
            var encoded = doc.dump(value)
            # A reconnect replays the current value of every query. When it has
            # not changed, that replay is bookkeeping rather than news, so it is
            # suppressed instead of being delivered a second time.
            var unchanged = self.subs[index].has_last and (
                self.subs[index].last_value == encoded
            )
            var suppress = self.subs[index].rehydrating and unchanged
            self.subs[index].last_value = encoded
            self.subs[index].has_last = True
            self.subs[index].rehydrating = False
            if suppress:
                return
            var update = Update()
            update.value_json = encoded
            update.logs_json = logs_json
            self.subs[index].enqueue(update^)
            return

        var update = Update()
        update.failed = True
        update.error_name = String("FunctionError")
        var message = doc.member(node, "errorMessage")
        update.error_message = doc.text(message)
        var data = doc.member(node, "errorData")
        if data >= 0:
            update.error_data_json = doc.dump(data)
        update.logs_json = logs_json
        self.subs[index].has_last = False
        self.subs[index].rehydrating = False
        self.subs[index].enqueue(update^)

    fn publish_failure(
        mut self, name: String, message: String, established_only: Bool
    ):
        """Report a transport or protocol fault to the affected subscriptions.

        A subscription still waiting for its first Add has never delivered
        anything, and a debug disconnect deliberately marks every subscription
        that way, so `established_only` keeps a scripted reconnect silent while
        an unexpected socket failure is still reported.
        """
        for i in range(len(self.subs)):
            if not self.subs[i].active or self.subs[i].remove_pending:
                continue
            if established_only and self.subs[i].add_pending:
                continue
            var update = Update()
            update.failed = True
            update.error_name = name
            update.error_message = message
            self.subs[i].enqueue(update^)

    fn close(mut self, timeout_ms: Int):
        """Retire the connection without waiting on an idle or stalled peer."""
        if self.closed:
            return
        self.closed = True
        if self.connected:
            self.socket.close(now_ms() + timeout_ms)
        self.socket = WebSocket(Conn())
        self.connected = False
        for i in range(len(self.subs)):
            self.subs[i].active = False


fn validate_modification(doc: Json, node: Int) raises:
    if doc.kind(node) != J_OBJECT:
        raise Error("ProtocolError|Transition modification is not an object")
    var kind_node = doc.member(node, "type")
    if doc.kind(kind_node) != J_STRING:
        raise Error("ProtocolError|Transition modification omitted its type")
    var kind = doc.text(kind_node)
    if doc.kind(doc.member(node, "queryId")) != J_NUMBER:
        raise Error("ProtocolError|Transition modification omitted its queryId")
    var logs = doc.member(node, "logLines")
    if logs >= 0 and doc.kind(logs) != J_ARRAY:
        raise Error(
            "ProtocolError|Transition modification has invalid logLines"
        )
    if kind == "QueryUpdated":
        if doc.member(node, "value") < 0:
            raise Error("ProtocolError|QueryUpdated omitted its value")
    elif kind == "QueryFailed":
        if doc.kind(doc.member(node, "errorMessage")) != J_STRING:
            raise Error("ProtocolError|QueryFailed omitted its errorMessage")
    elif kind != "QueryRemoved":
        raise Error("ProtocolError|unknown Transition modification " + kind)


fn decode_call(status: Int, body: String) -> CallResult:
    """Turn one HTTP reply into the documented success or failure shape."""
    var result = CallResult()
    try:
        var doc = parse(body)
        var state = doc.member(doc.root, "status")
        var logs = doc.member(doc.root, "logLines")
        var logs_json = doc.dump(logs) if logs >= 0 else String()
        if doc.kind(state) == J_STRING and doc.text(state) == "success":
            var value = doc.member(doc.root, "value")
            if value < 0:
                result.error_name = String("ProtocolError")
                result.error_message = String(
                    "Convex success omitted its value"
                )
                return result^
            result.ok = True
            result.value_json = doc.dump(value)
            result.logs_json = logs_json
            return result^
        if doc.kind(state) == J_STRING and doc.text(state) == "error":
            var message = doc.member(doc.root, "errorMessage")
            var data = doc.member(doc.root, "errorData")
            result.error_name = String("FunctionError")
            result.error_message = doc.text(message) if doc.kind(
                message
            ) == J_STRING else String("Convex function failed")
            if data >= 0:
                result.error_data_json = doc.dump(data)
            result.logs_json = logs_json
            return result^
    except:
        pass
    result.error_name = String("ProtocolError")
    result.error_message = String("Convex returned HTTP ") + String(status)
    return result^


fn new_session_id() -> String:
    """A version 4 UUID for the `Connect` message."""
    var raw: List[UInt8]
    try:
        raw = random_bytes(16)
    except:
        raw = List[UInt8](length=16, fill=0)
    raw[6] = (raw[6] & 0x0F) | 0x40
    raw[8] = (raw[8] & 0x3F) | 0x80
    var out = String()
    for i in range(16):
        if i == 4 or i == 6 or i == 8 or i == 10:
            out += "-"
        var byte = Int(raw[i])
        out += "0123456789abcdef"[byte = byte >> 4 : (byte >> 4) + 1]
        out += "0123456789abcdef"[byte = byte & 0xF : (byte & 0xF) + 1]
    return out


fn sleep_ms(milliseconds: Int) -> Int:
    """Sleep without a socket to wait on, so an idle pump does not spin."""
    if milliseconds <= 0:
        return 0
    var request = List[Int64]()
    request.append(Int64(milliseconds // 1000))
    request.append(Int64((milliseconds % 1000) * 1000000))
    var remaining = List[Int64](length=2, fill=0)
    return Int(
        external_call["nanosleep", c_int](
            request.unsafe_ptr(), remaining.unsafe_ptr()
        )
    )
