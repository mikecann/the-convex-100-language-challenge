package convex.kotlin

import kotlinx.serialization.json.JsonElement

/** A successful Convex function response, retaining JSON for application-specific decoding. */
data class Result(val value: JsonElement, val logLines: List<String> = emptyList())

/** Convex returned an application or function failure, distinct from a bad transport. */
class FunctionException(
    val operation: String,
    message: String,
    val data: JsonElement? = null,
    val logLines: List<String> = emptyList(),
) : RuntimeException("convex $operation failed: $message")

/** The server did not speak the explicitly pinned Live protocol profile. */
class ProtocolException(message: String) : RuntimeException("convex protocol error: $message")

/** A connection, timeout, or HTTP transport failed before Convex returned a value. */
class TransportException(operation: String, cause: Throwable) : RuntimeException(
    "convex $operation transport error: ${cause.message}",
    cause,
)

class ClosedException : IllegalStateException("convex client is closed")
