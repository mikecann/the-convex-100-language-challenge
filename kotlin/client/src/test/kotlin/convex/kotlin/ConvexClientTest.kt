package convex.kotlin

import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.InetSocketAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ConvexClientTest {
    @Test fun `documented HTTP request keeps arguments headers and logs`() {
        server { exchange ->
            assertEquals("/api/query", exchange.requestURI.path)
            assertEquals("Bearer test-token", exchange.requestHeaders.getFirst("Authorization"))
            val body = ConvexClient.json.parseToJsonElement(exchange.requestBody.readBytes().decodeToString()).jsonObject
            assertEquals("demo:state", body["path"]!!.jsonPrimitive.content)
            assertEquals("room-1", body["args"]!!.jsonObject["room"]!!.jsonPrimitive.content)
            exchange.responseHeaders.add("content-type", "application/json")
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.use {
                it.write(
                    "{\"status\":\"success\",\"value\":{\"count\":1},\"logLines\":[\"ran\"]}".encodeToByteArray(),
                )
            }
        }.use { server ->
            ConvexClient(server.value).use { client ->
                client.setAuth("test-token")
                val result = client.query("demo:state", buildJsonObject { put("room", "room-1") })
                assertEquals(
                    1,
                    result.value.jsonObject["count"]!!
                        .jsonPrimitive.int,
                )
                assertEquals(listOf("ran"), result.logLines)
            }
        }
    }

    @Test fun `HTTP function errors preserve their structured data`() {
        server { exchange ->
            exchange.responseHeaders.add("content-type", "application/json")
            exchange.sendResponseHeaders(560, 0)
            exchange.responseBody.use {
                it.write("{\"status\":\"error\",\"errorMessage\":\"empty\",\"errorData\":{\"code\":\"ROOM_EMPTY\"}}".encodeToByteArray())
            }
        }.use { server ->
            ConvexClient(server.value).use { client ->
                val failure = assertFailsWith<FunctionException> { client.query("demo:requiresNonzero") }
                assertEquals(
                    "ROOM_EMPTY",
                    failure.data!!
                        .jsonObject["code"]!!
                        .jsonPrimitive.content,
                )
            }
        }
    }

    @Test fun `URLs must be absolute HTTP without credentials`() {
        assertFailsWith<IllegalArgumentException> { ConvexClient("ftp://example.test") }
        assertFailsWith<IllegalArgumentException> { ConvexClient("https://user:secret@example.test") }
    }

    private fun server(handler: (com.sun.net.httpserver.HttpExchange) -> Unit): AutoCloseableUrl {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange -> handler(exchange) }
        server.start()
        return AutoCloseableUrl("http://127.0.0.1:${server.address.port}") { server.stop(0) }
    }
}

private class AutoCloseableUrl(
    val value: String,
    private val closeAction: () -> Unit,
) : AutoCloseable {
    override fun close() = closeAction()
}
