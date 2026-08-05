#!/usr/local/bin/node
import { randomUUID } from "node:crypto";
import { Client } from "../../client/convex.js";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");
const room =
  process.argv[2] ?? process.env.EXAMPLE_ROOM ?? "javascript-example";

// Create a native JavaScript client for the deployment selected by the verifier.
const client = new Client(deploymentUrl);
try {
  // Read the counter once over Convex's documented HTTP query endpoint.
  const current = await client.query("demo:state", { room });
  assertCount("current query", current.value.count, 0);
  console.log(`current count: ${current.value.count}`);

  // Start Live before the mutation so its first value proves the initial state.
  const subscription = client.subscribe("demo:state", { room });
  try {
    const initial = await nextUpdate(subscription, "initial Live value");
    assertCount("initial Live value", initial.value.count, current.value.count);
    console.log(`live initial count: ${initial.value.count}`);

    // Send an idempotency key with the mutation, so retries cannot double-count.
    const mutation = await client.mutation("demo:increment", {
      room,
      language: "javascript",
      runId: randomUUID(),
    });
    if (mutation.value.applied !== true) {
      throw new Error("mutation was not applied");
    }
    console.log("mutation applied: true");
    assertCount("mutation", mutation.value.state.count, 1);
    console.log(`mutation count: ${mutation.value.state.count}`);

    // The next Live value must be the write we just made, without another query.
    const updated = await nextUpdate(subscription, "updated Live value");
    assertCount("updated Live value", updated.value.count, 1);
    console.log(`live updated count: ${updated.value.count}`);
    console.log("verified count: 0 -> 1");
  } finally {
    // Always unsubscribe, including when a value or mutation check fails.
    await subscription.close();
  }
} finally {
  // Close the underlying WebSocket before the example exits.
  await client.close();
}

function assertCount(operation, actual, expected) {
  if (actual !== expected) {
    throw new Error(`${operation} count was ${actual}, expected ${expected}`);
  }
}

// Bound the wait and clear the timer on success so cleanup is immediate.
async function nextUpdate(subscription, name) {
  let timer;
  try {
    const item = await Promise.race([
      subscription.next(),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`${name} timed out`)),
          10_000,
        );
      }),
    ]);
    if (item.done) throw new Error(`${name} subscription closed`);
    if (item.value.error) throw item.value.error;
    return item.value;
  } finally {
    clearTimeout(timer);
  }
}
