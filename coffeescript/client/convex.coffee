# A deliberately small CoffeeScript Convex client. Node provides HTTP/TLS and
# `ws` provides WebSocket framing only. Convex request envelopes, sync state,
# reconnect policy, and bounded delivery are implemented below.

{ randomUUID } = require 'node:crypto'
WebSocket = require 'ws'

MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_LIVE_MESSAGE_BYTES = 2 * 1024 * 1024
MAX_PENDING_UPDATES = 16
MAX_PENDING_BYTES = 8 * 1024 * 1024
HTTP_DEADLINE_MS = 10_000
LIVE_WRITE_DEADLINE_MS = 5_000
INITIAL_RECONNECT_MS = 100
MAX_RECONNECT_MS = 15_000
INITIAL_TIMESTAMP = 'AAAAAAAAAAA='

class ConvexError extends Error
  constructor: (@name, message, details = {}) ->
    super message
    @data = details.data if Object.hasOwn details, 'data'
    @logs = details.logs ? []
    @cause = details.cause if details.cause?
    @operation = details.operation if details.operation?

class BoundedUpdates
  constructor: ->
    @items = []
    @bytes = 0
    @waiter = null
    @closed = false

  push: (update) ->
    return if @closed
    if @waiter?
      waiter = @waiter
      @waiter = null
      waiter.resolve value: update, done: false
      return
    bytes = encodedUpdateBytes update
    # A single malicious peer message cannot grow the mailbox beyond its budget.
    return if bytes > MAX_LIVE_MESSAGE_BYTES
    while @items.length >= MAX_PENDING_UPDATES or @bytes + bytes > MAX_PENDING_BYTES
      dropped = @items.shift()
      @bytes -= dropped.bytes
    @items.push update: update, bytes: bytes
    @bytes += bytes

  next: (deadlineMs = null) ->
    if @items.length
      item = @items.shift()
      @bytes -= item.bytes
      return Promise.resolve value: item.update, done: false
    return Promise.resolve done: true if @closed
    new Promise (resolve, reject) =>
      timer = null
      if deadlineMs?
        timer = setTimeout (=>
          return unless @waiter?
          @waiter = null
          reject new ConvexError 'TransportError', 'Live update deadline exceeded'
        ), deadlineMs
      @waiter =
        resolve: (result) ->
          clearTimeout timer if timer?
          resolve result
        reject: (error) ->
          clearTimeout timer if timer?
          reject error

  close: ->
    return if @closed
    @closed = true
    @items = []
    @bytes = 0
    if @waiter?
      @waiter.resolve done: true
      @waiter = null

class Subscription
  constructor: (@manager, @id, @path, @args) ->
    @updates = new BoundedUpdates()
    @active = true
    @generation = 0

  next: (deadlineMs) -> @updates.next deadlineMs

  close: ->
    return Promise.resolve() unless @active
    @manager.unsubscribe @

  _retire: ->
    @active = false
    @generation += 1
    @updates.close()

class LiveManager
  constructor: (deploymentUrl, @clientVersion) ->
    url = new URL deploymentUrl
    url.protocol = if url.protocol is 'https:' then 'wss:' else 'ws:'
    url.pathname = "#{url.pathname.replace(/\/$/, '')}/api/sync"
    url.search = ''
    url.hash = ''
    @url = url.toString()
    @subscriptions = new Map()
    @nextId = 0
    @querySetVersion = 0
    @remoteVersion = zeroVersion()
    @connectionCount = 0
    @lastCloseReason = 'InitialConnect'
    @maxObservedTimestamp = ''
    @lastDelivered = new Map()
    @awaitingRehydration = new Set()
    @socket = null
    @generation = 0
    @closed = false
    @reconnectTimer = null
    @backoffMs = INITIAL_RECONNECT_MS
    # Every network lifecycle mutation enters this promise chain. WebSocket
    # callbacks only enqueue immutable input, so they cannot race writes or a
    # query-set version change.
    @ownerChain = Promise.resolve()

  owner: (work) ->
    result = @ownerChain.then work, work
    @ownerChain = result.catch -> undefined
    result

  subscribe: (path, args) ->
    throw new ConvexError 'ProtocolError', 'Live query path is required' unless path
    throw new ConvexError 'ProtocolError', 'Live query arguments must be an object' unless isObject args
    @owner =>
      throw new ConvexError 'ClosedError', 'client is closed' if @closed
      subscription = new Subscription @, @nextId++, path, deepCopy args
      @subscriptions.set subscription.id, subscription
      if @socket?.readyState is WebSocket.OPEN
        @modify [addModification subscription]
      else
        @scheduleReconnect 0
      subscription

  unsubscribe: (subscription) ->
    @owner =>
      current = @subscriptions.get subscription.id
      return unless current is subscription
      # Retire before acknowledging the command. Adapter relays validate this
      # lease after dequeue, which blocks a stale event after unsubscribe/reuse.
      subscription._retire()
      @subscriptions.delete subscription.id
      @lastDelivered.delete subscription.id
      @awaitingRehydration.delete subscription.id
      if @socket?.readyState is WebSocket.OPEN
        try @modify [{ type: 'Remove', queryId: subscription.id }]
        catch error then @retireConnection error.message, true
      @cancelReconnect() unless @subscriptions.size

  debugDisconnect: ->
    @owner =>
      throw new ConvexError 'TransportError', 'Live WebSocket is not connected' unless @socket?.readyState is WebSocket.OPEN
      # Retire and schedule before the adapter acknowledgement. Reader messages
      # carry the retired generation and will be discarded on arrival.
      @retireConnection 'DebugDisconnect', true

  close: ->
    @owner =>
      return if @closed
      @closed = true
      @cancelReconnect()
      for subscription from @subscriptions.values()
        subscription._retire()
      @subscriptions.clear()
      @retireConnection 'ClientClosed', false

  scheduleReconnect: (delay) ->
    return if @closed or not @subscriptions.size or @socket? or @reconnectTimer?
    @reconnectTimer = setTimeout (=>
      @reconnectTimer = null
      @owner => @connect()
    ), delay
    @reconnectTimer.unref?()

  cancelReconnect: ->
    return unless @reconnectTimer?
    clearTimeout @reconnectTimer
    @reconnectTimer = null

  connect: ->
    return if @closed or not @subscriptions.size or @socket?
    generation = ++@generation
    try
      socket = new WebSocket @url,
        headers: 'Convex-Client': @clientVersion
        maxPayload: MAX_LIVE_MESSAGE_BYTES
        handshakeTimeout: HTTP_DEADLINE_MS
    catch cause
      @lastCloseReason = cause.message
      @scheduleBackoff()
      return
    @socket = socket
    socket.on 'open', => @owner => @onOpen generation, socket
    socket.on 'message', (data, isBinary) =>
      return if isBinary
      # Copy before it crosses the ownership boundary because ws buffers may be reused.
      bytes = Buffer.from data
      @owner => @onMessage generation, bytes
    socket.on 'error', (error) => @owner => @onSocketError generation, error
    socket.on 'close', (code, reason) => @owner => @onSocketClose generation, code, reason.toString()
    socket.on 'unexpected-response', (_request, response) =>
      @owner => @onSocketError generation, new Error "WebSocket upgrade returned HTTP #{response.statusCode}"

  onOpen: (generation, socket) ->
    return unless @isCurrent generation, socket
    @backoffMs = INITIAL_RECONNECT_MS
    @querySetVersion = 0
    @remoteVersion = zeroVersion()
    try
      @send
        type: 'Connect'
        sessionId: randomUUID().replaceAll '-', ''
        connectionCount: @connectionCount
        lastCloseReason: @lastCloseReason
        maxObservedTimestamp: @maxObservedTimestamp or undefined
        clientTs: 0
      modifications = []
      for subscription from @subscriptions.values()
        @awaitingRehydration.add subscription.id if @lastDelivered.has subscription.id
        modifications.push addModification subscription
      @modify modifications if modifications.length
    catch error
      @publishError error
      @retireConnection error.message, true

  onSocketError: (generation, error) ->
    return unless @isCurrent generation
    @lastCloseReason = error.message

  onSocketClose: (generation, code, reason) ->
    return unless @isCurrent generation
    @retireConnection reason or "WebSocket closed (#{code})", true

  onMessage: (generation, bytes) ->
    return unless @isCurrent generation
    if bytes.length > MAX_LIVE_MESSAGE_BYTES
      error = new ConvexError 'ProtocolError', 'Live message exceeded byte limit'
      @publishError error
      @retireConnection error.message, true
      return
    event = null
    try
      # Buffer-to-string only happens after a complete ws text message, so UTF-8
      # fragmentation remains the WebSocket library's job rather than ours.
      event = JSON.parse bytes.toString 'utf8'
    catch cause
      error = new ConvexError 'ProtocolError', 'Live server sent invalid JSON', cause: cause
      @publishError error
      @retireConnection error.message, true
      return
    if event.type is 'Transition'
      try
        @handleTransition event
        @backoffMs = INITIAL_RECONNECT_MS
      catch error
        @publishError error
        @retireConnection error.message, true
    else if event.type in ['Ping', 'MutationResponse', 'ActionResponse']
      @backoffMs = INITIAL_RECONNECT_MS
    else
      error = new ConvexError 'ProtocolError', "unsupported Live server message #{event.type}"
      @publishError error
      @retireConnection error.message, true

  handleTransition: (event) ->
    unless sameVersion event.startVersion, @remoteVersion
      throw new ConvexError 'ProtocolError', 'Live transition start version did not match local state'
    unless validTimestamp event.endVersion?.ts
      throw new ConvexError 'ProtocolError', 'Live transition had an invalid timestamp'
    changed = new Map()
    for modification in event.modifications ? []
      subscription = @subscriptions.get modification.queryId
      continue unless subscription?
      switch modification.type
        when 'QueryUpdated'
          update = value: modification.value, logs: modification.logLines ? []
          if @awaitingRehydration.delete modification.queryId
            previous = @lastDelivered.get modification.queryId
            continue if previous?.success and JSON.stringify(previous.value) is JSON.stringify(update.value)
          changed.set modification.queryId, update
        when 'QueryFailed'
          @awaitingRehydration.delete modification.queryId
          changed.set modification.queryId,
            error: new ConvexError 'FunctionError', modification.errorMessage ? 'Live query failed',
              data: modification.errorData, logs: modification.logLines ? [], operation: 'query'
            logs: modification.logLines ? []
        when 'QueryRemoved'
          @lastDelivered.delete modification.queryId
          @awaitingRehydration.delete modification.queryId
        else
          throw new ConvexError 'ProtocolError', "unsupported Live modification #{modification.type}"
    @remoteVersion = deepCopy event.endVersion
    @maxObservedTimestamp = event.endVersion.ts if not @maxObservedTimestamp or compareTimestamp(event.endVersion.ts, @maxObservedTimestamp) > 0
    for [id, update] from changed
      subscription = @subscriptions.get id
      continue unless subscription?.active
      subscription.updates.push update
      @lastDelivered.set id, success: not update.error?, value: deepCopy update.value

  send: (message) ->
    throw new ConvexError 'TransportError', 'Live WebSocket is not connected' unless @socket?.readyState is WebSocket.OPEN
    socket = @socket
    generation = @generation
    encoded = JSON.stringify message, (_key, value) -> if value is undefined then undefined else value
    throw new ConvexError 'ProtocolError', 'Live request exceeded byte limit' if Buffer.byteLength(encoded) > MAX_LIVE_MESSAGE_BYTES
    deadline = setTimeout (=>
      @owner => @retireConnection 'Live write deadline exceeded', true if @isCurrent generation, socket
    ), LIVE_WRITE_DEADLINE_MS
    socket.send encoded, (error) =>
      clearTimeout deadline
      @owner => @retireConnection(error.message, true) if error? and @isCurrent generation, socket

  modify: (modifications) ->
    return unless modifications.length
    @send
      type: 'ModifyQuerySet'
      baseVersion: @querySetVersion
      newVersion: @querySetVersion + 1
      modifications: modifications
    @querySetVersion += 1

  retireConnection: (reason, reconnect) ->
    socket = @socket
    @socket = null
    @generation += 1
    @querySetVersion = 0
    @remoteVersion = zeroVersion()
    @lastCloseReason = reason
    if socket?
      @connectionCount += 1
      try socket.terminate() catch then socket.close()
    @scheduleBackoff() if reconnect and not @closed and @subscriptions.size

  scheduleBackoff: ->
    delay = @backoffMs
    @backoffMs = Math.min @backoffMs * 2, MAX_RECONNECT_MS
    @scheduleReconnect delay

  publishError: (error) ->
    for [id, subscription] from @subscriptions
      continue unless subscription.active
      subscription.updates.push error: error, logs: error.logs ? []
      @lastDelivered.set id, success: false, value: undefined

  isCurrent: (generation, socket = @socket) -> generation is @generation and socket? and socket is @socket

class Client
  constructor: (deploymentUrl, options = {}) ->
    url = new URL deploymentUrl
    unless url.protocol in ['http:', 'https:'] and not url.username and not url.password
      throw new TypeError 'Convex deployment URL must be an absolute HTTP(S) URL'
    url.search = ''
    url.hash = ''
    @deploymentUrl = url.toString().replace /\/$/, ''
    @clientVersion = options.clientVersion ? 'coffeescript-0.1.0'
    @authToken = options.authToken ? ''
    @closed = false
    @live = null

  setAuth: (token) ->
    @ensureOpen()
    throw new TypeError 'bearer token must be a string' unless typeof token is 'string'
    @authToken = token

  query: (path, args = {}) -> @call 'query', path, args
  mutation: (path, args = {}) -> @call 'mutation', path, args
  action: (path, args = {}) -> @call 'action', path, args

  subscribe: (path, args = {}) ->
    @ensureOpen()
    @live ?= new LiveManager @deploymentUrl, @clientVersion
    @live.subscribe path, args

  debugDisconnectForAdapter: ->
    throw new ConvexError 'ProtocolError', 'Live WebSocket has not been started' unless @live?
    @live.debugDisconnect()

  close: ->
    return if @closed
    @closed = true
    await @live?.close()

  call: (operation, path, args) ->
    @ensureOpen()
    throw new TypeError 'Convex function path is required' unless typeof path is 'string' and path.length
    throw new TypeError 'Convex arguments must be a named JSON object' unless isObject args
    controller = new AbortController()
    timer = setTimeout (-> controller.abort()), HTTP_DEADLINE_MS
    try
      response = await fetch "#{@deploymentUrl}/api/#{operation}",
        method: 'POST'
        signal: controller.signal
        # Braced explicitly: CoffeeScript 2.7's indentation-based implicit
        # object literal cannot mix a spread element with plain key: value
        # pairs.
        headers: {
          'content-type': 'application/json'
          accept: 'application/json'
          'Convex-Client': @clientVersion
          ...(if @authToken then authorization: "Bearer #{@authToken}" else {})
        }
        body: JSON.stringify path: path, args: args, format: 'json'
      body = await readBody response
    catch cause
      throw cause if cause instanceof ConvexError
      throw new ConvexError 'TransportError', "#{operation} transport failed: #{cause.message}", cause: cause
    finally
      clearTimeout timer
    try
      decoded = JSON.parse body
    catch cause
      throw new ConvexError 'ProtocolError', "HTTP #{response.status} returned non-Convex JSON", cause: cause
    if decoded.status is 'success' and Object.hasOwn decoded, 'value'
      return value: decoded.value, logs: decoded.logLines ? []
    if decoded.status is 'error'
      throw new ConvexError 'FunctionError', decoded.errorMessage ? 'Convex function failed',
        data: decoded.errorData, logs: decoded.logLines ? [], operation: operation
    throw new ConvexError 'ProtocolError', "HTTP #{response.status} response has unknown status #{JSON.stringify decoded.status}"

  ensureOpen: -> throw new ConvexError 'ClosedError', 'client is closed' if @closed

readBody = (response) ->
  reader = response.body?.getReader?()
  return '' unless reader?
  chunks = []
  size = 0
  loop
    { value, done } = await reader.read()
    break if done
    size += value.byteLength
    throw new ConvexError 'TransportError', "HTTP response exceeds #{MAX_RESPONSE_BYTES} bytes" if size > MAX_RESPONSE_BYTES
    chunks.push value
  try
    new TextDecoder('utf-8', fatal: true).decode Buffer.concat chunks
  catch cause
    throw new ConvexError 'ProtocolError', 'HTTP response was not valid UTF-8', cause: cause

addModification = (subscription) ->
  type: 'Add'
  queryId: subscription.id
  udfPath: subscription.path
  args: [subscription.args]

encodedUpdateBytes = (update) -> Buffer.byteLength JSON.stringify update, (_key, value) -> if value instanceof Error then value.message else value
isObject = (value) -> value? and typeof value is 'object' and not Array.isArray value
deepCopy = (value) -> if value is undefined then undefined else JSON.parse JSON.stringify value
zeroVersion = -> querySet: 0, identity: 0, ts: INITIAL_TIMESTAMP
sameVersion = (left, right) -> JSON.stringify(left) is JSON.stringify(right)
validTimestamp = (timestamp) ->
  return false unless typeof timestamp is 'string'
  try
    decoded = Buffer.from timestamp, 'base64'
    decoded.length is 8 and decoded.toString('base64') is timestamp
  catch
    false
compareTimestamp = (left, right) ->
  a = Buffer.from left, 'base64'
  b = Buffer.from right, 'base64'
  for index in [7..0]
    return -1 if a[index] < b[index]
    return 1 if a[index] > b[index]
  0

module.exports = { Client, ConvexError, LiveManager, Subscription, readBody, compareTimestamp }
