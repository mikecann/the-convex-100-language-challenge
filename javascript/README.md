# JavaScript

JavaScript is the dynamic, prototype-based language created by Brendan Eich at
Netscape in 1995 and later standardised as ECMAScript. It began in web browsers,
where it remains the language built into the platform, and now also runs
server-side, on desktops, and in embedded systems. It borrows familiar syntax
from C and Java but has a very different object and type system. [MDN's
JavaScript reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript)
is the practical language home, while [ECMA-262](https://tc39.es/ecma262/)
defines the standard.

This folder uses Node.js to show JavaScript talking directly to Convex. It is an
educational, unofficial demonstration, not a production SDK or a package meant
for publication.

## Getting Started

Start with the [canonical basic example](examples/basics/main.js). It reads a
counter, subscribes before writing, applies one idempotent increment, and sees
the reactive value move from `0` to `1`.

From the repository root, run the exact example in its Docker image against the
approved test deployment:

```sh
./run verify-example javascript
```

## Interesting Parts

### JSON never leaves home

JSON was not adopted by JavaScript — it was carved *out of* it, when Douglas
Crockford froze the language's object-literal notation into a wire format. So
Convex arguments here are never built or marshalled; they are simply written.
And because Node runs ES modules with top-level `await`, the call needs no
`main()` wrapper either — this really is the whole program.

```javascript
const client = new Client(deploymentUrl);

// Top-level await: module scope, no main() in sight.
const current = await client.query("demo:state", { room });
// TypeScript: useQuery(api.demo.state, { room }) — generated refs instead of a string path.
console.log(current.value.count);
```

The literal `{ room }` is shorthand for `{ room: room }` — the source code and
the JSON on the wire are the same notation.

### A Live query is a `for await` loop

The subscription that `client.subscribe` returns implements
`[Symbol.asyncIterator]`, one of the language's protocol hooks. That single
method makes a reactive Convex query consumable by `for await ... of` (ES2018):
when `client.mutation("demo:increment", ...)` commits, the server reruns the
query, pushes the new value down the WebSocket, and the loop takes another turn.

```javascript
const subscription = client.subscribe("demo:state", { room });
for await (const update of subscription) {
  if (update.error) throw update.error;
  console.log(update.value.count); // TypeScript: React rerenders; here the loop body reruns.
  if (update.value.count >= 1) break; // Saw the increment land.
}
await subscription.close(); // break skips iterator cleanup, so close explicitly.
```

Realtime updates arrive through the same loop syntax you would use to read
lines from a file.

### `#call` is private because the language says so

For most of its life JavaScript faked privacy with `_underscore` naming
conventions. ES2022 finally gave classes `#`-prefixed members with hard,
syntax-level privacy — writing `client.#call(...)` outside the class is a
`SyntaxError`, not a lint warning. This client uses it to keep three thin
public verbs over one private HTTP engine.

```javascript
export class Client {
  query(path, args = {}) { return this.#call("query", path, args); }
  mutation(path, args = {}) { return this.#call("mutation", path, args); }
  action(path, args = {}) { return this.#call("action", path, args); }

  async #call(operation, path, args) {
    // ...one fetch to `${this.deploymentUrl}/api/${operation}`
  }
}
```

### Two operators keep the WebSocket lazy

Nothing Live exists until the first subscribe. Nullish assignment `??=`
(ES2021) creates the connection manager only if it is still `null`, and
optional chaining `?.` lets `close()` shrug when no subscription ever ran.

```javascript
subscribe(path, args = {}) {
  this.live ??= new LiveManager(this.deploymentUrl, this.clientVersion);
  return this.live.subscribe(path, args);
}

async close() {
  this.closed = true;
  await this.live?.close(); // Never subscribed? Then there is no socket to close.
}
```

A purely HTTP session never pays for a WebSocket — two operators carry the
whole lazy lifecycle.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| HTTP bearer token | Verified by shared local and hosted conformance |
| Initial and updated Live values | Verified by shared local and hosted conformance |
| Live reconnection test hook | Verified by shared local and hosted conformance |
| Capability badges | HTTP and Live earned from root-owned local and hosted evidence |
| Live authentication and WebSocket writes | Deferred |

## Example

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

## Implementation Notes

This is a native JavaScript implementation running on Node.js 22.16.0. Built-in
`fetch` handles HTTP and the `ws` package provides WebSocket transport, but no
existing Convex JavaScript client is delegated the work. The code in
[`client/convex.js`](client/convex.js) constructs HTTP requests, interprets
Convex success and error envelopes, and implements the Live query-set and
reconnect behaviour itself.

HTTP queries, mutations, and actions are one-shot promises. Live subscriptions
are async iterators backed by a newest-value queue capped at 16 pending updates.
If a consumer falls behind, the oldest queued state is discarded because a
reactive query represents current state rather than a durable event log.

The test-only [conformance adapter](client/tests/conformance/adapter.js) exposes
the shared controller protocol over stdin/stdout or TCP. Its `debugDisconnect`
operation exists only so conformance tests can force a real reconnect. It is not
part of the educational client API.

## Known Issues

1. Live authentication is not implemented, even though bearer tokens work for
   HTTP calls.
2. Mutations and actions use HTTP only. WebSocket writes, optimistic updates,
   and journal replay are deferred.
3. Live follows the experimental
   `convex-rs-0.10.4-unversioned-sync` profile. Transition chunks and tagged
   non-JSON Convex values are treated as protocol drift rather than decoded.
