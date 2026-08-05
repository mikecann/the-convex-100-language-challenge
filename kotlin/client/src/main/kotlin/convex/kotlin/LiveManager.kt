package convex.kotlin

import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.time.Duration
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

private const val INITIAL_TIMESTAMP = "AAAAAAAAAAA="
private const val MAX_PENDING_UPDATES = 16

/** An update is either the latest JSON value or a structured query failure. */
data class Update(val value: JsonElement? = null, val error: Throwable? = null, val logs: List<String> = emptyList())

/**
 * A bounded, newest-value-first stream. A full queue intentionally drops the
 * oldest intermediate reactive state, never blocks the protocol owner.
 */
class Subscription internal constructor(
    private val manager: LiveManager,
    internal val queryId: Int,
    internal val queue: ArrayBlockingQueue<Update>,
) : AutoCloseable {
    private val active = AtomicBoolean(true)
    internal fun deactivate(): Boolean = active.compareAndSet(true, false)
    /** Lets the test-only adapter suppress an event after unsubscribe/replacement. */
    fun isActive(): Boolean = active.get()
    fun next(timeout: Duration = Duration.ofSeconds(10)): Update? = queue.poll(timeout.toMillis(), TimeUnit.MILLISECONDS)
    override fun close() { if (deactivate()) manager.unsubscribe(queryId) }
}

private data class RemoteVersion(val querySet: Int, val identity: Int, val timestamp: String) {
    companion object {
        fun zero() = RemoteVersion(0, 0, INITIAL_TIMESTAMP)
    }
}

private data class State(val subscription: Subscription, val path: String, val args: JsonObject, var last: Update? = null)

/**
 * One actor owns all WebSocket reads, writes, reconnect scheduling, and query
 * set versions. JDK callbacks only enqueue work onto this actor, preventing
 * controller threads and receiver threads from touching a socket concurrently.
 */
internal class LiveManager(private val deploymentUrl: String, private val clientVersion: String) : AutoCloseable {
    private val owner = Executors.newSingleThreadExecutor { task -> Thread(task, "convex-kotlin-live").apply { isDaemon = true } }
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "convex-kotlin-reconnect").apply { isDaemon = true } }
    private val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build()
    private val states = linkedMapOf<Int, State>()
    private var socket: WebSocket? = null
    private var closed = false
    private var nextQueryId = 0
    private var querySet = 0
    private var remoteVersion = RemoteVersion.zero()
    private var connectionCount = 0
    private var lastCloseReason = "InitialConnect"
    private var maxObservedTimestamp: String? = null
    private var reconnectDelayMillis = 100L
    private var reconnectScheduled = false
    private var generation = 0L

    fun subscribe(path: String, args: JsonObject): Subscription = onOwner {
        if (closed) throw ClosedException()
        val subscription = Subscription(this, nextQueryId++, ArrayBlockingQueue(MAX_PENDING_UPDATES))
        states[subscription.queryId] = State(subscription, path, args)
        if (socket == null) scheduleReconnect(0) else modify(listOf(add(subscription.queryId, path, args)))
        subscription
    }

    fun unsubscribe(queryId: Int) = onOwner {
        // Invalidating before acknowledgement makes a relayed item dequeued just
        // before close harmless: the adapter checks Subscription.isActive().
        val state = states.remove(queryId) ?: return@onOwner
        state.subscription.deactivate()
        if (socket != null) modify(listOf(remove(queryId)))
    }

    fun debugDisconnect() = onOwner {
        if (closed) throw ClosedException()
        check(socket != null) { "Live WebSocket is not connected" }
        retire("DebugDisconnect", reconnect = true)
    }

    private fun scheduleReconnect(delay: Long) {
        if (closed || states.isEmpty() || reconnectScheduled) return
        reconnectScheduled = true
        scheduler.schedule({ owner.execute { reconnectScheduled = false; connect() } }, delay, TimeUnit.MILLISECONDS)
    }

    private fun connect() {
        if (closed || socket != null || states.isEmpty()) return
        val currentGeneration = ++generation
        val uri = URI(deploymentUrl.replaceFirst("https", "wss").replaceFirst("http", "ws") + "/api/sync")
        http.newWebSocketBuilder()
            .header("Convex-Client", clientVersion)
            .connectTimeout(Duration.ofSeconds(10))
            .buildAsync(uri, Listener(currentGeneration)).whenComplete { connected, error ->
                owner.execute {
                    if (closed || currentGeneration != generation) {
                        connected?.abort()
                        return@execute
                    }
                    if (error != null) {
                        lastCloseReason = "connect: ${error.message}"
                        connectionCount++
                        scheduleReconnect(reconnectDelayMillis)
                        reconnectDelayMillis = (reconnectDelayMillis * 2).coerceAtMost(15_000)
                        return@execute
                    }
                    socket = connected
                    querySet = 0
                    remoteVersion = RemoteVersion.zero()
                    // A successful handshake resets exponential transport backoff.
                    reconnectDelayMillis = 100
                    send(
                        buildJsonObject {
                            put("type", "Connect")
                            put("sessionId", UUID.randomUUID().toString())
                            put("connectionCount", connectionCount)
                            put("lastCloseReason", lastCloseReason)
                            maxObservedTimestamp?.let { put("maxObservedTimestamp", it) }
                            put("clientTs", 0)
                        },
                    )
                    if (states.isNotEmpty()) modify(states.map { (id, state) -> add(id, state.path, state.args) })
                }
            }
    }

    private fun send(value: JsonObject) {
        val current = socket ?: return
        current.sendText(ConvexClient.json.encodeToString(JsonObject.serializer(), value), true).whenComplete { _, error ->
            if (error != null) owner.execute { if (socket === current) retire("write: ${error.message}", true) }
        }
    }

    private fun modify(modifications: List<JsonObject>) {
        if (modifications.isEmpty()) return
        send(buildJsonObject {
            put("type", "ModifyQuerySet")
            put("baseVersion", querySet)
            put("newVersion", querySet + 1)
            put("modifications", JsonArray(modifications))
        })
        querySet++
    }

    private fun add(id: Int, path: String, args: JsonObject) = buildJsonObject {
        put("type", "Add")
        put("queryId", id)
        put("udfPath", path)
        put("args", buildJsonArray { add(args) })
    }
    private fun remove(id: Int) = buildJsonObject {
        put("type", "Remove")
        put("queryId", id)
    }

    private fun receive(currentGeneration: Long, text: String) = owner.execute {
        if (closed || currentGeneration != generation || socket == null) return@execute
        val message = try {
            ConvexClient.json.parseToJsonElement(text).jsonObject
        } catch (error: Exception) {
            protocolFailure(ProtocolException("decode server message: ${error.message}"))
            return@execute
        }
        when (message["type"]?.jsonPrimitive?.content) {
            "Transition" -> transition(message)
            "Ping", "MutationResponse", "ActionResponse" -> Unit
            "FatalError", "AuthError", "TransitionChunk" -> protocolFailure(
                ProtocolException("${message["type"]?.jsonPrimitive?.content} is unsupported by the Kotlin pilot"),
            )
            else -> protocolFailure(ProtocolException("unknown server message ${message["type"]}"))
        }
    }

    private fun transition(message: JsonObject) {
        val start = version(message["startVersion"]?.jsonObject ?: return protocolFailure(ProtocolException("Transition omitted startVersion")))
        if (start != remoteVersion) return protocolFailure(ProtocolException("Transition start version does not match local version"))
        val changed = mutableListOf<Pair<Int, Update>>()
        for (modification in message["modifications"]?.jsonArray.orEmpty()) {
            val item = modification.jsonObject
            val id = item["queryId"]?.jsonPrimitive?.intOrNull ?: return protocolFailure(ProtocolException("Transition modification omitted queryId"))
            val update = when (item["type"]?.jsonPrimitive?.content) {
                "QueryUpdated" -> Update(item["value"] ?: JsonNull, logs = logs(item))
                "QueryFailed" -> Update(error = FunctionException("query", item["errorMessage"]?.jsonPrimitive?.content ?: "query failed", item["errorData"], logs(item)), logs = logs(item))
                "QueryRemoved" -> {
                    states[id]?.last = null
                    null
                }
                else -> return protocolFailure(ProtocolException("unknown Transition modification ${item["type"]}"))
            }
            if (update != null) changed += id to update
        }
        val end = version(message["endVersion"]?.jsonObject ?: return protocolFailure(ProtocolException("Transition omitted endVersion")))
        remoteVersion = end
        maxObservedTimestamp = end.timestamp
        // Commit state before delivery. Rehydrated values identical to a last
        // delivered value are intentionally suppressed after reconnect.
        changed.sortedBy { it.first }.forEach { (id, update) ->
            val state = states[id] ?: return@forEach
            if (state.last != update) {
                state.last = update
                deliver(state.subscription, update)
            }
        }
    }

    private fun version(value: JsonObject): RemoteVersion = RemoteVersion(
        value["querySet"]?.jsonPrimitive?.int ?: throw ProtocolException("state version omitted querySet"),
        value["identity"]?.jsonPrimitive?.int ?: throw ProtocolException("state version omitted identity"),
        value["ts"]?.jsonPrimitive?.content ?: throw ProtocolException("state version omitted ts"),
    )
    private fun logs(value: JsonObject) = value["logLines"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()

    private fun deliver(subscription: Subscription, update: Update) {
        if (!subscription.isActive()) return
        if (!subscription.queue.offer(update)) {
            subscription.queue.poll()
            subscription.queue.offer(update)
        }
    }

    private fun protocolFailure(error: ProtocolException) {
        states.values.forEach { deliver(it.subscription, Update(error = error)) }
        retire(error.message ?: "protocol failure", true)
    }

    private fun retire(reason: String, reconnect: Boolean) {
        val old = socket
        socket = null
        generation++ // old callbacks cannot re-enter the new connection.
        old?.abort()
        connectionCount++
        lastCloseReason = reason
        querySet = 0
        remoteVersion = RemoteVersion.zero()
        if (reconnect) scheduleReconnect(reconnectDelayMillis)
    }

    override fun close() = onOwner {
        if (closed) return@onOwner
        closed = true
        socket?.abort()
        socket = null
        states.values.forEach { it.subscription.deactivate() }
        states.clear()
        scheduler.shutdownNow()
    }.also { owner.shutdown() }

    private fun <T> onOwner(block: () -> T): T {
        if (Thread.currentThread().name == "convex-kotlin-live") return block()
        return owner.submit<T> { block() }.get(5, TimeUnit.SECONDS)
    }

    private inner class Listener(private val generation: Long) : WebSocket.Listener {
        private val text = StringBuilder()
        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }
        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletableFuture<*> {
            text.append(data)
            if (last) {
                receive(generation, text.toString())
                text.clear()
            }
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }
        override fun onBinary(webSocket: WebSocket, data: ByteBuffer, last: Boolean): CompletableFuture<*> {
            receive(generation, "{not-json}")
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }
        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletableFuture<*> {
            owner.execute { if (!closed && generation == this.generation && socket === webSocket) retire("close $statusCode: $reason", true) }
            return CompletableFuture.completedFuture(null)
        }
        override fun onError(webSocket: WebSocket, error: Throwable) {
            owner.execute { if (!closed && generation == this.generation && socket === webSocket) retire("read: ${error.message}", true) }
        }
    }
}
