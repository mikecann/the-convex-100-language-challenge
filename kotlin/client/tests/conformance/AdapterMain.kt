package convex.kotlin.adapter

import convex.kotlin.ClosedException
import convex.kotlin.ConvexClient
import convex.kotlin.FunctionException
import convex.kotlin.ProtocolException
import convex.kotlin.Subscription
import convex.kotlin.TransportException
import convex.kotlin.Update
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

private const val ADAPTER_PROTOCOL_VERSION = 1

/** Test-only NDJSON protocol v1 facade over the real native Kotlin client. */
fun main() {
    val listen = System.getenv("ADAPTER_LISTEN")
    if (listen.isNullOrBlank()) {
        runAdapter(
            BufferedReader(InputStreamReader(System.`in`)),
            BufferedWriter(OutputStreamWriter(System.out)),
        )
        return
    }
    val (host, port) = parseListenAddress(listen)
    ServerSocket(port, 1, java.net.InetAddress.getByName(host)).use { server ->
        System.err.println("adapter listening on $listen")
        server.accept().use { socket ->
            runAdapter(socket.getInputStream().bufferedReader(), socket.getOutputStream().bufferedWriter())
        }
    }
}

internal fun parseListenAddress(value: String): Pair<String, Int> {
    val split = value.lastIndexOf(':')
    require(split > 0 && split < value.lastIndex) { "ADAPTER_LISTEN must be host:port" }
    return value.substring(0, split) to value.substring(split + 1).toInt()
}

internal fun runAdapter(input: BufferedReader, output: BufferedWriter) {
    val writer = LockedWriter(output)
    val subscriptions = ConcurrentHashMap<String, Subscription>()
    var client: ConvexClient? = null
    fun getClient(): ConvexClient {
        client?.let { return it }
        val url = System.getenv("CONVEX_URL") ?: error("CONVEX_URL is required")
        return ConvexClient(url).also { client = it }
    }
    fun failure(id: String?, subscriptionId: String?, error: Throwable) {
        val function = error as? FunctionException
        val name = when (error) {
            is FunctionException -> "FunctionError"
            is ProtocolException -> "ProtocolError"
            is TransportException -> "TransportError"
            is ClosedException -> "ClosedError"
            else -> "Error"
        }
        writer.write(
            buildJsonObject {
                put("type", if (subscriptionId == null) "error" else "subscription")
                if (subscriptionId == null && id != null) put("id", id)
                if (subscriptionId != null) put("subscriptionId", subscriptionId)
                put("error", buildJsonObject {
                    put("name", name)
                    put("message", error.message ?: error::class.simpleName ?: "error")
                    function?.data?.let { put("data", it) }
                })
                if (!function?.logLines.isNullOrEmpty()) {
                    put("logs", jsonStrings(function!!.logLines))
                }
            },
        )
    }
    fun relay(subscriptionId: String, subscription: Subscription) = Thread {
        while (subscription.isActive()) {
            val update = subscription.next(java.time.Duration.ofMillis(250)) ?: continue
            // Unsubscribe/replacement invalidates before its ack. This second
            // check closes the dequeue-to-write race for stale relay events.
            if (!subscription.isActive() || subscriptions[subscriptionId] !== subscription) continue
            val updateError = update.error
            if (updateError != null) failure(null, subscriptionId, updateError) else {
                writer.write(buildJsonObject {
                    put("type", "subscription")
                    put("subscriptionId", subscriptionId)
                    put("value", update.value!!)
                    if (update.logs.isNotEmpty()) put("logs", jsonStrings(update.logs))
                })
            }
        }
    }.apply { isDaemon = true; start() }

    input.lineSequence().forEach { line ->
        val command = try {
            ConvexClient.json.parseToJsonElement(line).jsonObject
        } catch (error: Exception) {
            failure(null, null, IllegalArgumentException("decode command: ${error.message}"))
            return@forEach
        }
        val id = command["id"]?.jsonPrimitive?.content
        val op = command["op"]?.jsonPrimitive?.content
        try {
            when (op) {
                "hello" -> {
                    require(command["protocolVersion"]?.jsonPrimitive?.int == ADAPTER_PROTOCOL_VERSION) {
                        "unsupported adapter protocol version"
                    }
                    writer.write(buildJsonObject {
                        put("protocolVersion", ADAPTER_PROTOCOL_VERSION)
                        put("id", id!!)
                        put("type", "ready")
                        put("language", "kotlin")
                        put("implementation", "native-kotlin-jdk21")
                        put("runtime", System.getProperty("java.runtime.version"))
                    })
                }
                "query", "mutation", "action" -> {
                    val args = command["args"]?.jsonObject ?: JsonObject(emptyMap())
                    val result = when (op) {
                        "query" -> getClient().query(command["path"]!!.jsonPrimitive.content, args)
                        "mutation" -> getClient().mutation(command["path"]!!.jsonPrimitive.content, args)
                        else -> getClient().action(command["path"]!!.jsonPrimitive.content, args)
                    }
                    writer.write(buildJsonObject {
                        put("type", "result")
                        put("id", id!!)
                        put("value", result.value)
                        if (result.logLines.isNotEmpty()) put("logs", jsonStrings(result.logLines))
                    })
                }
                "setAuth" -> {
                    getClient().setAuth(command["token"]?.jsonPrimitive?.content ?: "")
                    writer.write(ack(id!!))
                }
                "subscribe" -> {
                    val subscriptionId = command["subscriptionId"]?.jsonPrimitive?.content ?: error("subscriptionId is required")
                    val next = getClient().subscribe(
                        command["path"]!!.jsonPrimitive.content,
                        command["args"]?.jsonObject ?: JsonObject(emptyMap()),
                    )
                    subscriptions.put(subscriptionId, next)?.close()
                    relay(subscriptionId, next)
                    writer.write(ack(id!!))
                }
                "unsubscribe" -> {
                    subscriptions.remove(command["subscriptionId"]?.jsonPrimitive?.content)?.close()
                    writer.write(ack(id!!))
                }
                "debugDisconnect" -> {
                    getClient().debugDisconnectForAdapter()
                    writer.write(ack(id!!))
                }
                "close" -> {
                    subscriptions.values.forEach { it.close() }
                    subscriptions.clear()
                    client?.close()
                    writer.write(buildJsonObject {
                        put("type", "closed")
                        put("id", id!!)
                    })
                    return
                }
                else -> error("unknown operation $op")
            }
        } catch (error: Throwable) { failure(id, null, error) }
    }
    subscriptions.values.forEach { it.close() }
    client?.close()
}

private fun ack(id: String) = buildJsonObject {
    put("type", "ack")
    put("id", id)
}
private fun jsonStrings(values: List<String>) = kotlinx.serialization.json.JsonArray(values.map(::JsonPrimitive))

private class LockedWriter(private val output: BufferedWriter) {
    @Synchronized fun write(value: JsonObject) {
        output.write(ConvexClient.json.encodeToString(JsonObject.serializer(), value))
        output.newLine()
        output.flush()
    }
}
