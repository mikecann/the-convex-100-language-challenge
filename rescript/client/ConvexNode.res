// Every JavaScript value this client borrows from its host runtime is declared
// here, so the delegated surface stays small and auditable: fetch for HTTP,
// `ws` for WebSocket framing, Node streams for the adapter transport, and
// timers. All Convex behaviour lives in the other ReScript modules.

type timer

@val external setTimeout: (unit => unit, int) => timer = "setTimeout"
@val external clearTimeout: timer => unit = "clearTimeout"

// Node keeps the event loop alive for a pending timer. Cleanup fallbacks and
// example-only deadlines are unreferenced; active reconnect and heartbeat
// timers deliberately stay referenced until their owner is closed.
@send external unrefTimer: timer => timer = "unref"

@val @scope("process") external argv: array<string> = "argv"
@val @scope("process") external environment: Js.Dict.t<string> = "env"
@val @scope("process") external exitProcess: int => unit = "exit"
let setExitCode: int => unit = %raw(`function (code) { process.exitCode = code; }`)
@val @scope(("process", "versions")) external nodeVersion: string = "node"

type writable
type readable

@val @scope("process") external stdout: writable = "stdout"
@val @scope("process") external stderr: writable = "stderr"
@val @scope("process") external stdin: readable = "stdin"

@send external write: (writable, string) => bool = "write"

// The two-argument form reports when the runtime has actually flushed a chunk.
// The adapter uses it to keep its own outstanding-byte budget honest.
@send external writeThen: (writable, string, unit => unit) => bool = "write"
@send external destroyWritable: writable => unit = "destroy"

@send external setEncoding: (readable, string) => unit = "setEncoding"
@send external onData: (readable, string, string => unit) => unit = "on"
@send external onStreamEnd: (readable, string, unit => unit) => unit = "on"
@send external destroyReadable: readable => unit = "destroy"

type socket
type server

@module("node:net") external createServer: (socket => unit) => server = "createServer"
@send external listen: (server, int, string) => unit = "listen"
@send external closeServer: (server, unit => unit) => unit = "close"
@send external destroySocket: socket => unit = "destroy"

// `end` flushes what is already queued and then closes the connection, so a
// final protocol event is never truncated by a shutdown.
@send external endSocket: socket => unit = "end"
@send external onSocketEvent: (socket, string, unit => unit) => unit = "on"

// A Node TCP socket is both a readable and a writable stream. These casts are
// free at runtime and keep the stream helpers above usable for TCP mode.
external socketReadable: socket => readable = "%identity"
external socketWritable: socket => writable = "%identity"

type jsError

@get external errorMessageOption: jsError => Js.Nullable.t<string> = "message"

let errorMessage = (error: jsError) =>
  switch Js.Nullable.toOption(errorMessageOption(error)) {
  | Some(message) => message
  | None => "unknown error"
  }

@val @scope("Buffer") external byteLengthOf: (string, string) => int = "byteLength"

let utf8ByteLength = (value: string) => byteLengthOf(value, "utf8")

// Named `nodeBytes`, not `bytes`: the compiler reserves `bytes` as a
// built-in type and refuses to let a project redefine it.
type nodeBytes

@val @scope("Buffer") external bufferFrom: (string, string) => nodeBytes = "from"
@get external bytesLength: nodeBytes => int = "length"
@get_index external byteAt: (nodeBytes, int) => int = ""
@send external bytesToString: (nodeBytes, string) => string = "toString"

@module("node:crypto") external randomUUID: unit => string = "randomUUID"

type hash
@module("node:crypto") external createHash: string => hash = "createHash"
@send external updateHash: (hash, string) => hash = "update"
@send external digestHash: (hash, string) => string = "digest"

let sha256Text = value => digestHash(updateHash(createHash("sha256"), value), "hex")

type fetchRequest = {
  method: string,
  headers: Js.Dict.t<string>,
  body: string,
}

type boundedFetchResponse = {
  status: int,
  text: string,
}

// Fetch's `response.text()` buffers the whole body before the caller can apply
// a limit. Keep the small amount of JavaScript needed to drive the delegated
// Web Streams API at this runtime boundary instead. The limit is charged from
// raw bytes before decoding or concatenating them, and one absolute deadline
// covers connection, headers, and every body chunk.
let boundedFetch: (string, fetchRequest, int, int) => promise<boundedFetchResponse> = %raw(`
  async function boundedFetch(url, request, maximumBytes, deadlineMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error("HTTP deadline exceeded")), deadlineMs);
    try {
      const response = await fetch(url, {...request, signal: controller.signal});
      if (response.status < 200 || response.status >= 300) {
        if (response.body != null) await response.body.cancel("non-success HTTP status");
        return {status: response.status, text: ""};
      }
      if (response.body == null) {
        return {status: response.status, text: ""};
      }
      const reader = response.body.getReader();
      const decoder = new TextDecoder("utf-8", {fatal: true});
      const chunks = [];
      let bytes = 0;
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        bytes += part.value.byteLength;
        if (bytes > maximumBytes) {
          await reader.cancel("response exceeds byte limit");
          throw new Error("HTTP response exceeds " + maximumBytes + " bytes");
        }
        chunks.push(decoder.decode(part.value, {stream: true}));
      }
      chunks.push(decoder.decode());
      return {status: response.status, text: chunks.join("")};
    } finally {
      clearTimeout(timer);
    }
  }
`)

type webSocket
type webSocketOptions = {
  headers: Js.Dict.t<string>,
  handshakeTimeout: int,
  maxPayload: int,
}

@module("ws") @new
external makeWebSocket: (string, webSocketOptions) => webSocket = "WebSocket"

@send external webSocketSend: (webSocket, string) => unit = "send"
@send external webSocketPing: webSocket => unit = "ping"
@send external webSocketClose: (webSocket, int, string) => unit = "close"

// `terminate` drops the TCP connection without a closing handshake. It is the
// only honest way to simulate a network failure from the client side.
@send external webSocketTerminate: webSocket => unit = "terminate"

@send external webSocketOnOpen: (webSocket, string, unit => unit) => unit = "on"
@send external webSocketOnMessage: (webSocket, string, nodeBytes => unit) => unit = "on"
@send external webSocketOnClose: (webSocket, string, (int, nodeBytes) => unit) => unit = "on"
@send external webSocketOnError: (webSocket, string, jsError => unit) => unit = "on"
@send external webSocketOnPong: (webSocket, string, unit => unit) => unit = "on"

@new external makePromise: (('a => unit, exn => unit) => unit) => promise<'a> = "Promise"
@val @scope("Promise") external resolvedPromise: 'a => promise<'a> = "resolve"
@val @scope("Promise") external race: array<promise<'a>> => promise<'a> = "race"

// Used where a rejection must become an exit code rather than an unhandled
// rejection warning.
@send external catchError: (promise<'a>, exn => unit) => unit = "catch"

// A promise plus the two functions that settle it. The Live owner and the
// adapter hand these out so a caller can await work that is completed later by
// a socket event rather than by the calling stack.
module Deferred = {
  type t<'a> = {
    promise: promise<'a>,
    resolve: 'a => unit,
    reject: exn => unit,
  }

  let make = () => {
    let resolver = ref(None)
    let rejecter = ref(None)
    // The Promise executor runs synchronously, so both references are filled in
    // before `make` returns.
    let promise = makePromise((resolve, reject) => {
      resolver := Some(resolve)
      rejecter := Some(reject)
    })
    {
      promise,
      resolve: value =>
        switch resolver.contents {
        | Some(settle) => settle(value)
        | None => ()
        },
      reject: error =>
        switch rejecter.contents {
        | Some(settle) => settle(error)
        | None => ()
        },
    }
  }
}

// ReScript's dictionary type has no typed delete, and leaving tombstones would
// leak subscription state across reconnects.
let removeKey: (Js.Dict.t<'a>, string) => unit = %raw(`function (dict, key) {
  delete dict[key];
}`)

let logDiagnostic = (message: string) => {
  let _ = write(stderr, message ++ "\n")
}
