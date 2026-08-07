import ballerina/crypto;
import ballerina/lang.runtime;
import ballerina/random;
import ballerina/time;

// Hand-rolled RFC 6455 over `RawSocket` (see raw_socket.bal for why that is
// not simply `ballerina/tcp:Client`). `ballerina/websocket` corrupts a
// multi-byte UTF-8 character split across a continuation-frame boundary (a
// fault reproduced and diagnosed in this repository's history, not a doubt
// about this client's own framing); this module never touches that library.
//
// UTF-8 is validated exactly once, on the fully reassembled message, via
// `string:fromBytes` - never per frame - so a scalar split across a
// continuation boundary is judged only once both halves are in hand.

const string WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const int OPCODE_CONTINUATION = 0;
const int OPCODE_TEXT = 1;
const int OPCODE_CLOSE = 8;
const int OPCODE_PING = 9;
const int OPCODE_PONG = 10;

// A conservative per-message byte budget: generous for this demonstration's
// JSON payloads, small enough that a misbehaving peer cannot force unbounded
// buffering while a message is being reassembled.
const int MAX_WEBSOCKET_MESSAGE = 4194304;

# Bytes already read off the socket but not yet consumed by a frame parse.
# Owned exclusively by the single Live-owner strand, so it is a plain class,
# not an isolated one - nothing else ever touches it.
class SocketBuffer {
    private RawSocket sock;
    private byte[] leftover = [];

    function init(RawSocket sock) {
        self.sock = sock;
    }

    // Reads until at least `n` bytes are available (returning exactly `n`
    // and keeping any remainder buffered) or `deadline` (a `time:monotonicNow`
    // reading) passes. A read error before the deadline is retried after a
    // short pause rather than surfaced immediately, so a peer that resets the
    // connection mid-frame is judged by the same deadline as one that simply
    // stalls - the parser state (this buffer) is never restarted mid-message.
    function readExact(int n, decimal deadline) returns byte[]|TransportError {
        while self.leftover.length() < n {
            if time:monotonicNow() >= deadline {
                return error TransportError("WebSocket read did not complete before its deadline", logs = []);
            }
            byte[]|TransportError chunk = self.sock.readSome();
            if chunk is TransportError {
                runtime:sleep(0.01);
                continue;
            }
            self.leftover.push(...chunk);
        }
        byte[] result = self.leftover.slice(0, n);
        self.leftover = self.leftover.slice(n);
        return result;
    }

    // Reads at least one more chunk from the socket (blocking, retrying on
    // transient read errors up to `deadline`), appends it to whatever is
    // already buffered, and returns every buffered byte without consuming
    // it. Used only by the handshake reader below, which does not know in
    // advance how many bytes its terminator is away and must therefore ask
    // for strictly more data each time its search comes up empty.
    function readMoreWithoutConsuming(decimal deadline) returns byte[]|TransportError {
        while true {
            if time:monotonicNow() >= deadline {
                return error TransportError("WebSocket handshake did not complete before its deadline", logs = []);
            }
            byte[]|TransportError chunk = self.sock.readSome();
            if chunk is TransportError {
                runtime:sleep(0.01);
                continue;
            }
            self.leftover.push(...chunk);
            return self.leftover;
        }
    }

    // Consumes exactly the first `n` buffered bytes (already returned by
    // `readSomeWithoutConsuming`), leaving the remainder - which may already
    // be the start of the first WebSocket frame, if the peer pipelined its
    // handshake response and its first frame in the same TCP segment -
    // buffered for the next `readExact` call.
    function consume(int n) {
        self.leftover = self.leftover.slice(n);
    }

    // A thin passthrough so the handshake (which only ever holds a
    // `SocketBuffer`, to guarantee any bytes it over-reads stay visible to
    // the frame reader that follows it) can still send its own request.
    function socketWriteAll(byte[] data) returns TransportError? {
        return self.sock.writeAll(data);
    }
}

function randomBytes(int count) returns byte[] {
    byte[] result = [];
    foreach int _ in 0 ..< count {
        int|error next = random:createIntInRange(0, 256);
        result.push(next is int ? <byte>next : <byte>0);
    }
    return result;
}

# Sends one complete, masked client-to-server frame. Client frames are always
# final (this demonstration never fragments an outgoing message) except the
# handshake, which is plain HTTP and does not go through this function.
function writeFrame(RawSocket sock, int opcode, byte[] payload) returns TransportError? {
    byte[] header = [<byte>(0x80 | opcode)];
    int payloadLength = payload.length();
    if payloadLength <= 125 {
        header.push(<byte>(payloadLength | 0x80));
    } else if payloadLength <= 65535 {
        header.push(<byte>(126 | 0x80));
        header.push(<byte>((payloadLength >> 8) & 0xFF));
        header.push(<byte>(payloadLength & 0xFF));
    } else {
        header.push(<byte>(127 | 0x80));
        int remaining = payloadLength;
        byte[] lengthBytes = [0, 0, 0, 0, 0, 0, 0, 0];
        foreach int index in 0 ..< 8 {
            int position = 7 - index;
            lengthBytes[position] = <byte>(remaining & 0xFF);
            remaining = remaining >> 8;
        }
        header.push(...lengthBytes);
    }
    byte[] mask = randomBytes(4);
    header.push(...mask);
    byte[] masked = [];
    foreach int index in 0 ..< payloadLength {
        masked.push(<byte>(payload[index] ^ mask[index % 4]));
    }
    byte[] frame = header.clone();
    frame.push(...masked);
    return sock.writeAll(frame);
}

# Finds the first occurrence of `\r\n\r\n` (bytes 13,10,13,10) in `data`
# starting at `startIndex`, or `()` if absent. A real server routinely pipelines
# its first WebSocket frame immediately after the handshake response in the
# same TCP segment, so the terminator must be found by scanning raw bytes -
# decoding the whole accumulated buffer as UTF-8 first (as this function
# used to) fails outright once any binary frame bytes have arrived, which
# silently hangs the handshake until its deadline instead of ever finding a
# terminator that was there all along.
function findHeaderTerminator(byte[] data, int startIndex) returns int? {
    int lastValidStart = data.length() - 4;
    int index = startIndex;
    while index <= lastValidStart {
        if data[index] == 13 && data[index + 1] == 10 && data[index + 2] == 13 && data[index + 3] == 10 {
            return index;
        }
        index += 1;
    }
    return ();
}

# Performs the client handshake: sends the HTTP/1.1 Upgrade request and reads
# until the response headers are complete, then checks the status line and
# `Sec-WebSocket-Accept`. `buffer` is the same `SocketBuffer` `readMessage`
# will use afterwards, so any bytes read past the header terminator - the
# start of the server's first frame - stay buffered rather than lost.
function performHandshake(SocketBuffer buffer, string host, string path, decimal deadline) returns TransportError? {
    byte[] keyBytes = randomBytes(16);
    string secWebSocketKey = keyBytes.toBase64();
    string request = "GET " + path + " HTTP/1.1\r\n" +
        "Host: " + host + "\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        "Sec-WebSocket-Key: " + secWebSocketKey + "\r\n" +
        "Sec-WebSocket-Version: 13\r\n" +
        "Convex-Client: ballerina-0.1.0\r\n" +
        "\r\n";
    TransportError? sendError = buffer.socketWriteAll(request.toBytes());
    if sendError is TransportError {
        return error TransportError("handshake request failed: " + sendError.message(), logs = []);
    }

    int searchedFrom = 0;
    byte[] headerBytes = [];
    while true {
        byte[]|TransportError available = buffer.readMoreWithoutConsuming(deadline);
        if available is TransportError {
            return available;
        }
        if available.length() > 16384 {
            return error TransportError("WebSocket handshake response exceeded 16 KiB", logs = []);
        }
        int? terminatorAt = findHeaderTerminator(available, searchedFrom > 3 ? searchedFrom - 3 : 0);
        if terminatorAt is int {
            int headerEnd = terminatorAt + 4;
            headerBytes = available.slice(0, headerEnd);
            buffer.consume(headerEnd);
            break;
        }
        searchedFrom = available.length();
    }

    string|error headerText = string:fromBytes(headerBytes);
    if headerText is error {
        return error TransportError("handshake response was not valid UTF-8", logs = []);
    }
    string[] lines = re `\r\n`.split(headerText);
    if lines.length() == 0 || !lines[0].includes(" 101 ") {
        return error TransportError("handshake did not return HTTP 101: " + lines[0], logs = []);
    }
    string? acceptHeader = ();
    foreach string line in lines {
        int? colon = line.indexOf(":");
        if colon is int {
            string name = line.substring(0, colon).trim().toLowerAscii();
            if name == "sec-websocket-accept" {
                acceptHeader = line.substring(colon + 1).trim();
            }
        }
    }
    if acceptHeader is () {
        return error TransportError("handshake response omitted Sec-WebSocket-Accept", logs = []);
    }
    byte[] expected = crypto:hashSha1((secWebSocketKey + WS_GUID).toBytes(), ());
    if acceptHeader != expected.toBase64() {
        return error TransportError("handshake Sec-WebSocket-Accept did not match the request key", logs = []);
    }
    return ();
}

# One fully reassembled text message: either a decoded UTF-8 payload, or a
# signal that the peer sent a valid Close (in which case the masked Close
# reply has already been sent and the connection must be abandoned).
public type FrameResult record {|
    string? text;
    boolean closed;
|};

# Reads frames until one complete text message has been reassembled,
# transparently absorbing any Ping/Pong/Close frames interleaved with its
# continuation frames. Mirrors the shape proven correct by this repository's
# other hand-rolled clients (see `zig/client/convex.zig`'s `readWebSocket`):
# reject a masked server frame, reject non-minimal length encodings, and
# validate UTF-8 exactly once on the concatenated fragments rather than per
# frame - the concatenation is what may be valid even when neither half is.
function readMessage(SocketBuffer buffer, RawSocket sock, decimal deadline) returns FrameResult|TransportError {
    byte[] fragments = [];
    boolean awaitingContinuation = false;

    while true {
        byte[] header = check buffer.readExact(2, deadline);
        int first = header[0];
        int second = header[1];
        if (first & 0x70) != 0 {
            return error TransportError("WebSocket frame used a reserved bit", logs = []);
        }
        boolean fin = (first & 0x80) != 0;
        int opcode = first & 0x0f;
        boolean masked = (second & 0x80) != 0;
        if masked {
            return error TransportError("server WebSocket frame was masked", logs = []);
        }
        boolean control = (opcode & 0x08) != 0;
        int lengthField = second & 0x7f;
        if control && (!fin || lengthField > 125) {
            return error TransportError("WebSocket control frame was fragmented or oversized", logs = []);
        }
        if control && opcode != OPCODE_CLOSE && opcode != OPCODE_PING && opcode != OPCODE_PONG {
            return error TransportError("WebSocket frame used an unknown control opcode", logs = []);
        }

        int length = lengthField;
        if lengthField == 126 {
            byte[] extended = check buffer.readExact(2, deadline);
            length = (<int>extended[0] << 8) | <int>extended[1];
            if length <= 125 {
                return error TransportError("WebSocket frame used a non-minimal 16-bit length", logs = []);
            }
        } else if lengthField == 127 {
            byte[] extended = check buffer.readExact(8, deadline);
            length = 0;
            foreach byte b in extended {
                length = (length << 8) | <int>b;
            }
            if length <= 65535 {
                return error TransportError("WebSocket frame used a non-minimal 64-bit length", logs = []);
            }
        }
        if length > MAX_WEBSOCKET_MESSAGE || (fragments.length() + length) > MAX_WEBSOCKET_MESSAGE {
            return error TransportError("WebSocket message exceeded the configured maximum size", logs = []);
        }

        byte[] payload = check buffer.readExact(length, deadline);

        if opcode == OPCODE_CLOSE {
            if payload.length() == 1 {
                return error TransportError("WebSocket Close frame carried a truncated status code", logs = []);
            }
            if payload.length() >= 2 {
                int code = (<int>payload[0] << 8) | <int>payload[1];
                boolean validCode = code >= 1000 && code < 5000 && code != 1004 && code != 1005 &&
                    code != 1006 && code != 1015 && !(code >= 1016 && code < 3000);
                if !validCode {
                    return error TransportError("WebSocket Close frame used an invalid status code", logs = []);
                }
                if payload.length() > 2 {
                    string|error reasonText = string:fromBytes(payload.slice(2));
                    if reasonText is error {
                        return error TransportError("WebSocket Close reason was not valid UTF-8", logs = []);
                    }
                }
            }
            TransportError? replyError = writeFrame(sock, OPCODE_CLOSE, payload);
            if replyError is TransportError {
                return replyError;
            }
            return {text: (), closed: true};
        }
        if opcode == OPCODE_PING {
            TransportError? pongError = writeFrame(sock, OPCODE_PONG, payload);
            if pongError is TransportError {
                return pongError;
            }
            continue;
        }
        if opcode == OPCODE_PONG {
            continue;
        }
        if opcode == OPCODE_TEXT {
            if awaitingContinuation {
                return error TransportError("WebSocket text frame arrived mid-continuation", logs = []);
            }
            fragments.push(...payload);
            if fin {
                break;
            }
            awaitingContinuation = true;
            continue;
        }
        if opcode == OPCODE_CONTINUATION {
            if !awaitingContinuation {
                return error TransportError("WebSocket continuation frame arrived without a start", logs = []);
            }
            fragments.push(...payload);
            if fin {
                break;
            }
            continue;
        }
        return error TransportError("WebSocket frame used an unsupported opcode", logs = []);
    }

    string|error text = string:fromBytes(fragments);
    if text is error {
        return error TransportError("WebSocket message was not valid UTF-8 once reassembled", logs = []);
    }
    return {text, closed: false};
}
