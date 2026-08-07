# Convex from JavaScript

This folder shows a small JavaScript program talking directly to Convex. It
calls queries, mutations, and actions over HTTP, then follows a query over a
WebSocket.

This is an educational, unofficial demonstration for the 100-language project.
It is not a production SDK or a package intended for publication.

## Start here

Read the [basic example](examples/basics/main.js). It queries a counter room,
starts Live, applies one idempotent mutation, and checks that Live observes the
same `0 -> 1` change. The native implementation is in [client](client/).

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| HTTP bearer token | Verified by shared local and hosted conformance |
| Initial and updated Live values | Verified by shared local and hosted conformance |
| Live reconnection test hook | Verified by shared local and hosted conformance |
| Capability badges | Not claimed until root evidence |
| Live authentication and WebSocket writes | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.js -->
```javascript
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
```
<!-- END GENERATED EXAMPLE -->

## Docker-only verification

```sh
./run test javascript
./run build javascript
```

`test` parses the client, adapter, and exact canonical example, then runs its
local tests inside a pinned linux/amd64 Node image. `build` produces the
non-root conformance image and the matching example-runtime target. Root-owned
`verify-example`, `verify`, and `verify-hosted` are the only commands that can
award HTTP or Live capability badges.

## Conformance and protocol notes

The test-only adapter at `client/tests/conformance/adapter.js` accepts NDJSON
protocol v1 over stdin/stdout or `ADAPTER_LISTEN` TCP. Its `debugDisconnect`
command is deliberately adapter-only, so the shared controller can exercise
real reconnects without any Docker or host-network privilege.

HTTP uses the documented JSON `/api/query`, `/api/mutation`, and `/api/action`
endpoints. Live uses `ws` solely for WebSocket transport; JavaScript implements
the Convex query-set, transition, and reconnect behaviour itself against the
experimental `convex-rs-0.10.4-unversioned-sync` `/api/sync` profile.

## Limitations

Live authentication, WebSocket mutations/actions, optimistic updates, journal
replay, TransitionChunk assembly, and tagged Convex value encodings are
deferred. Each subscription keeps at most 16 pending updates and discards the
oldest value for a slow consumer, because reactive queries represent current
state rather than an event log.
