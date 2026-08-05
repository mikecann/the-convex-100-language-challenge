package convex.kotlin

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.concurrent.atomic.AtomicBoolean

private const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024

/**
 * An educational native Kotlin Convex client. It implements the documented JSON
 * HTTP endpoints itself and hands the experimental Live profile to [LiveManager].
 */
class ConvexClient(
    deploymentUrl: String,
    private val clientVersion: String = "kotlin-0.1.0",
    private val http: HttpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build(),
) : AutoCloseable {
    internal val deploymentUrl = normaliseDeploymentUrl(deploymentUrl)
    private val closed = AtomicBoolean(false)

    @Volatile private var authToken = ""

    @Volatile private var live: LiveManager? = null

    fun setAuth(token: String) {
        if (closed.get()) throw ClosedException()
        authToken = token
    }

    fun query(
        path: String,
        args: JsonObject = JsonObject(emptyMap()),
    ) = call("query", path, args)

    fun mutation(
        path: String,
        args: JsonObject = JsonObject(emptyMap()),
    ) = call("mutation", path, args)

    fun action(
        path: String,
        args: JsonObject = JsonObject(emptyMap()),
    ) = call("action", path, args)

    private fun call(
        operation: String,
        path: String,
        args: JsonObject,
    ): Result {
        require(path.isNotBlank()) { "Convex function path is required" }
        if (closed.get()) throw ClosedException()
        val body =
            json.encodeToString(
                JsonObject.serializer(),
                buildJsonObject {
                    put("path", path)
                    put("args", args)
                    put("format", "json")
                },
            )
        val request =
            HttpRequest
                .newBuilder(URI("$deploymentUrl/api/$operation"))
                .timeout(Duration.ofSeconds(30))
                .header("Content-Type", "application/json")
                .header("Accept", "application/json")
                .header("Convex-Client", clientVersion)
                .apply { if (authToken.isNotBlank()) header("Authorization", "Bearer $authToken") }
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build()
        val response =
            try {
                http.send(request, HttpResponse.BodyHandlers.ofByteArray())
            } catch (error: Exception) {
                throw TransportException(operation, error)
            }
        if (response.body().size > MAX_RESPONSE_BYTES) {
            throw TransportException(operation, IllegalStateException("response exceeds $MAX_RESPONSE_BYTES bytes"))
        }
        val decoded =
            try {
                json.parseToJsonElement(response.body().decodeToString()).jsonObject
            } catch (error: Exception) {
                throw TransportException(operation, IllegalStateException("HTTP ${response.statusCode()} returned non-Convex JSON", error))
            }
        val logs = decoded["logLines"]?.let { value -> value.jsonArray.map { it.jsonPrimitive.content } } ?: emptyList()
        return when (decoded["status"]?.jsonPrimitive?.content) {
            "success" -> Result(decoded["value"] ?: throw ProtocolException("success response omitted value"), logs)
            "error" -> throw FunctionException(
                operation,
                decoded["errorMessage"]?.jsonPrimitive?.content ?: "Convex function failed",
                decoded["errorData"],
                logs,
            )
            else -> throw ProtocolException("HTTP ${response.statusCode()} response has an unknown status")
        }
    }

    fun subscribe(
        path: String,
        args: JsonObject = JsonObject(emptyMap()),
    ): Subscription {
        require(path.isNotBlank()) { "Convex function path is required" }
        if (closed.get()) throw ClosedException()
        return synchronized(this) {
            val manager = live ?: LiveManager(deploymentUrl, clientVersion).also { live = it }
            manager.subscribe(path, args)
        }
    }

    /** Adapter-only test hook; normal client builds do not expose an adapter executable. */
    internal fun debugDisconnectForAdapter() {
        if (closed.get()) throw ClosedException()
        (live ?: throw IllegalStateException("Live WebSocket has not been started")).debugDisconnect()
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            live?.close()
            http.shutdownNow()
            http.close()
        }
    }

    private fun normaliseDeploymentUrl(raw: String): String {
        val uri = URI(raw)
        require(uri.scheme in setOf("http", "https") && uri.host != null && uri.userInfo == null) {
            "Convex deployment URL must be an absolute HTTP(S) URL without user information"
        }
        return URI(uri.scheme, null, uri.host, uri.port, uri.path?.trimEnd('/'), null, null).toString().trimEnd('/')
    }

    companion object {
        /** Shared strict-ish JSON codec used by the client and its test-only adapter. */
        val json =
            Json {
                ignoreUnknownKeys = true
                explicitNulls = false
            }
    }
}
