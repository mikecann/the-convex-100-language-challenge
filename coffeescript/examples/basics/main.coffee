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
