# Adapter output must remain bounded even when its controller has stopped
# reading. The real adapter closes the stream after its absolute write deadline.
{ PassThrough, Writable } = require 'node:stream'
test = require 'node:test'
assert = require 'node:assert/strict'
{ runAdapter, parseListenAddress, serialiseError } = require './adapter'
{ ConvexError } = require '../../convex'

test 'adapter serialises a structured error without null fields', ->
  error = new ConvexError 'FunctionError', 'fixture', data: code: 'FIXTURE'
  assert.deepEqual serialiseError(error), name: 'FunctionError', message: 'fixture', data: code: 'FIXTURE'

test 'adapter parses only a bounded host:port TCP address', ->
  assert.deepEqual parseListenAddress('127.0.0.1:18080'), host: '127.0.0.1', port: 18080
  assert.throws (-> parseListenAddress 'bad-address'), /host:port/

test 'final adapter gives up on a stopped reader', ->
  input = new PassThrough()
  stalled = new Writable
    highWaterMark: 1
    write: (_chunk, _encoding, _callback) ->
      # Deliberately never call back or drain. This mirrors the final-image
      # stopped-reader probe and catches accidental unbounded output queues.
      undefined
  controller = runAdapter input, stalled
  input.end '{"protocolVersion":1,"id":"hello","op":"hello"}\n'
  await new Promise (resolve) -> setTimeout resolve, 650
  assert.equal controller.gate.closed, true
