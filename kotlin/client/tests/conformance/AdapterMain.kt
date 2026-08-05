package convex.kotlin.adapter

import convex.kotlin.ClosedException
import convex.kotlin.ConvexClient
import convex.kotlin.FunctionException
import convex.kotlin.ProtocolException
import convex.kotlin.Subscription
import convex.kotlin.TransportException
import convex.kotlin.Update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

private const val ADAPTER_PROTOCOL_VERSION = 1

/** Deterministic pause points used only by language-local adapter race tests. */
object AdapterTestHooks {
    @Volatile
    var beforePublish: ((String, Long, Update) -> Unit)? = null

    @Volatile
    var insidePublicationLock: ((String, Long) -> Unit)? = null

    fun reset() {
        beforePublish = null
        insidePublicationLock = null
    }
}

private data class RelayRegistration(
    val generation: Long,
    val subscription: Subscription,
)

/** Test-only NDJSON protocol v1 facade over the real native Kotlin client. */
fun main() {
    val listen = System.getenv("ADAPTER_LISTEN")
    if (listen.isNullOrBlank()) {
        runAdapter(
            BufferedReader(InputStreamReader(System.`in`)),
            BufferedWriter(OutputStreamWriter(System.out)),
            System.getenv("CONVEX_URL"),
        )
        return
    }
    val (host, port) = parseListenAddress(listen)
    ServerSocket(port, 1, InetAddress.getByName(host)).use { server ->
        System.err.println("adapter listening on $listen")
        server.accept().use { socket ->
            runAdapter(
                socket.getInputStream().bufferedReader(),
                socket.getOutputStream().bufferedWriter(),
                System.getenv("CONVEX_URL"),
            )
        }
    }
}

fun parseListenAddress(value: String): Pair<String, Int> {
    val split = value.lastIndexOf(':')
    require(split > 0 && split < value.lastIndex) { "ADAPTER_LISTEN must be host:port" }
    return value.substring(0, split) to value.substring(split + 1).toInt()
}

fun runAdapter(
    input: BufferedReader,
    output: BufferedWriter,
    deploymentUrl: String?,
) {
    val writer = LockedWriter(output)
    val registrations = ConcurrentHashMap<String, RelayRegistration>()
    val nextGeneration = AtomicLong(1)
    var client: ConvexClient? = null

    fun getClient(): ConvexClient {
        client?.let { return it }
        val url = deploymentUrl ?: error("CONVEX_URL is required")
        return ConvexClient(url).also { created ->
            System.getenv("CONVEX_AUTH_TOKEN")?.takeIf { it.isNotEmpty() }?.let(created::setAuth)
            client = created
        }
    }

    fun failure(
        id: String?,
        subscriptionId: String?,
        error: Throwable,
    ): JsonObject {
        val function = error as? FunctionException
        val name =
            when (error) {
                is FunctionException -> "FunctionError"
                is ProtocolException -> "ProtocolError"
                is TransportException -> "TransportError"
                is ClosedException -> "ClosedError"
                else -> "Error"
            }
        return buildJsonObject {
            put("type", if (subscriptionId == null) "error" else "subscription")
            if (subscriptionId == null && id != null) put("id", id)
            if (subscriptionId != null) put("subscriptionId", subscriptionId)
            put(
                "error",
                buildJsonObject {
                    put("name", name)
                    put("message", error.message ?: error::class.simpleName ?: "error")
                    function?.data?.let { put("data", it) }
                },
            )
            if (!function?.logLines.isNullOrEmpty()) {
                put("logs", jsonStrings(function!!.logLines))
            }
        }
    }

    fun relay(
        subscriptionId: String,
        registration: RelayRegistration,
    ) = Thread {
        try {
            while (registration.subscription.isActive()) {
                val update = registration.subscription.next(Duration.ofMillis(250)) ?: continue
                AdapterTestHooks.beforePublish?.invoke(
                    subscriptionId,
                    registration.generation,
                    update,
                )
                val event =
                    update.error?.let { failure(null, subscriptionId, it) }
                        ?: buildJsonObject {
                            put("type", "subscription")
                            put("subscriptionId", subscriptionId)
                            put("value", update.value!!)
                            if (update.logs.isNotEmpty()) put("logs", jsonStrings(update.logs))
                        }
                writer.writeIf(
                    current = {
                        registrations[subscriptionId] === registration &&
                            registration.subscription.isActive()
                    },
                    beforeCondition = {
                        AdapterTestHooks.insidePublicationLock?.invoke(
                            subscriptionId,
                            registration.generation,
                        )
                    },
                    value = event,
                )
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (error: Throwable) {
            writer.writeIf(
                current = {
                    registrations[subscriptionId] === registration &&
                        registration.subscription.isActive()
                },
                value = failure(null, subscriptionId, error),
            )
        }
    }.apply {
        name = "convex-kotlin-adapter-relay-${registration.generation}"
        isDaemon = true
        start()
    }

    try {
        input.lineSequence().forEach { line ->
            val command =
                try {
                    ConvexClient.json.parseToJsonElement(line).jsonObject
                } catch (error: Exception) {
                    writer.write(failure(null, null, ProtocolException("decode command: ${error.message}")))
                    return@forEach
                }
            val id = command["id"]?.jsonPrimitive?.content
            val op = command["op"]?.jsonPrimitive?.content
            try {
                when (op) {
                    "hello" -> {
                        require(
                            command["protocolVersion"]?.jsonPrimitive?.int ==
                                ADAPTER_PROTOCOL_VERSION,
                        ) { "unsupported adapter protocol version" }
                        writer.write(
                            buildJsonObject {
                                put("protocolVersion", ADAPTER_PROTOCOL_VERSION)
                                put("id", id ?: error("hello id is required"))
                                put("type", "ready")
                                put("language", "kotlin")
                                put("implementation", "native-kotlin-jdk21")
                                put("runtime", System.getProperty("java.runtime.version"))
                            },
                        )
                    }
                    "query", "mutation", "action" -> {
                        val args = command["args"]?.jsonObject ?: JsonObject(emptyMap())
                        val path =
                            command["path"]?.jsonPrimitive?.content
                                ?: error("path is required")
                        val result =
                            when (op) {
                                "query" -> getClient().query(path, args)
                                "mutation" -> getClient().mutation(path, args)
                                else -> getClient().action(path, args)
                            }
                        writer.write(
                            buildJsonObject {
                                put("type", "result")
                                put("id", id ?: error("id is required"))
                                put("value", result.value)
                                if (result.logLines.isNotEmpty()) {
                                    put("logs", jsonStrings(result.logLines))
                                }
                            },
                        )
                    }
                    "setAuth" -> {
                        getClient().setAuth(command["token"]?.jsonPrimitive?.content ?: "")
                        writer.write(ack(id))
                    }
                    "subscribe" -> {
                        val subscriptionId =
                            command["subscriptionId"]?.jsonPrimitive?.content
                                ?: error("subscriptionId is required")
                        val path =
                            command["path"]?.jsonPrimitive?.content
                                ?: error("path is required")

                        // Remove and close the old generation before publishing
                        // the replacement acknowledgement.
                        registrations.remove(subscriptionId)?.subscription?.close()
                        val subscription =
                            getClient().subscribe(
                                path,
                                command["args"]?.jsonObject ?: JsonObject(emptyMap()),
                            )
                        val registration =
                            RelayRegistration(
                                nextGeneration.getAndIncrement(),
                                subscription,
                            )
                        registrations[subscriptionId] = registration
                        writer.write(ack(id))
                        relay(subscriptionId, registration)
                    }
                    "unsubscribe" -> {
                        val subscriptionId =
                            command["subscriptionId"]?.jsonPrimitive?.content
                                ?: ""
                        registrations.remove(subscriptionId)?.subscription?.close()
                        // LockedWriter shares the publication lock with relays.
                        // Once this ack is visible no old relay can cross it.
                        writer.write(ack(id))
                    }
                    "debugDisconnect" -> {
                        getClient().debugDisconnectForAdapter()
                        writer.write(ack(id))
                    }
                    "close" -> {
                        registrations.values.forEach { it.subscription.close() }
                        registrations.clear()
                        client?.close()
                        writer.close(
                            buildJsonObject {
                                put("type", "closed")
                                put("id", id ?: error("id is required"))
                            },
                        )
                        return
                    }
                    else -> error("unknown operation $op")
                }
            } catch (error: Throwable) {
                writer.write(failure(id, null, error))
            }
        }
    } finally {
        registrations.values.forEach { it.subscription.close() }
        registrations.clear()
        client?.close()
    }
}

private fun ack(id: String?) =
    buildJsonObject {
        put("type", "ack")
        put("id", id ?: error("id is required"))
    }

private fun jsonStrings(values: List<String>) = JsonArray(values.map(::JsonPrimitive))

private class LockedWriter(
    private val output: BufferedWriter,
) {
    private var closed = false

    @Synchronized
    fun write(value: JsonObject) {
        if (!closed) writeUnlocked(value)
    }

    @Synchronized
    fun writeIf(
        current: () -> Boolean,
        beforeCondition: () -> Unit = {},
        value: JsonObject,
    ) {
        beforeCondition()
        if (!closed && current()) writeUnlocked(value)
    }

    @Synchronized
    fun close(value: JsonObject) {
        if (closed) return
        closed = true
        writeUnlocked(value)
    }

    private fun writeUnlocked(value: JsonObject) {
        output.write(ConvexClient.json.encodeToString(JsonObject.serializer(), value))
        output.newLine()
        output.flush()
    }
}
