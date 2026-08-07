# A local ws fixture sends a query failure followed by a valid update. It keeps
# the test deterministic while exercising actual WebSocket framing and recovery.
http = require 'node:http'
{ WebSocketServer } = require 'ws'
test = require 'node:test'
assert = require 'node:assert/strict'
{ Client } = require '../convex'

version = (querySet, timestamp) -> querySet: querySet, identity: 0, ts: timestamp
timestamp = (number) ->
  bytes = Buffer.alloc 8
  bytes.writeBigUInt64LE BigInt(number)
  bytes.toString 'base64'

test 'hostile WebSocket QueryFailed recovers on the same subscription', ->
  server = http.createServer()
  sockets = new WebSocketServer server: server
  await new Promise (resolve) -> server.listen 0, '127.0.0.1', resolve
  port = server.address().port
  sockets.on 'connection', (socket) ->
    socket.once 'message', ->
      socket.once 'message', (raw) ->
        add = JSON.parse raw.toString()
        id = add.modifications[0].queryId
        socket.send JSON.stringify
          type: 'Transition'
          startVersion: version 0, timestamp(0)
          endVersion: version 1, timestamp(1)
          modifications: [{ type: 'QueryFailed', queryId: id, errorMessage: 'empty', errorData: code: 'ROOM_EMPTY' }]
        socket.send JSON.stringify
          type: 'Transition'
          startVersion: version 1, timestamp(1)
          endVersion: version 1, timestamp(2)
          modifications: [{ type: 'QueryUpdated', queryId: id, value: count: 1 }]
  client = new Client "http://127.0.0.1:#{port}"
  subscription = await client.subscribe 'demo:requiresNonzero', room: 'fixture'
  failed = await subscription.next 2_000
  assert.equal failed.value.error.data.code, 'ROOM_EMPTY'
  recovered = await subscription.next 2_000
  assert.equal recovered.value.value.count, 1
  await subscription.close()
  await client.close()
  await new Promise (resolve) -> sockets.close -> server.close resolve
