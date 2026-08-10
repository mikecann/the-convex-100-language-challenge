<img src="logo.png" alt="Pike logo" width="204">
<!-- Logo source: https://pike.lysator.liu.se/assets/img/pike-logo.svg -->

# Pike

[Pike](https://pike.lysator.liu.se/) is a dynamic, general-purpose language
with C- and Java-like syntax, automatic memory management, and strong built-in
collection types. Fredrik Hübinette began its predecessor, µLPC, in 1994; it
was renamed Pike in 1996 and later moved to Linköping University. Its roots are
in multiplayer games and the Roxen web server, while its broader uses include
network services, multimedia, text processing, and systems administration.
Pike remains actively developed in 2026, but it is a niche choice compared with
JavaScript, Java, or C#. The official site has the fuller
[history](https://pike.lysator.liu.se/about/history/) and current releases.

This repository contains an educational, unofficial Convex client. It is not a
production SDK, is not supported by Convex, and is not published as a package.

## Getting Started

Start with the canonical
[counter example](examples/basics/main.pike). It reads a fresh room, opens a
Live subscription, increments the counter, and checks the reactive `0 -> 1`
update. From the repository root, run it in its pinned Docker environment:

```sh
./run verify-example pike
```

That command builds the minimal example image, gives it a unique room, and
compares its output with the shared expected transcript. It does not install
Pike or any build dependency on your host.

## Interesting Parts

### Named arguments are mappings, but returned data needs runtime checks

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function RoomCount() {
  const room = "readme-pike-room";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // The generated API makes state.count type-safe.
}
```

**Pike**

```pike
string deployment_url = getenv("CONVEX_URL");
if (!deployment_url || !sizeof(deployment_url))
  error("CONVEX_URL is required\n");

// Compile this educational client, then connect to the checked deployment.
object convex = compile_file("client/convex.pike")();
object client = convex->Client(deployment_url);
string room = "readme-pike-room";

// ([ ... ]) is Pike's mapping literal, much like a JavaScript object.
object result = client->query("demo:state", ([ "room": room ]));
mapping state = convex->require_object(result->value, "demo:state result");

// Mapping lookup returns 0 for both a missing key and a real zero value.
if (zero_type(state->count))
  error("demo:state omitted count\n");
int count = convex->require_whole_number(state->count, "state count");
write("%d\n", count);
client->close(); // This command-line program owns its client lifecycle.
```

Both calls send `{ room: "readme-pike-room" }` to `api.demo.state`, but the
semantics differ. React's `useQuery` owns a reactive subscription and rerenders
the component. Pike's `query` is one HTTP snapshot, and the native client
returns dynamically decoded JSON, so the example checks the object shape and
number explicitly. Pike's `->` member syntax works for both objects and mapping
keys, which is convenient until zero is a valid answer.

### A command-line program owns the Live subscription itself

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function IncrementButton() {
  const room = "readme-pike-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function onIncrement() {
    const result = await increment({
      room,
      language: "TypeScript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The mutation returns the updated state.
  }

  return <button onClick={onIncrement}>Count: {state?.count ?? 0}</button>;
}
```

**Pike**

```pike
string deployment_url = getenv("CONVEX_URL");
if (!deployment_url || !sizeof(deployment_url))
  error("CONVEX_URL is required\n");

// Compile this educational client, then connect to the checked deployment.
object convex = compile_file("client/convex.pike")();
object client = convex->Client(deployment_url);
string room = "readme-pike-live";

// Subscribe before mutating so this handle can observe the pushed update.
object updates = client->subscribe("demo:state", ([ "room": room ]));
object initial = updates->next_update(20000); // Wait for initial hydration.
if (initial->failure)
  error("initial Live query failed: %s\n", initial->failure->describe());
write("initial count: %d\n",
      convex->require_whole_number(initial->value->count, "initial count"));

// Reuse this stable id for retries of this one logical mutation call.
string run_id = sprintf("pike-%s-%d-%d", room, time(), random(1000000000));
object result = client->mutation("demo:increment", ([
  "room": room,
  "language": "Pike",
  "runId": run_id,
]));
mapping outcome = convex->require_object(result->value, "mutation result");
write("mutation count: %d\n",
      convex->require_whole_number(outcome->state->count, "mutation count"));

object changed = updates->next_update(20000); // The existing Live query moved.
write("live count: %d\n",
      convex->require_whole_number(changed->value->count, "live count"));
updates->close();
client->close(); // Explicit cleanup replaces React's automatic unmount cleanup.
```

React owns setup, cleanup, and rerendering around `useQuery`. This Pike program
owns an explicit subscription and closes it itself. The blocking `next_update`
call is a deliberate API choice for a linear command-line example, not a Pike
limitation. The same client also supports callbacks, which the conformance
adapter uses when it needs pushed events instead of a blocking read.

## Status

The reviewed implementation earned both repository capability badges after
passing 31 of 31 shared checks on both the local and hosted profiles.

| Area | Repository state |
| --- | --- |
| HTTP queries, mutations, actions, and bearer tokens | Verified locally and hosted |
| Live subscriptions, reconnect, replay, and recovery | Verified locally and hosted |
| Implementation provenance | Native Pike |
| Supported platform | `linux/amd64` |
| Earned capabilities | HTTP and Live |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pike -->
```pike
#!/usr/local/bin/pike

// Convex from Pike: read a shared counter over HTTP, watch the same query over
// Live, increment it once, and prove the 0 -> 1 journey.
//
// This is the canonical example. The README and the website show this exact
// file, and the Docker verifier runs this exact file against a fresh room.

// The client is compiled from source at startup rather than linked in, so the
// example, the tests, and the conformance adapter all run the same code
// wherever it happens to be installed.
string client_source()
{
  array(string) locations = ({
    getenv("CONVEX_CLIENT_PATH"),
    "/opt/convex/client",
    combine_path(dirname(__FILE__), "..", "..", "client"),
  });
  foreach (locations, string directory) {
    if (!directory || !sizeof(directory))
      continue;
    string candidate = combine_path(directory, "convex.pike");
    if (Stdio.is_file(candidate))
      return candidate;
  }
  error("could not find the Pike Convex client source\n");
  return 0;
}

// Convex sends JSON numbers, and a whole number may legitimately arrive as 0.0.
// The client's decoder accepts a mathematically integral value and rejects
// fractions, quoted numbers, and anything out of range, so the example never
// has to guess what a count meant.
int room_count(object convex, mixed state, string what)
{
  mapping room_state = convex->require_object(state, what);
  // Pike's `->` on a mapping returns 0 for a missing key, which is also a
  // legitimate count, so absence has to be checked before extraction can
  // treat a bare 0 as meaningful.
  if (zero_type(room_state->count))
    throw(convex->protocol_error(what + " state is missing its count field"));
  return convex->require_whole_number(room_state->count, what + " count");
}

// A Live update carries either a value or a classified failure, never both.
// Raising on the failure keeps the printed transcript honest: nothing is
// reported as verified unless every operation really agreed.
int live_count(object convex, object update, string what)
{
  if (update->failure)
    error("%s failed: %s\n", what, update->failure->describe());
  return room_count(convex, update->value, what);
}

int demonstrate(object convex, object client, string room)
{
  // Read the room's current state through Convex's documented JSON HTTP query
  // endpoint. A fresh room reports zero without needing to be created first.
  object current = client->query("demo:state", ([ "room": room ]));
  int before = room_count(convex, current->value, "current query");
  if (before != 0)
    error("the room started at %d instead of 0\n", before);
  write("current count: %d\n", before);

  // Subscribe before writing anything. Starting Live first is what makes the
  // increment below observable: a subscription opened afterwards could not
  // prove that the update was pushed rather than polled.
  object updates = client->subscribe("demo:state", ([ "room": room ]));

  // Convex hydrates a new Live query with its current value. That first value
  // has to agree with the HTTP read before the example changes anything.
  object initial = updates->next_update(20000);
  int live_before = live_count(convex, initial, "initial Live value");
  if (live_before != before)
    error("Live started at %d but HTTP reported %d\n", live_before, before);
  write("live initial count: %d\n", live_before);

  // runId is the mutation's idempotency key. Convex records it, so retrying
  // this logical request would return the same write instead of incrementing
  // the room a second time.
  string run_id = sprintf("pike-%s-%d-%d", room, time(), random(1000000000));
  object applied = client->mutation("demo:increment", ([
    "room": room,
    "language": "Pike",
    "runId": run_id,
  ]));
  mapping outcome = convex->require_object(applied->value, "mutation result");
  if (!convex->json_is_true(outcome->applied))
    error("Convex reported that the increment was not applied\n");
  write("mutation applied: true\n");
  int after = room_count(convex, outcome->state, "mutation");
  if (after != before + 1)
    error("the increment moved the count to %d instead of %d\n", after,
          before + 1);
  write("mutation count: %d\n", after);

  // The reactive update now arrives on the subscription opened earlier, with
  // no second HTTP query. This is the whole point of Live.
  object changed = updates->next_update(20000);
  int live_after = live_count(convex, changed, "updated Live value");
  if (live_after != after)
    error("Live reported %d but the mutation returned %d\n", live_after, after);
  write("live updated count: %d\n", live_after);

  // Only now, with HTTP and Live agreeing on the whole journey, is the run
  // verified.
  write("verified count: %d -> %d\n", before, after);

  // Stop this query before the shared client is torn down.
  updates->close();
  return 0;
}

int main(int argc, array(string) argv)
{
  string deployment_url = getenv("CONVEX_URL");
  if (!deployment_url || !sizeof(deployment_url)) {
    werror("CONVEX_URL is required\n");
    return 2;
  }

  // The verifier passes a unique room so independent runs never collide. The
  // default only exists for someone running this image by hand.
  string room = argc > 1 ? argv[1] : (getenv("EXAMPLE_ROOM") || "pike-example");

  object convex = compile_file(client_source())();
  object client = convex->Client(deployment_url);

  // Diagnostics belong on stderr: stdout is the transcript the verifier
  // compares line for line.
  int status = 1;
  mixed failed = catch { status = demonstrate(convex, client, room); };
  client->close();
  if (failed) {
    werror("pike example failed: %s\n",
           convex->as_convex_error(failed)->describe());
    return 1;
  }
  return status;
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public client is assembled from seven Pike files under
[`client/`](client/). `compile_file("client/convex.pike")()` compiles the facade
and its textual includes into one program at runtime. Pike's standard modules
provide JSON, sockets, TLS, SHA-1, and base64, but the Convex request envelopes,
HTTP exchange, WebSocket framing, and Live state machine are implemented here.
That is why the manifest describes this as native rather than a bridge to an
existing SDK.

The HTTP API is synchronous and returns a `CallResult` containing a dynamically
decoded value, log lines, and any classified failure. Live has one owner object
for socket reads, writes, query changes, and reconnects. Subscriptions can use a
callback or a bounded relay; the canonical example uses `next_update` because
the sequence is easier to teach linearly. A relay holds at most 16 updates and
2 MiB, then fails closed instead of dropping events or growing without limit.

The client pins the `convex-rs-0.10.4-unversioned-sync` profile at source commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It validates an entire Live
transition before applying any part of it, replays active subscriptions after a
reconnect, suppresses unchanged rehydration, and gives stalled frames and close
handshakes deadlines. Pike has no canonical source formatter, so a local style
test checks line endings, tabs, trailing whitespace, line width, and source
characters instead.

For the wider evidence layers, `./run test pike` covers formatting,
language-local behavior, compilation, runtime entrypoints, and the adapter TCP
path inside Docker. `./run verify pike` adds local black-box conformance, while
`./run verify-hosted pike` repeats it against the hosted drift target. These are
different claims, and only the shared evaluator awards capabilities.

## Known Issues

1. Values are limited to Convex's JSON-safe subset. Tagged values such as
   `Int64` and bytes are not implemented.
2. Live authentication, WebSocket mutations and actions, optimistic updates,
   journals, and `TransitionChunk` assembly are deferred. The client rejects a
   `TransitionChunk` rather than applying a partial result.
3. Live relies on a pinned, undocumented sync profile, so future protocol drift
   is treated as an error. The pinned Debian package revisions can also leave
   the archive, in which case the Docker build fails instead of silently taking
   newer dependencies.
4. TLS compatibility depends on Pike 8.0's `SSL.Context` trust-store naming and
   `SSL.File` writable-callback behavior. The runtime checks the available API
   and loaded authorities, but the loopback socket tests do not provide a real
   TLS handshake by themselves.
