<img src="logo.png" alt="CoffeeScript logo" width="420">
<!-- Logo source: https://raw.githubusercontent.com/jashkenas/coffeescript/main/documentation/site/logo.svg -->

# CoffeeScript

[CoffeeScript](https://coffeescript.org/) is a small language that compiles to
JavaScript. First released in 2009, it brought Ruby-flavoured concise syntax,
significant whitespace, classes, and comprehensions to browser and Node.js
development. Projects including Atom, Hubot, and Trix helped make it familiar
in the 2010s. It is a niche choice today, but CoffeeScript 2 still targets the
modern JavaScript ecosystem and supports features such as `async`/`await`.

This is an educational, unofficial demonstration for the 100-language project.
It is not a production SDK or a package intended for publication.

## Getting Started

Read the [canonical basic example](examples/basics/main.coffee), then run it
from the repository root:

```sh
./run verify-example coffeescript
```

Docker compiles the exact CoffeeScript example and runs its final minimal image
against a fresh counter room. It checks a one-off query, an initial Live value,
one idempotent mutation, and the resulting Live update from `0` to `1`.

## Interesting Parts

### Indentation builds the same argument object

React's `useQuery` is reactive and stays subscribed while the component needs
the result. This CoffeeScript client's `query` method is a one-off HTTP read.
The interesting language difference here is smaller: indentation replaces the
braces and commas around the argument object, and parentheses around the call
are optional.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const [room] = useState(() => `readme-react-query-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, {
    room,
  });
  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**CoffeeScript**

```coffeescript
{ randomUUID } = require 'node:crypto'
{ Client } = require './client/convex'

# The deployment URL selects the same Convex backend that React is configured for.
deploymentUrl = process.env.CONVEX_URL
throw new Error 'CONVEX_URL is required' unless deploymentUrl
client = new Client deploymentUrl
try
  args =
    room: "readme-coffeescript-query-#{randomUUID()}"

  # No braces, commas, or call parentheses are needed here.
  result = await client.query 'demo:state', args
  console.log result.value.count # Decoded at runtime, not type-checked like api.demo.state.
finally
  await client.close()
```

The function name is a string and the returned value is decoded at runtime in
this client. CoffeeScript does not gain the generated argument and result types
that the TypeScript import provides.

### The command-line client owns the Live lifecycle

React starts and stops the `useQuery` subscription as the component mounts,
changes arguments, and unmounts. This client deliberately exposes a pull-style
`next` operation instead. That is this educational API's design, not
a limit of CoffeeScript, which supports callbacks, promises, and
`async`/`await`.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const [room] = useState(() => `readme-react-live-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  if (state === undefined) return <p>Loading...</p>;
  return (
    <button
      onClick={async () => {
        const result = await increment({
          room,
          language: "TypeScript",
          runId: crypto.randomUUID(),
        });
        console.log(result.state.count); // The mutation result is type-safe here.
      }}
    >
      Count: {state.count}
    </button>
  );
}
```

**CoffeeScript**

```coffeescript
{ randomUUID } = require 'node:crypto'
{ Client } = require './client/convex'

deploymentUrl = process.env.CONVEX_URL
throw new Error 'CONVEX_URL is required' unless deploymentUrl
client = new Client deploymentUrl
room = "readme-coffeescript-live-#{randomUUID()}" # Fresh state for this run.
subscription = await client.subscribe 'demo:state', { room }
try
  initial = await subscription.next 10_000 # Wait explicitly for the initial value.
  console.log initial.value.value.count # A dynamic runtime value, not a generated type.

  result = await client.mutation 'demo:increment',
    room: room
    language: 'CoffeeScript'
    runId: randomUUID() # Makes this mutation attempt idempotent.
  console.log result.value.state.count # The mutation's returned state.

  updated = await subscription.next 10_000 # Wait for the reactive update.
  console.log updated.value.value.count
finally
  await subscription.close() # The CLI owns cleanup that React normally manages.
  await client.close()
```

CoffeeScript infers that surrounding code is asynchronous as soon as it uses
`await`, so there is no separate `async` keyword. The complete example adds
deadline, error, and value checks around each focused step.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| HTTP bearer-token replacement | Verified by shared local and hosted conformance |
| Initial and updated Live query values | Verified by shared local and hosted conformance |
| Adapter-only Live reconnect hook | Verified by shared local and hosted conformance |
| Capability badges | HTTP and Live earned from root-owned local and hosted evidence |
| Live authentication and WebSocket writes | Deferred |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.coffee -->
```coffeescript
#!/usr/local/bin/node
{ randomUUID } = require 'node:crypto'
{ Client } = require '../../client/convex'

deploymentUrl = process.env.CONVEX_URL
throw new Error 'CONVEX_URL is required' unless deploymentUrl
room = process.argv[2] ? process.env.EXAMPLE_ROOM ? 'coffeescript-example'

# Convex JSON may spell an integer as 0.0, but strings, fractions, and unsafe
# numbers must not silently become valid counter values.
assertCount = (operation, actual, expected) ->
  unless typeof actual is 'number' and Number.isSafeInteger(actual) and actual is expected
    throw new Error "#{operation} count was #{JSON.stringify actual}, expected #{expected}"

# Bound a single wait and let the subscription report structured Live failures.
nextUpdate = (subscription, name) ->
  item = await subscription.next 10_000
  throw new Error "#{name} subscription closed" if item.done
  throw item.value.error if item.value.error?
  item.value

# Create a client for the verifier-selected Convex deployment.
client = new Client deploymentUrl
try
  # Read the shared counter once through Convex's HTTP query endpoint.
  current = await client.query 'demo:state', { room }
  assertCount 'current query', current.value.count, 0
  console.log "current count: #{current.value.count}"

  # Start Live before writing, so this proves the counter's initial state.
  subscription = await client.subscribe 'demo:state', { room }
  try
    initial = await nextUpdate subscription, 'initial Live value'
    assertCount 'initial Live value', initial.value.count, current.value.count
    console.log "live initial count: #{initial.value.count}"

    # This idempotency key means a retry cannot increment the room twice.
    mutation = await client.mutation 'demo:increment',
      room: room
      language: 'CoffeeScript'
      runId: randomUUID()
    throw new Error 'mutation was not applied' unless mutation.value.applied is true
    console.log 'mutation applied: true'
    assertCount 'mutation', mutation.value.state.count, 1
    console.log "mutation count: #{mutation.value.state.count}"

    # The next reactive value must be the mutation, without another HTTP read.
    updated = await nextUpdate subscription, 'updated Live value'
    assertCount 'updated Live value', updated.value.count, 1
    console.log "live updated count: #{updated.value.count}"
    console.log 'verified count: 0 -> 1'
  finally
    # Always remove the Live query when any operation fails.
    await subscription.close()
finally
  # Close the WebSocket owner before the example exits.
  await client.close()
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

CoffeeScript 2.7.0 compiles these `.coffee` files to modern JavaScript during
the Docker build. The compiler stays in the build stage. The final images run
the generated JavaScript on Node 22.16.0, which is why the manifest honestly
labels this implementation `transpiled` rather than native.

Node supplies HTTP, TLS, JSON, promises, and cryptographic UUIDs. The `ws`
package supplies WebSocket framing only. The CoffeeScript in
[`client/convex.coffee`](client/convex.coffee) still owns the Convex request
shapes, Live query bookkeeping, reconnect policy, duplicate rehydration
suppression, and bounded update delivery.

The public client returns promises for HTTP operations and subscriptions. Its
Live API uses `subscription.next()` to make sequencing obvious in a terminal
example. One promise chain owns all WebSocket lifecycle changes so callbacks
cannot race a reconnect or query-set update. The test-only adapter adds strict
serialization and bounded input and output for the shared conformance harness;
it is not another public client API.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   journal replay, tagged Convex values, and `TransitionChunk` assembly are not
   implemented.
2. Live values are limited to the JSON-safe subset used by the pinned sync
   profile.
3. A slow consumer keeps only the newest 16 subscription updates within an
   8 MiB encoded-data budget, so older intermediate states can be discarded.
