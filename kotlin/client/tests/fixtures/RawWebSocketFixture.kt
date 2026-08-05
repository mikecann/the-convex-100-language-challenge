package convex.kotlin.testing

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Duration
import java.util.Base64
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * A deliberately tiny RFC 6455 peer for exercising the JDK WebSocket client.
 * It speaks raw frames so tests can split UTF-8, stall mid-frame, and terminate
 * transport without another WebSocket implementation hiding those details.
 */
class RawWebSocketFixture(
    private val handler: (Connection, Int) -> Unit,
) : AutoCloseable {
    private val server = ServerSocket(0, 50, java.net.InetAddress.getLoopbackAddress())
    private val workers =
        Executors.newCachedThreadPool { task ->
            Thread(task, "raw-websocket-fixture").apply { isDaemon = true }
        }
    private val failures = ConcurrentLinkedQueue<Throwable>()
    private val connectionCounter = AtomicInteger()
    private val accepted = CountDownLatch(1)

    val url = "http://127.0.0.1:${server.localPort}"

    init {
        workers.execute {
            while (!server.isClosed) {
                try {
                    val socket = server.accept()
                    val index = connectionCounter.getAndIncrement()
                    accepted.countDown()
                    workers.execute {
                        try {
                            Connection(socket).use { connection ->
                                connection.handshake()
                                handler(connection, index)
                            }
                        } catch (error: Throwable) {
                            if (!server.isClosed && error !is IOException && error !is InterruptedException) {
                                failures += error
                            }
                        }
                    }
                } catch (error: Throwable) {
                    if (!server.isClosed) failures += error
                }
            }
        }
    }

    fun awaitConnection(timeout: Duration = Duration.ofSeconds(3)) =
        check(accepted.await(timeout.toMillis(), TimeUnit.MILLISECONDS)) {
            "WebSocket client did not connect"
        }

    fun assertHealthy() {
        failures.poll()?.let { throw AssertionError("raw WebSocket fixture failed", it) }
    }

    override fun close() {
        server.close()
        workers.shutdownNow()
        workers.awaitTermination(2, TimeUnit.SECONDS)
        assertHealthy()
    }

    class Connection internal constructor(
        private val socket: Socket,
    ) : AutoCloseable {
        private val input = DataInputStream(socket.getInputStream())
        private val output = socket.getOutputStream()

        internal fun handshake() {
            val request = readHttpHeaders()
            val key =
                request
                    .lineSequence()
                    .firstOrNull { it.startsWith("Sec-WebSocket-Key:", ignoreCase = true) }
                    ?.substringAfter(':')
                    ?.trim()
                    ?: error("handshake omitted Sec-WebSocket-Key")
            val accept =
                Base64.getEncoder().encodeToString(
                    MessageDigest
                        .getInstance("SHA-1")
                        .digest("$key$WEBSOCKET_GUID".toByteArray(StandardCharsets.US_ASCII)),
                )
            output.write(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n" +
                        "Upgrade: websocket\r\n" +
                        "Connection: Upgrade\r\n" +
                        "Sec-WebSocket-Accept: $accept\r\n\r\n"
                ).toByteArray(StandardCharsets.US_ASCII),
            )
            output.flush()
        }

        fun readText(timeout: Duration = Duration.ofSeconds(3)): String {
            socket.soTimeout = timeout.toMillis().toInt()
            val message = ByteArrayOutputStream()
            var started = false
            while (true) {
                val frame = readFrame()
                when (frame.opcode) {
                    0x1 -> {
                        check(!started) { "nested text frame" }
                        started = true
                        message.write(frame.payload)
                    }
                    0x0 -> {
                        check(started) { "continuation without text frame" }
                        message.write(frame.payload)
                    }
                    0x8 -> throw EOFException("client closed WebSocket")
                    0x9 -> sendFrame(0xA, frame.payload)
                    0xA -> continue
                    else -> error("unexpected client opcode ${frame.opcode}")
                }
                if (started && frame.final) {
                    return message.toByteArray().toString(StandardCharsets.UTF_8)
                }
            }
        }

        @Synchronized
        fun sendText(text: String) = sendFrame(0x1, text.toByteArray(StandardCharsets.UTF_8))

        /** Split inside a multibyte code point and interleave a control frame. */
        @Synchronized
        fun sendFragmentedText(
            text: String,
            firstFragmentBytes: Int,
        ) {
            val bytes = text.toByteArray(StandardCharsets.UTF_8)
            require(firstFragmentBytes in 1 until bytes.size)
            sendFrame(0x1, bytes.copyOfRange(0, firstFragmentBytes), final = false, flush = false)
            sendFrame(0x9, "probe".toByteArray(), flush = false)
            sendFrame(0x0, bytes.copyOfRange(firstFragmentBytes, bytes.size), flush = true)
        }

        @Synchronized
        fun sendPing(payload: String = "ping") = sendFrame(0x9, payload.toByteArray())

        /** Consume a frame prefix, then leave the peer blocked in its payload parser. */
        @Synchronized
        fun sendPartialText(
            declaredLength: Int,
            prefix: ByteArray,
        ) {
            require(declaredLength in 1..125 && prefix.size < declaredLength)
            output.write(byteArrayOf(0x81.toByte(), declaredLength.toByte()))
            output.write(prefix)
            output.flush()
        }

        fun closeTransport() = socket.close()

        /** Force an I/O reset instead of performing a cooperative WebSocket close. */
        fun abortTransport() {
            socket.setSoLinger(true, 0)
            socket.close()
        }

        fun awaitClientClose(timeout: Duration = Duration.ofSeconds(3)) {
            socket.soTimeout = timeout.toMillis().toInt()
            try {
                while (input.read() != -1) {
                    // An abort can arrive after queued bytes. Drain until EOF.
                }
            } catch (_: SocketTimeoutException) {
                error("client did not retire the old connection")
            }
        }

        override fun close() = socket.close()

        private fun readHttpHeaders(): String {
            val bytes = ByteArrayOutputStream()
            var matched = 0
            val terminator = byteArrayOf(13, 10, 13, 10)
            while (matched < terminator.size) {
                val byte = input.read()
                if (byte < 0) throw EOFException("handshake ended early")
                bytes.write(byte)
                matched = if (byte.toByte() == terminator[matched]) matched + 1 else 0
                check(bytes.size() <= 32 * 1024) { "oversized HTTP handshake" }
            }
            return bytes.toString(StandardCharsets.US_ASCII)
        }

        private fun readFrame(): Frame {
            val first = input.readUnsignedByte()
            val second = input.readUnsignedByte()
            val final = first and 0x80 != 0
            val opcode = first and 0x0f
            val masked = second and 0x80 != 0
            var length = second and 0x7f
            if (length == 126) length = input.readUnsignedShort()
            if (length == 127) {
                val longLength = input.readLong()
                require(longLength <= Int.MAX_VALUE) { "fixture frame is too large" }
                length = longLength.toInt()
            }
            check(masked) { "client frames must be masked" }
            val mask = ByteArray(4).also(input::readFully)
            val payload = ByteArray(length).also(input::readFully)
            payload.indices.forEach { index ->
                payload[index] = (payload[index].toInt() xor mask[index % 4].toInt()).toByte()
            }
            return Frame(final, opcode, payload)
        }

        private fun sendFrame(
            opcode: Int,
            payload: ByteArray,
            final: Boolean = true,
            flush: Boolean = true,
        ) {
            output.write((if (final) 0x80 else 0x00) or opcode)
            when {
                payload.size < 126 -> output.write(payload.size)
                payload.size <= 65_535 -> {
                    output.write(126)
                    output.write(payload.size ushr 8)
                    output.write(payload.size and 0xff)
                }
                else -> error("fixture payload too large")
            }
            output.write(payload)
            if (flush) output.flush()
        }
    }

    private data class Frame(
        val final: Boolean,
        val opcode: Int,
        val payload: ByteArray,
    )

    private companion object {
        const val WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    }
}
