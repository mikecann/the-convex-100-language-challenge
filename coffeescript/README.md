# Convex from CoffeeScript

This folder shows a compact CoffeeScript program talking directly to Convex. It
uses HTTP for functions, then follows a query over the pinned WebSocket sync
profile.

This is an educational, unofficial demonstration for the 100-language project.
It is not a production SDK or a package intended for publication.

## Start here

Read the [basic example](examples/basics/main.coffee). It queries a unique
counter room, starts Live before writing, applies one idempotent mutation, and
checks the whole `0 -> 1` journey. The CoffeeScript implementation is under
[client](client/); Docker compiles it to JavaScript only while building.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Implemented, pending shared evidence |
| HTTP bearer-token replacement | Implemented, pending shared evidence |
| Initial and updated Live query values | Implemented, pending shared evidence |
| Adapter-only Live reconnect hook | Implemented, pending shared evidence |
| Capability badges | Not claimed until root-owned evidence |
| Live authentication and WebSocket writes | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.coffee -->
```text
#!/usr/local/bin/node
{ randomUUID } = require 'node:crypto'
{ Client } = require '../../client/convex'

deploymentUrl = process.env.CONVEX_URL
throw new Error 'CONVEX_URL is required' unless deploymentUrl
room = process.argv[2] ? process.env.EXAMPLE_ROOM ? 'coffeescript-example'

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

# Convex JSON may spell an integer as 0.0, but strings, fractions, and unsafe
# numbers must not silently become valid counter values.
assertCount = (operation, actual, expected) ->
  unless typeof actual is 'number' and Number.isSafeInteger actual and actual is expected
    throw new Error "#{operation} count was #{JSON.stringify actual}, expected #{expected}"

# Bound a single wait and let the subscription report structured Live failures.
nextUpdate = (subscription, name) ->
  item = await subscription.next 10_000
  throw new Error "#{name} subscription closed" if item.done
  throw item.value.error if item.value.error?
  item.value
```
<!-- END GENERATED EXAMPLE -->

## Docker-only verification

```sh
./run test coffeescript
./run build coffeescript
```

`test` compiles and checks the CoffeeScript client, adapter, deterministic
transport fixtures, and the exact canonical example inside a pinned
`linux/amd64` image. `build` produces non-root `runtime` and `example-runtime`
images. Root-owned `verify-example`, `verify`, and `verify-hosted` are the only
commands that can award HTTP or Live badges.

## Conformance and protocol notes

The test-only adapter accepts strict NDJSON v1 over stdin/stdout or the
single-controller `ADAPTER_LISTEN` TCP endpoint. It serializes commands and
all output, caps input at 32 lines or 4 MiB, caps output at 3 MiB, and closes a
stalled controller after a 500 ms write deadline. It uses an adapter-only
`debugDisconnect` command to retire a connection before acknowledging it.

CoffeeScript compiles to JavaScript in the build stage, so this implementation
is accurately marked `transpiled`. Node is the declared target runtime in the
minimal images. `ws` is used solely for TLS WebSocket framing, while this
CoffeeScript source owns the Convex HTTP envelopes, query-set versions,
rehydration suppression, reconnect backoff, timestamp tracking, and delivery
queues.

## Limitations

Live authentication, optimistic updates, WebSocket mutations/actions, journal
replay, tagged Convex values, and `TransitionChunk` assembly are deferred. A
subscription keeps only its newest 16 updates and 8 MiB of queued encoded data,
discarding old intermediate query states for a slow consumer. Capability badges
remain empty until the exact source is exercised by shared local and hosted
conformance.
