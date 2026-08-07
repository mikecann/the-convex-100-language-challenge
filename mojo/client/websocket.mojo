"""RFC 6455 WebSocket framing, written from the specification.

Nothing here is delegated: the opening handshake, SHA-1 for the accept token,
client masking, continuation assembly, control frames and the close handshake
are all implemented in Mojo over the byte stream from `net.mojo`.

A frame is only consumed from the connection buffer once every one of its bytes
has arrived. A read that times out therefore leaves the buffer exactly as it
was, so the next attempt resumes at the same frame boundary instead of
misreading a payload byte as an opcode.
"""

from std.base64 import b64encode

from http import HeaderBlock, read_headers
from net import Conn, now_ms, random_bytes

comptime OP_CONTINUATION = 0
comptime OP_TEXT = 1
comptime OP_BINARY = 2
comptime OP_CLOSE = 8
comptime OP_PING = 9
comptime OP_PONG = 10

# The magic value RFC 6455 appends to the client key before hashing.
comptime WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

comptime MAX_FRAME_BYTES = 4 * 1024 * 1024
comptime MAX_MESSAGE_BYTES = 8 * 1024 * 1024


fn sha1(data: Span[UInt8, _]) -> List[UInt8]:
    """SHA-1 over `data`, used only for the WebSocket accept token."""
    var h0 = UInt32(0x67452301)
    var h1 = UInt32(0xEFCDAB89)
    var h2 = UInt32(0x98BADCFE)
    var h3 = UInt32(0x10325476)
    var h4 = UInt32(0xC3D2E1F0)

    var message = List[UInt8]()
    for i in range(len(data)):
        message.append(data[i])
    var bit_length = UInt64(len(data)) * 8
    message.append(0x80)
    while len(message) % 64 != 56:
        message.append(0)
    for shift in range(8):
        message.append(UInt8((bit_length >> UInt64(56 - shift * 8)) & 0xFF))

    var words = List[UInt32](length=80, fill=0)
    for block in range(len(message) // 64):
        var base = block * 64
        for i in range(16):
            words[i] = (
                (UInt32(message[base + i * 4]) << 24)
                | (UInt32(message[base + i * 4 + 1]) << 16)
                | (UInt32(message[base + i * 4 + 2]) << 8)
                | UInt32(message[base + i * 4 + 3])
            )
        for i in range(16, 80):
            var mixed = (
                words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16]
            )
            words[i] = rotate_left(mixed, 1)

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        for i in range(80):
            var f: UInt32
            var k: UInt32
            if i < 20:
                f = (b & c) | ((~b) & d)
                k = 0x5A827999
            elif i < 40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            elif i < 60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            else:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            var temporary = rotate_left(a, 5) + f + e + k + words[i]
            e = d
            d = c
            c = rotate_left(b, 30)
            b = a
            a = temporary
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e

    var digest = List[UInt8]()
    var state = List[UInt32]()
    state.append(h0)
    state.append(h1)
    state.append(h2)
    state.append(h3)
    state.append(h4)
    for i in range(5):
        for shift in range(4):
            digest.append(UInt8((state[i] >> UInt32(24 - shift * 8)) & 0xFF))
    return digest^


fn rotate_left(value: UInt32, count: Int) -> UInt32:
    return (value << UInt32(count)) | (value >> UInt32(32 - count))


struct Message(Copyable, Movable):
    """One decoded WebSocket message, or the marker that none was ready."""

    var present: Bool
    var text: String

    fn __init__(out self, present: Bool, text: String):
        self.present = present
        self.text = text


struct WebSocket(Movable):
    """A client-side WebSocket with its own reassembly state."""

    var conn: Conn
    var assembling: Bool
    var message: List[UInt8]
    var open: Bool

    fn __init__(out self, var conn: Conn):
        self.open = conn.fd >= 0
        self.conn = conn^
        self.assembling = False
        self.message = List[UInt8]()

    fn close(mut self, deadline: Int):
        """Send a courtesy close frame and drop the connection either way."""
        if self.open:
            var payload = List[UInt8]()
            payload.append(0x03)
            payload.append(0xE8)
            try:
                self.send_frame(OP_CLOSE, Span(payload), deadline)
            except:
                pass
            self.open = False
        self.conn.shutdown()

    fn send_text(mut self, text: String, deadline: Int) raises:
        self.send_frame(OP_TEXT, text.as_bytes(), deadline)

    fn send_frame(
        mut self, opcode: Int, payload: Span[UInt8, _], deadline: Int
    ) raises:
        """Emit one masked client frame.

        RFC 6455 requires every client-to-server frame to be masked with a
        fresh unpredictable key, so the key comes from the kernel rather than
        from a counter.
        """
        var frame = List[UInt8]()
        frame.append(UInt8(0x80 | opcode))
        var length = len(payload)
        if length < 126:
            frame.append(UInt8(0x80 | length))
        elif length < 65536:
            frame.append(0xFE)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        else:
            frame.append(0xFF)
            for shift in range(8):
                frame.append(UInt8((length >> (56 - shift * 8)) & 0xFF))
        var key = random_bytes(4)
        for i in range(4):
            frame.append(key[i])
        for i in range(length):
            frame.append(payload[i] ^ key[i % 4])
        self.conn.write_all(Span(frame), deadline)

    fn ready(self, timeout_ms: Int) -> Bool:
        return self.conn.ready(timeout_ms)

    fn poll_message(mut self, deadline: Int) raises -> Message:
        """Return the next complete text message, or a "not ready" marker.

        Control frames are handled here and never surface to the caller, which
        is what lets a ping arrive in the middle of a fragmented message
        without disturbing the assembly buffer.
        """
        while True:
            var frame = self._take_frame(deadline)
            if not frame.present:
                return Message(False, String())
            if frame.opcode == OP_PING:
                self.send_frame(OP_PONG, Span(frame.payload), deadline)
                continue
            if frame.opcode == OP_PONG:
                continue
            if frame.opcode == OP_CLOSE:
                self.open = False
                raise Error(
                    "TransportError|the server closed the Live WebSocket"
                )
            if frame.opcode == OP_BINARY:
                raise Error("ProtocolError|Live sent a binary frame")
            if frame.opcode == OP_TEXT:
                if self.assembling:
                    raise Error(
                        "ProtocolError|Live interleaved two text messages"
                    )
                self.message.clear()
            elif frame.opcode == OP_CONTINUATION:
                if not self.assembling:
                    raise Error(
                        "ProtocolError|Live continuation without a start"
                    )
            else:
                raise Error("ProtocolError|Live sent an unknown opcode")

            if len(self.message) + len(frame.payload) > MAX_MESSAGE_BYTES:
                raise Error(
                    "ProtocolError|Live message exceeded the size limit"
                )
            for i in range(len(frame.payload)):
                self.message.append(frame.payload[i])
            if not frame.final:
                self.assembling = True
                continue
            self.assembling = False
            # UTF-8 validity is a property of the whole message, not of any one
            # fragment: a codepoint may legitimately straddle a frame boundary,
            # so validation happens exactly once, here.
            var text = String(from_utf8=Span(self.message))
            self.message.clear()
            return Message(True, text)

    fn _take_frame(mut self, deadline: Int) raises -> Frame:
        """Peek a complete frame and only then consume its bytes."""
        while True:
            var parsed = self._parse_buffered()
            if parsed.present:
                return parsed^
            var remaining = deadline - now_ms()
            if remaining <= 0:
                return Frame()
            if not self.conn.ready(remaining):
                return Frame()
            var got = self.conn.fill(deadline)
            if got == 0:
                raise Error(
                    "TransportError|the Live connection ended mid-frame"
                )
            if got < 0:
                # Nothing more arrived in time. Every byte of the incomplete
                # frame is still buffered, so the next attempt resumes here.
                return Frame()

    fn _parse_buffered(mut self) raises -> Frame:
        var available = self.conn.buffered()
        if available < 2:
            return Frame()
        var first = Int(self.conn.peek(0))
        var second = Int(self.conn.peek(1))
        var final = (first & 0x80) != 0
        var reserved = first & 0x70
        var opcode = first & 0x0F
        if reserved != 0:
            raise Error("ProtocolError|Live set a reserved WebSocket bit")
        if (second & 0x80) != 0:
            raise Error("ProtocolError|Live masked a server frame")
        var length = second & 0x7F
        var offset = 2
        if length == 126:
            if available < 4:
                return Frame()
            length = (Int(self.conn.peek(2)) << 8) | Int(self.conn.peek(3))
            offset = 4
        elif length == 127:
            if available < 10:
                return Frame()
            length = 0
            for i in range(8):
                length = (length << 8) | Int(self.conn.peek(2 + i))
            offset = 10
        if length > MAX_FRAME_BYTES:
            raise Error("ProtocolError|Live frame exceeded the size limit")
        var is_control = opcode >= OP_CLOSE
        if is_control and (length > 125 or not final):
            raise Error("ProtocolError|Live sent an invalid control frame")
        if available < offset + length:
            return Frame()
        var payload = List[UInt8]()
        for i in range(length):
            payload.append(self.conn.peek(offset + i))
        self.conn.consume(offset + length)
        return Frame(True, final, opcode, payload^)


struct Frame(Movable):
    var present: Bool
    var final: Bool
    var opcode: Int
    var payload: List[UInt8]

    fn __init__(out self):
        self.present = False
        self.final = False
        self.opcode = 0
        self.payload = List[UInt8]()

    fn __init__(
        out self,
        present: Bool,
        final: Bool,
        opcode: Int,
        var payload: List[UInt8],
    ):
        self.present = present
        self.final = final
        self.opcode = opcode
        self.payload = payload^


fn accept_token(key: String) -> String:
    """The `Sec-WebSocket-Accept` value the server must return for `key`."""
    var combined = key + WS_GUID
    return b64encode(Span(sha1(combined.as_bytes())))


fn handshake(
    var conn: Conn,
    host: String,
    port: Int,
    path: String,
    client_version: String,
    deadline: Int,
) raises -> WebSocket:
    """Perform the opening handshake and verify the server's accept token.

    Checking the token is what proves the peer is a WebSocket endpoint rather
    than a proxy that happened to answer 101, so a mismatch aborts here instead
    of surfacing as unreadable framing later.
    """
    var key = b64encode(Span(random_bytes(16)))
    var request = String("GET ")
    request += path
    request += " HTTP/1.1\r\nHost: "
    request += host
    if port != 443 and port != 80:
        request += ":"
        request += String(port)
    request += "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    request += "Sec-WebSocket-Key: "
    request += key
    request += "\r\nSec-WebSocket-Version: 13\r\nConvex-Client: "
    request += client_version
    request += "\r\n\r\n"

    var socket = WebSocket(conn^)
    socket.conn.write_all(request.as_bytes(), deadline)
    var headers = read_headers(socket.conn, deadline)
    if headers.status != 101:
        raise Error(
            "TransportError|Live handshake returned HTTP "
            + String(headers.status)
        )
    if headers.value("upgrade").lower() != "websocket":
        raise Error("ProtocolError|Live handshake did not upgrade")
    if headers.value("sec-websocket-accept") != accept_token(key):
        raise Error(
            "ProtocolError|Live handshake returned a wrong accept token"
        )
    return socket^
