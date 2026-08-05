package convex.kotlin

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.time.Duration
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val INITIAL_TIMESTAMP = "AAAAAAAAAAA="
private const val MAX_PENDING_UPDATES = 16
private const val INITIAL_RECONNECT_DELAY_MILLIS = 100L
private const val MAX_RECONNECT_DELAY_MILLIS = 15_000L

/** An update is either the latest JSON value or a structured query failure. */
data class Update(
    val value: JsonElement? = null,
    val error: Throwable? = null,
    val logs: List<String> = emptyList(),
)

/**
 * A bounded, newest-value stream. Reactive values are snapshots, so a slow
 * consumer loses old intermediate snapshots instead of blocking the socket.
 */
class Subscription internal constructor(
    private val manager: LiveManager,
    internal val queryId: Int,
    internal val queue: ArrayBlockingQueue<Update>,
) : AutoCloseable {
    private val active = AtomicBoolean(true)

    internal fun deactivate(): Boolean = active.compareAndSet(true, false)

    /** The adapter uses this inside its publication lock to reject stale relays. */
    fun isActive(): Boolean = active.get()

    fun next(timeout: Duration = Duration.ofSeconds(10)): Update? = queue.poll(timeout.toMillis(), TimeUnit.MILLISECONDS)

    override fun close() {
        if (deactivate()) manager.unsubscribe(queryId)
    }
}

private data class RemoteVersion(
    val querySet: Int,
    val identity: Int,
    val timestamp: String,
) {
    companion object {
        fun zero() = RemoteVersion(0, 0, INITIAL_TIMESTAMP)
    }
}

private data class State(
    val subscription: Subscription,
    val path: String,
    val args: JsonObject,
    var last: Update? = null,
)

/**
 * One actor owns socket state, outgoing frames, reconnects, and query versions.
 * JDK callbacks only copy transport data and enqueue it back to that actor.
 */
internal class LiveManager(
    deploymentUrl: String,
    private val clientVersion: String,
    private val http: HttpClient =
        HttpClient
            .newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build(),
) : AutoCloseable {
    private val webSocketUrl =
        URI(
            deploymentUrl
                .replaceFirst("https", "wss")
                .replaceFirst("http", "ws") + "/api/sync",
        )
    private val owner =
        Executors.newSingleThreadExecutor { task ->
            Thread(task, "convex-kotlin-live").apply { isDaemon = true }
        }
    private val scheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "convex-kotlin-reconnect").apply { isDaemon = true }
        }
    private val states = linkedMapOf<Int, State>()

    private var socket: WebSocket? = null
    private var pendingHandshake: CompletableFuture<WebSocket>? = null
    private var pendingReconnect: ScheduledFuture<*>? = null
    private var sendTail: CompletableFuture<Void> = CompletableFuture.completedFuture(null)
    private var closed = false
    private var nextQueryId = 0
    private var querySet = 0
    private var remoteVersion = RemoteVersion.zero()
    private var connectionCount = 0
    private var lastCloseReason = "InitialConnect"
    private var maxObservedTimestamp: String? = null
    private var reconnectDelayMillis = INITIAL_RECONNECT_DELAY_MILLIS
    private var generation = 0L

    internal var reconnectDelayObserver: ((Long) -> Unit)? = null

    fun subscribe(
        path: String,
        args: JsonObject,
    ): Subscription =
        onOwner {
            if (closed) throw ClosedException()
            val subscription =
                Subscription(
                    this,
                    nextQueryId++,
                    ArrayBlockingQueue(MAX_PENDING_UPDATES),
                )
            states[subscription.queryId] = State(subscription, path, args)
            if (socket == null) {
                scheduleReconnect(0)
            } else {
                modify(listOf(add(subscription.queryId, path, args)))
            }
            subscription
        }

    fun unsubscribe(queryId: Int) =
        onOwner {
            val state = states.remove(queryId) ?: return@onOwner
            state.subscription.deactivate()
            if (socket != null) modify(listOf(remove(queryId)))
            if (states.isEmpty()) cancelReconnect()
        }

    fun debugDisconnect() =
        onOwner {
            if (closed) throw ClosedException()
            check(socket != null) { "Live WebSocket is not connected" }
            // Retire the old generation before returning. The adapter may now ack;
            // no callback or queued send from this socket can publish afterwards.
            retire("DebugDisconnect", reconnect = true)
        }

    private fun scheduleReconnect(delayMillis: Long) {
        if (closed || states.isEmpty() || pendingReconnect != null || pendingHandshake != null) return
        reconnectDelayObserver?.invoke(delayMillis)
        pendingReconnect =
            scheduler.schedule(
                {
                    dispatch {
                        pendingReconnect = null
                        connect()
                    }
                },
                delayMillis,
                TimeUnit.MILLISECONDS,
            )
    }

    private fun cancelReconnect() {
        pendingReconnect?.cancel(false)
        pendingReconnect = null
    }

    private fun connect() {
        if (closed || socket != null || pendingHandshake != null || states.isEmpty()) return
        val connectGeneration = ++generation
        val future =
            http
                .newWebSocketBuilder()
                .header("Convex-Client", clientVersion)
                .connectTimeout(Duration.ofSeconds(10))
                .buildAsync(webSocketUrl, Listener(connectGeneration))
        pendingHandshake = future
        future.whenComplete { connected, error ->
            dispatch {
                if (pendingHandshake === future) pendingHandshake = null
                if (closed || connectGeneration != generation) {
                    connected?.abort()
                    return@dispatch
                }
                if (error != null) {
                    val cause = unwrap(error)
                    publishTransportFailure("live handshake", cause)
                    recordFailedConnection("handshake: ${cause.message}")
                    scheduleReconnect(reconnectDelayMillis)
                    increaseBackoff()
                    return@dispatch
                }

                socket = connected
                querySet = 0
                remoteVersion = RemoteVersion.zero()
                sendTail = CompletableFuture.completedFuture(null)
                reconnectDelayMillis = INITIAL_RECONNECT_DELAY_MILLIS

                enqueueJson(
                    buildJsonObject {
                        put("type", "Connect")
                        put("sessionId", UUID.randomUUID().toString())
                        put("connectionCount", connectionCount)
                        put("lastCloseReason", lastCloseReason)
                        maxObservedTimestamp?.let { put("maxObservedTimestamp", it) }
                        put("clientTs", 0)
                    },
                )
                // enqueueJson chains each JDK send future. The Add cannot start
                // until the Connect future has completed successfully.
                if (states.isNotEmpty()) {
                    modify(states.map { (id, state) -> add(id, state.path, state.args) })
                }
            }
        }
    }

    private fun enqueueJson(value: JsonObject) {
        val payload = ConvexClient.json.encodeToString(JsonObject.serializer(), value)
        enqueueSend("live write") { webSocket ->
            webSocket.sendText(payload, true).thenApply { null }
        }
    }

    private fun enqueuePong(payload: ByteBuffer) {
        enqueueSend("live pong") { webSocket ->
            webSocket.sendPong(payload).thenApply { null }
        }
    }

    private fun enqueueSend(
        operation: String,
        action: (WebSocket) -> CompletableFuture<Void>,
    ) {
        val expectedSocket = socket ?: return
        val expectedGeneration = generation
        val next =
            sendTail
                .handle { _, priorFailure ->
                    if (priorFailure != null) throw CompletionException(unwrap(priorFailure))
                    if (closed || socket !== expectedSocket || generation != expectedGeneration) {
                        throw CancellationException("Live connection generation retired")
                    }
                    expectedSocket
                }.thenCompose(action)
        sendTail = next
        next.whenComplete { _, error ->
            if (error == null) return@whenComplete
            dispatch {
                if (!closed && socket === expectedSocket && generation == expectedGeneration) {
                    val cause = unwrap(error)
                    if (cause !is CancellationException) {
                        publishTransportFailure(operation, cause)
                    }
                    retire("$operation: ${cause.message}", reconnect = true)
                }
            }
        }
    }

    private fun modify(modifications: List<JsonObject>) {
        if (modifications.isEmpty()) return
        enqueueJson(
            buildJsonObject {
                put("type", "ModifyQuerySet")
                put("baseVersion", querySet)
                put("newVersion", querySet + 1)
                put("modifications", JsonArray(modifications))
            },
        )
        querySet++
    }

    private fun add(
        id: Int,
        path: String,
        args: JsonObject,
    ) = buildJsonObject {
        put("type", "Add")
        put("queryId", id)
        put("udfPath", path)
        put("args", buildJsonArray { add(args) })
    }

    private fun remove(id: Int) =
        buildJsonObject {
            put("type", "Remove")
            put("queryId", id)
        }

    private fun receive(
        receiveGeneration: Long,
        text: String,
    ) = dispatch {
        if (closed || receiveGeneration != generation || socket == null) return@dispatch
        try {
            val message = ConvexClient.json.parseToJsonElement(text).jsonObject
            when (message["type"]?.jsonPrimitive?.content) {
                "Transition" -> transition(message)
                "Ping", "MutationResponse", "ActionResponse" -> Unit
                "FatalError", "AuthError", "TransitionChunk" -> throw ProtocolException(
                    "${message["type"]?.jsonPrimitive?.content} is unsupported by the Kotlin pilot",
                )
                else -> throw ProtocolException("unknown server message ${message["type"]}")
            }
        } catch (error: Exception) {
            val protocolError =
                if (error is ProtocolException) {
                    error
                } else {
                    ProtocolException("decode Live server message: ${error.message}")
                }
            publishProtocolFailure(protocolError)
            retire(protocolError.message ?: "protocol failure", reconnect = true)
        }
    }

    private fun transition(message: JsonObject) {
        val start =
            version(
                message["startVersion"]?.jsonObject
                    ?: throw ProtocolException("Transition omitted startVersion"),
            )
        if (start != remoteVersion) {
            throw ProtocolException("Transition start version does not match local version")
        }
        val modifications =
            message["modifications"]?.jsonArray
                ?: throw ProtocolException("Transition omitted modifications")
        val changed = mutableListOf<Pair<Int, Update>>()
        for (modification in modifications) {
            val item = modification.jsonObject
            val id =
                item["queryId"]?.jsonPrimitive?.intOrNull
                    ?: throw ProtocolException("Transition modification omitted queryId")
            val logs = logs(item)
            val update =
                when (item["type"]?.jsonPrimitive?.content) {
                    "QueryUpdated" -> Update(item["value"] ?: JsonNull, logs = logs)
                    "QueryFailed" ->
                        Update(
                            error =
                                FunctionException(
                                    "query",
                                    item["errorMessage"]?.jsonPrimitive?.content ?: "query failed",
                                    item["errorData"],
                                    logs,
                                ),
                            logs = logs,
                        )
                    "QueryRemoved" -> {
                        states[id]?.last = null
                        null
                    }
                    else -> throw ProtocolException(
                        "unknown Transition modification ${item["type"]}",
                    )
                }
            if (update != null) changed += id to update
        }
        val end =
            version(
                message["endVersion"]?.jsonObject
                    ?: throw ProtocolException("Transition omitted endVersion"),
            )

        // Commit the complete transition before waking consumers. Any callback
        // from a retired socket was rejected by receiveGeneration above.
        remoteVersion = end
        maxObservedTimestamp = end.timestamp
        reconnectDelayMillis = INITIAL_RECONNECT_DELAY_MILLIS
        changed.sortedBy { it.first }.forEach { (id, update) ->
            val state = states[id] ?: return@forEach
            if (!sameUpdate(state.last, update)) {
                state.last = update
                deliver(state.subscription, update)
            }
        }
    }

    private fun version(value: JsonObject): RemoteVersion =
        RemoteVersion(
            value["querySet"]?.jsonPrimitive?.int
                ?: throw ProtocolException("state version omitted querySet"),
            value["identity"]?.jsonPrimitive?.int
                ?: throw ProtocolException("state version omitted identity"),
            value["ts"]?.jsonPrimitive?.content
                ?: throw ProtocolException("state version omitted ts"),
        )

    private fun logs(value: JsonObject): List<String> = value["logLines"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList()

    private fun sameUpdate(
        previous: Update?,
        next: Update,
    ): Boolean =
        previous != null &&
            previous.error == null &&
            next.error == null &&
            previous.value == next.value &&
            previous.logs == next.logs

    private fun deliver(
        subscription: Subscription,
        update: Update,
    ) {
        if (!subscription.isActive()) return
        if (!subscription.queue.offer(update)) {
            subscription.queue.poll()
            subscription.queue.offer(update)
        }
    }

    private fun publishProtocolFailure(error: ProtocolException) {
        states.values.forEach { deliver(it.subscription, Update(error = error)) }
    }

    private fun publishTransportFailure(
        operation: String,
        error: Throwable,
    ) {
        val transport = TransportException(operation, error)
        states.values.forEach { deliver(it.subscription, Update(error = transport)) }
    }

    private fun recordFailedConnection(reason: String) {
        connectionCount++
        lastCloseReason = reason
        querySet = 0
        remoteVersion = RemoteVersion.zero()
    }

    private fun increaseBackoff() {
        reconnectDelayMillis =
            (reconnectDelayMillis * 2)
                .coerceAtMost(MAX_RECONNECT_DELAY_MILLIS)
    }

    private fun retire(
        reason: String,
        reconnect: Boolean,
    ) {
        val oldSocket = socket
        socket = null
        generation++
        sendTail.cancel(true)
        sendTail = CompletableFuture.completedFuture(null)
        oldSocket?.abort()
        if (oldSocket != null) connectionCount++
        lastCloseReason = reason
        querySet = 0
        remoteVersion = RemoteVersion.zero()
        if (reconnect) {
            scheduleReconnect(reconnectDelayMillis)
            increaseBackoff()
        }
    }

    override fun close() {
        if (!owner.isShutdown) {
            onOwner {
                if (closed) return@onOwner
                closed = true
                generation++
                cancelReconnect()
                pendingHandshake?.cancel(true)
                pendingHandshake = null
                sendTail.cancel(true)
                socket?.abort()
                socket = null
                states.values.forEach { it.subscription.deactivate() }
                states.clear()
            }
        }
        scheduler.shutdownNow()
        http.shutdownNow()
        http.close()
        owner.shutdownNow()
    }

    private fun <T> onOwner(block: () -> T): T {
        if (Thread.currentThread().name == "convex-kotlin-live") return block()
        return owner.submit<T> { block() }.get(5, TimeUnit.SECONDS)
    }

    private fun dispatch(block: () -> Unit) {
        try {
            owner.execute(block)
        } catch (_: RejectedExecutionException) {
            // Shutdown has already retired the generation that produced this callback.
        }
    }

    private fun unwrap(error: Throwable): Throwable {
        var current = error
        while ((current is CompletionException || current is java.util.concurrent.ExecutionException) &&
            current.cause != null
        ) {
            current = current.cause!!
        }
        return current
    }

    private inner class Listener(
        private val listenerGeneration: Long,
    ) : WebSocket.Listener {
        private val text = StringBuilder()

        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }

        override fun onText(
            webSocket: WebSocket,
            data: CharSequence,
            last: Boolean,
        ): CompletableFuture<*> {
            text.append(data)
            if (last) {
                receive(listenerGeneration, text.toString())
                text.clear()
            }
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }

        override fun onBinary(
            webSocket: WebSocket,
            data: ByteBuffer,
            last: Boolean,
        ): CompletableFuture<*> {
            dispatch {
                if (!closed && listenerGeneration == generation && socket === webSocket) {
                    val error = ProtocolException("binary Live messages are unsupported")
                    publishProtocolFailure(error)
                    retire(error.message ?: "binary Live message", reconnect = true)
                }
            }
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }

        override fun onPing(
            webSocket: WebSocket,
            message: ByteBuffer,
        ): CompletableFuture<*> {
            val bytes = ByteArray(message.remaining())
            message.get(bytes)
            dispatch {
                if (!closed && listenerGeneration == generation && socket === webSocket) {
                    enqueuePong(ByteBuffer.wrap(bytes))
                }
            }
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }

        override fun onPong(
            webSocket: WebSocket,
            message: ByteBuffer,
        ): CompletableFuture<*> {
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }

        override fun onClose(
            webSocket: WebSocket,
            statusCode: Int,
            reason: String,
        ): CompletableFuture<*> {
            dispatch {
                if (!closed && listenerGeneration == generation && socket === webSocket) {
                    publishTransportFailure(
                        "live read",
                        IllegalStateException("WebSocket closed $statusCode: $reason"),
                    )
                    retire("close $statusCode: $reason", reconnect = true)
                }
            }
            return CompletableFuture.completedFuture(null)
        }

        override fun onError(
            webSocket: WebSocket,
            error: Throwable,
        ) {
            dispatch {
                if (!closed && listenerGeneration == generation && socket === webSocket) {
                    publishTransportFailure("live read", error)
                    retire("read: ${error.message}", reconnect = true)
                }
            }
        }
    }
}
