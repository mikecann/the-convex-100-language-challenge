"""The NDJSON conformance adapter. Test infrastructure, not client API.

The shared controller drives this over stdin/stdout, or over one TCP
connection when `ADAPTER_LISTEN` is set. Every command is answered by calling
the real Mojo client; nothing here reimplements Convex behaviour.

The loop is deliberately single-threaded. It alternates between reading
controller commands, giving the client a bounded slice of time to service its
Live socket, and draining whatever that produced. Because the client owns its
socket from exactly one call site, no relay thread exists that could publish a
value after an unsubscribe acknowledgement.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer, alloc
from std.os import getenv
from std.sys.defines import get_defined_string

from convex import Client, default_ca_file, error_name_of, error_text_of
from events import (
    error_event,
    ready_event,
    result_event,
    simple_event,
    subscription_event,
)
from json import J_OBJECT, J_STRING, Json, parse, quote
from net import listen_once, now_ms, poll_fd

comptime LANGUAGE_ID = "mojo"
comptime IMPLEMENTATION = "native-mojo-ffi-libc-openssl"
comptime MOJO_VERSION = get_defined_string["MOJO_VERSION", "unknown"]()

comptime POLLIN = Int16(1)
comptime MAX_COMMAND_BYTES = 4 * 1024 * 1024


fn write_all(fd: Int, text: String) raises:
    """Write one framed event, retrying until the controller has taken it all.
    """
    var bytes = text.as_bytes()
    var total = len(bytes)
    var scratch = alloc[UInt8](total)
    for i in range(total):
        scratch[i] = bytes[i]
    var sent = 0
    var failed = False
    while sent < total:
        var wrote = external_call["write", Int](
            Int(fd), scratch + sent, total - sent
        )
        if wrote > 0:
            sent += Int(wrote)
            continue
        if wrote < 0:
            failed = True
            break
    scratch.free()
    if failed:
        raise Error("TransportError|could not write an adapter event")


struct Reader(Movable):
    """Line framing over a raw descriptor."""

    var fd: Int
    var buffer: List[UInt8]
    var eof: Bool

    fn __init__(out self, fd: Int):
        self.fd = fd
        self.buffer = List[UInt8]()
        self.eof = False

    fn poll(mut self, timeout_ms: Int) raises:
        if self.eof:
            return
        if (poll_fd(Int32(self.fd), POLLIN, timeout_ms) & POLLIN) == 0:
            return
        var scratch = alloc[UInt8](65536)
        var got = external_call["read", Int](Int(self.fd), scratch, 65536)
        if got > 0:
            for i in range(Int(got)):
                self.buffer.append(scratch[i])
        elif got == 0:
            self.eof = True
        scratch.free()
        if len(self.buffer) > MAX_COMMAND_BYTES:
            raise Error("ProtocolError|adapter command exceeded the size limit")

    fn take_line(mut self) -> String:
        """Return the next complete line, or an empty string when none is ready.
        """
        for i in range(len(self.buffer)):
            if self.buffer[i] == 0x0A:
                var raw = List[UInt8]()
                for n in range(i):
                    raw.append(self.buffer[n])
                var rest = List[UInt8]()
                for n in range(i + 1, len(self.buffer)):
                    rest.append(self.buffer[n])
                self.buffer = rest^
                return String(from_utf8_lossy=Span(raw))
        return String()


struct Adapter(Movable):
    """One controller session and the client it drives."""

    var out_fd: Int
    var client: Client
    var have_client: Bool
    var subscription_ids: List[String]
    var running: Bool

    fn __init__(out self, out_fd: Int):
        self.out_fd = out_fd
        self.client = Client()
        self.have_client = False
        self.subscription_ids = List[String]()
        self.running = True

    fn emit(mut self, event: String) raises:
        write_all(self.out_fd, event + "\n")

    fn ensure_client(mut self) raises:
        """Create the client on first use so `hello` works without a deployment.
        """
        if self.have_client:
            return
        var url = getenv("CONVEX_URL")
        if not url:
            raise Error("ProtocolError|CONVEX_URL is required")
        self.client = Client(url, default_ca_file())
        self.have_client = True

    fn handle(mut self, line: String) raises:
        var doc: Json
        try:
            doc = parse(line)
        except:
            self.emit(
                error_event(
                    String(),
                    String(),
                    String("ProtocolError"),
                    String("malformed adapter command"),
                    String(),
                    String(),
                )
            )
            return
        if doc.kind(doc.root) != J_OBJECT:
            self.emit(
                error_event(
                    String(),
                    String(),
                    String("ProtocolError"),
                    String("malformed adapter command"),
                    String(),
                    String(),
                )
            )
            return
        var id_node = doc.member(doc.root, "id")
        var id = (
            doc.text(id_node) if doc.kind(id_node) == J_STRING else String()
        )
        var op_node = doc.member(doc.root, "op")
        var op = (
            doc.text(op_node) if doc.kind(op_node) == J_STRING else String()
        )

        try:
            self.dispatch(doc, id, op)
        except error:
            var text = String(error)
            self.emit(
                error_event(
                    id,
                    String(),
                    error_name_of(text),
                    error_text_of(text),
                    String(),
                    String(),
                )
            )

    fn dispatch(mut self, doc: Json, id: String, op: String) raises:
        if op == "hello":
            var version = doc.member(doc.root, "protocolVersion")
            if doc.as_int(version) != 1:
                raise Error(
                    "ProtocolError|unsupported adapter protocol version"
                )
            self.emit(
                ready_event(
                    id,
                    String(LANGUAGE_ID),
                    String(IMPLEMENTATION),
                    String("Mojo ") + String(MOJO_VERSION),
                )
            )
            return

        if op == "query" or op == "mutation" or op == "action":
            self.ensure_client()
            var path = doc.text(doc.member(doc.root, "path"))
            var args = doc.dump(doc.member(doc.root, "args"))
            var result = self.client.call(op, path, args)
            if not result.ok:
                self.emit(
                    error_event(
                        id,
                        String(),
                        result.error_name,
                        result.error_message,
                        result.error_data_json,
                        result.logs_json,
                    )
                )
                return
            self.emit(result_event(id, result.value_json, result.logs_json))
            return

        if op == "setAuth":
            self.ensure_client()
            var token_node = doc.member(doc.root, "token")
            var token = (
                doc.text(token_node) if doc.kind(token_node)
                == J_STRING else String()
            )
            self.client.set_auth(token)
            self.emit(simple_event(id, String("ack")))
            return

        if op == "subscribe":
            self.ensure_client()
            var subscription_id = doc.text(
                doc.member(doc.root, "subscriptionId")
            )
            var path = doc.text(doc.member(doc.root, "path"))
            var args = doc.dump(doc.member(doc.root, "args"))
            self.forget(subscription_id)
            self.client.subscribe(subscription_id, path, args)
            self.subscription_ids.append(subscription_id)
            self.emit(simple_event(id, String("ack")))
            return

        if op == "unsubscribe":
            var subscription_id = doc.text(
                doc.member(doc.root, "subscriptionId")
            )
            # Retiring the registration drops everything already queued for it,
            # so the acknowledgement below cannot be overtaken by a stale value.
            self.forget(subscription_id)
            if self.have_client:
                self.client.unsubscribe(subscription_id)
            self.emit(simple_event(id, String("ack")))
            return

        if op == "debugDisconnect":
            self.ensure_client()
            self.client.debug_disconnect()
            self.emit(simple_event(id, String("ack")))
            return

        if op == "close":
            if self.have_client:
                for i in range(len(self.subscription_ids)):
                    self.client.unsubscribe(self.subscription_ids[i])
                self.client.close(1000)
            self.subscription_ids.clear()
            self.emit(simple_event(id, String("closed")))
            self.running = False
            return

        raise Error("ProtocolError|unknown adapter operation")

    fn forget(mut self, subscription_id: String):
        var kept = List[String]()
        for i in range(len(self.subscription_ids)):
            if self.subscription_ids[i] != subscription_id:
                kept.append(self.subscription_ids[i])
        self.subscription_ids = kept^

    fn drain(mut self) raises:
        """Publish every delivery the client has ready for a live registration.
        """
        if not self.have_client:
            return
        for i in range(len(self.subscription_ids)):
            var subscription_id = self.subscription_ids[i]
            while self.client.has_update(subscription_id):
                var update = self.client.take_update(subscription_id)
                self.emit(subscription_event(subscription_id, update))

    fn serve(mut self, mut reader: Reader) raises:
        while self.running:
            reader.poll(5)
            while self.running:
                var line = reader.take_line()
                if not line:
                    break
                self.handle(line)
            if not self.running:
                break
            if reader.eof and len(reader.buffer) == 0:
                break
            if self.have_client:
                self.client.pump(10)
            else:
                _ = poll_fd(Int32(reader.fd), POLLIN, 10)
            self.drain()


fn main() raises:
    var listen = getenv("ADAPTER_LISTEN")
    var in_fd = 0
    var out_fd = 1
    if listen:
        var colon = listen.rfind(":")
        if colon <= 0:
            raise Error("ADAPTER_LISTEN must be host:port")
        var host = String(listen[byte=0:colon])
        var port = Int(listen[byte = colon + 1 : len(listen.as_bytes())])
        var peer = Int(listen_once(host, port))
        in_fd = peer
        out_fd = peer
    var adapter = Adapter(out_fd)
    var reader = Reader(in_fd)
    adapter.serve(reader)
