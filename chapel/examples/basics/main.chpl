module ChapelConvexBasics {
  use IO;
  use Convex;
  use ConvexTransport;

  // Turn the JSON shape used by this demo into an application value. The C
  // JSON transport helper performs exact decimal validation, so 1.0 is valid
  // while fractional, quoted, non-finite, and overflowing counts are rejected.
  proc countFromState(operation: string, stateJson: string): int(64) {
    const (valid, count) = jsonIntegralField(stateJson, "count");
    if !valid then
      halt("decode ", operation, ": count must be an in-range integer");
    return count;
  }

  // Every demonstrated operation is checked before anything claims success.
  proc expectCount(operation: string, actual: int(64), expected: int(64)) {
    if actual != expected then
      halt(operation, " count was ", actual, ", expected ", expected);
  }

  proc requireSuccess(operation: string,
                      const ref result: callResult): string {
    if !result.ok then halt(operation, " failed: ", result.failure.message);
    return result.valueJson;
  }

  proc main(args: [] string) {
    const deploymentUrl = environment("CONVEX_URL");
    if deploymentUrl.numBytes == 0 then halt("CONVEX_URL is required");

    // Create a Convex client connected to the deployment from the environment.
    var client = new owned Client(deploymentUrl);

    // Close the HTTP and Live resources before the example exits.
    defer client.close();

    const room = if args.size > 1 then args[1] else "chapel-example";
    const roomArgs = "{\"room\":" + jsonQuote(room) + "}";

    // Run a Convex query over HTTPS to get this room's current state.
    const currentJson = requireSuccess(
      "current query", client.query("demo:state", roomArgs)
    );

    // Decode the raw JSON into the Chapel integer used by the application.
    const currentCount = countFromState("current query", currentJson);
    expectCount("current query", currentCount, 0);
    writeln("current count: ", currentCount);

    // Start Live before mutating so it cannot miss the demonstrated change.
    const (subscription, subscribeFailure) =
      client.subscribe("demo:state", roomArgs);
    if subscribeFailure.isPresent || subscription == nil then
      halt("subscribe failed: ", subscribeFailure.message);

    // Stop the query on scope exit. Shared ownership keeps an active reader
    // alive until its task has observed the terminal close.
    defer subscription!.close();

    // Convex Live first sends a snapshot. Read and validate it before writing.
    const initial = subscription!.next(10.0);
    if !initial.available || initial.failure.isPresent ||
       !initial.hasValue then
      halt("Live subscription did not deliver its initial value");
    const initialCount = countFromState(
      "initial Live value", initial.valueJson
    );
    expectCount("initial Live value", initialCount, currentCount);
    writeln("live initial count: ", initialCount);

    // Run the mutation over HTTPS. runId is its idempotency key, so a retry
    // cannot accidentally apply a second increment.
    const mutationArgs = "{\"room\":" + jsonQuote(room) +
      ",\"language\":\"chapel\",\"runId\":" +
      jsonQuote(randomUUID()) + "}";
    const mutationJson = requireSuccess(
      "mutation", client.mutation("demo:increment", mutationArgs)
    );
    const (hasApplied, appliedJson) = jsonRaw(mutationJson, "applied");
    if !hasApplied || appliedJson != "true" then
      halt("mutation was not applied");
    writeln("mutation applied: true");
    const (hasState, mutationState) = jsonRaw(mutationJson, "state");
    if !hasState then halt("mutation result omitted state");
    const mutationCount = countFromState("mutation", mutationState);
    expectCount("mutation", mutationCount, 1);
    writeln("mutation count: ", mutationCount);

    // Receive the changed room through Live without another HTTP query.
    const changed = subscription!.next(10.0);
    if !changed.available || changed.failure.isPresent ||
       !changed.hasValue then
      halt("Live subscription did not deliver the changed value");
    const changedCount = countFromState(
      "updated Live value", changed.valueJson
    );
    expectCount("updated Live value", changedCount, 1);
    writeln("live updated count: ", changedCount);

    // Reaching here proves HTTPS and Live agreed on the same 0 -> 1 change.
    writeln("verified count: ", currentCount, " -> ", changedCount);
  }
}
