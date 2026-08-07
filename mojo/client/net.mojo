"""Sockets and TLS, spoken straight to the C ABI.

Mojo's standard library has no sockets, no TLS and no HTTP, so every byte this
client sends or receives crosses `sys.ffi.external_call` into libc
(`getaddrinfo`, `socket`, `connect`, `poll`, `read`, `write`) and into OpenSSL
(`SSL_CTX_new`, `SSL_connect`, `SSL_read`, `SSL_write`). That is the same set of
C entry points a C client would call; only the spelling is Mojo.

Everything above this file - HTTP framing, WebSocket framing, JSON and the
Convex sync protocol - is written in Mojo on top of the byte stream this file
hands back.
"""

from std.ffi import external_call, c_char, c_int
from std.memory import UnsafePointer, alloc
from std.time import perf_counter_ns

comptime AF_UNSPEC = Int32(0)
comptime AF_INET = Int32(2)
comptime SOCK_STREAM = Int32(1)

# `struct addrinfo` field byte offsets on the LP64 C ABI. glibc and musl agree
# on this layout: four ints, a socklen_t, then three pointers on 8-byte
# boundaries.
comptime AI_FAMILY_OFFSET = 4
comptime AI_SOCKTYPE_OFFSET = 8
comptime AI_PROTOCOL_OFFSET = 12
comptime AI_ADDRLEN_OFFSET = 16
comptime AI_ADDR_OFFSET = 24
comptime AI_NEXT_OFFSET = 40
comptime ADDRINFO_SIZE = 48

comptime F_SETFL = Int32(4)
comptime O_NONBLOCK = Int32(2048)
comptime O_RDONLY = Int32(0)

comptime POLLIN = Int16(1)
comptime POLLOUT = Int16(4)

comptime SOL_SOCKET = Int32(1)
comptime SO_ERROR = Int32(4)

comptime EINTR = 4
comptime EAGAIN = 11
comptime EINPROGRESS = 115

# OpenSSL constants. SSL_CTRL_SET_TLSEXT_HOSTNAME is the `SSL_ctrl` command
# behind the `SSL_set_tlsext_host_name` macro, which the C preprocessor expands
# and therefore never exports as a linkable symbol.
comptime SSL_CTRL_SET_TLSEXT_HOSTNAME = Int32(55)
comptime TLSEXT_NAMETYPE_host_name = Int64(0)
comptime SSL_VERIFY_PEER = Int32(1)
comptime SSL_ERROR_WANT_READ = Int32(2)
comptime SSL_ERROR_WANT_WRITE = Int32(3)

comptime READ_CHUNK = 32768

comptime CPtr = UnsafePointer[UInt8, MutExternalOrigin]
comptime VPtr = OpaquePointer[MutExternalOrigin]


fn now_ms() -> Int:
    """Monotonic milliseconds, used for every deadline in the client."""
    return Int(perf_counter_ns() // 1000000)


fn c_string(value: String) -> CPtr:
    """Copy a Mojo string into a freshly allocated NUL-terminated C string.

    The caller owns the result and must free it. Mojo strings are not
    guaranteed NUL-terminated, so handing their buffer straight to a C function
    that expects `char *` would read past the end.
    """
    var bytes = value.as_bytes()
    var out = alloc[UInt8](len(bytes) + 1)
    for i in range(len(bytes)):
        out[i] = bytes[i]
    out[len(bytes)] = 0
    return out


fn errno() -> Int:
    """Read the calling thread's `errno` through the accessor glibc exports."""
    var location = external_call[
        "__errno_location", UnsafePointer[Int32, MutExternalOrigin]
    ]()
    return Int(location[0])


fn random_bytes(count: Int) raises -> List[UInt8]:
    """Read `count` bytes from the kernel entropy pool.

    WebSocket masking keys and Convex session IDs both need unpredictable
    bytes; a deterministic fallback would make masking pointless.
    """
    var path = c_string("/dev/urandom")
    var fd = external_call["open", c_int](path, O_RDONLY, c_int(0))
    path.free()
    if fd < 0:
        raise Error("TransportError|could not open /dev/urandom")
    var buffer = alloc[UInt8](count)
    var filled = 0
    while filled < count:
        var got = external_call["read", Int](
            Int(fd), buffer + filled, count - filled
        )
        if got <= 0:
            _ = external_call["close", c_int](fd)
            buffer.free()
            raise Error("TransportError|could not read /dev/urandom")
        filled += Int(got)
    _ = external_call["close", c_int](fd)
    var out = List[UInt8]()
    for i in range(count):
        out.append(buffer[i])
    buffer.free()
    return out^


fn poll_fd(fd: Int32, events: Int16, timeout_ms: Int) -> Int16:
    """Wait for `events` on one descriptor and return the reported revents.

    Returns 0 on timeout. `poll` is used rather than blocking reads so that
    every network wait in this client carries a deadline.
    """
    var cell = alloc[UInt8](8)
    cell.bitcast[Int32]()[0] = fd
    cell.bitcast[Int16]()[2] = events
    cell.bitcast[Int16]()[3] = 0
    var remaining = timeout_ms
    var revents: Int16
    while True:
        var started = now_ms()
        var ready = external_call["poll", c_int](
            cell, UInt64(1), Int32(remaining)
        )
        if ready < 0:
            if errno() == EINTR:
                # A signal interrupted the wait. Charge the elapsed time to the
                # deadline rather than restarting it, so an interrupted poll
                # cannot extend a bounded close.
                remaining -= now_ms() - started
                if remaining < 0:
                    remaining = 0
                continue
            revents = 0
            break
        if ready == 0:
            revents = 0
            break
        revents = cell.bitcast[Int16]()[3]
        break
    cell.free()
    return revents


struct Conn(Movable):
    """One TCP connection, optionally wrapped in TLS, plus its read buffer.

    HTTP responses and WebSocket frames are both parsed by peeking at buffered
    bytes, so the buffer lives here rather than being rebuilt by each caller.
    """

    var fd: Int32
    var ssl: VPtr
    var ctx: VPtr
    var tls: Bool
    var buffer: List[UInt8]
    var position: Int
    var closed: Bool

    fn __init__(out self):
        self.fd = -1
        self.ssl = VPtr()
        self.ctx = VPtr()
        self.tls = False
        self.buffer = List[UInt8]()
        self.position = 0
        self.closed = True

    fn __del__(deinit self):
        self.shutdown()

    fn shutdown(mut self):
        """Release the TLS objects and the descriptor exactly once."""
        if self.ssl:
            _ = external_call["SSL_shutdown", c_int](self.ssl)
            external_call["SSL_free", NoneType](self.ssl)
            self.ssl = VPtr()
        if self.ctx:
            external_call["SSL_CTX_free", NoneType](self.ctx)
            self.ctx = VPtr()
        if self.fd >= 0:
            _ = external_call["close", c_int](self.fd)
            self.fd = -1
        self.closed = True

    fn buffered(self) -> Int:
        return len(self.buffer) - self.position

    fn peek(self, offset: Int) -> UInt8:
        return self.buffer[self.position + offset]

    fn consume(mut self, count: Int):
        """Drop `count` parsed bytes, compacting when the buffer is drained."""
        self.position += count
        if self.position == len(self.buffer):
            self.buffer.clear()
            self.position = 0

    fn ready(self, timeout_ms: Int) -> Bool:
        """True when a read would make progress without blocking.

        OpenSSL may hold whole decrypted records that the kernel has already
        delivered, so asking `poll` alone would sleep on data we already have.
        """
        if self.buffered() > 0:
            return True
        if self.tls and self.ssl:
            if external_call["SSL_pending", c_int](self.ssl) > 0:
                return True
        if self.fd < 0:
            return False
        return (poll_fd(self.fd, POLLIN, timeout_ms) & POLLIN) != 0

    fn fill(mut self, deadline: Int) raises -> Int:
        """Read one chunk into the buffer.

        Returns the byte count, 0 at end of stream, or -1 when the deadline
        passed with nothing more available. A deadline is not an error: a
        half-delivered frame stays in the buffer and the caller retries at the
        same boundary rather than abandoning a healthy but slow connection.
        """
        if self.fd < 0:
            raise Error("TransportError|connection is closed")
        var scratch = alloc[UInt8](READ_CHUNK)
        var result = 0
        var failure = String()
        while True:
            var got: Int
            if self.tls:
                var read = external_call["SSL_read", c_int](
                    self.ssl, scratch, Int32(READ_CHUNK)
                )
                if read > 0:
                    got = Int(read)
                else:
                    var code = external_call["SSL_get_error", c_int](
                        self.ssl, read
                    )
                    if (
                        code == SSL_ERROR_WANT_READ
                        or code == SSL_ERROR_WANT_WRITE
                    ):
                        got = -1
                    elif read == 0:
                        got = 0
                    else:
                        failure = "TransportError|TLS read failed"
                        break
            else:
                var read = external_call["read", Int](
                    Int(self.fd), scratch, READ_CHUNK
                )
                if read > 0:
                    got = Int(read)
                elif read == 0:
                    got = 0
                elif errno() == EAGAIN or errno() == EINTR:
                    got = -1
                else:
                    failure = "TransportError|socket read failed"
                    break
            if got >= 0:
                if got > 0:
                    for i in range(got):
                        self.buffer.append(scratch[i])
                result = got
                break
            var remaining = deadline - now_ms()
            if remaining <= 0:
                result = -1
                break
            if poll_fd(self.fd, POLLIN | POLLOUT, remaining) == 0:
                result = -1
                break
        scratch.free()
        if failure:
            raise Error(failure)
        return result

    fn write_all(mut self, data: Span[UInt8, _], deadline: Int) raises:
        """Send every byte or raise; partial writes are retried against poll."""
        if self.fd < 0:
            raise Error("TransportError|connection is closed")
        var total = len(data)
        if total == 0:
            return
        var scratch = alloc[UInt8](total)
        for i in range(total):
            scratch[i] = data[i]
        var sent = 0
        var failure = String()
        while sent < total:
            var wrote: Int
            if self.tls:
                var result = external_call["SSL_write", c_int](
                    self.ssl, scratch + sent, Int32(total - sent)
                )
                if result > 0:
                    wrote = Int(result)
                else:
                    var code = external_call["SSL_get_error", c_int](
                        self.ssl, result
                    )
                    if (
                        code == SSL_ERROR_WANT_READ
                        or code == SSL_ERROR_WANT_WRITE
                    ):
                        wrote = -1
                    else:
                        failure = "TransportError|TLS write failed"
                        break
            else:
                var result = external_call["write", Int](
                    Int(self.fd), scratch + sent, total - sent
                )
                if result > 0:
                    wrote = Int(result)
                elif errno() == EAGAIN or errno() == EINTR:
                    wrote = -1
                else:
                    failure = "TransportError|socket write failed"
                    break
            if wrote > 0:
                sent += wrote
                continue
            var remaining = deadline - now_ms()
            if remaining <= 0:
                failure = "TransportError|write timed out"
                break
            _ = poll_fd(self.fd, POLLOUT | POLLIN, remaining)
        scratch.free()
        if failure:
            raise Error(failure)


fn set_nonblocking(fd: Int32) raises:
    if external_call["fcntl", c_int](fd, F_SETFL, O_NONBLOCK) < 0:
        raise Error("TransportError|could not make the socket non-blocking")


fn tcp_connect(host: String, port: Int, deadline: Int) raises -> Int32:
    """Resolve `host` and connect to the first address that answers.

    Every candidate `getaddrinfo` returns is tried in turn. Docker's default
    bridge has no IPv6 route, so an AAAA answer fails immediately here and the
    loop falls through to the A record instead of stalling the client.
    """
    var hints = alloc[UInt8](ADDRINFO_SIZE)
    for i in range(ADDRINFO_SIZE):
        hints[i] = 0
    hints.bitcast[Int32]()[AI_FAMILY_OFFSET // 4] = AF_UNSPEC
    hints.bitcast[Int32]()[AI_SOCKTYPE_OFFSET // 4] = SOCK_STREAM

    var host_c = c_string(host)
    var port_c = c_string(String(port))
    var results = alloc[CPtr](1)
    results[0] = CPtr()
    var status = external_call["getaddrinfo", c_int](
        host_c, port_c, hints, results
    )
    host_c.free()
    port_c.free()
    hints.free()
    if status != 0:
        results.free()
        raise Error("TransportError|could not resolve " + host)

    var head = results[0]
    var node = head
    var fd = Int32(-1)
    while node:
        var family = node.bitcast[Int32]()[AI_FAMILY_OFFSET // 4]
        var socktype = node.bitcast[Int32]()[AI_SOCKTYPE_OFFSET // 4]
        var protocol = node.bitcast[Int32]()[AI_PROTOCOL_OFFSET // 4]
        var addrlen = node.bitcast[Int32]()[AI_ADDRLEN_OFFSET // 4]
        var address = (node + AI_ADDR_OFFSET).bitcast[CPtr]()[0]
        var candidate = external_call["socket", c_int](
            family, socktype, protocol
        )
        if candidate >= 0:
            if _connect_one(candidate, address, addrlen, deadline):
                fd = candidate
                break
            _ = external_call["close", c_int](candidate)
        node = (node + AI_NEXT_OFFSET).bitcast[CPtr]()[0]

    external_call["freeaddrinfo", NoneType](head)
    results.free()
    if fd < 0:
        raise Error("TransportError|could not connect to " + host)
    return fd


fn _connect_one(
    fd: Int32, address: CPtr, addrlen: Int32, deadline: Int
) -> Bool:
    """Non-blocking connect with a deadline, reporting success as a Bool."""
    try:
        set_nonblocking(fd)
    except:
        return False
    var result = external_call["connect", c_int](fd, address, addrlen)
    if result == 0:
        return True
    if errno() != EINPROGRESS:
        return False
    var remaining = deadline - now_ms()
    if remaining <= 0:
        return False
    if (poll_fd(fd, POLLOUT, remaining) & POLLOUT) == 0:
        return False
    # A writable socket is not a connected socket: the pending error has to be
    # read back before any bytes are trusted.
    var pending = alloc[Int32](1)
    pending[0] = 0
    var length = alloc[Int32](1)
    length[0] = 4
    var status = external_call["getsockopt", c_int](
        fd, SOL_SOCKET, SO_ERROR, pending, length
    )
    var connected = status == 0 and pending[0] == 0
    pending.free()
    length.free()
    return connected


fn tls_wrap(
    mut conn: Conn, host: String, ca_file: String, deadline: Int
) raises:
    """Perform the TLS handshake and verify the server certificate.

    `SSL_set1_host` puts the expected name into the verification parameters, so
    OpenSSL rejects a valid certificate issued for someone else rather than
    leaving that check to this client.
    """
    var method = external_call["TLS_client_method", VPtr]()
    var ctx = external_call["SSL_CTX_new", VPtr](method)
    if not ctx:
        raise Error("TransportError|could not create a TLS context")
    conn.ctx = ctx

    var bundle = c_string(ca_file)
    var loaded = external_call["SSL_CTX_load_verify_locations", c_int](
        ctx, bundle, VPtr()
    )
    bundle.free()
    if loaded != 1:
        raise Error(
            "TransportError|could not load the CA bundle from " + ca_file
        )
    external_call["SSL_CTX_set_verify", NoneType](ctx, SSL_VERIFY_PEER, VPtr())

    var ssl = external_call["SSL_new", VPtr](ctx)
    if not ssl:
        raise Error("TransportError|could not create a TLS session")
    conn.ssl = ssl
    conn.tls = True
    _ = external_call["SSL_set_fd", c_int](ssl, conn.fd)

    var name = c_string(host)
    _ = external_call["SSL_ctrl", Int64](
        ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, name
    )
    var verified = external_call["SSL_set1_host", c_int](ssl, name)
    name.free()
    if verified != 1:
        raise Error("TransportError|could not pin the TLS hostname")

    while True:
        var result = external_call["SSL_connect", c_int](ssl)
        if result == 1:
            break
        var code = external_call["SSL_get_error", c_int](ssl, result)
        if code != SSL_ERROR_WANT_READ and code != SSL_ERROR_WANT_WRITE:
            raise Error("TransportError|TLS handshake failed")
        var remaining = deadline - now_ms()
        if remaining <= 0:
            raise Error("TransportError|TLS handshake timed out")
        var wanted = POLLIN if code == SSL_ERROR_WANT_READ else POLLOUT
        if poll_fd(conn.fd, wanted, remaining) == 0:
            raise Error("TransportError|TLS handshake timed out")

    if external_call["SSL_get_verify_result", Int64](ssl) != 0:
        raise Error("TransportError|the server certificate did not verify")


fn connect(
    host: String, port: Int, use_tls: Bool, ca_file: String, timeout_ms: Int
) raises -> Conn:
    """Open a connection, optionally upgrading it to TLS, within one deadline.
    """
    var deadline = now_ms() + timeout_ms
    var conn = Conn()
    conn.fd = tcp_connect(host, port, deadline)
    conn.closed = False
    if use_tls:
        tls_wrap(conn, host, ca_file, deadline)
    return conn^


fn tls_cipher(conn: Conn) -> String:
    """The negotiated cipher suite, for diagnostics on stderr."""
    if not conn.tls or not conn.ssl:
        return String("plaintext")
    var cipher = external_call["SSL_get_current_cipher", VPtr](conn.ssl)
    if not cipher:
        return String("unknown")
    var name = external_call[
        "SSL_CIPHER_get_name", UnsafePointer[c_char, MutExternalOrigin]
    ](cipher)
    if not name:
        return String("unknown")
    return String(unsafe_from_utf8_ptr=name.bitcast[UInt8]())


fn listen_once(host: String, port: Int) raises -> Int32:
    """Bind an IPv4 listener and accept exactly one controller connection.

    The shared harness drives the conformance adapter over TCP. Only one
    controller ever connects, so the accepted descriptor replaces stdin and
    stdout for the rest of the run.
    """
    var fd = external_call["socket", c_int](AF_INET, SOCK_STREAM, Int32(0))
    if fd < 0:
        raise Error("TransportError|could not create the listening socket")
    var reuse = alloc[Int32](1)
    reuse[0] = 1
    _ = external_call["setsockopt", c_int](
        fd, SOL_SOCKET, Int32(2), reuse, Int32(4)
    )
    reuse.free()

    # struct sockaddr_in: family (2), port in network order (2), address (4).
    var address = alloc[UInt8](16)
    for i in range(16):
        address[i] = 0
    address.bitcast[Int16]()[0] = Int16(AF_INET)
    address[2] = UInt8((port >> 8) & 0xFF)
    address[3] = UInt8(port & 0xFF)
    var host_c = c_string(host)
    var parsed = external_call["inet_pton", c_int](AF_INET, host_c, address + 4)
    host_c.free()
    if parsed != 1:
        address.free()
        _ = external_call["close", c_int](fd)
        raise Error(
            "TransportError|ADAPTER_LISTEN host must be an IPv4 address"
        )
    var bound = external_call["bind", c_int](fd, address, Int32(16))
    address.free()
    if bound != 0:
        _ = external_call["close", c_int](fd)
        raise Error("TransportError|could not bind the adapter listener")
    if external_call["listen", c_int](fd, Int32(1)) != 0:
        _ = external_call["close", c_int](fd)
        raise Error("TransportError|could not listen on the adapter socket")
    var peer = external_call["accept", c_int](fd, VPtr(), VPtr())
    _ = external_call["close", c_int](fd)
    if peer < 0:
        raise Error("TransportError|could not accept the controller connection")
    return peer
