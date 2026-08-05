using System.Text.Json;
using System.Text.Json.Nodes;

/// <summary>Normalizes Convex JSON numbers used by the counter example.</summary>
public static class CountValue
{
    public static int Read(JsonNode state, string operation)
    {
        if (state["count"] is not JsonValue value)
            throw Invalid(operation);

        // HTTP JSON nodes retain their JsonElement representation. Prefer the
        // exact integer path, then accept 0.0-style encodings only when whole.
        if (value.TryGetValue<JsonElement>(out var element))
        {
            if (element.ValueKind != JsonValueKind.Number) throw Invalid(operation);
            if (element.TryGetInt32(out var integer)) return integer;
            if (element.TryGetDouble(out var floating)) return Normalize(floating, operation);
            throw Invalid(operation);
        }

        // These branches keep the helper useful for programmatically-created
        // JsonNodes in tests and for callers composing values without parsing.
        if (value.TryGetValue<int>(out var directInteger)) return directInteger;
        if (value.TryGetValue<long>(out var longInteger) && longInteger >= int.MinValue && longInteger <= int.MaxValue)
            return (int)longInteger;
        if (value.TryGetValue<double>(out var directDouble)) return Normalize(directDouble, operation);
        throw Invalid(operation);
    }

    private static int Normalize(double value, string operation)
    {
        if (!double.IsFinite(value) || value != Math.Truncate(value) || value < int.MinValue || value > int.MaxValue)
            throw Invalid(operation);
        return (int)value;
    }

    private static InvalidOperationException Invalid(string operation) =>
        new(operation + " did not return a whole Int32 count");
}
