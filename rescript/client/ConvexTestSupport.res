// Bindings and fixtures used only by the language-local tests. Nothing in the
// shipped client or the adapter imports this module, and the runtime images do
// not copy it.

@module("node:test") external test: (string, unit => promise<unit>) => unit = "test"

@module("node:assert/strict") external equal: ('a, 'a) => unit = "equal"
@module("node:assert/strict") external deepEqual: ('a, 'a) => unit = "deepEqual"
@module("node:assert/strict") external ok: (bool, string) => unit = "ok"
@module("node:assert/strict") external fail: string => unit = "fail"

// Deliberately a referenced timer, not unref'd: this drives polling loops
// such as `waitForSocket` where it is often the only pending handle left. An
// unref'd timer that is the sole outstanding work item never gets a turn --
// Node's event loop is free to conclude there is nothing left to do and the
// test runner cancels every remaining test in the file with a generic
// "Promise resolution is still pending but the event loop has already
// resolved" error instead of letting the wait complete.
let delay = milliseconds =>
  ConvexNode.makePromise((resolve, _reject) => {
    let _ = ConvexNode.setTimeout(() => resolve(), milliseconds)
  })

// Lets a test observe a rejection without letting it fail the test run.
let failureOf = async work =>
  try {
    let _ = await work()
    None
  } catch {
  | error => Some(ConvexError.fromException(error))
  }

let expectFailure = async (work, label) =>
  switch await failureOf(work) {
  | Some(error) => error
  | None => {
      fail(label ++ " unexpectedly succeeded")
      ConvexError.transport("unreachable")
    }
  }

// A one-shot barrier a test can hold open and then release, used to pause a
// relay in the exact window between dequeueing an update and publishing it.
type gate = {
  wait: unit => promise<unit>,
  release: unit => unit,
  entered: unit => bool,
}

let makeGate = () => {
  let deferred = ConvexNode.Deferred.make()
  let entered = ref(false)
  {
    wait: () => {
      entered := true
      deferred.promise
    },
    release: () => deferred.resolve(),
    entered: () => entered.contents,
  }
}

let jsonObject = entries => ConvexJson.object_(entries)
let jsonString = value => Js.Json.string(value)
let jsonNumber = value => Js.Json.number(value)

// A real local HTTP server, so the transport tests exercise fetch, headers,
// and status handling rather than a stubbed request function.
type httpServer
type httpRequest
type httpResponse
type addressInfo = {port: int}

@module("node:http")
external createHttpServer: ((httpRequest, httpResponse) => unit) => httpServer = "createServer"

@send external httpListen: (httpServer, int, string, unit => unit) => unit = "listen"
@send external httpClose: (httpServer, unit => unit) => unit = "close"

// fetch keeps connections alive, so a test server has to drop them to stop.
@send external httpCloseConnections: httpServer => unit = "closeAllConnections"
@send external httpAddress: httpServer => addressInfo = "address"
@get external requestUrl: httpRequest => string = "url"
@get external requestHeaders: httpRequest => Js.Dict.t<string> = "headers"
@send external requestSetEncoding: (httpRequest, string) => unit = "setEncoding"
@send external onRequestData: (httpRequest, string, string => unit) => unit = "on"
@send external onRequestEnd: (httpRequest, string, unit => unit) => unit = "on"
@set external setStatusCode: (httpResponse, int) => unit = "statusCode"
@send external setResponseHeader: (httpResponse, string, string) => unit = "setHeader"
@send external endResponse: (httpResponse, string) => unit = "end"

type testServer = {
  url: string,
  stop: unit => promise<unit>,
}

let startHttpServer = async handler => {
  let server = createHttpServer((request, response) => {
    requestSetEncoding(request, "utf8")
    let body = ref("")
    onRequestData(request, "data", chunk => body := body.contents ++ chunk)
    onRequestEnd(request, "end", () => handler(request, response, body.contents))
  })
  await ConvexNode.makePromise((resolve, _reject) =>
    httpListen(server, 0, "127.0.0.1", () => resolve())
  )
  {
    url: "http://127.0.0.1:" ++ Belt.Int.toString(httpAddress(server).port),
    stop: () =>
      ConvexNode.makePromise((resolve, _reject) => {
        httpCloseConnections(server)
        httpClose(server, () => resolve())
      }),
  }
}

// A real WebSocket server, used by the example test so the canonical example
// is exercised end to end over a socket rather than a stub.
type webSocketServer
type webSocketServerOptions = {
  server: httpServer,
  path: string,
}

@module("ws") @new
external makeWebSocketServer: webSocketServerOptions => webSocketServer = "WebSocketServer"

@send
external onWebSocketConnection: (webSocketServer, string, ConvexNode.webSocket => unit) => unit =
  "on"

@send external closeWebSocketServer: (webSocketServer, unit => unit) => unit = "close"

// Spawning the compiled example is the only way to prove what it prints on
// stdout, which is the shared happy-path test surface.
type childProcess
type spawnOptions = {
  env: Js.Dict.t<string>,
  stdio: array<string>,
}

@module("node:child_process")
external spawn: (string, array<string>, spawnOptions) => childProcess = "spawn"

@get external childStdout: childProcess => ConvexNode.readable = "stdout"
@get external childStderr: childProcess => ConvexNode.readable = "stderr"

type exitHandler = (Js.Nullable.t<int>, Js.Nullable.t<string>) => unit

@send external onChildExit: (childProcess, string, exitHandler) => unit = "on"

@val @scope("process") external execPath: string = "execPath"
@val @scope("process") external processEnvironment: Js.Dict.t<string> = "env"

let respondJson = (response, status, payload) => {
  setStatusCode(response, status)
  setResponseHeader(response, "content-type", "application/json")
  endResponse(response, payload)
}

// Sends progress forever without completing a body. The bounded-fetch fixture
// uses this to prove its deadline is absolute rather than reset by each chunk.
let dripResponse: httpResponse => unit = %raw(`function (response) {
  response.statusCode = 200;
  response.setHeader("content-type", "application/json");
  const timer = setInterval(() => response.write(" "), 10);
  response.on("close", () => clearInterval(timer));
}`)

// A writable stream that records what the adapter wrote and, crucially, only
// releases the runtime's flush callbacks when a test asks it to. That is how a
// stopped controller is simulated.
type collector = {
  stream: ConvexNode.writable,
  written: unit => array<string>,
  flush: unit => unit,
  pending: unit => int,
}

// Inside a %raw JS template literal, "\\n" is the two-character sequence
// backslash-n, not a newline, so `written` below used to never split
// anything: every test that read back more than one written record saw one
// unparseable blob instead. writeEvent really does terminate each record
// with a genuine newline, so splitting on a plain "\n" is what matches the
// wire format.
let makeCollector: unit => collector = %raw(`function () {
  const chunks = [];
  const callbacks = [];
  const stream = {
    write(text, callback) {
      chunks.push(text);
      if (typeof callback === "function") {
        callbacks.push(callback);
      }
      return true;
    },
    destroy() {},
  };
  return {
    stream,
    written: () => chunks.join("").split("\n").filter((line) => line.length > 0),
    flush: () => {
      while (callbacks.length > 0) {
        callbacks.shift()();
      }
    },
    pending: () => callbacks.length,
  };
}`)

// A readable stream a test can push NDJSON into, standing in for stdin or an
// accepted TCP connection.
type feeder = {
  input: ConvexNode.readable,
  push: string => unit,
  finish: unit => unit,
  destroyed: unit => bool,
}

let makeFeeder: unit => feeder = %raw(`function () {
  const handlers = { data: [], end: [] };
  let destroyed = false;
  const input = {
    setEncoding() {},
    on(event, handler) {
      if (handlers[event]) handlers[event].push(handler);
      return input;
    },
    destroy() {
      destroyed = true;
    },
  };
  return {
    input,
    push: (chunk) => {
      for (const handler of handlers.data.slice()) handler(chunk);
    },
    finish: () => {
      for (const handler of handlers.end.slice()) handler();
    },
    destroyed: () => destroyed,
  };
}`)

// A scripted WebSocket transport. Tests drive the handshake, deliver server
// messages, and inspect exactly what the Live owner wrote, with no network and
// no timing assumptions.
type fakeSocket = {
  sent: array<string>,
  mutable terminated: bool,
  mutable gracefulClose: bool,
  handlers: ConvexLive.connectionHandlers,
}

type fakeTransport = {
  transport: ConvexLive.transport,
  sockets: array<fakeSocket>,
  failNextConnect: ref<bool>,
}

let makeFakeTransport = () => {
  let sockets = []
  let failNextConnect = ref(false)
  let connect = (_url, _clientVersion, handlers) => {
    if failNextConnect.contents {
      failNextConnect := false
      Js.Exn.raiseError("connect refused")
    }
    let socket = {sent: [], terminated: false, gracefulClose: false, handlers}
    let _ = Js.Array2.push(sockets, socket)
    let connection: ConvexLive.connection = {
      send: text => {
        if socket.terminated {
          Js.Exn.raiseError("socket is closed")
        }
        let _ = Js.Array2.push(socket.sent, text)
      },
      terminate: () => socket.terminated = true,
      closeGracefully: () => socket.gracefulClose = true,
    }
    connection
  }
  {transport: {connect: connect}, sockets, failNextConnect}
}

let latestSocket = fake => {
  let count = Js.Array2.length(fake.sockets)
  count == 0 ? None : Some(Js.Array2.unsafe_get(fake.sockets, count - 1))
}

let openSocket = socket => socket.handlers.onOpen()
let deliver = (socket, text) => socket.handlers.onMessage(text)
let dropSocket = (socket, reason) => socket.handlers.onClosed(reason)

let sentMessages = socket =>
  Js.Array2.map(socket.sent, text =>
    switch ConvexJson.parse(text) {
    | Ok(json) => json
    | Error(_) => ConvexJson.emptyObject()
    }
  )

let messageTypes = socket =>
  Js.Array2.map(sentMessages(socket), json => ConvexJson.stringFieldOr(json, "type", "?"))

let lastMessage = socket => {
  let messages = sentMessages(socket)
  let count = Js.Array2.length(messages)
  count == 0 ? None : Some(Js.Array2.unsafe_get(messages, count - 1))
}

// Builds a Transition the pinned profile accepts, so tests exercise the real
// decoder rather than a convenient shortcut. A version is (querySet,
// timestamp); identity is always zero because this client does not send auth
// over the socket.
let versionJson = version => {
  let (querySet, ts) = version
  ConvexJson.object_([
    ("querySet", Js.Json.number(Belt.Int.toFloat(querySet))),
    ("identity", Js.Json.number(0.0)),
    ("ts", Js.Json.string(ts)),
  ])
}

let transitionJson = (~from, ~to_, ~modifications) =>
  ConvexJson.object_([
    ("type", Js.Json.string("Transition")),
    ("startVersion", versionJson(from)),
    ("endVersion", versionJson(to_)),
    ("modifications", Js.Json.array(modifications)),
  ])

let queryUpdated = (~queryId, ~value) =>
  ConvexJson.object_([
    ("type", Js.Json.string("QueryUpdated")),
    ("queryId", Js.Json.number(Belt.Int.toFloat(queryId))),
    ("value", value),
  ])

let queryFailed = (~queryId, ~message, ~code) =>
  ConvexJson.object_([
    ("type", Js.Json.string("QueryFailed")),
    ("queryId", Js.Json.number(Belt.Int.toFloat(queryId))),
    ("errorMessage", Js.Json.string(message)),
    ("errorData", ConvexJson.object_([("code", Js.Json.string(code))])),
  ])

let countValue = count => ConvexJson.object_([("count", Js.Json.number(count))])

// Protocol timestamps are opaque base64 of a little-endian unsigned 64-bit
// value, so tests build them the same way a server would.
let timestampFor: int => string = %raw(`function (value) {
  const bytes = Buffer.alloc(8);
  bytes.writeUInt32LE(value, 0);
  return bytes.toString("base64");
}`)

let timestampOne = timestampFor(1)
let timestampTwo = timestampFor(2)

// The version every fresh connection starts from.
let startVersion = (0, ConvexProtocol.initialTimestamp)

let sendTransition = (socket, ~from, ~to_, ~modifications) =>
  deliver(socket, ConvexJson.stringify(transitionJson(~from, ~to_, ~modifications)))

// Reconnects are driven by real timers, so tests wait for the owner to make
// the next connection rather than assuming when it happens.
let waitForSocket = async (fake, count) => {
  let attempts = ref(0)
  while Js.Array2.length(fake.sockets) < count && attempts.contents < 400 {
    await delay(5)
    attempts := attempts.contents + 1
  }
  switch latestSocket(fake) {
  | Some(socket) if Js.Array2.length(fake.sockets) >= count => socket
  | _ => {
      fail("expected connection " ++ Belt.Int.toString(count) ++ " was never made")
      Js.Exn.raiseError("expected connection " ++ Belt.Int.toString(count) ++ " was never made")
    }
  }
}

// Completes a handshake the way a Convex backend would: accept the socket, let
// the client send Connect and its query set, then confirm.
let handshake = async (fake, count) => {
  let socket = await waitForSocket(fake, count)
  openSocket(socket)
  socket
}
