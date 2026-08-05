package convex.kotlin

import convex.kotlin.testing.RawWebSocketFixture
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.ServerSocket
import java.time.Duration
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.measureTimeMillis
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LiveManagerTest {
    @Test
    fun `one owner serializes Connect Add Remove and delivers fragmented updates and recovery`() {
        val sent = CountDownLatch(1)
        val sendThreads = Collections.synchronizedList(mutableListOf<String>())
        RawWebSocketFixture { connection, _ ->
            val connect = connection.readMessage()
            assertEquals("Connect", connect.type)
            val add = connection.readMessage()
            assertModify(add, base = 0, next = 1, modification = "Add", queryId = 0)

            val initial = transition(version(0), version(1, 1), updated(0, count(0), "split 🙂"))
            val bytes = initial.toByteArray()
            val emoji = bytes.indexOfFirst { it.toInt() and 0xff == 0xf0 }
            connection.sendFragmentedText(initial, emoji + 1)
            connection.sendText(transition(version(1, 1), version(1, 2), updated(0, count(1))))
            connection.sendText(transition(version(1, 2), version(1, 3), failed(0, "try again")))
            connection.sendText(transition(version(1, 3), version(1, 4), updated(0, count(2))))
            sent.countDown()

            val secondAdd = connection.readMessage()
            assertModify(secondAdd, base = 1, next = 2, modification = "Add", queryId = 1)
            connection.sendText(transition(version(1, 4), version(2, 5), updated(1, count(9))))
            val remove = connection.readMessage()
            assertModify(remove, base = 2, next = 3, modification = "Remove", queryId = 1)
            connection.awaitClientClose()
        }.use { fixture ->
            LiveManager(fixture.url, "test").use { manager ->
                manager.sendInitiatedThreadObserver = { sendThreads += it }
                val first = manager.subscribe("demo:state", JsonObject(emptyMap()))
                val initialUpdate = first.next() ?: error("initial update timed out")
                assertEquals(0, initialUpdate.value.countValue())
                assertEquals(listOf("split 🙂"), initialUpdate.logs)
                // The external value follows the initial fragmented message.
                assertEquals(1, first.nextValue())
                assertIs<FunctionException>(first.next()!!.error)
                assertEquals(2, first.nextValue())
                assertTrue(sent.await(1, TimeUnit.SECONDS))

                val second = manager.subscribe("demo:other", JsonObject(emptyMap()))
                assertEquals(9, second.nextValue())
                second.close()
                awaitCondition { sendThreads.size >= 4 }
                assertTrue(sendThreads.all { it == "convex-kotlin-live" }, sendThreads.toString())
            }
        }
    }

    @Test
    fun `five reconnects resend Add preserve metadata suppress hydration and reset backoff`() {
        val connects = Collections.synchronizedList(mutableListOf<JsonObject>())
        val adds = Collections.synchronizedList(mutableListOf<JsonObject>())
        RawWebSocketFixture { connection, index ->
            connects += connection.readMessage()
            adds += connection.readMessage()
            val hydration =
                transition(
                    version(0),
                    version(1, index * 2 + 1),
                    updated(0, count((index - 1).coerceAtLeast(0))),
                )
            connection.sendText(hydration)
            if (index > 0) {
                connection.sendText(
                    transition(
                        version(1, index * 2 + 1),
                        version(1, index * 2 + 2),
                        updated(0, count(index)),
                    ),
                )
            }
            connection.awaitClientClose(Duration.ofSeconds(8))
        }.use { fixture ->
            LiveManager(fixture.url, "test").use { manager ->
                val delays = Collections.synchronizedList(mutableListOf<Long>())
                manager.reconnectDelayObserver = { delays += it }
                val subscription = manager.subscribe("demo:state", JsonObject(emptyMap()))
                assertEquals(0, subscription.nextValue())

                repeat(5) { attempt ->
                    manager.debugDisconnect()
                    // The unchanged hydration is deliberately suppressed. The
                    // first item after each acknowledged disconnect is new data.
                    assertEquals(attempt + 1, subscription.nextValue(Duration.ofSeconds(8)))
                }

                awaitCondition { connects.size == 6 && adds.size == 6 }
                connects.forEachIndexed { index, connect ->
                    assertEquals("Connect", connect.type)
                    assertEquals(index, connect["connectionCount"]!!.jsonPrimitive.int)
                    assertEquals(
                        if (index ==
                            0
                        ) {
                            "InitialConnect"
                        } else {
                            "DebugDisconnect"
                        },
                        connect["lastCloseReason"]!!.jsonPrimitive.content,
                    )
                    if (index == 0) {
                        assertNull(connect["maxObservedTimestamp"])
                    } else {
                        val priorTimestamp = if (index == 1) 1 else index * 2
                        assertEquals("ts-$priorTimestamp", connect["maxObservedTimestamp"]!!.jsonPrimitive.content)
                    }
                }
                adds.forEach { add -> assertModify(add, 0, 1, "Add", 0) }
                assertEquals(listOf(0L, 100L, 100L, 100L, 100L, 100L), delays)
            }
        }
    }

    @Test
    fun `malformed transition and I O closure are classified and later values recover`() {
        val resetTransport = CountDownLatch(1)
        RawWebSocketFixture { connection, index ->
            connection.readMessage()
            connection.readMessage()
            when (index) {
                0 ->
                    connection.sendText(
                        """{"type":"Transition","startVersion":${version(0)},"endVersion":${version(1, 1)},"modifications":{}}""",
                    )
                1 -> {
                    connection.sendText(transition(version(0), version(1, 2), updated(0, count(1))))
                    assertTrue(resetTransport.await(3, TimeUnit.SECONDS))
                    connection.abortTransport()
                }
                else -> {
                    connection.sendText(transition(version(0), version(1, 3), updated(0, count(2))))
                    connection.awaitClientClose()
                }
            }
        }.use { fixture ->
            LiveManager(fixture.url, "test").use { manager ->
                val subscription = manager.subscribe("demo:state", JsonObject(emptyMap()))
                assertIs<ProtocolException>(subscription.next(Duration.ofSeconds(5))!!.error)
                assertEquals(1, subscription.nextValue(Duration.ofSeconds(5)))
                resetTransport.countDown()
                assertIs<TransportException>(subscription.next(Duration.ofSeconds(5))!!.error)
                assertEquals(2, subscription.nextValue(Duration.ofSeconds(5)))
            }
        }
    }

    @Test
    fun `slow consumers retain exactly the newest sixteen updates`() {
        RawWebSocketFixture { connection, _ ->
            connection.readMessage()
            connection.readMessage()
            var start = version(0)
            repeat(21) { value ->
                val end = version(1, value + 1)
                connection.sendText(transition(start, end, updated(0, count(value))))
                start = end
            }
            connection.awaitClientClose()
        }.use { fixture ->
            LiveManager(fixture.url, "test").use { manager ->
                val subscription = manager.subscribe("demo:state", JsonObject(emptyMap()))
                awaitCondition {
                    subscription.queue.size == 16 &&
                        subscription.queue
                            .toList()
                            .lastOrNull()
                            ?.value
                            ?.countValue() == 20
                }
                assertEquals((5..20).toList(), subscription.queue.toList().map { it.value.countValue() })
            }
        }
    }

    @Test
    fun `close is bounded for idle continuous partial frame and pending handshake peers`() {
        assertBoundedClose(PeerMode.IDLE)
        assertBoundedClose(PeerMode.CONTINUOUS)
        assertBoundedClose(PeerMode.PARTIAL)

        ServerSocket(0).use { server ->
            val accepted = CountDownLatch(1)
            val peer =
                Thread {
                    server.accept().use {
                        accepted.countDown()
                        CountDownLatch(1).await()
                    }
                }.apply {
                    isDaemon = true
                    start()
                }
            val manager = LiveManager("http://127.0.0.1:${server.localPort}", "test")
            manager.subscribe("demo:state", JsonObject(emptyMap()))
            assertTrue(accepted.await(2, TimeUnit.SECONDS))
            val elapsed = measureTimeMillis { manager.close() }
            assertTrue(elapsed < 2_000, "pending handshake close took ${elapsed}ms")
            server.close()
            peer.interrupt()
        }
    }

    @Test
    fun `subscription close is bounded for idle continuous partial frame and pending handshake peers`() {
        assertBoundedUnsubscribe(PeerMode.IDLE)
        assertBoundedUnsubscribe(PeerMode.CONTINUOUS)
        assertBoundedUnsubscribe(PeerMode.PARTIAL)

        ServerSocket(0).use { server ->
            val accepted = CountDownLatch(1)
            val peer =
                Thread {
                    server.accept().use {
                        accepted.countDown()
                        CountDownLatch(1).await()
                    }
                }.apply {
                    isDaemon = true
                    start()
                }
            LiveManager("http://127.0.0.1:${server.localPort}", "test").use { manager ->
                val subscription = manager.subscribe("demo:state", JsonObject(emptyMap()))
                assertTrue(accepted.await(8, TimeUnit.SECONDS))
                val elapsed = measureTimeMillis { subscription.close() }
                assertTrue(elapsed < 2_000, "pending handshake unsubscribe took ${elapsed}ms")
            }
            server.close()
            peer.interrupt()
        }
    }

    private fun assertBoundedClose(mode: PeerMode) {
        val ready = CountDownLatch(1)
        RawWebSocketFixture { connection, _ ->
            connection.readMessage()
            connection.readMessage()
            ready.countDown()
            when (mode) {
                PeerMode.IDLE -> CountDownLatch(1).await()
                PeerMode.PARTIAL -> {
                    connection.sendPartialText(20, "{\"type\":".toByteArray())
                    CountDownLatch(1).await()
                }
                PeerMode.CONTINUOUS -> {
                    while (true) connection.sendPing("busy")
                }
            }
        }.use { fixture ->
            val manager = LiveManager(fixture.url, "test")
            manager.subscribe("demo:state", JsonObject(emptyMap()))
            assertTrue(ready.await(8, TimeUnit.SECONDS), "$mode peer did not become ready")
            val elapsed = measureTimeMillis { manager.close() }
            assertTrue(elapsed < 2_000, "$mode close took ${elapsed}ms")
        }
    }

    private fun assertBoundedUnsubscribe(mode: PeerMode) {
        val ready = CountDownLatch(1)
        RawWebSocketFixture { connection, _ ->
            connection.readMessage()
            connection.readMessage()
            ready.countDown()
            when (mode) {
                PeerMode.IDLE -> CountDownLatch(1).await()
                PeerMode.PARTIAL -> {
                    connection.sendPartialText(20, "{\"type\":".toByteArray())
                    CountDownLatch(1).await()
                }
                PeerMode.CONTINUOUS -> {
                    while (true) connection.sendPing("busy")
                }
            }
        }.use { fixture ->
            LiveManager(fixture.url, "test").use { manager ->
                val subscription = manager.subscribe("demo:state", JsonObject(emptyMap()))
                assertTrue(ready.await(8, TimeUnit.SECONDS), "$mode peer did not become ready")
                val elapsed = measureTimeMillis { subscription.close() }
                assertTrue(elapsed < 2_000, "$mode unsubscribe took ${elapsed}ms")
            }
        }
    }

    private enum class PeerMode { IDLE, CONTINUOUS, PARTIAL }
}

private val JsonObject.type: String
    get() = this["type"]!!.jsonPrimitive.content

private fun RawWebSocketFixture.Connection.readMessage() = ConvexClient.json.parseToJsonElement(readText()).jsonObject

private fun assertModify(
    message: JsonObject,
    base: Int,
    next: Int,
    modification: String,
    queryId: Int,
) {
    assertEquals("ModifyQuerySet", message.type)
    assertEquals(base, message["baseVersion"]!!.jsonPrimitive.int)
    assertEquals(next, message["newVersion"]!!.jsonPrimitive.int)
    val item = message["modifications"]!!.jsonArray.single().jsonObject
    assertEquals(modification, item.type)
    assertEquals(queryId, item["queryId"]!!.jsonPrimitive.int)
}

private fun version(
    querySet: Int,
    timestamp: Int = 0,
) = buildJsonObject {
    put("querySet", querySet)
    put("identity", 0)
    put("ts", if (timestamp == 0) "AAAAAAAAAAA=" else "ts-$timestamp")
}

private fun transition(
    start: JsonObject,
    end: JsonObject,
    vararg modifications: JsonObject,
) = ConvexClient.json.encodeToString(
    JsonObject.serializer(),
    buildJsonObject {
        put("type", "Transition")
        put("startVersion", start)
        put("endVersion", end)
        put("modifications", JsonArray(modifications.toList()))
    },
)

private fun updated(
    queryId: Int,
    value: JsonElement,
    vararg logs: String,
) = buildJsonObject {
    put("type", "QueryUpdated")
    put("queryId", queryId)
    put("value", value)
    if (logs.isNotEmpty()) put("logLines", JsonArray(logs.map(::JsonPrimitive)))
}

private fun failed(
    queryId: Int,
    message: String,
) = buildJsonObject {
    put("type", "QueryFailed")
    put("queryId", queryId)
    put("errorMessage", message)
    put("errorData", JsonNull)
}

private fun count(value: Int) = buildJsonObject { put("count", value) }

private fun Subscription.nextValue(timeout: Duration = Duration.ofSeconds(3)): Int {
    val update = next(timeout) ?: error("timed out waiting for Live update")
    update.error?.let { throw it }
    return update.value.countValue()
}

private fun JsonElement?.countValue(): Int = this!!.jsonObject["count"]!!.jsonPrimitive.int

private fun awaitCondition(condition: () -> Boolean) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
    while (!condition()) {
        check(System.nanoTime() < deadline) { "condition did not become true" }
        Thread.sleep(10)
    }
}
