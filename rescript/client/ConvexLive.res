// Live queries over the pinned convex-rs 0.10.4 unversioned `/api/sync`
// profile.
//
// The whole module is built around one rule: a single owner touches the
// socket. Public calls, timer expiries, and socket callbacks all become
// commands on one queue, and `pump` drains that queue without ever
// interleaving two commands. Nothing else may read the socket, write to it,
// reconnect it, or move the query-set version. That is what keeps a reconnect
// from racing a subscribe, and a retired connection's message from being
// applied to a fresh session.

type update =
  | Value({value: Js.Json.t, logs: array<string>})
  | Failure(ConvexError.t)

// The socket, reduced to what the owner needs. A test transport implements the
// same three functions, so reconnect, replay, and shutdown semantics can be
// exercised deterministically without a network.
type connection = {
  send: string => unit,
  terminate: unit => unit,
  closeGracefully: unit => unit,
}

type connectionHandlers = {
  onOpen: unit => unit,
  onMessage: string => unit,
  onClosed: string => unit,
}

type transport = {connect: (string, string, connectionHandlers) => connection}

let initialBackoffMs = 100
let maximumBackoffMs = 15000

// A graceful close waits for the server's closing handshake. A peer that is
// idle, flooding, or stalled mid-frame must not be able to hold the client
// open, so the handshake gets a deadline and then the socket is dropped.
let closeHandshakeMs = 250
let websocketHandshakeMs = 5000
let maximumWebSocketMessageBytes = 2 * 1024 * 1024
let websocketHeartbeatMs = 5000
let maximumActiveSubscriptions = 16
let maximumSubscriptionBytes = 16 * 1024

// Live delivery is a bounded newest-value queue. A count bound alone is not a
// memory bound, because a single Convex value can be large, so a byte budget
// applies as well. The queue always keeps at least the newest update.
let maximumQueuedUpdates = 16
let maximumQueuedBytes = 1024 * 1024
let queuedUpdateOverhead = 256

let websocketTransport = {
  connect: (url, clientVersion, handlers) => {
    let headers = Js.Dict.empty()
    Js.Dict.set(headers, "Convex-Client", clientVersion)
    let options: ConvexNode.webSocketOptions = {
      headers,
      handshakeTimeout: websocketHandshakeMs,
      maxPayload: maximumWebSocketMessageBytes,
    }
    let socket = ConvexNode.makeWebSocket(url, options)
    // `ws` reports a failed connection as an error event, a closed one as a
    // close event, and frequently both. The owner must hear about it once.
    let reported = ref(false)
    let heartbeatTimer = ref(None)
    let awaitingPong = ref(false)
    let cancelHeartbeat = () => {
      switch heartbeatTimer.contents {
      | Some(timer) => ConvexNode.clearTimeout(timer)
      | None => ()
      }
      heartbeatTimer := None
    }
    let reportClosed = reason => {
      if !reported.contents {
        reported := true
        cancelHeartbeat()
        handlers.onClosed(reason)
      }
    }
    let rec scheduleHeartbeat = () => {
      let timer = ConvexNode.setTimeout(() => {
        if awaitingPong.contents {
          reportClosed("WebSocket heartbeat deadline exceeded")
          ConvexNode.webSocketTerminate(socket)
        } else {
          awaitingPong := true
          try {
            ConvexNode.webSocketPing(socket)
            scheduleHeartbeat()
          } catch {
          | error => reportClosed(ConvexError.fromException(error).message)
          }
        }
      }, websocketHeartbeatMs)
      heartbeatTimer := Some(timer)
    }
    ConvexNode.webSocketOnOpen(socket, "open", () => {
      scheduleHeartbeat()
      handlers.onOpen()
    })
    ConvexNode.webSocketOnPong(socket, "pong", () => awaitingPong := false)
    ConvexNode.webSocketOnMessage(socket, "message", data =>
      handlers.onMessage(ConvexNode.bytesToString(data, "utf8"))
    )
    ConvexNode.webSocketOnError(socket, "error", error =>
      reportClosed(ConvexNode.errorMessage(error))
    )
    ConvexNode.webSocketOnClose(socket, "close", (code, _reason) =>
      reportClosed("close code " ++ Belt.Int.toString(code))
    )
    {
      send: text => ConvexNode.webSocketSend(socket, text),
      terminate: () => {
        cancelHeartbeat()
        ConvexNode.webSocketTerminate(socket)
      },
      closeGracefully: () => {
        cancelHeartbeat()
        ConvexNode.webSocketClose(socket, 1000, "client closed")
        let timer = ConvexNode.setTimeout(
          () => ConvexNode.webSocketTerminate(socket),
          closeHandshakeMs,
        )
        let _ = ConvexNode.unrefTimer(timer)
      },
    }
  },
}

type deliveredUpdate = {
  fingerprint: option<string>,
  success: bool,
}

type subscriptionState = {
  queryId: int,
  path: string,
  args: Js.Json.t,
  queue: array<update>,
  mutable queueBytes: int,
  mutable waiter: option<ConvexNode.Deferred.t<option<update>>>,
  mutable finished: bool,
}

type rec manager = {
  syncUrl: string,
  clientVersion: string,
  // One UUID identifies the logical client session across every reconnect.
  // Changing it per socket would discard the resume metadata carried by
  // connectionCount and maxObservedTimestamp.
  sessionId: string,
  transport: transport,
  active: Js.Dict.t<subscriptionState>,
  // What each subscriber has already seen, used to suppress an unchanged value
  // when a reconnect rehydrates the query set.
  lastDelivered: Js.Dict.t<deliveredUpdate>,
  awaitingRehydration: Js.Dict.t<bool>,
  pending: array<command>,
  mutable pumping: bool,
  mutable nextQueryId: int,
  mutable querySetVersion: int,
  // True from the moment a ModifyQuerySet is written to the socket until the
  // Transition confirming it arrives. The protocol allows only one
  // outstanding query-set change at a time: a second one sent before the
  // first is acknowledged races the server's own reply and is exactly the
  // "Transition query-set version does not match" failure this flag exists
  // to prevent. A Subscribe or Unsubscribe that lands while this is true
  // queues its modification instead of writing it immediately.
  mutable querySetAckPending: bool,
  mutable queuedModifications: array<ConvexProtocol.queryModification>,
  mutable remoteVersion: ConvexProtocol.stateVersion,
  mutable maxObservedTimestamp: string,
  mutable connectionCount: int,
  mutable lastCloseReason: string,
  mutable backoffMs: int,
  // Bumped whenever a socket is retired, so late events from a dead connection
  // are recognised and dropped instead of being applied to the new session.
  mutable generation: int,
  mutable connection: option<connection>,
  mutable handshakeComplete: bool,
  mutable reconnectTimer: option<ConvexNode.timer>,
  mutable reconnectToken: int,
  mutable closed: bool,
}
and command =
  | Subscribe({path: string, args: Js.Json.t, reply: ConvexNode.Deferred.t<int>})
  | Next({queryId: int, reply: ConvexNode.Deferred.t<option<update>>})
  | Unsubscribe({queryId: int, reply: ConvexNode.Deferred.t<unit>})
  | DebugDisconnect({reply: ConvexNode.Deferred.t<unit>})
  | CloseManager({reply: ConvexNode.Deferred.t<unit>})
  | SocketOpen({generation: int})
  | SocketMessage({generation: int, data: string})
  | SocketClosed({generation: int, reason: string})
  | ReconnectDue({token: int})

type subscription = {
  manager: manager,
  queryId: int,
}

let make = (~deploymentUrl, ~clientVersion, ~transport) => {
  syncUrl: ConvexProtocol.syncUrl(deploymentUrl),
  clientVersion,
  sessionId: ConvexNode.randomUUID(),
  transport,
  active: Js.Dict.empty(),
  lastDelivered: Js.Dict.empty(),
  awaitingRehydration: Js.Dict.empty(),
  pending: [],
  pumping: false,
  nextQueryId: 0,
  querySetVersion: 0,
  querySetAckPending: false,
  queuedModifications: [],
  remoteVersion: ConvexProtocol.zeroVersion(),
  maxObservedTimestamp: "",
  connectionCount: 0,
  lastCloseReason: "InitialConnect",
  backoffMs: initialBackoffMs,
  generation: 0,
  connection: None,
  handshakeComplete: false,
  reconnectTimer: None,
  reconnectToken: 0,
  closed: false,
}

let subscriptionKey = queryId => Belt.Int.toString(queryId)

let activeCount = manager => Js.Array2.length(Js.Dict.keys(manager.active))

let updateCost = update =>
  switch update {
  | Value({value, logs}) =>
    ConvexNode.utf8ByteLength(
      ConvexJson.stringify(
        ConvexJson.object_([
          ("value", value),
          ("logs", Js.Json.array(Js.Array2.map(logs, Js.Json.string))),
        ]),
      ),
    ) +
    queuedUpdateOverhead
  | Failure(error) =>
    ConvexNode.utf8ByteLength(
      ConvexJson.stringify(
        ConvexJson.object_([
          ("message", Js.Json.string(error.message)),
          ("logs", Js.Json.array(Js.Array2.map(error.logs, Js.Json.string))),
          (
            "data",
            switch error.data {
            | Some(data) => data
            | None => Js.Json.null
            },
          ),
        ]),
      ),
    ) +
    queuedUpdateOverhead
  }

let sortedActive = manager => {
  let states = Js.Dict.values(manager.active)
  let _ = Js.Array2.sortInPlaceWith(states, (left, right) => left.queryId - right.queryId)
  states
}

// Drops the oldest updates until the subscription is inside both bounds. A
// reactive query describes current state, so a slow reader is given the newest
// values rather than an unbounded backlog.
let trimQueue = state => {
  let trimming = ref(true)
  while trimming.contents {
    let tooMany = Js.Array2.length(state.queue) > maximumQueuedUpdates
    let tooLarge = state.queueBytes > maximumQueuedBytes
    if tooMany || tooLarge {
      switch Js.Array2.shift(state.queue) {
      | Some(dropped) => state.queueBytes = state.queueBytes - updateCost(dropped)
      | None => trimming := false
      }
    } else {
      trimming := false
    }
  }
}

let deliver = (state, update) =>
  switch state.waiter {
  | Some(waiter) => {
      state.waiter = None
      waiter.resolve(Some(update))
    }
  | None => {
      let stored =
        updateCost(update) > maximumQueuedBytes
          ? Failure(ConvexError.transport("Live update exceeds the subscription queue byte limit"))
          : update
      let _ = Js.Array2.push(state.queue, stored)
      state.queueBytes = state.queueBytes + updateCost(stored)
      trimQueue(state)
    }
  }

let finishSubscription = state => {
  state.finished = true
  let _ = Js.Array2.removeCountInPlace(state.queue, ~pos=0, ~count=Js.Array2.length(state.queue))
  state.queueBytes = 0
  switch state.waiter {
  | Some(waiter) => {
      state.waiter = None
      waiter.resolve(None)
    }
  | None => ()
  }
}

let rec enqueue = (manager, command) => {
  let _ = Js.Array2.push(manager.pending, command)
  pump(manager)
}
// The owner loop. One command runs at a time, and a command enqueued from
// inside a command joins the same drain rather than nesting inside it.
and pump = manager =>
  if !manager.pumping {
    manager.pumping = true
    let draining = ref(true)
    while draining.contents {
      switch Js.Array2.shift(manager.pending) {
      | Some(command) =>
        try handle(manager, command) catch {
        | error =>
          // A failed command must never leave the owner wedged.
          ConvexNode.logDiagnostic(
            "convex live command failed: " ++ ConvexError.fromException(error).message,
          )
        }
      | None => draining := false
      }
    }
    manager.pumping = false
  }
and handle = (manager, command) =>
  switch command {
  | Subscribe({path, args, reply}) => handleSubscribe(manager, path, args, reply)
  | Next({queryId, reply}) => handleNext(manager, queryId, reply)
  | Unsubscribe({queryId, reply}) => handleUnsubscribe(manager, queryId, reply)
  | DebugDisconnect({reply}) => handleDebugDisconnect(manager, reply)
  | CloseManager({reply}) => handleClose(manager, reply)
  | SocketOpen({generation}) => handleSocketOpen(manager, generation)
  | SocketMessage({generation, data}) => handleSocketMessage(manager, generation, data)
  | SocketClosed({generation, reason}) => handleSocketClosed(manager, generation, reason)
  | ReconnectDue({token}) => handleReconnectDue(manager, token)
  }
// Returns the failure reason, or None when the message reached the socket.
and sendMessage = (manager, json) =>
  switch manager.connection {
  | None => Some("Live WebSocket is not connected")
  | Some(connection) =>
    try {
      let encoded = ConvexJson.stringify(json)
      if ConvexNode.utf8ByteLength(encoded) > maximumWebSocketMessageBytes {
        Some("Live WebSocket message exceeds the byte limit")
      } else {
        connection.send(encoded)
        None
      }
    } catch {
    | error => Some(ConvexError.fromException(error).message)
    }
  }
and cancelReconnect = manager => {
  switch manager.reconnectTimer {
  | Some(timer) => ConvexNode.clearTimeout(timer)
  | None => ()
  }
  manager.reconnectTimer = None

  // A timer that has already fired but not yet been handled is now stale.
  manager.reconnectToken = manager.reconnectToken + 1
}
and scheduleReconnect = (manager, delayMs) => {
  cancelReconnect(manager)
  let token = manager.reconnectToken
  let timer = ConvexNode.setTimeout(() => enqueue(manager, ReconnectDue({token: token})), delayMs)

  // An active subscription is unfinished work. Keep its reconnect timer
  // referenced so a temporary outage cannot make an otherwise idle process
  // exit before the subscription recovers.
  manager.reconnectTimer = Some(timer)
}
and growBackoff = manager =>
  manager.backoffMs = Js.Math.min_int(manager.backoffMs * 2, maximumBackoffMs)
and closeConnection = (manager, reason, schedule) => {
  switch manager.connection {
  | Some(connection) => {
      connection.terminate()
      manager.connection = None
      manager.connectionCount = manager.connectionCount + 1
    }
  | None => ()
  }
  manager.generation = manager.generation + 1
  manager.handshakeComplete = false
  manager.lastCloseReason = reason

  // Query-set and transition versions belong to one connection. A new session
  // always starts from zero. Anything still queued or awaiting the dead
  // connection's own ack is moot: the next resendActiveQueries() rebuilds the
  // whole query set from manager.active's current membership regardless.
  manager.querySetVersion = 0
  manager.querySetAckPending = false
  manager.queuedModifications = []
  manager.remoteVersion = ConvexProtocol.zeroVersion()
  if schedule && !manager.closed && activeCount(manager) > 0 {
    scheduleReconnect(manager, manager.backoffMs)
    growBackoff(manager)
  }
}
and openConnection = manager =>
  switch manager.connection {
  | Some(_) => ()
  | None =>
    if !manager.closed && activeCount(manager) > 0 {
      manager.generation = manager.generation + 1
      manager.handshakeComplete = false
      let generation = manager.generation
      let handlers = {
        onOpen: () => enqueue(manager, SocketOpen({generation: generation})),
        onMessage: data => enqueue(manager, SocketMessage({generation, data})),
        onClosed: reason => enqueue(manager, SocketClosed({generation, reason})),
      }
      let attempt = try Ok(
        manager.transport.connect(manager.syncUrl, manager.clientVersion, handlers),
      ) catch {
      | error => Error(ConvexError.fromException(error).message)
      }
      switch attempt {
      | Ok(connection) => manager.connection = Some(connection)
      | Error(message) => {
          clearQueuedGeneration(manager)
          publishError(manager, ConvexError.transport("Live WebSocket connect failed: " ++ message))
          manager.lastCloseReason = message
          manager.connectionCount = manager.connectionCount + 1
          scheduleReconnect(manager, manager.backoffMs)
          growBackoff(manager)
        }
      }
    }
  }
and handleSocketOpen = (manager, generation) =>
  if generation == manager.generation {
    switch manager.connection {
    | None => ()
    | Some(_) => {
        // A completed handshake means the transport is healthy, so a later
        // failure starts from the shortest delay again instead of inheriting
        // the backoff of an older outage.
        manager.backoffMs = initialBackoffMs
        manager.handshakeComplete = true
        manager.querySetVersion = 0
        manager.querySetAckPending = false
        manager.queuedModifications = []
        manager.remoteVersion = ConvexProtocol.zeroVersion()
        let connect = ConvexProtocol.connectMessage(
          ~sessionId=manager.sessionId,
          ~connectionCount=manager.connectionCount,
          ~lastCloseReason=manager.lastCloseReason,
          ~maxObservedTimestamp=manager.maxObservedTimestamp,
        )
        switch sendMessage(manager, connect) {
        | Some(message) =>
          failConnection(manager, ConvexError.transport("Live WebSocket write failed: " ++ message))
        | None => resendActiveQueries(manager)
        }
      }
    }
  }
// Every connection rebuilds the entire active query set from scratch. A query
// whose current value the subscriber has already seen is marked as awaiting
// rehydration, so an identical replayed value is not published as news.
and resendActiveQueries = manager => {
  let states = sortedActive(manager)
  let modifications = Js.Array2.map(states, state => {
    switch Js.Dict.get(manager.lastDelivered, subscriptionKey(state.queryId)) {
    | Some(_) => Js.Dict.set(manager.awaitingRehydration, subscriptionKey(state.queryId), true)
    | None => ()
    }
    ConvexProtocol.Add({queryId: state.queryId, path: state.path, args: state.args})
  })
  if Js.Array2.length(modifications) > 0 {
    let message = ConvexProtocol.modifyQuerySetMessage(
      ~baseVersion=0,
      ~newVersion=1,
      ~modifications,
    )
    switch sendMessage(manager, message) {
    | None => {
        manager.querySetVersion = 1
        manager.querySetAckPending = true
      }
    | Some(text) =>
      failConnection(manager, ConvexError.transport("Live WebSocket write failed: " ++ text))
    }
  }
}
// The protocol allows only one outstanding, unacknowledged ModifyQuerySet at
// a time: a Subscribe immediately followed by an Unsubscribe (or vice versa)
// used to write two of these back to back, and the server's Transition for
// the first one would arrive reporting a querySet version this client had
// already raced past locally -- the exact "Transition query-set version does
// not match the locally sent query set" failure the shared conformance pilot
// caught. Queue instead of writing whenever one is already in flight;
// flushQueuedModifications sends the backlog, combined into a single
// message, the moment the outstanding one is confirmed.
and sendOrQueueModification = (manager, modification) =>
  if manager.querySetAckPending {
    let _ = Js.Array2.push(manager.queuedModifications, modification)
  } else {
    let newVersion = manager.querySetVersion + 1
    let message = ConvexProtocol.modifyQuerySetMessage(
      ~baseVersion=manager.querySetVersion,
      ~newVersion,
      ~modifications=[modification],
    )
    switch sendMessage(manager, message) {
    | None => {
        manager.querySetVersion = newVersion
        manager.querySetAckPending = true
      }
    | Some(text) =>
      failConnection(manager, ConvexError.transport("Live WebSocket write failed: " ++ text))
    }
  }
// The Transition that just landed confirms the server has caught up to
// manager.querySetVersion, so whatever Subscribe or Unsubscribe queued a
// modification while that was still outstanding can now go out as one
// combined ModifyQuerySet.
and flushQueuedModifications = manager => {
  manager.querySetAckPending = false
  if Js.Array2.length(manager.queuedModifications) > 0 {
    let modifications = manager.queuedModifications
    manager.queuedModifications = []
    let newVersion = manager.querySetVersion + Js.Array2.length(modifications)
    let message = ConvexProtocol.modifyQuerySetMessage(
      ~baseVersion=manager.querySetVersion,
      ~newVersion,
      ~modifications,
    )
    switch sendMessage(manager, message) {
    | None => {
        manager.querySetVersion = newVersion
        manager.querySetAckPending = true
      }
    | Some(text) =>
      failConnection(manager, ConvexError.transport("Live WebSocket write failed: " ++ text))
    }
  }
}
and handleSocketMessage = (manager, generation, data) =>
  if generation == manager.generation {
    switch ConvexJson.parse(data) {
    | Error(message) =>
      failConnection(manager, ConvexError.protocol("Live server sent invalid JSON: " ++ message))
    | Ok(json) =>
      switch ConvexProtocol.decodeServerMessage(json) {
      | Error(message) => failConnection(manager, ConvexError.protocol(message))
      | Ok(ConvexProtocol.Transition(transition)) =>
        switch applyTransition(manager, transition) {
        | Some(message) => failConnection(manager, ConvexError.protocol(message))
        | None => manager.backoffMs = initialBackoffMs
        }
      | Ok(Ignorable(_)) => manager.backoffMs = initialBackoffMs
      | Ok(ServerError(message)) => failConnection(manager, ConvexError.protocol(message))
      | Ok(Unsupported(message)) => failConnection(manager, ConvexError.protocol(message))
      }
    }
  }
// A transition is atomic: it is validated and committed in full before any
// subscriber is told about any part of it. Returns a protocol failure reason,
// or None when the transition was applied.
and applyTransition = (manager, transition) =>
  if !ConvexProtocol.sameVersion(transition.startVersion, manager.remoteVersion) {
    Some("Transition start version does not match local state")
  } else if transition.endVersion.querySet != manager.querySetVersion {
    Some("Transition query-set version does not match the locally sent query set")
  } else if (
    transition.endVersion.querySet < transition.startVersion.querySet ||
      transition.endVersion.identity < transition.startVersion.identity
  ) {
    Some("Transition end version regresses a version counter")
  } else {
    switch ConvexProtocol.compareTimestamps(transition.endVersion.ts, transition.startVersion.ts) {
    | Error(message) => Some("invalid Transition timestamp: " ++ message)
    | Ok(ordering) if ordering < 0 => Some("Transition end timestamp regresses")
    | Ok(_) => {
        // A transition may mention one query more than once. Its modifications
        // are ordered, so one dictionary naturally implements last-wins while
        // ensuring a subscriber receives at most one publication per commit.
        let changed: Js.Dict.t<update> = Js.Dict.empty()
        Js.Array2.forEach(transition.changes, change =>
          switch change {
          | ConvexProtocol.QueryUpdated({queryId, value, logs}) => {
              let key = subscriptionKey(queryId)
              let unchanged = switch (
                Js.Dict.get(manager.awaitingRehydration, key),
                Js.Dict.get(manager.lastDelivered, key),
              ) {
              | (Some(true), Some(previous)) =>
                previous.success &&
                switch previous.fingerprint {
                | Some(seen) => seen == ConvexNode.sha256Text(ConvexJson.stringify(value))
                | None => false
                }
              | _ => false
              }
              ConvexNode.removeKey(manager.awaitingRehydration, key)
              if !unchanged {
                Js.Dict.set(changed, key, Value({value, logs}))
              }
            }
          | QueryFailed({queryId, message, data, logs}) => {
              // A reactive query failure is a value-shaped event: the
              // subscription stays active and can recover later.
              ConvexNode.removeKey(manager.awaitingRehydration, subscriptionKey(queryId))
              Js.Dict.set(
                changed,
                subscriptionKey(queryId),
                Failure(ConvexError.functionFailure(message, data, logs)),
              )
            }
          | QueryRemoved({queryId}) => {
              let key = subscriptionKey(queryId)
              ConvexNode.removeKey(manager.lastDelivered, key)
              ConvexNode.removeKey(manager.awaitingRehydration, key)
              ConvexNode.removeKey(changed, key)
            }
          }
        )
        manager.remoteVersion = transition.endVersion
        rememberTimestamp(manager, transition.endVersion.ts)
        // The server has now caught up to manager.querySetVersion, so any
        // Subscribe or Unsubscribe that queued a modification while this
        // Transition was outstanding can be sent now.
        flushQueuedModifications(manager)
        Js.Array2.forEach(sortedActive(manager), state => {
          let key = subscriptionKey(state.queryId)
          switch Js.Dict.get(changed, key) {
          | Some(update) => {
              deliver(state, update)
              let record = switch update {
              | Value({value}) => {
                  fingerprint: Some(ConvexNode.sha256Text(ConvexJson.stringify(value))),
                  success: true,
                }
              | Failure(_) => {fingerprint: None, success: false}
              }
              Js.Dict.set(manager.lastDelivered, key, record)
            }
          | None => ()
          }
        })
        None
      }
    }
  }
// The newest timestamp this client has observed is reported on the next
// Connect, so a resumed session does not go backwards in time.
and rememberTimestamp = (manager, ts) =>
  if manager.maxObservedTimestamp == "" {
    manager.maxObservedTimestamp = ts
  } else {
    switch ConvexProtocol.compareTimestamps(ts, manager.maxObservedTimestamp) {
    | Ok(comparison) =>
      if comparison > 0 {
        manager.maxObservedTimestamp = ts
      }
    | Error(_) => ()
    }
  }
and publishError = (manager, error) =>
  Js.Array2.forEach(sortedActive(manager), state => {
    deliver(state, Failure(error))
    Js.Dict.set(
      manager.lastDelivered,
      subscriptionKey(state.queryId),
      {fingerprint: None, success: false},
    )
  })
and clearQueuedGeneration = manager =>
  Js.Array2.forEach(sortedActive(manager), state => {
    let _ = Js.Array2.removeCountInPlace(state.queue, ~pos=0, ~count=Js.Array2.length(state.queue))
    state.queueBytes = 0
  })
and failConnection = (manager, error) => {
  // Nothing dequeued from the retired transport may be observed after its
  // structured failure. Clear first, publish the failure, then reconnect.
  clearQueuedGeneration(manager)
  publishError(manager, error)
  closeConnection(manager, error.message, true)
}
and handleSocketClosed = (manager, generation, reason) =>
  if generation == manager.generation {
    clearQueuedGeneration(manager)
    publishError(manager, ConvexError.transport("Live WebSocket closed: " ++ reason))
    closeConnection(manager, reason, true)
  }
and handleReconnectDue = (manager, token) =>
  if token == manager.reconnectToken && !manager.closed {
    manager.reconnectTimer = None
    openConnection(manager)
  }
and handleSubscribe = (manager, path, args, reply) =>
  if manager.closed {
    reply.reject(ConvexError.ConvexFailure(ConvexError.closed()))
  } else if activeCount(manager) >= maximumActiveSubscriptions {
    reply.reject(ConvexError.ConvexFailure(ConvexError.usage("too many active Live subscriptions")))
  } else if ConvexNode.utf8ByteLength(ConvexJson.stringify(args)) > maximumSubscriptionBytes {
    reply.reject(
      ConvexError.ConvexFailure(ConvexError.usage("Live subscription arguments are too large")),
    )
  } else {
    let queryId = manager.nextQueryId
    manager.nextQueryId = manager.nextQueryId + 1
    let state = {
      queryId,
      path,
      args,
      queue: [],
      queueBytes: 0,
      waiter: None,
      finished: false,
    }
    Js.Dict.set(manager.active, subscriptionKey(queryId), state)
    reply.resolve(queryId)
    switch (manager.connection, manager.handshakeComplete) {
    | (Some(_), true) => sendOrQueueModification(manager, ConvexProtocol.Add({queryId, path, args}))
    // A connection that has not finished its handshake will send an Add for
    // every active query, including this one, so there is nothing to do here.
    | (Some(_), false) => ()
    | (None, _) => scheduleReconnect(manager, 0)
    }
  }
and handleNext = (manager, queryId, reply) =>
  switch Js.Dict.get(manager.active, subscriptionKey(queryId)) {
  | None => reply.resolve(None)
  | Some(state) =>
    switch Js.Array2.shift(state.queue) {
    | Some(update) => {
        state.queueBytes = state.queueBytes - updateCost(update)
        reply.resolve(Some(update))
      }
    | None =>
      if state.finished {
        reply.resolve(None)
      } else {
        switch state.waiter {
        | Some(_) =>
          reply.reject(
            ConvexError.ConvexFailure(
              ConvexError.usage("a Live subscription allows one pending read"),
            ),
          )
        | None => state.waiter = Some(reply)
        }
      }
    }
  }
and handleUnsubscribe = (manager, queryId, reply) => {
  let key = subscriptionKey(queryId)
  switch Js.Dict.get(manager.active, key) {
  | None => reply.resolve()
  | Some(state) => {
      // The subscription is retired, and every queued or awaited update is
      // dropped, before the caller is acknowledged. Nothing that was already in
      // flight can cross that acknowledgement.
      ConvexNode.removeKey(manager.active, key)
      ConvexNode.removeKey(manager.lastDelivered, key)
      ConvexNode.removeKey(manager.awaitingRehydration, key)
      finishSubscription(state)
      switch (manager.connection, manager.handshakeComplete) {
      | (Some(_), true) =>
        sendOrQueueModification(manager, ConvexProtocol.Remove({queryId: queryId}))
      | _ => ()
      }
      if activeCount(manager) == 0 {
        cancelReconnect(manager)
      }
      reply.resolve()
    }
  }
}
and handleDebugDisconnect = (manager, reply) =>
  switch manager.connection {
  | None =>
    reply.reject(
      ConvexError.ConvexFailure(ConvexError.transport("Live WebSocket is not connected")),
    )
  | Some(_) => {
      // Retire the socket and schedule the reconnect on the owner before
      // acknowledging, so the controller's next mutation cannot race a stale
      // event from the connection it just asked the client to drop.
      clearQueuedGeneration(manager)
      closeConnection(manager, "DebugDisconnect", true)
      reply.resolve()
    }
  }
and handleClose = (manager, reply) => {
  manager.closed = true
  cancelReconnect(manager)
  switch manager.connection {
  | Some(connection) => {
      connection.closeGracefully()
      manager.connection = None
      manager.generation = manager.generation + 1
    }
  | None => ()
  }
  manager.handshakeComplete = false
  Js.Array2.forEach(Js.Dict.keys(manager.active), key =>
    switch Js.Dict.get(manager.active, key) {
    | Some(state) => {
        finishSubscription(state)
        ConvexNode.removeKey(manager.active, key)
        ConvexNode.removeKey(manager.lastDelivered, key)
        ConvexNode.removeKey(manager.awaitingRehydration, key)
      }
    | None => ()
    }
  )
  reply.resolve()
}

let subscribe = async (manager, path, args) => {
  if path == "" {
    ConvexError.raiseError(ConvexError.usage("Convex function path is required"))
  } else if ConvexNode.utf8ByteLength(path) > 1024 {
    ConvexError.raiseError(ConvexError.usage("Convex function path is too long"))
  }
  switch ConvexJson.asObject(args) {
  | Some(_) => ()
  | None =>
    ConvexError.raiseError(ConvexError.usage("Live query arguments must be a named JSON object"))
  }
  let reply = ConvexNode.Deferred.make()
  enqueue(manager, Subscribe({path, args, reply}))
  let queryId = await reply.promise
  {manager, queryId}
}

// Waits for the next value or query failure. `None` means the subscription is
// finished: unsubscribed, replaced, or closed with the client.
let next = async subscription => {
  let reply = ConvexNode.Deferred.make()
  enqueue(subscription.manager, Next({queryId: subscription.queryId, reply}))
  await reply.promise
}

let closeSubscription = async subscription => {
  let reply = ConvexNode.Deferred.make()
  enqueue(subscription.manager, Unsubscribe({queryId: subscription.queryId, reply}))
  await reply.promise
}

// Adapter-only fault injection. It drops the socket without closing the client
// so the shared controller can prove real reconnects; it is not part of the
// educational client API.
// `{reply}` (punned) parses as a block returning that value, not as a
// one-field record -- see the comment on the QueryRemoved case in
// ConvexProtocol.res for why spelling out the field is required here.
let debugDisconnect = async manager => {
  let reply = ConvexNode.Deferred.make()
  enqueue(manager, DebugDisconnect({reply: reply}))
  await reply.promise
}

let close = async manager => {
  let reply = ConvexNode.Deferred.make()
  enqueue(manager, CloseManager({reply: reply}))
  await reply.promise
}
