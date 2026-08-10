<img src="logo.png" alt="TypeScript logo" width="120">
<!-- Logo source: https://www.typescriptlang.org/branding/ts-logo-512.png -->

# TypeScript

[TypeScript](https://www.typescriptlang.org/) is Microsoft's typed superset of JavaScript. First unveiled in October 2012, it adds a static type checker while preserving JavaScript's runtime behaviour, then erases those types when it emits JavaScript. That relationship lets developers use the same language across browser interfaces and Node.js services, with earlier feedback from editors and build tools as applications grow.

TypeScript is now a common choice for application-scale JavaScript, including React front ends and server code. This directory takes it somewhere deliberately lower-level: a small native TypeScript client implements Convex HTTP calls and Live subscriptions without importing the official JavaScript Convex client. It is an educational, unofficial demonstration, not a production SDK or publishable package.

## Getting Started

Read the [canonical basic example](examples/basics/main.ts) for the complete `0 -> 1` counter journey, then run it from the repository root:

```sh
./run verify-example typescript
```

The command builds and runs the exact example in Docker against a unique test room. It checks the initial HTTP query, the first Live value, an idempotent mutation, and the resulting Live update.

## Interesting Parts

### Type information stops at this client's JSON boundary

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function CounterSnapshot() {
  const room = "typescript-readme";
  const state = useQuery(api.demo.state, { room });

  if (!state) return <span>Loading...</span>;
  return <span>{state.count}</span>; // Generated types know count is a number.
}
```

**TypeScript**

```typescript
import { Client } from "./client/convex.js";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");
const room = "typescript-readme";
const client = new Client(deploymentUrl);

try {
  const response = await client.query("demo:state", { room });
  // This educational client returns unknown, so we describe the JSON shape here.
  const state = response.value as { count: number };
  console.log(state.count);
} finally {
  await client.close();
}
```

The official Convex React workflow generates types from the backend, including the function reference, arguments, and returned value. This client's HTTP query is a one-off request, not the reactive equivalent of `useQuery`. It intentionally accepts a string path and returns `unknown`, so the cast helps the compiler but does not validate the server response at runtime. The [complete example](examples/basics/main.ts) adds explicit value checks after decoding.

### The command-line program owns its Live subscription

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function Counter() {
  const room = "typescript-readme";
  const state = useQuery(api.demo.state, { room });

  // React and the Convex hook own subscription setup, updates, and cleanup.
  return <span>{state?.count ?? "Loading..."}</span>;
}
```

**TypeScript**

```typescript
import { Client } from "./client/convex.js";

const deploymentUrl = process.env.CONVEX_URL;
if (!deploymentUrl) throw new Error("CONVEX_URL is required");
const room = "typescript-readme";
const client = new Client(deploymentUrl);
const subscription = client.subscribe("demo:state", { room });

try {
  // next() waits for the initial state, then waits again for each later update.
  const initial = await subscription.next();
  if (!initial.done && !initial.value.error) {
    const state = initial.value.value as { count: number };
    console.log(state.count);
  }
} finally {
  // A command-line program has no React unmount, so cleanup is explicit.
  await subscription.close();
  await client.close();
}
```

`Subscription` is an `AsyncIterable`, but this client exposes `next()` directly because the verifier needs precise control over the initial and updated values. That is a client API choice, not a TypeScript limitation. In React, `useQuery` manages the reactive lifecycle and causes the component to render again when the value changes.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| HTTP bearer token lifecycle | Verified by shared local and hosted conformance |
| Initial and updated Live values | Verified by shared local and hosted conformance |
| Reconnect and adapter-only disconnect hook | Verified by shared local and hosted conformance |
| Capability badges | HTTP and Live earned from root-owned local and hosted evidence |

## Example

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

## Implementation Notes

The client is native TypeScript rather than a wrapper around another Convex client. Node.js supplies `fetch`, URL handling, JSON, cryptographic UUIDs, and the runtime itself. The pinned `ws` package supplies ordinary WebSocket transport. The TypeScript code owns the Convex-specific HTTP request shapes, error decoding, Live query-set messages, transition handling, reconnects, resubscription, and delivery queue.

HTTP queries, mutations, and actions all return a small `{ value, logs }` result. Function failures become `ConvexError` values with structured data and logs preserved. HTTP bearer tokens can be replaced with `setAuth`, while the current Live connection is deliberately unauthenticated.

Live subscriptions are async iterables backed by a newest-value queue. The queue holds at most 16 pending updates per subscription and drops the oldest snapshot when a consumer falls behind. A test-only adapter translates calls and subscription updates into the repository's shared line-oriented protocol; it is not part of the educational client API. The code targets ES2022, compiles with TypeScript 5.8.3, and runs on the pinned Node.js 22.16.0 image as an unprivileged user.

## Known Issues

1. Live authentication, mutations and actions over the WebSocket, optimistic updates, and journals are not implemented. Mutations and actions use the verified HTTP path instead.
2. `TransitionChunk` messages and non-JSON tagged Convex values are treated as protocol drift rather than decoded.
3. A slow Live consumer sees only the newest 16 queued updates. Older pending state snapshots are discarded by design.
