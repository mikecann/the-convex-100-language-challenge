# Convex from TypeScript

This folder shows a small TypeScript program speaking directly to Convex over HTTP and WebSocket. It is educational and unofficial, not a production SDK or publishable package.

## Start here

Read the [canonical basic example](examples/basics/main.ts). It reads a counter, starts Live, applies an idempotent increment, and verifies the `0 -> 1` journey.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| HTTP bearer token lifecycle | Verified by shared local and hosted conformance |
| Initial and updated Live values | Verified by shared local and hosted conformance |
| Reconnect and adapter-only disconnect hook | Verified by shared local and hosted conformance |
| Capability badges | Not claimed until root evidence |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ts -->
```typescript
#!/usr/local/bin/node
import { randomUUID } from "node:crypto";
import { Client, Subscription } from "../../client/convex.js";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");
const room =
  process.argv[2] ?? process.env.EXAMPLE_ROOM ?? "typescript-example";

// Create the native TypeScript client for the verifier's selected deployment.
const client = new Client(deploymentUrl);
try {
  // Query the counter first, establishing the expected starting value over HTTP.
  const current = await client.query("demo:state", { room });
  assertCount("current query", (current.value as { count: number }).count, 0);
  console.log(`current count: ${(current.value as { count: number }).count}`);

  // Start Live before the mutation so its first value proves the initial state.
  const subscription = client.subscribe("demo:state", { room });
  try {
    const initial = await nextUpdate(subscription, "initial Live value");
    assertCount(
      "initial Live value",
      (initial.value as { count: number }).count,
      0,
    );
    console.log(
      `live initial count: ${(initial.value as { count: number }).count}`,
    );

    // A UUID idempotency key makes retrying this mutation safe.
    const mutation = await client.mutation("demo:increment", {
      room,
      language: "typescript",
      runId: randomUUID(),
    });
    const mutationValue = mutation.value as {
      applied: boolean;
      state: { count: number };
    };
    if (mutationValue.applied !== true)
      throw new Error("mutation was not applied");
    console.log("mutation applied: true");
    assertCount("mutation", mutationValue.state.count, 1);
    console.log(`mutation count: ${mutationValue.state.count}`);

    // The next Live value must be the mutation's resulting state, with no extra query.
    const updated = await nextUpdate(subscription, "updated Live value");
    assertCount(
      "updated Live value",
      (updated.value as { count: number }).count,
      1,
    );
    console.log(
      `live updated count: ${(updated.value as { count: number }).count}`,
    );
    console.log("verified count: 0 -> 1");
  } finally {
    await subscription.close();
  }
} finally {
  await client.close();
}
function assertCount(
  operation: string,
  actual: number,
  expected: number,
): void {
  if (actual !== expected)
    throw new Error(`${operation} count was ${actual}, expected ${expected}`);
}
// Race each subscription read against a timer so a protocol stall fails clearly.
async function nextUpdate(subscription: Subscription, name: string) {
  let timer: NodeJS.Timeout | undefined;
  try {
    const item = await Promise.race([
      subscription.next(),
      new Promise<never>((_, reject) => {
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
    if (timer) clearTimeout(timer);
  }
}
```
<!-- END GENERATED EXAMPLE -->

## Docker-only verification

```sh
./run test typescript
./run build typescript
```

The first command typechecks, tests, and compiles inside the pinned linux/amd64 image. The second builds the non-root adapter and matching example images. Root-owned `verify-example`, `verify`, and `verify-hosted` decide the badges.

## Conformance and protocol notes

The test-only NDJSON v1 adapter supports stdin/stdout and `ADAPTER_LISTEN` TCP. The TypeScript client implements HTTP request formatting, Convex error decoding, the query-set protocol, transitions, reconnect/resubscribe, and a bounded queue. `ws` is used only as the normal WebSocket transport.

## Limitations

Live auth, WebSocket writes, optimistic updates, journals, TransitionChunk assembly, and tagged Convex value encodings are deferred. A slow subscriber retains the newest 16 updates, discarding older state snapshots.
