#!/usr/local/bin/node
# Test-only NDJSON adapter v1. It never exposes a second public client API:
# every command goes through the CoffeeScript Client above.

net = require 'node:net'
{ StringDecoder } = require 'node:string_decoder'
{ Client, ConvexError } = require '../../convex'

MAX_LINE_BYTES = 2 * 1024 * 1024
MAX_INPUT_QUEUE_BYTES = 4 * 1024 * 1024
MAX_INPUT_QUEUE_LINES = 32
MAX_OUTPUT_LINE_BYTES = 3 * 1024 * 1024
OUTPUT_DEADLINE_MS = 500
MAX_SUBSCRIPTIONS = 16
runtime = "node-#{process.versions.node}"

class OutputGate
  constructor: (@stream, @onStall) ->
    @chain = Promise.resolve()
    @closed = false

  write: (event) ->
    encoded = JSON.stringify event
    if Buffer.byteLength(encoded) > MAX_OUTPUT_LINE_BYTES
      encoded = JSON.stringify type: 'error', error: name: 'ProtocolError', message: 'adapter output exceeded byte limit'
    line = "#{encoded}\n"
    task = @chain.then => @writeOne line
    @chain = task.catch -> undefined
    task

  writeOne: (line) ->
    return if @closed
    await new Promise (resolve) =>
      settled = false
      finish = =>
        return if settled
        settled = true
        clearTimeout timer
        resolve()
      timer = setTimeout (=>
        return if settled
        @closed = true
        try @stream.destroy?() catch then undefined
        @onStall?()
        finish()
      ), OUTPUT_DEADLINE_MS
      try
        return finish() if @stream.write line
        @stream.once 'drain', finish
        @stream.once 'error', finish
      catch
        finish()

serialiseError = (error) ->
  result =
    name: if error instanceof ConvexError then error.name else 'Error'
    message: error?.message ? String(error)
  result.data = error.data if Object.hasOwn(error ? {}, 'data') and error.data isnt undefined
  result

validateId = (id) -> typeof id is 'string' and id.length >= 1 and id.length <= 128
validateCommand = (command) ->
  throw new ConvexError 'ProtocolError', 'adapter command must be an object' unless command? and typeof command is 'object' and not Array.isArray command
  throw new ConvexError 'ProtocolError', 'adapter command id must be 1 to 128 bytes' unless validateId command.id
  switch command.op
    when 'hello'
      throw new ConvexError 'ProtocolError', "unsupported adapter protocol version #{command.protocolVersion}" unless command.protocolVersion is 1
    when 'query', 'mutation', 'action'
      throw new ConvexError 'ProtocolError', 'function path is required' unless typeof command.path is 'string' and command.path.length >= 3
      throw new ConvexError 'ProtocolError', 'function args must be an object' unless command.args? and typeof command.args is 'object' and not Array.isArray command.args
    when 'subscribe'
      throw new ConvexError 'ProtocolError', 'subscriptionId is required' unless validateId command.subscriptionId
      throw new ConvexError 'ProtocolError', 'function path is required' unless typeof command.path is 'string' and command.path.length >= 3
      throw new ConvexError 'ProtocolError', 'function args must be an object' unless command.args? and typeof command.args is 'object' and not Array.isArray command.args
    when 'unsubscribe'
      throw new ConvexError 'ProtocolError', 'subscriptionId is required' unless validateId command.subscriptionId
    when 'setAuth'
      throw new ConvexError 'ProtocolError', 'token must be a string' unless typeof command.token is 'string'
    when 'close', 'debugDisconnect'
      undefined
    else throw new ConvexError 'ProtocolError', "unknown operation #{JSON.stringify command.op}"

runAdapter = (input, output, environment = process.env) ->
  client = null
  subscriptions = new Map()
  decoder = new StringDecoder 'utf8'
  received = ''
  queue = []
  queueBytes = 0
  processing = false
  closed = false
  inputEnded = false
  gate = new OutputGate output, => closeSession()

  getClient = ->
    return client if client?
    throw new ConvexError 'ProtocolError', 'CONVEX_URL is required' unless environment.CONVEX_URL
    client = new Client environment.CONVEX_URL, authToken: environment.CONVEX_AUTH_TOKEN ? ''

  sendError = (id, error, subscriptionId = null) ->
    event = if subscriptionId?
      type: 'subscription'
      subscriptionId: subscriptionId
      error: serialiseError error
    else
      type: 'error'
      error: serialiseError error
    event.id = id if id?
    event.logs = error.logs if error.logs?.length
    gate.write event

  forward = (subscriptionId, subscription, lease) ->
    try
      loop
        item = await subscription.next()
        break if item.done
        current = subscriptions.get subscriptionId
        # Re-check after dequeue. This is the generation barrier that prevents
        # a paused relay from publishing through unsubscribe or ID replacement.
        continue unless current?.subscription is subscription and current.lease is lease and subscription.active
        if item.value.error?
          await sendError null, item.value.error, subscriptionId
        else
          event = type: 'subscription', subscriptionId: subscriptionId, value: item.value.value
          event.logs = item.value.logs if item.value.logs?.length
          await gate.write event
    catch error
      current = subscriptions.get subscriptionId
      await sendError null, error, subscriptionId if current?.subscription is subscription and current.lease is lease and subscription.active

  closeSession = ->
    return if closed
    closed = true
    input.pause?()
    for { subscription } from subscriptions.values()
      subscription.close().catch -> undefined
    subscriptions.clear()
    client?.close().catch -> undefined
    try input.destroy?() unless input is process.stdin catch then undefined

  execute = (line) ->
    command = null
    try
      command = JSON.parse line
      validateCommand command
      switch command.op
        when 'hello'
          await gate.write
            protocolVersion: 1
            id: command.id
            type: 'ready'
            language: 'coffeescript'
            implementation: "transpiled-coffeescript-#{runtime}"
            runtime: runtime
        when 'query', 'mutation', 'action'
          result = await getClient()[command.op] command.path, command.args
          event = id: command.id, type: 'result', value: result.value
          event.logs = result.logs if result.logs?.length
          await gate.write event
        when 'setAuth'
          getClient().setAuth command.token
          await gate.write id: command.id, type: 'ack'
        when 'subscribe'
          old = subscriptions.get command.subscriptionId
          await old.subscription.close() if old?
          throw new ConvexError 'ProtocolError', "adapter subscription limit is #{MAX_SUBSCRIPTIONS}" if not old? and subscriptions.size >= MAX_SUBSCRIPTIONS
          subscription = await getClient().subscribe command.path, command.args
          lease = (old?.lease ? 0) + 1
          subscriptions.set command.subscriptionId, { subscription, lease }
          await gate.write id: command.id, type: 'ack'
          # Detach the relay instead of returning its promise: `execute` is
          # async, so a bare implicit return here would make CoffeeScript's
          # last-expression return chain execute()'s own promise onto the
          # relay's, which only settles once the subscription is retired.
          # That would stall processQueue's sequential loop for as long as
          # the subscription stays open, deadlocking every command queued
          # behind this one (including the eventual unsubscribe).
          forward(command.subscriptionId, subscription, lease).catch -> undefined
          undefined
        when 'unsubscribe'
          old = subscriptions.get command.subscriptionId
          if old?
            subscriptions.delete command.subscriptionId
            await old.subscription.close()
          await gate.write id: command.id, type: 'ack'
        when 'debugDisconnect'
          await getClient().debugDisconnectForAdapter()
          await gate.write id: command.id, type: 'ack'
        when 'close'
          for { subscription } from subscriptions.values()
            await subscription.close()
          subscriptions.clear()
          await client?.close()
          await gate.write id: command.id, type: 'closed'
          closeSession()
    catch error
      await sendError command?.id, error

  processQueue = ->
    return if processing
    processing = true
    while queue.length and not closed
      item = queue.shift()
      queueBytes -= item.bytes
      await execute item.line
      input.resume?() if queue.length < MAX_INPUT_QUEUE_LINES and queueBytes < MAX_INPUT_QUEUE_BYTES
    processing = false
    closeSession() if inputEnded and not queue.length

  enqueueLine = (line) ->
    bytes = Buffer.byteLength line
    if bytes > MAX_LINE_BYTES
      sendError null, new ConvexError 'ProtocolError', 'adapter input line exceeded byte limit'
      return
    if queue.length >= MAX_INPUT_QUEUE_LINES or queueBytes + bytes > MAX_INPUT_QUEUE_BYTES
      input.pause?()
      sendError null, new ConvexError 'TransportError', 'adapter input queue exceeded limit'
      return
    queue.push line: line, bytes: bytes
    queueBytes += bytes
    processQueue().catch (error) -> sendError null, error

  input.on 'data', (chunk) ->
    return if closed
    # stdio normally supplies small chunks. Reject a pathological controller
    # before appending it, so a long stream cannot accumulate outside the queue.
    if chunk.length + Buffer.byteLength(received) > MAX_INPUT_QUEUE_BYTES + MAX_LINE_BYTES
      sendError null, new ConvexError 'TransportError', 'adapter input exceeded byte budget'
      closeSession()
      return
    received += decoder.write chunk
    if Buffer.byteLength(received) > MAX_LINE_BYTES + 1 and received.indexOf('\n') < 0
      received = ''
      sendError null, new ConvexError 'ProtocolError', 'adapter input line exceeded byte limit'
      return
    while (newline = received.indexOf '\n') >= 0
      line = received.slice 0, newline
      received = received.slice newline + 1
      enqueueLine line.replace /\r$/, ''
  input.on 'end', ->
    received += decoder.end()
    enqueueLine received if received.length
    inputEnded = true
    processQueue().catch -> undefined
  input.on 'error', -> closeSession()
  { close: closeSession, gate }

parseListenAddress = (value) ->
  throw new Error 'ADAPTER_LISTEN must use host:port' unless typeof value is 'string'
  match = value.match /^([^:]+):(\d{1,5})$/
  throw new Error 'ADAPTER_LISTEN must use host:port' unless match?
  port = Number match[2]
  throw new Error 'ADAPTER_LISTEN must use host:port' unless port >= 0 and port <= 65535
  { host: match[1], port }

startTcpAdapter = (listenAddress, environment = process.env) ->
  address = parseListenAddress listenAddress
  server = net.createServer (socket) ->
    # The verifier expects one controller. Closing the listener makes a second
    # connection impossible while leaving this bounded duplex NDJSON stream live.
    server.close()
    runAdapter socket, socket, environment
  server.listen address
  server

if require.main is module
  if process.env.ADAPTER_LISTEN then startTcpAdapter process.env.ADAPTER_LISTEN else runAdapter process.stdin, process.stdout

module.exports = { runAdapter, startTcpAdapter, parseListenAddress, serialiseError }
