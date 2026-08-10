# SETL

[SETL](https://setl.org/setl/) is a high-level language built around the
mathematical ideas of sets and maps. Jack Schwartz began it around 1970 for
expressing complex algorithms clearly, and it later became known as a rapid
prototyping language. GNU SETL is the Unix-oriented implementation used here.
Today it is a specialist language, but its set, tuple, and map notation makes
the data shapes in a Convex call unusually visible.

This is an educational, unofficial demonstration. It is not a production
Convex SDK or a package intended for publication.

## Getting Started

The [canonical example](examples/basics/main.setl) reads a counter, subscribes
before changing it, calls `demo:increment`, and observes the reactive update.
From the repository root, run:

```sh
./run verify-example setl
```

The command builds and runs the example in Docker against an approved test
deployment. You do not need GNU SETL installed on your machine.

## Interesting Parts

### Convex objects really are maps

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CounterRead() {
  const state = useQuery(api.demo.state, { room: "readme-setl-room" });
  if (state === undefined) {
    return <output>loading</output>;
  }
  return <output>{state.count}</output>; // state.count is a typed number.
}
```

**SETL**

```setl
deployment_url := getenv("CONVEX_URL"); -- Real configuration, not a hidden global.
if deployment_url = om or deployment_url = "" then
  printa(stderr, "CONVEX_URL is required");
  stop 1;
end if;
query_args := {};                       -- An empty set can become a map.
query_args("room") := "readme-setl-room"; -- Adds ["room", value] to that map.

response := convex_query(deployment_url, "demo:state", query_args, om, 10000); -- om means no auth token.
if response("kind") = "result" then
  state := response("value");
  print(state("count")); -- SETL checks this shape at runtime, not compile time.
end if;
```

A SETL map is a set of two-element tuples, so the object passed to
`api.demo.state` is built with ordinary map operations. The React hook owns a
subscription and rerenders when the result changes. `convex_query` is only one
HTTP read, so it deliberately does not offer that reactive lifecycle.

### A mutation is assembled from the same data primitives

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);
  async function handleClick() {
    const result = await increment({
      room: "readme-setl-room",
      language: "setl",
      runId: crypto.randomUUID(), // A fresh id makes this attempt idempotent.
    });
    console.log(result.state.count); // The generated return type is known here.
  }
  return <button onClick={handleClick}>Increment</button>;
}
```

**SETL**

```setl
deployment_url := getenv("CONVEX_URL");
if deployment_url = om or deployment_url = "" then
  printa(stderr, "CONVEX_URL is required");
  stop 1;
end if;
mutation_args := {};
mutation_args("room") := "readme-setl-room";
mutation_args("language") := "setl";
mutation_args("runId") := "readme-" + str(clock) + "-" + str(random(1000000));
-- clock plus a random suffix gives this demonstration run a fresh key.

result := convex_mutation(
    deployment_url, "demo:increment", mutation_args, om, 10000); -- om means no auth token.
if result("kind") = "result" then
  print(result("value")("state")("count")); -- Shape checks happen at runtime.
end if;
```

Both calls send the same three arguments and receive `{ applied, state }`.
SETL has no datatype declarations, so this client validates the decoded JSON
envelope and the complete example performs the stricter count checks.

### Reactive state is passed back explicitly

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const state = useQuery(api.demo.state, { room: "readme-setl-room" });
  // React starts, updates, and disposes this component's subscription.
  return <output>{state?.count ?? "loading"}</output>;
}
```

**SETL**

```setl
deployment_url := getenv("CONVEX_URL");
if deployment_url = om or deployment_url = "" then
  printa(stderr, "CONVEX_URL is required");
  stop 1;
end if;
args := {};
args("room") := "readme-setl-room";
subscription_id := "counter-" + str(clock); -- Caller-owned local identity.

live := live_open(deployment_url, "setl-0.1.0");
live := live_add(live, subscription_id, "demo:state", args);
while live("revisions")(subscription_id) = om loop
  live := live_pump(live, 100); -- Every call returns the next session map.
end loop;
print(live("results")(subscription_id)("value")("count"));
live := live_close(live, "example complete");
```

This blocking `live_pump` API is a choice made by this command-line client,
not a limitation of SETL. SETL passes maps by value, so connection and
subscription state must be returned and reassigned explicitly. The client uses
structural map equality to avoid publishing an unchanged value immediately
after reconnecting.

## Status

| Item | Status |
| --- | --- |
| Selection tier | `ranked` |
| Implementation | `working`, native GNU SETL |
| Earned capabilities | `http`, `live` |
| Canonical example | HTTP query, initial Live value, mutation, Live update |
| Verification profiles recorded by the project | Local and hosted |

These capability claims are preserved from the repository's shared evidence.
Only the shared result evaluator awards them.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.setl -->
```setl
-- Convex from SETL: the shared counter journey.
--
-- Reads a room's counter over Convex's documented HTTP API, starts a
-- Live subscription, increments the counter once, and proves that the
-- Live subscription reported the same change without polling. This is
-- an educational demonstration of a hand-written, from-scratch Convex
-- client (see ../../README.md), not an official Convex SDK.
--
-- Run it with:
--   CONVEX_URL=https://<deployment>.convex.cloud setl --cpp main.setl <room>
--
-- This file's own executable statements all come first, and every
-- helper it defines -- along with every client module it pulls in via
-- #include -- follows them: GNU SETL requires a source unit's mainline
-- statements to precede every proc definition, with no interleaving.
-- See client/json.setl's module comment for more on why this client is
-- laid out that way throughout.

-- Configuration: the deployment URL is required. The room comes from
-- the verifier's first command-line argument (so repeated runs never
-- collide), an EXAMPLE_ROOM environment variable for a convenient hand
-- run, or a literal fallback so this still does something either way.
deployment_url := getenv("CONVEX_URL");
if deployment_url = om or deployment_url = "" then
  printa(stderr, "SETL example failed: CONVEX_URL is required");
  stop 1;
end if;

room := om;
if #command_line >= 1 then
  room := command_line(1);
end if;
if room = om or room = "" then
  room := getenv("EXAMPLE_ROOM");
end if;
if room = om or room = "" then
  room := "setl-example";
end if;

query_args := {};
query_args("room") := room;

-- The HTTP query: reads the room's current counter through Convex's
-- documented POST /api/query envelope, before anything reactive is
-- involved, so the Live subscription below has a known value to agree
-- with.
response := convex_query(deployment_url, "demo:state", query_args, om, 10000);
if response("kind") /= "result" then
  printa(stderr, "SETL example failed: query: " + str(response("errMessage")));
  stop 1;
end if;
-- Decoding into an idiomatic value: Convex JSON may encode an integral
-- count as 0 or as 0.0 (see examples/basics/count.setl), and either
-- other shape is a bug this example must fail loudly on, not paper over.
[decoded, current, decode_message] := convex_state_count(response("value"), "current query");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  stop 1;
end if;
print("current count: " + str(current));

-- Client creation: opens the WebSocket handshake to /api/sync and sends
-- the Connect message (client/sync.setl). No query has been added yet.
[connected, sync] := sync_connect(deployment_url, "setl-0.1.0", 10000);
if not connected then
  printa(stderr, "SETL example failed: sync connect: " + str(sync));
  stop 1;
end if;

-- Starting Live before the mutation: subscribing first is what makes
-- the update received below an observation of a real change, rather
-- than a race against one that already happened.
[subscribed, sync, query_id] := sync_add(sync, "demo:state", query_args);
if not subscribed then
  printa(stderr, "SETL example failed: subscribe: " + str(sync("last_error")));
  sync_close(sync, "example failed");
  stop 1;
end if;

-- The initial Live value: the same state the HTTP query above already
-- read, delivered this time as the subscription's first Transition.
[outcome, sync, result] := sync_wait_next(sync, query_id, 10000);
if outcome /= "ok" or result("kind") /= "value" then
  printa(stderr, "SETL example failed: initial Live value: " + str(sync("last_error")));
  sync_close(sync, "example failed");
  stop 1;
end if;
[decoded, live_initial, decode_message] := convex_state_count(result("value"), "initial Live value");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  sync_close(sync, "example failed");
  stop 1;
end if;
if live_initial /= current then
  printa(stderr, "SETL example failed: the initial Live count disagreed with HTTP");
  sync_close(sync, "example failed");
  stop 1;
end if;
print("live initial count: " + str(live_initial));

-- The mutation and its idempotency key: runId lets Convex recognize a
-- retried request and return the previous result instead of
-- incrementing twice. A fresh random key means this run really applies
-- its increment rather than replaying an old one.
mutation_args := {};
mutation_args("room") := room;
mutation_args("language") := "setl";
mutation_args("runId") := random_hex(16);
mutation_response := convex_mutation(deployment_url, "demo:increment", mutation_args, om, 10000);
if mutation_response("kind") /= "result" then
  printa(stderr, "SETL example failed: mutation: " + str(mutation_response("errMessage")));
  sync_close(sync, "example failed");
  stop 1;
end if;
mutation_value := mutation_response("value");
if mutation_value = om or mutation_value("applied") /= true then
  printa(stderr, "SETL example failed: the mutation was not applied");
  sync_close(sync, "example failed");
  stop 1;
end if;
[decoded, mutation_count, decode_message] := convex_state_count(mutation_value("state"), "mutation");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  sync_close(sync, "example failed");
  stop 1;
end if;
expected := current + 1;
if mutation_count /= expected then
  printa(stderr, "SETL example failed: the mutation returned an unexpected count");
  sync_close(sync, "example failed");
  stop 1;
end if;
print("mutation applied: true");
print("mutation count: " + str(mutation_count));

-- The resulting Live update: received over the same subscription,
-- without polling HTTP again.
[outcome, sync, result] := sync_wait_next(sync, query_id, 10000);
if outcome /= "ok" or result("kind") /= "value" then
  printa(stderr, "SETL example failed: updated Live value: " + str(sync("last_error")));
  sync_close(sync, "example failed");
  stop 1;
end if;
[decoded, live_updated, decode_message] := convex_state_count(result("value"), "updated Live value");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  sync_close(sync, "example failed");
  stop 1;
end if;
if live_updated /= expected then
  printa(stderr, "SETL example failed: the updated Live count disagreed with the mutation");
  sync_close(sync, "example failed");
  stop 1;
end if;
print("live updated count: " + str(live_updated));

-- Every operation above agreed before this proof line is printed.
print("verified count: " + str(current) + " -> " + str(live_updated));

-- Cleanup: close the Live connection cleanly before exiting.
sync_close(sync, "example complete");

-- Generates AByteCount random bytes as lowercase hex, for the mutation's
-- idempotency key above. It does not need to be unpredictable, only
-- unique enough that this run's key has never been sent before.
proc random_hex(byte_count);
  hex_digits := "0123456789abcdef";
  out := "";
  for i in [1..byte_count] loop
    b := random(255);
    out +:= hex_digits(b div 16 + 1);
    out +:= hex_digits(b mod 16 + 1);
  end loop;
  return out;
end proc;

#include "tcp.setl"
#include "tls.setl"
#include "stream.setl"
#include "http.setl"
#include "json.setl"
#include "websocket.setl"
#include "convex.setl"
#include "sync.setl"
#include "count.setl"
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native GNU SETL 8.13.22 client. SETL code implements JSON, HTTP/1.1,
Convex query, mutation and action envelopes, WebSocket framing, and the pinned
Live protocol. It does not delegate Convex behavior to JavaScript, Node.js,
Python, `curl`, or another SDK.

JSON objects decode to SETL maps and arrays decode to tuples. GNU SETL normally
uses `om` for both null and a missing map key, so the JSON codec represents a
nested null with an atom. That keeps fields such as `lastLanguage: null` from
silently disappearing, then converts the atom back to JSON null when encoding.

Plain local connections use GNU SETL's own TCP streams. Hosted TLS crosses the
language's fixed, strings-only `callout()` boundary into the OpenSSL code in
[client/callskel.c](client/callskel.c), with binary payloads hex-encoded across
that boundary. The Live layer keeps one owner for the socket, reconnects with
bounded exponential backoff, restores active subscriptions, and suppresses the
first unchanged value replayed after a reconnect.

The canonical source must put executable statements before procedure
definitions, then include its procedure-only modules. GNU SETL's strict value
semantics also explain the repeated `live := live_pump(live, ...)` style:
mutating a procedure's map argument changes a copy unless the new map is
returned and assigned.

The Docker test and evidence layers remain distinct:

```sh
./run test setl
./run verify-example setl
./run verify setl
./run verify-hosted setl
./run verify-all setl
```

`test` builds the pinned toolchain and runs language-local checks.
`verify-example` runs the exact example above. The remaining commands add
shared local and hosted conformance checks; only those shared results can
support HTTP and Live capability badges.

## Known Issues

1. GNU SETL needs its `setltran` compiler and `setlcpp` preprocessor beside
   the interpreter even at runtime. They are not placed on `PATH`, but the
   interpreter cannot run this source without them.
2. The Live client retains only the latest value per subscription. The
   conformance adapter separately bounds outgoing work to 8 slots and 4 MiB.
3. Live authentication, mutations and actions over WebSocket, and
   `TransitionChunk` assembly are not implemented.
4. GNU SETL's TCP client opening operation exposes no separate connect timeout,
   so a stalled connect is not independently bounded inside the wider operation
   deadline.
