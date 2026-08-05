module basics_main;

import convex : ConvexClient;
import std.json : JSONType, JSONValue;
import std.math : isFinite;
import std.process : environment;
import std.stdio : writeln;

/* Convex may encode a whole counter as either 1 or 1.0. Accept both JSON
 * spellings, but reject fractions and out-of-range values. */
long wholeCounter(JSONValue value, string operation)
{
    if (value.type == JSONType.integer)
    {
        if (value.integer >= 0)
            return value.integer;
    }
    if (value.type == JSONType.float_)
    {
        auto number = value.floating;
        /* long.max rounds up when converted to double, so compare against the
         * first unrepresentable integer instead of casting before the guard. */
        if (number.isFinite && number >= 0 && number < 9_223_372_036_854_775_808.0)
        {
            auto integer = cast(long) number;
            if (number == integer)
                return integer;
        }
    }
    throw new Exception(operation ~ " count is not a whole nonnegative integer");
}

version (ExampleUnitTest)
{
    void main()
    {
    }
}
else
    void main(string[] arguments)
{
    // Read the dedicated verification deployment and unique room supplied by
    // the shared example runner.
    auto url = environment.get("CONVEX_URL", "");
    if (url.length == 0)
        throw new Exception("CONVEX_URL is required");
    auto room = arguments.length > 1 ? arguments[1] : "d-basic-example";

    // Create the native D client and guarantee cleanup on every failure path.
    auto client = new ConvexClient(url);
    scope (exit)
        client.close();

    // Query the current counter over Convex's documented HTTP endpoint.
    auto query = client.query("demo:state", JSONValue(["room": JSONValue(room)]));
    // Decode the JSON response into the integer compared by the journey.
    auto before = wholeCounter(query.value.object["count"], "query");
    if (before != 0)
        throw new Exception("expected a fresh room to start at zero");
    writeln("current count: 0");

    // Start Live before mutating, so the initial snapshot and later change
    // prove a reactive WebSocket subscription rather than HTTP polling.
    auto live = client.subscribe("demo:state", JSONValue([
        "room": JSONValue(room)
    ]));
    scope (exit)
        live.close();
    auto initial = live.next(10_000);
    if (initial is null || initial.error !is null || !initial.hasValue
            || wholeCounter(initial.value.object["count"], "initial Live") != before)
        throw new Exception("unexpected initial Live value");
    writeln("live initial count: 0");

    // The unique room also makes this idempotency key safe if verification is
    // retried after the mutation response was lost.
    auto mutation = client.mutation("demo:increment", JSONValue([
        "room": JSONValue(room),
        "language": JSONValue("d"),
        "runId": JSONValue(room ~ "-once")
    ]));
    if (mutation.value.object["applied"].type != JSONType.true_)
        throw new Exception("mutation was not applied");
    auto after = wholeCounter(mutation.value.object["state"].object["count"], "mutation");
    if (after != before + 1)
        throw new Exception("mutation did not increment once");
    writeln("mutation applied: true");
    writeln("mutation count: 1");

    // Read the resulting Live update and fail if it disagrees with HTTP.
    auto updated = live.next(10_000);
    if (updated is null || updated.error !is null || !updated.hasValue
            || wholeCounter(updated.value.object["count"], "updated Live") != after)
        throw new Exception("unexpected updated Live value");
    writeln("live updated count: 1");

    // Print verification only after HTTP and Live agree on the 0 -> 1 journey.
    writeln("verified count: 0 -> 1");
}

unittest
{
    assert(wholeCounter(JSONValue(0.0), "zero") == 0);
    assert(wholeCounter(JSONValue(1.0), "one") == 1);
    foreach (invalid; [
        JSONValue(0.5), JSONValue("1"), JSONValue(double.nan),
        JSONValue(double.infinity), JSONValue(9_223_372_036_854_775_808.0),
        JSONValue(-1L)
    ])
    {
        bool rejected;
        try
            wholeCounter(invalid, "invalid");
        catch (Exception)
            rejected = true;
        assert(rejected);
    }
}
