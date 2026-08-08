// NDJSON adapter protocol v1. This is test infrastructure, not public client
// code: the shared controller drives it over stdin/stdout or, in the isolated
// Docker harness, over one TCP connection.
//
// Three rules shape everything here. Stdout carries protocol events and
// nothing else, so diagnostics go to stderr. Commands run strictly one at a
// time, so the controller's ordering assumptions hold. Both the input and the
// output are bounded, so a stalled controller cannot make this process grow
// past the 128 MiB the verifier allows it.

let protocolVersion = 1
let languageId = "rescript"

// Matches the pinned toolchain in manifest.yaml.
let compilerVersion = "11.1.4"

// One command line is a JSON object with a Convex argument payload. One MiB is
// far above anything the controller sends and keeps parsing workspace small.
let maximumLineBytes = 1024 * 1024

// Output that the runtime has not yet flushed is the adapter's real memory
// risk, because Node will happily buffer it forever if the controller stops
// reading. Both bounds are deliberately conservative: sixteen records, eight
// MiB, and a fixed per-record overhead charge for the encoding workspace.
let maximumOutstandingRecords = 16
let maximumOutstandingBytes = 8 * 1024 * 1024
let outputRecordOverhead = 1024
let tcpAcceptDeadlineMs = 30000

let runtimeName = () => "node-" ++ ConvexNode.nodeVersion

let implementationName = () => "native-rescript-" ++ compilerVersion ++ "-" ++ runtimeName()

type output = {
  stream: ConvexNode.writable,
  mutable outstandingRecords: int,
  mutable outstandingBytes: int,
  mutable exhausted: bool,
  mutable onExhausted: unit => unit,
}

let makeOutput = stream => {
  stream,
  outstandingRecords: 0,
  outstandingBytes: 0,
  exhausted: false,
  onExhausted: () => (),
}

// Charges every record against both budgets until the runtime confirms the
// flush. Exhausting the budget is a hard failure reported on stderr, never a
// silent unbounded buffer.
let writeEvent = (output, event) =>
  if !output.exhausted {
    let encoded = ConvexJson.stringify(event) ++ "\n"
    let cost = ConvexNode.utf8ByteLength(encoded) + outputRecordOverhead
    if (
      output.outstandingRecords + 1 > maximumOutstandingRecords ||
        output.outstandingBytes + cost > maximumOutstandingBytes
    ) {
      output.exhausted = true
      ConvexNode.logDiagnostic("adapter output budget exhausted; stopping the event stream")
      // Do not turn a truncated protocol conversation into a successful
      // process. Existing queued writes may flush, but the final status is
      // unambiguously nonzero and no further events are accepted.
      output.onExhausted()
    } else {
      output.outstandingRecords = output.outstandingRecords + 1
      output.outstandingBytes = output.outstandingBytes + cost
      let _ = ConvexNode.writeThen(output.stream, encoded, () => {
        output.outstandingRecords = output.outstandingRecords - 1
        output.outstandingBytes = output.outstandingBytes - cost
      })
    }
  }

// Event shapes are validated strictly by the shared controller, so an absent
// id, subscription id, value, or error is omitted rather than serialised as
// null.
let logFields = logs =>
  Js.Array2.length(logs) == 0 ? [] : [("logs", Js.Json.array(Js.Array2.map(logs, Js.Json.string)))]

let errorJson = (error: ConvexError.t) => {
  let fields = [
    ("name", Js.Json.string(ConvexError.name(error))),
    ("message", Js.Json.string(error.message)),
  ]
  switch error.data {
  | Some(data) => ConvexJson.object_(Js.Array2.concat(fields, [("data", data)]))
  | None => ConvexJson.object_(fields)
  }
}

let readyEvent = id =>
  ConvexJson.object_([
    ("protocolVersion", Js.Json.number(Belt.Int.toFloat(protocolVersion))),
    ("id", Js.Json.string(id)),
    ("type", Js.Json.string("ready")),
    ("language", Js.Json.string(languageId)),
    ("implementation", Js.Json.string(implementationName())),
    ("runtime", Js.Json.string(runtimeName())),
  ])

let resultEvent = (id, value, logs) =>
  ConvexJson.object_(
    Js.Array2.concat(
      [("id", Js.Json.string(id)), ("type", Js.Json.string("result")), ("value", value)],
      logFields(logs),
    ),
  )

let ackEvent = (id, eventType) =>
  ConvexJson.object_([("id", Js.Json.string(id)), ("type", Js.Json.string(eventType))])

let errorEvent = (id, error: ConvexError.t) => {
  let base = [("type", Js.Json.string("error")), ("error", errorJson(error))]
  let withId = switch id {
  | Some(value) => Js.Array2.concat([("id", Js.Json.string(value))], base)
  | None => base
  }
  ConvexJson.object_(Js.Array2.concat(withId, logFields(error.logs)))
}

let subscriptionValueEvent = (subscriptionId, value, logs) =>
  ConvexJson.object_(
    Js.Array2.concat(
      [
        ("type", Js.Json.string("subscription")),
        ("subscriptionId", Js.Json.string(subscriptionId)),
        ("value", value),
      ],
      logFields(logs),
    ),
  )

let subscriptionErrorEvent = (subscriptionId, error: ConvexError.t) =>
  ConvexJson.object_(
    Js.Array2.concat(
      [
        ("type", Js.Json.string("subscription")),
        ("subscriptionId", Js.Json.string(subscriptionId)),
        ("error", errorJson(error)),
      ],
      logFields(error.logs),
    ),
  )

type lineReader = {
  mutable buffer: string,
  mutable overflowed: bool,
}

let makeLineReader = () => {buffer: "", overflowed: false}

// Splits NDJSON without ever holding more than one bounded line. A command
// that never terminates is a protocol failure, not a reason to keep buffering.
let feedLineReader = (reader, chunk, onLine, onOverflow) =>
  if !reader.overflowed {
    if (
      ConvexNode.utf8ByteLength(reader.buffer) + ConvexNode.utf8ByteLength(chunk) > maximumLineBytes
    ) {
      reader.overflowed = true
      reader.buffer = ""
      onOverflow()
    } else {
      reader.buffer = reader.buffer ++ chunk
    }
    let scanning = ref(true)
    while scanning.contents && !reader.overflowed {
      switch Js.String2.indexOf(reader.buffer, "\n") {
      | -1 => {
          if ConvexNode.utf8ByteLength(reader.buffer) > maximumLineBytes {
            reader.overflowed = true
            reader.buffer = ""
            onOverflow()
          }
          scanning := false
        }
      | index => {
          let line = Js.String2.slice(reader.buffer, ~from=0, ~to_=index)
          reader.buffer = Js.String2.sliceToEnd(reader.buffer, ~from=index + 1)
          let trimmed = Js.String2.trim(line)
          if trimmed != "" {
            onLine(trimmed)
          }
        }
      }
    }
  }

type command = {
  id: option<string>,
  op: string,
  commandProtocolVersion: option<int>,
  path: string,
  args: Js.Json.t,
  subscriptionId: option<string>,
  token: string,
}

// The shared protocol schema is intentionally tiny, so validating it at the
// boundary is clearer and safer than coercing arbitrary JSON into a partially
// filled command. `Array.from` measures Unicode code points, matching JSON
// Schema's string length rather than JavaScript UTF-16 code units.
let commandSchemaError: Js.Json.t => Js.Nullable.t<string> = %raw(`function (value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return "adapter command must be an object";
  }
  const op = value.op;
  if (typeof op !== "string") return "adapter command requires a string op";
  const shapes = {
    hello: {required: ["protocolVersion", "id", "op"], allowed: ["protocolVersion", "id", "op"]},
    query: {required: ["id", "op", "path", "args"], allowed: ["id", "op", "path", "args"]},
    mutation: {required: ["id", "op", "path", "args"], allowed: ["id", "op", "path", "args"]},
    action: {required: ["id", "op", "path", "args"], allowed: ["id", "op", "path", "args"]},
    subscribe: {required: ["id", "op", "subscriptionId"], allowed: ["id", "op", "subscriptionId", "path", "args"]},
    unsubscribe: {required: ["id", "op", "subscriptionId"], allowed: ["id", "op", "subscriptionId", "path", "args"]},
    setAuth: {required: ["id", "op", "token"], allowed: ["id", "op", "token"]},
    close: {required: ["id", "op"], allowed: ["id", "op"]},
    debugDisconnect: {required: ["id", "op"], allowed: ["id", "op"]},
  };
  const shape = Object.prototype.hasOwnProperty.call(shapes, op) ? shapes[op] : null;
  if (!shape) return "unknown operation " + op;
  for (const key of Object.keys(value)) {
    if (!shape.allowed.includes(key)) return "unexpected command field " + key;
  }
  for (const key of shape.required) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) return "missing command field " + key;
  }
  const validId = id => typeof id === "string" && id.trim().length > 0 && Array.from(id).length <= 128;
  if (!validId(value.id)) return "id must be nonblank and contain at most 128 Unicode code points";
  if (value.subscriptionId !== undefined && !validId(value.subscriptionId)) {
    return "subscriptionId must be nonblank and contain at most 128 Unicode code points";
  }
  if (op === "hello" && value.protocolVersion !== 1) return "hello requires protocolVersion 1";
  if (["query", "mutation", "action"].includes(op)) {
    if (typeof value.path !== "string" || Array.from(value.path).length < 3) return "call path is invalid";
    if (value.args === null || typeof value.args !== "object" || Array.isArray(value.args)) return "call args must be an object";
  }
  if (value.path !== undefined && typeof value.path !== "string") return "path must be a string";
  if (value.args !== undefined && (value.args === null || typeof value.args !== "object" || Array.isArray(value.args))) return "args must be an object";
  if (value.token !== undefined && typeof value.token !== "string") return "token must be a string";
  return null;
}`)

let safeCommandId: Js.Json.t => Js.Nullable.t<string> = %raw(`function (value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const id = value.id;
  return typeof id === "string" && id.trim().length > 0 && Array.from(id).length <= 128
    ? id
    : null;
}`)

let decodeCommand = json => {
  id: ConvexJson.stringField(json, "id"),
  op: ConvexJson.stringFieldOr(json, "op", ""),
  commandProtocolVersion: ConvexJson.intField(json, "protocolVersion"),
  path: ConvexJson.stringFieldOr(json, "path", ""),
  args: switch ConvexJson.field(json, "args") {
  | Some(args) => args
  | None => ConvexJson.emptyObject()
  },
  subscriptionId: ConvexJson.stringField(json, "subscriptionId"),
  token: ConvexJson.stringFieldOr(json, "token", ""),
}

// A relay forwards one subscription's updates. The generation and the valid
// flag exist so an update dequeued just before an unsubscribe or a same-id
// replacement is discarded instead of crossing the acknowledgement.
type relay = {
  subscriptionId: string,
  generation: int,
  subscription: ConvexLive.subscription,
  mutable valid: bool,
}

type adapter = {
  output: output,
  environment: Js.Dict.t<string>,
  // Client options are injected so tests can supply a scripted Live transport
  // without changing how the shipped adapter builds its client.
  options: Convex.options,
  relays: Js.Dict.t<relay>,
  mutable client: option<Convex.t>,
  mutable chain: promise<unit>,
  mutable nextRelayGeneration: int,
  mutable stopped: bool,
  // Test-only barrier between dequeueing an update and publishing it.
  afterDequeue: (string, int) => promise<unit>,
  onFinished: unit => unit,
}

let noAfterDequeue = (_subscriptionId, _generation) => ConvexNode.resolvedPromise()

let makeAdapter = (~stream, ~environment, ~options, ~afterDequeue, ~onFinished) => {
  let output = makeOutput(stream)
  let adapter = {
    output,
    environment,
    options,
    relays: Js.Dict.empty(),
    client: None,
    chain: ConvexNode.resolvedPromise(),
    nextRelayGeneration: 0,
    stopped: false,
    afterDequeue,
    onFinished,
  }
  output.onExhausted = () => {
    ConvexNode.setExitCode(1)
    adapter.stopped = true
    // A controller that stopped reading cannot be drained. Destroying this
    // one transport is what makes the 1 second stopped-reader deadline real;
    // stderr already contains the fatal diagnostic.
    ConvexNode.destroyWritable(output.stream)
    Js.Array2.forEach(Js.Dict.values(adapter.relays), relay => relay.valid = false)
    let cleanup = async () => {
      switch adapter.client {
      | Some(client) => await Convex.close(client)
      | None => ()
      }
      adapter.onFinished()
    }
    ConvexNode.catchError(cleanup(), error =>
      ConvexNode.logDiagnostic(
        "adapter exhaustion cleanup failed: " ++ ConvexError.fromException(error).message,
      )
    )
  }
  adapter
}

let getClient = adapter =>
  switch adapter.client {
  | Some(client) => client
  | None =>
    switch Js.Dict.get(adapter.environment, "CONVEX_URL") {
    | None
    | Some("") =>
      ConvexError.raiseError(ConvexError.usage("CONVEX_URL is required"))
    | Some(url) => {
        let token = switch Js.Dict.get(adapter.environment, "CONVEX_AUTH_TOKEN") {
        | Some(value) => value
        | None => ""
        }
        let client = Convex.makeWithOptions(url, {...adapter.options, authToken: token})
        adapter.client = Some(client)
        client
      }
    }
  }

let publishUpdate = (adapter, relay, update) =>
  switch update {
  | ConvexLive.Value({value, logs}) =>
    writeEvent(adapter.output, subscriptionValueEvent(relay.subscriptionId, value, logs))
  | ConvexLive.Failure(error) =>
    writeEvent(adapter.output, subscriptionErrorEvent(relay.subscriptionId, error))
  }

let forwardRelay = async (adapter, relay) => {
  let running = ref(true)
  while running.contents && relay.valid {
    let update = await ConvexLive.next(relay.subscription)
    // Deterministic tests pause here, between dequeue and publish, to prove
    // that an already-dequeued event cannot cross an unsubscribe or a
    // replacement acknowledgement.
    await adapter.afterDequeue(relay.subscriptionId, relay.generation)
    if !relay.valid {
      running := false
    } else {
      switch update {
      | None => running := false
      | Some(value) => publishUpdate(adapter, relay, value)
      }
    }
  }
}

// Retires a relay before anything is acknowledged, then stops the underlying
// subscription.
let retireRelay = async (adapter, subscriptionId) =>
  switch Js.Dict.get(adapter.relays, subscriptionId) {
  | None => ()
  | Some(relay) => {
      relay.valid = false
      ConvexNode.removeKey(adapter.relays, subscriptionId)
      await ConvexLive.closeSubscription(relay.subscription)
    }
  }

let retireAllRelays = async adapter => {
  let ids = Js.Dict.keys(adapter.relays)
  // Invalidate every relay first, so nothing can be published while the
  // remaining subscriptions are being closed.
  Js.Array2.forEach(ids, id =>
    switch Js.Dict.get(adapter.relays, id) {
    | Some(relay) => relay.valid = false
    | None => ()
    }
  )
  let index = ref(0)
  while index.contents < Js.Array2.length(ids) {
    await retireRelay(adapter, Js.Array2.unsafe_get(ids, index.contents))
    index := index.contents + 1
  }
}

let handleHello = (adapter, command) =>
  switch command.commandProtocolVersion {
  | Some(version) if version == protocolVersion =>
    switch command.id {
    | Some(id) => writeEvent(adapter.output, readyEvent(id))
    | None => ConvexError.raiseError(ConvexError.usage("hello requires a request id"))
    }
  | Some(version) =>
    ConvexError.raiseError(
      ConvexError.usage("unsupported adapter protocol version " ++ Belt.Int.toString(version)),
    )
  | None => ConvexError.raiseError(ConvexError.usage("hello requires protocolVersion 1"))
  }

let requireId = command =>
  switch command.id {
  | Some(id) => id
  | None => ConvexError.raiseError(ConvexError.usage("command requires a request id"))
  }

// `command` and `relay` both have a `subscriptionId` field (option<string>
// on one, string on the other); without this annotation the compiler
// resolves the unqualified field access against whichever type was
// declared closer by, not necessarily this parameter's real type.
let requireSubscriptionId = (command: command) =>
  switch command.subscriptionId {
  | Some(id) => id
  | None => ConvexError.raiseError(ConvexError.usage("subscriptionId is required"))
  }

let handleCall = async (adapter, command, operation) => {
  let id = requireId(command)
  let result = await Convex.call(getClient(adapter), operation, command.path, command.args)
  writeEvent(adapter.output, resultEvent(id, result.value, result.logs))
}

let handleSubscribe = async (adapter, command) => {
  let id = requireId(command)
  let subscriptionId = requireSubscriptionId(command)
  // A repeated subscription id replaces the old one. The old relay is
  // invalidated before the new subscription exists, so no stale value can be
  // attributed to the replacement.
  await retireRelay(adapter, subscriptionId)
  let subscription = await Convex.subscribe(getClient(adapter), command.path, command.args)
  let generation = adapter.nextRelayGeneration
  adapter.nextRelayGeneration = generation + 1
  let relay = {subscriptionId, generation, subscription, valid: true}
  Js.Dict.set(adapter.relays, subscriptionId, relay)
  writeEvent(adapter.output, ackEvent(id, "ack"))
  // The relay runs beside the command chain; it must never block it.
  ConvexNode.catchError(forwardRelay(adapter, relay), error => {
    if relay.valid {
      relay.valid = false
      ConvexNode.removeKey(adapter.relays, subscriptionId)
      writeEvent(
        adapter.output,
        subscriptionErrorEvent(subscriptionId, ConvexError.fromException(error)),
      )
    }
  })
}

let handleUnsubscribe = async (adapter, command) => {
  let id = requireId(command)
  await retireRelay(adapter, requireSubscriptionId(command))
  writeEvent(adapter.output, ackEvent(id, "ack"))
}

let handleSetAuth = (adapter, command) => {
  let id = requireId(command)
  Convex.setAuth(getClient(adapter), command.token)
  writeEvent(adapter.output, ackEvent(id, "ack"))
}

let handleDebugDisconnect = async (adapter, command) => {
  let id = requireId(command)
  // Fault injection belongs to the conformance adapter, not the educational
  // client API. The adapter can reach the client's owned Live manager because
  // it is compiled in the same source package.
  switch getClient(adapter).live {
  | None => ConvexError.raiseError(ConvexError.protocol("Live WebSocket has not been started"))
  | Some(manager) => await ConvexLive.debugDisconnect(manager)
  }
  writeEvent(adapter.output, ackEvent(id, "ack"))
}

let handleClose = async (adapter, command) => {
  let id = requireId(command)
  await retireAllRelays(adapter)
  switch adapter.client {
  | Some(client) => await Convex.close(client)
  | None => ()
  }
  writeEvent(adapter.output, ackEvent(id, "closed"))
  if !adapter.stopped {
    adapter.stopped = true
    adapter.onFinished()
  }
}

let dispatch = async (adapter, command) =>
  switch command.op {
  | "hello" => handleHello(adapter, command)
  | "query" => await handleCall(adapter, command, ConvexHttp.Query)
  | "mutation" => await handleCall(adapter, command, ConvexHttp.Mutation)
  | "action" => await handleCall(adapter, command, ConvexHttp.Action)
  | "subscribe" => await handleSubscribe(adapter, command)
  | "unsubscribe" => await handleUnsubscribe(adapter, command)
  | "setAuth" => handleSetAuth(adapter, command)
  | "debugDisconnect" => await handleDebugDisconnect(adapter, command)
  | "close" => await handleClose(adapter, command)
  | other => ConvexError.raiseError(ConvexError.usage("unknown operation " ++ other))
  }

// Commands are chained, so the controller sees exactly the ordering it sent
// even though each command is asynchronous.
let submit = (adapter, task) => {
  let previous = adapter.chain
  let run = async () => {
    try {
      await previous
    } catch {
    | _ => ()
    }
    await task()
  }
  adapter.chain = run()
}

let handleLine = (adapter, line) =>
  submit(adapter, async () =>
    switch ConvexJson.parse(line) {
    | Error(message) =>
      writeEvent(
        adapter.output,
        errorEvent(None, ConvexError.protocol("invalid adapter command: " ++ message)),
      )
    | Ok(json) =>
      switch Js.Nullable.toOption(commandSchemaError(json)) {
      | Some(message) =>
        // Echo only an independently validated id. This keeps useful
        // correlation for another schema error without allowing a wrong-type
        // or overlong id to create a schema-invalid event.
        writeEvent(
          adapter.output,
          errorEvent(Js.Nullable.toOption(safeCommandId(json)), ConvexError.protocol(message)),
        )
      | None => {
          let command = decodeCommand(json)
          try {
            await dispatch(adapter, command)
          } catch {
          | error =>
            writeEvent(adapter.output, errorEvent(command.id, ConvexError.fromException(error)))
          }
        }
      }
    }
  )

let reportOverflow = adapter =>
  writeEvent(
    adapter.output,
    errorEvent(
      None,
      ConvexError.protocol(
        "adapter command exceeded " ++ Belt.Int.toString(maximumLineBytes) ++ " bytes",
      ),
    ),
  )

let stopAfterInputEnds = async adapter => {
  if !adapter.stopped {
    adapter.stopped = true
    await retireAllRelays(adapter)
    switch adapter.client {
    | Some(client) => await Convex.close(client)
    | None => ()
    }
    adapter.onFinished()
  }
}

// Wires a readable stream into the adapter. Both transports use this, so the
// stdio and TCP modes share one implementation and one set of bounds.
let attachInput = (adapter, input) => {
  let reader = makeLineReader()
  ConvexNode.setEncoding(input, "utf8")
  ConvexNode.onData(input, "data", chunk =>
    feedLineReader(
      reader,
      chunk,
      line => handleLine(adapter, line),
      () => {
        reportOverflow(adapter)
        ConvexNode.setExitCode(1)
        ConvexNode.destroyReadable(input)
        submit(adapter, () => stopAfterInputEnds(adapter))
      },
    )
  )
  ConvexNode.onStreamEnd(input, "end", () =>
    if !adapter.stopped {
      submit(adapter, () => stopAfterInputEnds(adapter))
    }
  )
}

let parseListenAddress = value => {
  let separator = Js.String2.lastIndexOf(value, ":")
  if separator < 1 {
    Error("ADAPTER_LISTEN must use host:port")
  } else {
    let host = Js.String2.slice(value, ~from=0, ~to_=separator)
    let portText = Js.String2.sliceToEnd(value, ~from=separator + 1)
    switch Belt.Int.fromString(portText) {
    | Some(port) if port >= 0 && port <= 65535 => Ok((host, port))
    | _ => Error("ADAPTER_LISTEN must use host:port")
    }
  }
}

let runStdio = () => {
  let adapter = makeAdapter(
    ~stream=ConvexNode.stdout,
    ~environment=ConvexNode.environment,
    ~options=Convex.defaultOptions,
    ~afterDequeue=noAfterDequeue,
    ~onFinished=() => ConvexNode.destroyReadable(ConvexNode.stdin),
  )
  attachInput(adapter, ConvexNode.stdin)
  adapter
}

// The isolated Docker harness keeps the controller and the client in separate
// containers, so the same NDJSON stream is carried over one accepted TCP
// connection instead of stdio.
let runTcp = address =>
  switch parseListenAddress(address) {
  | Error(message) => ConvexError.raiseError(ConvexError.usage(message))
  | Ok((host, port)) => {
      let serverRef = ref(None)
      let accepted = ref(false)
      let acceptTimer = ref(None)
      let server = ConvexNode.createServer(socket => {
        if accepted.contents {
          ConvexNode.destroySocket(socket)
        } else {
          accepted := true
          switch acceptTimer.contents {
          | Some(timer) => ConvexNode.clearTimeout(timer)
          | None => ()
          }
          // Exactly one controller connection is expected. The boolean closes
          // the small asynchronous listener-close window as well.
          switch serverRef.contents {
          | Some(listener) => ConvexNode.closeServer(listener, () => ())
          | None => ()
          }
          let adapter = makeAdapter(
            ~stream=ConvexNode.socketWritable(socket),
            ~environment=ConvexNode.environment,
            ~options=Convex.defaultOptions,
            ~afterDequeue=noAfterDequeue,
            ~onFinished=() => ConvexNode.endSocket(socket),
          )
          attachInput(adapter, ConvexNode.socketReadable(socket))
        }
      })
      serverRef := Some(server)
      ConvexNode.listen(server, port, host)
      acceptTimer := Some(ConvexNode.setTimeout(() => {
            if !accepted.contents {
              ConvexNode.logDiagnostic(
                "adapter controller did not connect before the accept deadline",
              )
              ConvexNode.setExitCode(1)
              ConvexNode.closeServer(server, () => ())
            }
          }, tcpAcceptDeadlineMs))
      server
    }
  }

let main = () => {
  let listenAddress = switch Js.Dict.get(ConvexNode.environment, "ADAPTER_LISTEN") {
  | Some(value) => value
  | None => ""
  }
  if listenAddress == "" {
    let _ = runStdio()
  } else {
    let _ = runTcp(listenAddress)
  }
}
