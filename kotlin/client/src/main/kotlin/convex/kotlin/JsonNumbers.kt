package convex.kotlin

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal

/**
 * Decode a JSON number only when it represents an exact Kotlin [Int].
 *
 * Convex may serialize an integral database value as `0.0`, so the usual
 * kotlinx.serialization `int` accessor is too strict for this boundary. Using
 * [BigDecimal.intValueExact] accepts decimal or exponent notation without
 * rounding, while rejecting fractions and values outside the Int range.
 */
fun JsonElement.integralIntOrNull(): Int? {
    val primitive = this as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    val decimal = primitive.content.toBigDecimalOrNull() ?: return null
    return try {
        decimal.intValueExact()
    } catch (_: ArithmeticException) {
        null
    }
}
