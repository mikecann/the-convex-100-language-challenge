using System.Text.Json.Nodes;

static JsonNode State(string count) => JsonNode.Parse("{\"count\":" + count + "}")!;
static void Equal(int expected, int actual, string message)
{
    if (expected != actual)
        throw new Exception(message);
}
static void Reject(JsonNode state, string message)
{
    try
    {
        CountValue.Read(state, "test");
        throw new Exception(message);
    }
    catch (InvalidOperationException) { }
}

Equal(0, CountValue.Read(State("0"), "integer"), "JSON integer was rejected");
Equal(0, CountValue.Read(State("0.0"), "double"), "integral JSON double was rejected");
Equal(
    int.MinValue,
    CountValue.Read(State(int.MinValue.ToString()), "minimum"),
    "Int32 minimum was rejected"
);
Equal(
    int.MaxValue,
    CountValue.Read(State(int.MaxValue.ToString()), "maximum"),
    "Int32 maximum was rejected"
);
Reject(State("0.5"), "fraction was accepted");
Reject(JsonNode.Parse("{\"count\":\"0\"}")!, "non-number was accepted");
Reject(State("2147483648"), "out-of-range number was accepted");
Reject(new JsonObject { ["count"] = double.NaN }, "NaN was accepted");
Reject(new JsonObject { ["count"] = double.PositiveInfinity }, "infinity was accepted");
Reject(new JsonObject { ["count"] = true }, "boolean was accepted");
Console.WriteLine("C# example count tests passed");
