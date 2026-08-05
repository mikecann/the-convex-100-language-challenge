package convex.kotlin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class JsonNumbersTest {
    @Test
    fun `integral decimal JSON numbers decode without rounding`() {
        assertEquals(0, number("0.0").integralIntOrNull())
        assertEquals(1, number("1.0").integralIntOrNull())
        assertEquals(1, number("1e0").integralIntOrNull())
    }

    @Test
    fun `fractional out of range and quoted values are rejected`() {
        assertNull(number("1.5").integralIntOrNull())
        assertNull(number("2147483648.0").integralIntOrNull())
        assertNull(ConvexClient.json.parseToJsonElement("\"1.0\"").integralIntOrNull())
    }

    private fun number(json: String) = ConvexClient.json.parseToJsonElement(json)
}
