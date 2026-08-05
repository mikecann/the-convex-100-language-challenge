package convex.kotlin.adapter

import com.sun.net.httpserver.HttpServer
import convex.kotlin.ConvexClient
import convex.kotlin.testing.RawWebSocketFixture
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.PipedReader
import java.io.PipedWriter
import java.io.StringReader
import java.io.StringWriter
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.time.Duration
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AdapterTest {
    @AfterTest
    fun resetHooks() = AdapterTestHooks.reset()

    @Test
    fun `stdin protocol serializes success structured function error and close without null fields`() {
        httpServer { path ->
            if (path == "demo:fail") {
                560 to """{"status":"error","errorMessage":"nope","errorData":{"code":"NOPE"},"logLines":["failed"]}"""
            } else {
                200 to """{"status":"success","value":{"count":1},"logLines":["ok"]}"""
            }
        }.use { server ->
            val input =
                listOf(
                    command("h", "hello") { put("protocolVersion", 1) },
                    command("q", "query") {
                        put("path", "demo:state")
                        put("args", JsonObject(emptyMap()))
                    },
                    command("f", "query") {
                        put("path", "demo:fail")
                        put("args", JsonObject(emptyMap()))
                    },
                    command("c", "close"),
                ).joinToString("\n", postfix = "\n") { encode(it) }
            val output = StringWriter()
            runAdapter(BufferedReader(StringReader(input)), BufferedWriter(output), server.url)
            val events =
                output
                    .toString()
                    .lineSequence()
                    .filter(String::isNotBlank)
                    .map(::decode)
                    .toList()

            assertEquals(listOf("ready", "result", "error", "closed"), events.map { it.type })
            assertEquals("native-kotlin-jdk21", events[0]["implementation"]!!.jsonPrimitive.content)
            assertEquals(1, events[1]["value"]!!.jsonObject["count"]!!.jsonPrimitive.int)
            assertEquals(listOf("ok"), events[1]["logs"]!!.jsonArray.map { it.jsonPrimitive.content })
            assertEquals("FunctionError", events[2]["error"]!!.jsonObject["name"]!!.jsonPrimitive.content)
            assertEquals(
                "NOPE",
                events[2]["error"]!!
                    .jsonObject["data"]!!
                    .jsonObject["code"]!!
                    .jsonPrimitive.content,
            )
            events.forEach { event ->
                assertFalse(event.values.any { it.toString() == "null" }, "optional fields must be omitted: $event")
            }
        }
    }

    @Test
    fun `subscription errors recover and debug disconnect acks before the next changed value`() {
        RawWebSocketFixture { connection, index ->
            connection.readMessage()
            connection.readMessage()
            if (index == 0) {
                connection.sendText(adapterTransition(adapterVersion(0), adapterVersion(1, 1), adapterFailed(0)))
                connection.sendText(adapterTransition(adapterVersion(1, 1), adapterVersion(1, 2), adapterUpdated(0, 0)))
            } else {
                connection.sendText(adapterTransition(adapterVersion(0), adapterVersion(1, 3), adapterUpdated(0, 0)))
                connection.sendText(adapterTransition(adapterVersion(1, 3), adapterVersion(1, 4), adapterUpdated(0, 1)))
            }
            connection.awaitClientClose(Duration.ofSeconds(8))
        }.use { fixture ->
            AdapterHarness(fixture.url).use { adapter ->
                adapter.send(
                    command("s", "subscribe") {
                        put("subscriptionId", "sub")
                        put("path", "demo:state")
                        put("args", JsonObject(emptyMap()))
                    },
                )
                assertEquals("ack", adapter.next().type)
                val failed = adapter.next()
                assertEquals("subscription", failed.type)
                assertNull(failed["id"])
                assertEquals("FunctionError", failed["error"]!!.jsonObject["name"]!!.jsonPrimitive.content)
                assertEquals(0, adapter.next().valueCount())

                adapter.send(command("d", "debugDisconnect"))
                assertEquals("ack", adapter.next().type)
                // Rehydrated 0 is unchanged and therefore cannot cross the ack.
                assertEquals(1, adapter.next(Duration.ofSeconds(8)).valueCount())
                adapter.closeCommand()
            }
        }
    }

    @Test
    fun `adapter preserves protocol and transport error classes while subscriptions recover`() {
        val resetTransport = CountDownLatch(1)
        RawWebSocketFixture { connection, index ->
            connection.readMessage()
            connection.readMessage()
            when (index) {
                0 ->
                    connection.sendText(
                        encode(
                            buildJsonObject {
                                put("type", "Transition")
                                put("startVersion", adapterVersion(0))
                                put("endVersion", adapterVersion(1, 1))
                                put("modifications", "bad")
                            },
                        ),
                    )
                1 -> {
                    connection.sendText(adapterTransition(adapterVersion(0), adapterVersion(1, 2), adapterUpdated(0, 0)))
                    assertTrue(resetTransport.await(3, TimeUnit.SECONDS))
                    connection.abortTransport()
                }
                else -> {
                    connection.sendText(adapterTransition(adapterVersion(0), adapterVersion(1, 3), adapterUpdated(0, 1)))
                    connection.awaitClientClose()
                }
            }
        }.use { fixture ->
            AdapterHarness(fixture.url).use { adapter ->
                adapter.send(subscribe("s", "sub", "demo:state"))
                assertEquals("ack", adapter.next().type)
                assertEquals("ProtocolError", adapter.next(Duration.ofSeconds(5)).errorName())
                assertEquals(0, adapter.next(Duration.ofSeconds(5)).valueCount())
                resetTransport.countDown()
                assertEquals("TransportError", adapter.next(Duration.ofSeconds(5)).errorName())
                assertEquals(1, adapter.next(Duration.ofSeconds(5)).valueCount())
                adapter.closeCommand()
            }
        }
    }

    @Test
    fun `replacement and unsubscribe invalidate stale relays across the acknowledgement lock`() {
        val sendOld = CountDownLatch(1)
        val sendNew = CountDownLatch(1)
        val sendBlocked = CountDownLatch(1)
        RawWebSocketFixture { connection, _ ->
            connection.readMessage()
            connection.readMessage()
            assertTrue(sendOld.await(3, TimeUnit.SECONDS))
            connection.sendText(adapterTransition(adapterVersion(0), adapterVersion(1, 1), adapterUpdated(0, 1)))

            val remove = connection.readMessage()
            assertAdapterModify(remove, 1, 2, "Remove", 0)
            val add = connection.readMessage()
            assertAdapterModify(add, 2, 3, "Add", 1)
            assertTrue(sendNew.await(3, TimeUnit.SECONDS))
            connection.sendText(adapterTransition(adapterVersion(1, 1), adapterVersion(3, 2), adapterUpdated(1, 2)))
            assertTrue(sendBlocked.await(3, TimeUnit.SECONDS))
            connection.sendText(adapterTransition(adapterVersion(3, 2), adapterVersion(3, 3), adapterUpdated(1, 3)))
            connection.readMessage() // Remove for the replacement generation.
            connection.awaitClientClose()
        }.use { fixture ->
            AdapterHarness(fixture.url).use { adapter ->
                val oldDequeued = CountDownLatch(1)
                val releaseOld = CountDownLatch(1)
                AdapterTestHooks.beforePublish = { _, generation, _ ->
                    if (generation == 1L) {
                        oldDequeued.countDown()
                        releaseOld.await()
                    }
                }
                adapter.send(subscribe("one", "sub", "demo:old"))
                assertEquals("ack", adapter.next().type)
                sendOld.countDown()
                assertTrue(oldDequeued.await(3, TimeUnit.SECONDS))

                adapter.send(subscribe("two", "sub", "demo:new"))
                assertEquals("ack", adapter.next().type)
                releaseOld.countDown()
                adapter.assertNoEvent()

                AdapterTestHooks.beforePublish = null
                sendNew.countDown()
                assertEquals(2, adapter.next().valueCount())

                val relayInsideLock = CountDownLatch(1)
                val releaseLock = CountDownLatch(1)
                AdapterTestHooks.insidePublicationLock = { _, generation ->
                    if (generation == 2L) {
                        relayInsideLock.countDown()
                        releaseLock.await()
                    }
                }
                sendBlocked.countDown()
                assertTrue(relayInsideLock.await(3, TimeUnit.SECONDS))
                adapter.send(command("three", "unsubscribe") { put("subscriptionId", "sub") })
                // The relay holds the publication lock, so the acknowledgement
                // cannot be visible until it rechecks the invalidated generation.
                adapter.assertNoEvent()
                releaseLock.countDown()
                assertEquals("ack", adapter.next().type)
                adapter.assertNoEvent()
                adapter.closeCommand()
            }
        }
    }

    @Test
    fun `the same NDJSON stream works over the TCP adapter transport`() {
        assertEquals("127.0.0.1" to 3210, parseListenAddress("127.0.0.1:3210"))
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val failure = AtomicReference<Throwable>()
            val adapterThread =
                Thread {
                    try {
                        server.accept().use { socket ->
                            runAdapter(
                                socket.getInputStream().bufferedReader(),
                                socket.getOutputStream().bufferedWriter(),
                                null,
                            )
                        }
                    } catch (error: Throwable) {
                        failure.set(error)
                    }
                }.apply {
                    isDaemon = true
                    start()
                }
            Socket(InetAddress.getLoopbackAddress(), server.localPort).use { controller ->
                val input = controller.getInputStream().bufferedReader()
                val output = controller.getOutputStream().bufferedWriter()
                output.write(encode(command("h", "hello") { put("protocolVersion", 1) }))
                output.newLine()
                output.write(encode(command("c", "close")))
                output.newLine()
                output.flush()
                assertEquals("ready", decode(input.readLine()).type)
                assertEquals("closed", decode(input.readLine()).type)
            }
            adapterThread.join(2_000)
            assertFalse(adapterThread.isAlive)
            failure.get()?.let { throw it }
        }
    }
}

private class AdapterHarness(
    deploymentUrl: String,
) : AutoCloseable {
    private val adapterInput = PipedReader()
    private val controllerOutput = PipedWriter(adapterInput).buffered()
    private val controllerInput = PipedReader()
    private val adapterOutput = PipedWriter(controllerInput).buffered()
    private val events = ArrayBlockingQueue<JsonObject>(32)
    private val failure = AtomicReference<Throwable>()
    private val adapterThread =
        Thread {
            try {
                runAdapter(adapterInput.buffered(), adapterOutput, deploymentUrl)
            } catch (error: Throwable) {
                failure.set(error)
            }
        }.apply {
            isDaemon = true
            start()
        }
    private val readerThread =
        Thread {
            try {
                controllerInput.buffered().lineSequence().forEach { events.put(decode(it)) }
            } catch (error: Throwable) {
                if (adapterThread.isAlive) failure.compareAndSet(null, error)
            }
        }.apply {
            isDaemon = true
            start()
        }

    fun send(command: JsonObject) {
        controllerOutput.write(encode(command))
        controllerOutput.newLine()
        controllerOutput.flush()
    }

    fun next(timeout: Duration = Duration.ofSeconds(3)): JsonObject =
        events.poll(timeout.toMillis(), TimeUnit.MILLISECONDS)
            ?: error("adapter event timed out; failure=${failure.get()}")

    fun assertNoEvent(timeout: Duration = Duration.ofMillis(250)) {
        val event = events.poll(timeout.toMillis(), TimeUnit.MILLISECONDS)
        assertNull(event, "unexpected adapter event $event")
    }

    fun closeCommand() {
        send(command("close", "close"))
        assertEquals("closed", next().type)
    }

    override fun close() {
        controllerOutput.close()
        adapterThread.join(2_000)
        adapterOutput.close()
        controllerInput.close()
        adapterInput.close()
        readerThread.interrupt()
        assertFalse(adapterThread.isAlive, "adapter did not stop")
        failure.get()?.let { throw AssertionError("adapter fixture failed", it) }
    }
}

private class HttpFixture(
    val url: String,
    private val server: HttpServer,
) : AutoCloseable {
    override fun close() = server.stop(0)
}

private fun httpServer(response: (String) -> Pair<Int, String>): HttpFixture {
    val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    server.createContext("/") { exchange ->
        val request = decode(exchange.requestBody.readBytes().decodeToString())
        val (status, body) = response(request["path"]!!.jsonPrimitive.content)
        exchange.sendResponseHeaders(status, body.toByteArray().size.toLong())
        exchange.responseBody.use { it.write(body.toByteArray()) }
    }
    server.start()
    return HttpFixture("http://127.0.0.1:${server.address.port}", server)
}

private fun subscribe(
    id: String,
    subscriptionId: String,
    path: String,
) = command(id, "subscribe") {
    put("subscriptionId", subscriptionId)
    put("path", path)
    put("args", JsonObject(emptyMap()))
}

private fun command(
    id: String,
    operation: String,
    fields: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
) = buildJsonObject {
    put("id", id)
    put("op", operation)
    fields()
}

private fun encode(value: JsonObject) = ConvexClient.json.encodeToString(JsonObject.serializer(), value)

private fun decode(value: String) = ConvexClient.json.parseToJsonElement(value).jsonObject

private val JsonObject.type: String
    get() = this["type"]!!.jsonPrimitive.content

private fun JsonObject.valueCount() = this["value"]!!.jsonObject["count"]!!.jsonPrimitive.int

private fun JsonObject.errorName() = this["error"]!!.jsonObject["name"]!!.jsonPrimitive.content

private fun RawWebSocketFixture.Connection.readMessage() = decode(readText())

private fun adapterVersion(
    querySet: Int,
    timestamp: Int = 0,
) = buildJsonObject {
    put("querySet", querySet)
    put("identity", 0)
    put("ts", if (timestamp == 0) "AAAAAAAAAAA=" else "adapter-ts-$timestamp")
}

private fun adapterTransition(
    start: JsonObject,
    end: JsonObject,
    vararg modifications: JsonObject,
) = encode(
    buildJsonObject {
        put("type", "Transition")
        put("startVersion", start)
        put("endVersion", end)
        put("modifications", JsonArray(modifications.toList()))
    },
)

private fun adapterUpdated(
    queryId: Int,
    count: Int,
) = buildJsonObject {
    put("type", "QueryUpdated")
    put("queryId", queryId)
    put("value", buildJsonObject { put("count", count) })
}

private fun adapterFailed(queryId: Int) =
    buildJsonObject {
        put("type", "QueryFailed")
        put("queryId", queryId)
        put("errorMessage", "fixture failure")
        put("errorData", buildJsonObject { put("code", "FIXTURE") })
    }

private fun assertAdapterModify(
    message: JsonObject,
    base: Int,
    next: Int,
    type: String,
    queryId: Int,
) {
    assertEquals("ModifyQuerySet", message.type)
    assertEquals(base, message["baseVersion"]!!.jsonPrimitive.int)
    assertEquals(next, message["newVersion"]!!.jsonPrimitive.int)
    val modification = message["modifications"]!!.jsonArray.single().jsonObject
    assertEquals(type, modification.type)
    assertEquals(queryId, modification["queryId"]!!.jsonPrimitive.int)
}
