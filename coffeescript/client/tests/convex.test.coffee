# Deterministic hostile HTTP fixtures exercise bounded streaming and the exact
# structured-error path without relying on a deployment or host network.
test = require 'node:test'
assert = require 'node:assert/strict'
net = require 'node:net'
{ Client, ConvexError, readBody, compareTimestamp } = require '../convex'

readerFor = (chunks) ->
  index = 0
  getReader: ->
    read: ->
      return Promise.resolve done: true if index is chunks.length
      value = chunks[index++]
      Promise.resolve value: Buffer.from(value), done: false

test 'hostile HTTP response stops at the byte budget', ->
  response = body: readerFor [Buffer.alloc(2 * 1024 * 1024 + 1)]
  await assert.rejects readBody(response), (error) ->
    error instanceof ConvexError and error.name is 'TransportError'

test 'HTTP function errors retain Convex data and logs', ->
  originalFetch = global.fetch
  global.fetch = ->
    status: 400
    body: readerFor [JSON.stringify(
      status: 'error'
      errorMessage: 'broken'
      errorData: { code: 'BROKEN' }
      logLines: ['fixture']
    )]
  client = new Client 'https://fixture.invalid'
  await assert.rejects client.query('demo:state', room: 'fixture'), (error) ->
    error.name is 'FunctionError' and error.data.code is 'BROKEN' and error.logs[0] is 'fixture'
  global.fetch = originalFetch

test 'hostile TLS peer is a bounded TransportError, never a JSON response', ->
  # This is intentionally not TLS: fetch starts a real TLS handshake and must
  # reject the malformed peer before the HTTP decoder sees the bytes.
  sockets = []
  server = net.createServer (socket) ->
    sockets.push socket
    socket.end 'not a TLS record\n'
  await new Promise (resolve) -> server.listen 0, '127.0.0.1', resolve
  port = server.address().port
  client = new Client "https://127.0.0.1:#{port}"
  await assert.rejects client.query('demo:state', room: 'tls-fixture'), (error) ->
    error.name is 'TransportError'
  # socket.end() only half-closes the write side. If the client aborts the
  # TLS handshake without ever sending its own FIN, the connection lingers
  # half-open and server.close() below would wait for it forever.
  peer.destroy() for peer in sockets
  await new Promise (resolve) -> server.close resolve

test 'little-endian sync timestamps compare numerically', ->
  timestamp = (number) ->
    bytes = Buffer.alloc 8
    bytes.writeBigUInt64LE BigInt(number)
    bytes.toString 'base64'
  assert.equal compareTimestamp(timestamp(255), timestamp(256)), -1
  assert.equal compareTimestamp(timestamp(256), timestamp(255)), 1
