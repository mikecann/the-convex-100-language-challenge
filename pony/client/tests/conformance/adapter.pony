use "net"
use "core"
use "../../../client"
use "../../../client/tls"

// The conformance executable.
//
// It is test infrastructure, not client code: it exists so the shared black
// box controller can drive the real Pony client. Every operation below goes
// through the same public client API the canonical example uses, and nothing
// here reimplements Convex behaviour.
//
// Two transports carry the same strict NDJSON v1 stream. With no
// `ADAPTER_LISTEN` it reads standard input and writes standard output; with
// one it listens on that address and accepts a single controller connection.
// Diagnostics always go to standard error, because standard output is the
// protocol.

primitive AdapterEnv
  """
  `Env.vars` is a list of `NAME=value` strings rather than a map, so lookups
  are done here once instead of at every call site.
  """

  fun lookup(vars: Array[String] val, name: String): String =>
    let prefix: String val = name + "="
    for entry in vars.values() do
      if Bytes.starts_with(entry, prefix) then
        return HttpText.slice(entry, prefix.size(), entry.size())
      end
    end
    ""

  fun split_address(address: String): (String, String) =>
    """
    Splits `host:port`, defaulting the host to every interface when the value
    starts with a colon.
    """
    var index = address.size()
    while index > 0 do
      index = index - 1
      if (try address(index)? else 0 end) == ':' then
        return (HttpText.slice(address, 0, index),
          HttpText.slice(address, index + 1, address.size()))
      end
    end
    ("", address)

actor Main is AdapterExit
  let _env: Env
  var _listener: (TCPListener | None) = None
  var _finished: Bool = false

  new create(env: Env) =>
    _env = env

    let url = AdapterEnv.lookup(env.vars, "CONVEX_URL")
    let token = AdapterEnv.lookup(env.vars, "CONVEX_AUTH_TOKEN")
    // The runtime version is stamped by the image that pins the toolchain,
    // because the Pony runtime does not expose it to a program.
    var runtime = AdapterEnv.lookup(env.vars, "PONY_RUNTIME_VERSION")
    if runtime.size() == 0 then runtime = "pony-unknown" end

    var config: (ConvexConfig | None) = None
    if url.size() > 0 then
      try
        config = ConvexConfig(ConvexEndpoint(url)?, "pony-0.1.0", token)
      else
        env.err.print("CONVEX_URL is not a usable Convex deployment URL")
      end
    end

    let opener = TlsStreamOpener(env.root)
    let ticker = RealTicker

    let listen_address = AdapterEnv.lookup(env.vars, "ADAPTER_LISTEN")
    if listen_address.size() == 0 then
      let output = AdapterOutput(StdoutWriter, this)
      let runner = AdapterRunner(output, this, config, opener, ticker, runtime)
      env.input(_StdinNotify(runner), 8192)
    else
      (let host, let service) = AdapterEnv.split_address(listen_address)
      env.err.print("adapter listening on " + listen_address)
      _listener = TCPListener(
        TCPListenAuth(env.root),
        _ControllerListener(this, config, opener, ticker, runtime, env.err),
        host,
        service)
    end

  be adapter_finished(code: I32) =>
    if _finished then return end
    _finished = true
    _env.exitcode(code)
    // Releasing the input source and the listening socket is what lets the
    // program reach quiescence and exit rather than waiting for more commands.
    _env.input.dispose()
    match _listener
    | let listener: TCPListener => listener.dispose()
    end
    _listener = None

class _StdinNotify is InputNotify
  let _runner: AdapterRunner
  let _lines: AdapterLineBuffer = AdapterLineBuffer

  new iso create(runner: AdapterRunner) =>
    _runner = runner

  fun ref apply(data: Array[U8] iso) =>
    for entry in _lines.push(consume data).values() do
      if entry._1 then
        _runner.line(entry._2)
      else
        _runner.malformed_line()
      end
    end

  fun ref dispose() =>
    _runner.input_closed()

class _ControllerListener is TCPListenNotify
  let _main: Main
  let _config: (ConvexConfig | None)
  let _opener: StreamOpener
  let _ticker: Ticker
  let _runtime: String
  let _errors: OutStream

  new iso create(
    main: Main,
    config: (ConvexConfig | None),
    opener: StreamOpener,
    ticker: Ticker,
    runtime: String,
    errors: OutStream)
  =>
    _main = main
    _config = config
    _opener = opener
    _ticker = ticker
    _runtime = runtime
    _errors = errors

  fun ref listening(listen: TCPListener ref) =>
    None

  fun ref not_listening(listen: TCPListener ref) =>
    _errors.print("adapter could not listen for the conformance controller")
    _main.adapter_finished(1)

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    // Exactly one controller connection is expected, so the listener stops
    // accepting once it has one - but only once that connection is fully
    // wired up. Disposing the listener synchronously from inside its own
    // `connected` callback races the just-accepted socket's own event
    // registration and leaves it orphaned (accepted at the OS level but
    // never wired to a notify, so the connection spins forever instead of
    // ever receiving data), so the close is deferred to `accepted` below.
    _ControllerNotify(listen, _main, _config, _opener, _ticker, _runtime)

class _ControllerNotify is TCPConnectionNotify
  """
  A controller that sends `hello` then `close` and shuts down its write half
  the instant it is done sending - exactly what the shared harness does -
  can beat this program's answer to the socket: closing your write half
  does not stop you reading, and Pony's own `TCPConnection` discovers that
  peer close on its own schedule, on its own thread, independent of how far
  this program has gotten through answering. When it wins that race it does
  a hard close and drops every write still in flight, so an answer that
  goes through `AdapterRunner` and `AdapterOutput` - real actors, real
  messages, real scheduling - can arrive too late no matter how quickly
  those actors run.

  `hello` and a `close` that has not needed a deployment yet never depend on
  anything those actors do, so both are answered here instead, synchronously,
  with `conn.write_final` rather than the queued `conn.write`: a direct call
  made in this behaviour's own execution is guaranteed to reach the kernel
  before that same behaviour returns, which is to say before this actor can
  possibly act on a peer close it has not even looked at yet.
  """
  let _listener: TCPListener
  let _main: Main
  let _config: (ConvexConfig | None)
  let _opener: StreamOpener
  let _ticker: Ticker
  let _runtime: String
  let _lines: AdapterLineBuffer = AdapterLineBuffer
  var _output: (AdapterOutput | None) = None
  var _runner: (AdapterRunner | None) = None
  var _saw_other_op: Bool = false

  new iso create(
    listener: TCPListener,
    main: Main,
    config: (ConvexConfig | None),
    opener: StreamOpener,
    ticker: Ticker,
    runtime: String)
  =>
    _listener = listener
    _main = main
    _config = config
    _opener = opener
    _ticker = ticker
    _runtime = runtime

  fun ref accepted(conn: TCPConnection ref) =>
    // Deferred from `connected`: see the comment there.
    _listener.dispose()
    let output = AdapterOutput(StreamWriter(conn), _main)
    _output = output
    _runner = AdapterRunner(
      output, _main, _config, _opener, _ticker, _runtime)

  fun ref connect_failed(conn: TCPConnection ref) =>
    _main.adapter_finished(1)

  fun ref received(
    conn: TCPConnection ref,
    data: Array[U8] iso,
    times: USize)
    : Bool
  =>
    match _runner
    | let runner: AdapterRunner =>
      for entry in _lines.push(consume data).values() do
        if entry._1 then
          _handle_line(conn, runner, entry._2)
        else
          runner.malformed_line()
        end
      end
    end
    // Yield rather than looping straight back into another read. Even the
    // synchronous replies above do not make looping back safe: Pony's own
    // read loop discovering the peer's close is what triggers the hard
    // close in the first place, and there is no reason to invite that any
    // sooner than the next scheduled read has to.
    false

  fun ref _handle_line(conn: TCPConnection ref, runner: AdapterRunner,
    text: String)
  =>
    match AdapterCommandParser.parse(text)
    | let command: AdapterCommand =>
      if command.op == "hello" then
        try
          conn.write_final(AdapterEvents.ready(
            command.id, "pony", "native-pony-0.1.0", _runtime)? + "\n")
        end
        return
      end
      if (command.op == "close") and (not _saw_other_op) then
        try conn.write_final(AdapterEvents.closed(command.id)? + "\n") end
        runner.close_quietly(command.id)
        return
      end
      _saw_other_op = true
      runner.line(text)
    else
      runner.line(text)
    end

  fun ref throttled(conn: TCPConnection ref) =>
    // TCPConnection's pressure signal means it has already started retaining
    // unsent bytes. Retire the socket immediately instead of allowing relay
    // credit to keep feeding its actor mailbox while the controller is not
    // reading.
    match _output
    | let output: AdapterOutput => output.stop()
    end
    match _runner
    | let runner: AdapterRunner => runner.input_closed()
    end
    conn.hard_close()

  fun ref unthrottled(conn: TCPConnection ref) =>
    match _output
    | let output: AdapterOutput => output.resume()
    end

  fun ref closed(conn: TCPConnection ref) =>
    match _runner
    | let runner: AdapterRunner => runner.input_closed()
    | None => _main.adapter_finished(1)
    end
