// The MoonBit conformance adapter.
//
// Test infrastructure, not client code. It speaks NDJSON adapter protocol v1
// and calls the real `convexdemo/moonbit/convex` client for every operation, so
// a passing conformance run is evidence about the client rather than about this
// file.
//
// Two transports, one implementation: with `ADAPTER_LISTEN` set it accepts a
// single controller connection and carries the same stream over TCP, otherwise
// it reads stdin and writes stdout. Diagnostics always go to stderr, because
// stdout is reserved for protocol events.

///|
/// Reported in the `hello` response. The Dockerfile asserts that these match
/// the toolchain it actually built with, so drift is a build failure rather
/// than a quiet lie in the evidence.
const ADAPTER_LANGUAGE : String = "moonbit"

///|
const ADAPTER_IMPLEMENTATION : String = "native-moonbit-0.1.0 (moonbitlang/async 0.20.3 transport)"

///|
const ADAPTER_RUNTIME : String = "moonbit-native 0.10.6+80dc50f24"

///|
/// Largest command line this adapter will assemble. Longer input is refused
/// with a structured error and skipped without being retained, so a controller
/// that sends an unterminated flood cannot grow this process.
const MAX_COMMAND_BYTES : Int = 4194304

///|
/// Read granularity for the command stream.
const INPUT_CHUNK_BYTES : Int = 16384

///|
/// One registered subscription. `generation` increases whenever the id is
/// retired or replaced, which is what lets a queued event be recognised as
/// stale.
struct Relay {
  subscription : @convex.Subscription
  generation : Int
}

///|
/// Everything one adapter session needs.
struct Session {
  client : @convex.Client
  writer : EventWriter
  relays : Map[String, Relay]
  mut next_generation : Int
}

///|
/// Stdout carries protocol events only, so every diagnostic goes to stderr. A
/// failure to report a diagnostic is itself ignored: it must never turn into a
/// protocol event.
async fn diagnostic(message : String) -> Unit {
  @stdio.stderr.write(@utf8.encode("convex-adapter: " + message + "\n")) catch {
    _ => ()
  }
}

///|
/// What one attempt at reading a command produced.
priv enum LineOutcome {
  Line(String)
  Rejected(String)
  Eof
}

///|
/// Incremental, bounded NDJSON reader.
///
/// Lines are assembled as bytes arrive rather than by slurping the stream, and
/// a line that grows past `MAX_COMMAND_BYTES` is abandoned in place: the reader
/// keeps scanning for the terminating newline while retaining nothing.
struct LineReader {
  source : &@io.Reader
  chunk : FixedArray[Byte]
  mut chunk_len : Int
  mut chunk_pos : Int
  pending : @buffer.Buffer
  mut overflowed : Bool
  mut eof : Bool
}

///|
fn LineReader::new(source : &@io.Reader) -> LineReader {
  {
    source,
    chunk: FixedArray::make(INPUT_CHUNK_BYTES, b'\x00'),
    chunk_len: 0,
    chunk_pos: 0,
    pending: @buffer.Buffer(size_hint=INPUT_CHUNK_BYTES),
    overflowed: false,
    eof: false,
  }
}

///|
/// Decode and clear whatever has been accumulated for the current line.
fn LineReader::take(self : LineReader) -> LineOutcome {
  let raw = self.pending.to_bytes()
  self.pending.reset()
  let text = @utf8.decode(raw[:]) catch {
    _ => return Rejected("command line was not valid UTF-8")
  }
  // Tolerate CRLF so a controller on either convention works.
  if text.has_suffix("\r") {
    Line(text.substring(start=0, end=text.length() - 1))
  } else {
    Line(text)
  }
}

///|
async fn LineReader::next_line(self : LineReader) -> LineOutcome {
  for ;; {
    if self.chunk_pos >= self.chunk_len {
      if self.eof {
        if self.overflowed {
          self.overflowed = false
          return Rejected("command line exceeded the adapter's line limit")
        }
        return if self.pending.length() > 0 { self.take() } else { Eof }
      }
      let read = self.source.read(self.chunk, max_len=INPUT_CHUNK_BYTES)
      if read <= 0 {
        self.eof = true
        continue
      }
      self.chunk_len = read
      self.chunk_pos = 0
    }
    let start = self.chunk_pos
    let mut index = start
    while index < self.chunk_len && self.chunk[index] != b'\n' {
      index = index + 1
    }
    let terminated = index < self.chunk_len
    if !self.overflowed {
      if self.pending.length() + (index - start) > MAX_COMMAND_BYTES {
        // Stop retaining this line. Scanning continues so the stream stays in
        // sync with the next newline.
        self.overflowed = true
        self.pending.reset()
      } else {
        self.pending.write_bytes(
          self.chunk.unsafe_reinterpret_as_bytes()[start:index],
        )
      }
    }
    self.chunk_pos = if terminated { index + 1 } else { index }
    if terminated {
      if self.overflowed {
        self.overflowed = false
        return Rejected("command line exceeded the adapter's line limit")
      }
      return self.take()
    }
  }
}

///|
/// Read the `id` of a command, if it has a usable one.
fn command_id(command : Json) -> String? {
  match @convex.json_field(command, "id") {
    Some(String(id)) => if id.length() == 0 { None } else { Some(id) }
    _ => None
  }
}

///|
fn command_string(command : Json, key : String) -> String? {
  match @convex.json_field(command, key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
fn command_args(command : Json) -> Json? {
  match @convex.json_field(command, "args") {
    Some(Object(members)) => Some(Json::object(members))
    _ => None
  }
}

///|
/// Turn a client failure into the adapter's error shape.
fn failure_parts(error : Error) -> (String, String, Json?) {
  match error {
    @convex.ConvexError(info) =>
      (info.kind.to_string(), info.message, info.data)
    other => ("TransportError", "\{other}", None)
  }
}

///|
/// Pump one subscription's updates onto the writer.
///
/// The relay re-checks the registry after every dequeue, and the writer checks
/// again before the line reaches the socket. Either check alone would leave a
/// window; together they mean a relay can be paused anywhere without a stale
/// event crossing an unsubscribe or replacement acknowledgement.
async fn relay_updates(
  session : Session,
  subscription_id : String,
  relay : Relay,
) -> Unit {
  for ;; {
    let update = relay.subscription.next(timeout_ms=1000) catch {
      // The subscription was retired or the client closed. Nothing more can
      // arrive on it, and the acknowledgement path already reported that.
      _ => return
    }
    match session.relays.get(subscription_id) {
      Some(current) => if current.generation != relay.generation { return }
      None => return
    }
    match update {
      None => continue
      Some(value) =>
        match value.error {
          Some(info) =>
            session.writer.emit(
              subscription_error_event(
                subscription_id,
                info.kind.to_string(),
                info.message,
                info.data,
              ),
              guard_subscription=subscription_id,
              guard_generation=relay.generation,
            )
          None =>
            match value.value {
              Some(payload) =>
                session.writer.emit(
                  subscription_value_event(subscription_id, payload, value.logs),
                  guard_subscription=subscription_id,
                  guard_generation=relay.generation,
                )
              None => ()
            }
        }
    }
  }
}

///|
/// Invalidate a subscription id before anything is acknowledged for it.
///
/// Returns the subscription that was registered, if any, so the caller can ask
/// the client to retire it as well.
fn Session::invalidate(
  self : Session,
  subscription_id : String,
) -> @convex.Subscription? {
  match self.relays.get(subscription_id) {
    Some(relay) => {
      self.relays.remove(subscription_id)
      self.writer.retire(subscription_id)
      Some(relay.subscription)
    }
    None => None
  }
}

///|
/// Handle one decoded command. Returns true when the session should end.
async fn Session::handle(
  self : Session,
  group : @async.TaskGroup[Unit],
  command : Json,
) -> Bool {
  let id = command_id(command)
  guard command is Object(_) else {
    self.writer.emit(
      error_event(id, "ProtocolError", "command was not a JSON object", None),
    )
    return false
  }
  guard command_string(command, "op") is Some(op) else {
    self.writer.emit(
      error_event(id, "ProtocolError", "command omitted a string op", None),
    )
    return false
  }
  guard id is Some(command_id_value) else {
    self.writer.emit(
      error_event(None, "ProtocolError", "command omitted a non-empty id", None),
    )
    return false
  }
  match op {
    "hello" => {
      let version = match @convex.json_field(command, "protocolVersion") {
        Some(Number(value, ..)) => value
        _ => -1.0
      }
      guard version == 1.0 else {
        self.writer.emit(
          error_event(
            id,
            "ProtocolError",
            "unsupported adapter protocol version",
            None,
          ),
        )
        return false
      }
      self.writer.emit(
        ready_event(
          command_id_value,
          ADAPTER_LANGUAGE,
          ADAPTER_IMPLEMENTATION,
          ADAPTER_RUNTIME,
        ),
      )
      false
    }
    "query" | "mutation" | "action" => {
      guard command_string(command, "path") is Some(path) else {
        self.writer.emit(
          error_event(id, "ProtocolError", "call omitted a string path", None),
        )
        return false
      }
      guard command_args(command) is Some(args) else {
        self.writer.emit(
          error_event(id, "ProtocolError", "call omitted object args", None),
        )
        return false
      }
      let outcome = try {
        let result = match op {
          "query" => self.client.query(path, args)
          "mutation" => self.client.mutation(path, args)
          _ => self.client.action(path, args)
        }
        result_event(command_id_value, result.value, result.logs)
      } catch {
        error => {
          let parts = failure_parts(error)
          error_event(id, parts.0, parts.1, parts.2)
        }
      }
      self.writer.emit(outcome)
      false
    }
    "setAuth" => {
      guard command_string(command, "token") is Some(token) else {
        self.writer.emit(
          error_event(id, "ProtocolError", "setAuth omitted a token", None),
        )
        return false
      }
      // An empty token clears the credential, which is how the shared suite
      // proves a replaced token is really forgotten.
      self.client.set_auth(if token.length() == 0 { None } else { Some(token) })
      self.writer.emit(ack_event(command_id_value))
      false
    }
    "subscribe" => {
      guard command_string(command, "subscriptionId") is Some(subscription_id) else {
        self.writer.emit(
          error_event(
            id,
            "ProtocolError",
            "subscribe omitted a subscriptionId",
            None,
          ),
        )
        return false
      }
      guard command_string(command, "path") is Some(path) else {
        self.writer.emit(
          error_event(id, "ProtocolError", "subscribe omitted a path", None),
        )
        return false
      }
      guard command_args(command) is Some(args) else {
        self.writer.emit(
          error_event(
            id,
            "ProtocolError",
            "subscribe omitted object args",
            None,
          ),
        )
        return false
      }
      // Re-using a subscription id replaces the old subscription. Invalidate
      // first so nothing from the old one can appear after this command's
      // acknowledgement.
      match self.invalidate(subscription_id) {
        Some(previous) =>
          self.client.unsubscribe(previous) catch {
            error => diagnostic("replacing a subscription: \{error}")
          }
        None => ()
      }
      let started = Ok(self.client.subscribe(path, args)) catch {
        error => Err(error)
      }
      match started {
        Err(error) => {
          let parts = failure_parts(error)
          self.writer.emit(error_event(id, parts.0, parts.1, parts.2))
        }
        Ok(subscription) => {
          self.next_generation = self.next_generation + 1
          let relay = { subscription, generation: self.next_generation }
          self.relays[subscription_id] = relay
          self.writer.register(subscription_id, relay.generation)
          group.spawn_bg(
            () => relay_updates(self, subscription_id, relay),
            no_wait=true,
            allow_failure=true,
          )
          self.writer.emit(ack_event(command_id_value))
        }
      }
      false
    }
    "unsubscribe" => {
      guard command_string(command, "subscriptionId") is Some(subscription_id) else {
        self.writer.emit(
          error_event(
            id,
            "ProtocolError",
            "unsubscribe omitted a subscriptionId",
            None,
          ),
        )
        return false
      }
      // Invalidation happens before the acknowledgement is even queued, and the
      // writer drops anything already queued for the retired generation.
      match self.invalidate(subscription_id) {
        Some(subscription) =>
          self.client.unsubscribe(subscription) catch {
            error => diagnostic("unsubscribe: \{error}")
          }
        None => ()
      }
      self.writer.emit(ack_event(command_id_value))
      false
    }
    "debugDisconnect" => {
      let outcome = try {
        self.client.debug_disconnect()
        ack_event(command_id_value)
      } catch {
        error => {
          let parts = failure_parts(error)
          error_event(id, parts.0, parts.1, parts.2)
        }
      }
      self.writer.emit(outcome)
      false
    }
    "close" => {
      for entry in self.relays.to_array() {
        self.writer.retire(entry.0)
        self.client.unsubscribe(entry.1.subscription) catch {
          error => diagnostic("closing a subscription: \{error}")
        }
      }
      self.relays.clear()
      self.writer.emit(closed_event(command_id_value))
      true
    }
    other => {
      self.writer.emit(
        error_event(id, "ProtocolError", "unknown operation " + other, None),
      )
      false
    }
  }
}

///|
/// Read commands until the controller closes the session or the stream ends.
async fn Session::serve(
  self : Session,
  group : @async.TaskGroup[Unit],
  input : &@io.Reader,
) -> Unit {
  let reader = LineReader::new(input)
  for ;; {
    let outcome = reader.next_line() catch {
      error => {
        diagnostic("reading commands: \{error}")
        return
      }
    }
    match outcome {
      Eof => return
      Rejected(reason) =>
        self.writer.emit(error_event(None, "ProtocolError", reason, None))
      Line(line) =>
        if line.trim_space().length() != 0 {
          let command = Ok(@json.parse(line)) catch { error => Err(error) }
          match command {
            Err(_) =>
              self.writer.emit(
                error_event(
                  None,
                  "ProtocolError",
                  "command was not valid JSON",
                  None,
                ),
              )
            Ok(decoded) => if self.handle(group, decoded) { return }
          }
        }
    }
  }
}

///|
/// Run one adapter session over an already established stream pair.
async fn run_session(input : &@io.Reader, output : &@io.Writer) -> Unit {
  guard @env.get_env_var("CONVEX_URL") is Some(url) else {
    diagnostic("CONVEX_URL is required")
    return
  }
  @async.with_task_group(group => {
    let writer = EventWriter::new()
    let writing = group.spawn(() => writer.run(output), no_wait=true)
    @convex.with_client(url, client => {
      let session = Session::{
        client,
        writer,
        relays: Map::new(),
        next_generation: 0,
      }
      session.serve(group, input)
    })
    // Stop after the client is closed so every event the session produced is
    // already queued, then wait for the writer to flush it.
    writer.stop()
    writing.wait()
  })
}

///|
async fn main {
  let listen = @env.get_env_var("ADAPTER_LISTEN")
  match listen {
    Some(address) =>
      if address.length() > 0 {
        // The shared harness runs the adapter as a long-lived container and
        // dials it. Exactly one controller connection is served, then the
        // process exits so `docker wait` observes a clean status.
        let server = @socket.TcpServer::TcpServer(
          @socket.Addr::parse(address),
          reuse_addr=true,
        )
        let (connection, _) = server.accept()
        // Stop listening immediately: this adapter serves one controller, and
        // leaving the socket open would invite a second one.
        server.close()
        run_session(connection, connection)
        connection.close()
      } else {
        run_session(@stdio.stdin, @stdio.stdout)
      }
    None => run_session(@stdio.stdin, @stdio.stdout)
  }
}
