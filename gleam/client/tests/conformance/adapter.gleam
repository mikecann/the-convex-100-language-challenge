//// NDJSON adapter protocol v1. Test infrastructure, not public client code.
////
//// The shared controller drives this program over stdin/stdout, or over a TCP
//// connection when `ADAPTER_LISTEN` is set, and validates every emitted line
//// against the shared schema. Three rules shape the design:
////
//// * stdout carries protocol events only; diagnostics go to stderr.
//// * Every operation calls the real client. Nothing here fakes a Convex
////   result, and a failure is never flattened into a successful value.
//// * Input and output are both explicitly bounded. A reader waits for an
////   acknowledgement before reading again, and the writer refuses work once
////   its queue exceeds a count or byte budget, so neither direction can grow
////   this process without limit.

import convex.{type Client}
import convex_error
import convex_json.{type Json, JsonArray, JsonInt, JsonObject, JsonString} as json
import convex_live.{
  type SubscriptionEvent, LiveFailure, LiveValue, SubscriptionEvent,
}
import convex_sys
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const language_id = "gleam"

/// Provenance string reported in the `ready` event. It names the target
/// language, the runtime, and what the client does not delegate.
const implementation = "native-gleam-otp-sockets-0.1.0"

/// Pinned Gleam version. The Docker test stage asserts that the toolchain in
/// the image matches this string, so the reported runtime cannot drift from
/// the compiler that produced the image.
const gleam_version = "1.9.1"

/// One NDJSON command may not exceed this many bytes. A longer line is
/// discarded up to its newline and answered with a protocol error.
const max_command_bytes = 9_437_184

/// Bounds on queued output, including the payload the sender is physically
/// writing. Saturation closes the stalled controller instead of buffering.
const max_output_count = 16

const max_output_bytes = 12_582_912

/// How long a caller waits for the writer to accept an event before treating
/// the writer as unusable.
const emit_timeout = 1000

/// How long the reader waits for the controller to acknowledge a command.
const ack_timeout = 5000

const read_chunk = 16_384

/// The adapter accepts individual commands close to 9 MiB. Once one command
/// has been acknowledged, retaining its expanded JSON heap until a later
/// generational collection would make two sequential legal messages overlap
/// inside the shared 128 MiB runtime cgroup. This adapter-local collection
/// barrier releases that completed command before the reader accepts another.
@external(erlang, "erlang", "garbage_collect")
fn garbage_collect() -> Bool

fn release_completed_command() -> Nil {
  let _ = garbage_collect()
  Nil
}

pub fn main() -> Nil {
  let url = convex_sys.env("CONVEX_URL", "http://127.0.0.1:3210")
  case convex.new(url) {
    Error(error) -> {
      convex_sys.stderr_write("adapter could not start: " <> error.message)
      Nil
    }
    Ok(client) ->
      case convex_sys.getenv("ADAPTER_LISTEN") {
        Error(_) -> run(client, StdIo)
        Ok(address) -> listen(client, address)
      }
  }
}

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

type Channel {
  StdIo
  Tcp(socket: convex_sys.Socket)
}

/// `ADAPTER_LISTEN` is `host:port`. The shared controller runs in a sibling
/// container, so `0.0.0.0` must reach the actual listener rather than being
/// silently narrowed to loopback.
fn listen(client: Client, address: String) -> Nil {
  case parse_listen(address) {
    Error(reason) -> convex_sys.stderr_write(reason)
    Ok(#(host, port)) -> listen_on_address(client, host, port)
  }
}

@internal
pub fn parse_listen(address: String) -> Result(#(String, Int), String) {
  use #(host, raw_port) <- result.try(
    string.split_once(address, ":")
    |> result.replace_error("ADAPTER_LISTEN must be host:port"),
  )
  use port <- result.try(
    int.parse(raw_port)
    |> result.replace_error("ADAPTER_LISTEN has an invalid port"),
  )
  let bind_host = case host {
    "localhost" -> "127.0.0.1"
    other -> other
  }
  case
    host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0",
    port > 0 && port < 65_536
  {
    True, True -> Ok(#(bind_host, port))
    _, _ ->
      Error(
        "ADAPTER_LISTEN must name an approved numeric host and valid port",
      )
  }
}

fn listen_on_address(client: Client, host: String, port: Int) -> Nil {
  case convex_sys.listen(host, port) {
    Error(reason) ->
      convex_sys.stderr_write("adapter cannot listen: " <> reason)
    Ok(listener) -> {
      let outcome = case convex_sys.accept(listener, 60_000) {
        Error(reason) -> {
          convex_sys.stderr_write("adapter accept failed: " <> reason)
          Nil
        }
        Ok(socket) -> {
          run(client, Tcp(socket))
          convex_sys.close(socket)
        }
      }
      convex_sys.close(listener)
      outcome
    }
  }
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

type Event {
  /// One complete NDJSON command. `ack` is how the reader learns it may read
  /// again, which is what bounds this process's mailbox.
  Incoming(payload: BitArray, ack: Subject(Nil))
  Oversized(ack: Subject(Nil))
  InputFailed(reason: String, ack: Subject(Nil))
  InputClosed
  /// A Live event, forwarded by the subscription bridge.
  Live(event: SubscriptionEvent)
  OutputFailed(reason: String)
}

type Controller {
  Controller(
    client: Client,
    /// Real client subscription id to the identifier the controller asked for.
    subscriptions: Dict(String, String),
    writer: Subject(WriterMessage),
    events: Subject(Event),
    sink: Subject(SubscriptionEvent),
  )
}

fn run(client: Client, channel: Channel) -> Nil {
  let events = process.new_subject()
  let writer = start_writer(events, channel)
  let sink = start_bridge(events)
  let _reader = start_reader(events, channel)
  let controller =
    Controller(
      client: client,
      subscriptions: dict.new(),
      writer: writer,
      events: events,
      sink: sink,
    )
  serve(controller)
  let _ = flush(writer, 2000)
  let stopped = stop_writer(writer)
  case convex_sys.getenv("ADAPTER_RESERVATION_DIAGNOSTIC"), stopped {
    Ok("1"), Ok(WriterStopped(released_count, released_bytes, 0, 0)) ->
      convex_sys.stderr_write(
        "adapter output reservations released: count="
        <> int.to_string(released_count)
        <> " bytes="
        <> int.to_string(released_bytes)
        <> " remaining_count=0 remaining_bytes=0",
      )
    Ok("1"), _ ->
      convex_sys.stderr_write(
        "adapter output reservation cleanup did not complete cleanly",
      )
    _, _ -> Nil
  }
  Nil
}

fn serve(controller: Controller) -> Nil {
  case process.receive(controller.events, 60_000) {
    Error(_) -> serve(controller)
    Ok(InputClosed) -> {
      let _ = convex.close(controller.client)
      Nil
    }
    Ok(OutputFailed(reason)) -> {
      convex_sys.stderr_write("controller output failed: " <> reason)
      let _ = convex.close(controller.client)
      Nil
    }
    Ok(InputFailed(reason, ack)) -> {
      let _ = emit(controller, error_event(None, "TransportError", reason))
      let _ = flush(controller.writer, 2000)
      process.send(ack, Nil)
      let _ = convex.close(controller.client)
      Nil
    }
    Ok(Oversized(ack)) -> {
      let outcome =
        emit(
          controller,
          error_event(None, "ProtocolError", "NDJSON command exceeds 9 MiB"),
        )
      process.send(ack, Nil)
      continue(controller, outcome)
    }
    Ok(Live(SubscriptionEvent(subscription_id, event, acknowledged))) -> {
      let outcome = case dict.get(controller.subscriptions, subscription_id) {
        Error(_) -> Emitted
        Ok(requested) -> emit(controller, subscription_event(requested, event))
      }
      process.send(acknowledged, Nil)
      continue(controller, outcome)
    }
    Ok(Incoming(payload, ack)) -> {
      let #(controller, outcome, stop) = handle_line(controller, payload)
      process.send(ack, Nil)
      release_completed_command()
      case stop {
        True -> {
          let _ = flush(controller.writer, 2000)
          Nil
        }
        False -> continue(controller, outcome)
      }
    }
  }
}

/// Keep serving unless the writer refused an event. Saturation is treated as
/// a fatal condition on purpose: silently dropping protocol events would make
/// a conformance run report a false result.
fn continue(controller: Controller, outcome: EmitResult) -> Nil {
  case outcome {
    Emitted -> serve(controller)
    Overflowed -> {
      convex_sys.stderr_write("controller output budget exceeded")
      let _ = convex.close(controller.client)
      Nil
    }
  }
}

fn handle_line(
  controller: Controller,
  payload: BitArray,
) -> #(Controller, EmitResult, Bool) {
  case decode_command(payload) {
    Error(#(id, message)) -> #(
      controller,
      emit(controller, error_event(id, "ProtocolError", message)),
      False,
    )
    Ok(command) -> execute(controller, command)
  }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

type Command {
  Hello(id: String)
  Call(id: String, kind: convex.CallKind, path: String, args: Json)
  SetAuth(id: String, token: String)
  Subscribe(id: String, subscription_id: String, path: String, args: Json)
  Unsubscribe(id: String, subscription_id: String)
  DebugDisconnect(id: String)
  Close(id: String)
  Unknown(id: String)
}

/// Validate a command before anything acts on it. The error path carries the
/// command id when one could be recovered, because the controller correlates
/// replies by id.
fn decode_command(
  payload: BitArray,
) -> Result(Command, #(Option(String), String)) {
  case json.parse_bits(payload) {
    Error(_) -> Error(#(None, "invalid NDJSON command"))
    Ok(value) -> {
      let id = optional_id(value)
      case id, json.string_field(value, "op") {
        Some(id), Ok(op) -> validate(op, id, value)
        _, _ -> Error(#(id, "command requires string id and op"))
      }
    }
  }
}

fn validate(
  op: String,
  id: String,
  value: Json,
) -> Result(Command, #(Option(String), String)) {
  case op {
    "hello" ->
      case
        json.only_fields(value, ["protocolVersion", "id", "op"]),
        json.field(value, "protocolVersion")
      {
        True, Ok(version) ->
          case json.integral_int(version) {
            Ok(1) -> Ok(Hello(id))
            _ -> Error(#(Some(id), "hello requires protocolVersion 1"))
          }
        _, _ -> Error(#(Some(id), "hello requires protocolVersion 1"))
      }
    "query" -> call_command(id, convex.Query, value)
    "mutation" -> call_command(id, convex.Mutation, value)
    "action" -> call_command(id, convex.Action, value)
    "setAuth" ->
      case
        json.only_fields(value, ["id", "op", "token"]),
        json.string_field(value, "token")
      {
        True, Ok(token) -> Ok(SetAuth(id, token))
        _, _ -> Error(#(Some(id), "setAuth requires a string token"))
      }
    "subscribe" ->
      case
        json.only_fields(value, ["id", "op", "subscriptionId", "path", "args"]),
        subscription_id(value),
        json.string_field(value, "path"),
        json.field(value, "args")
      {
        True, Ok(subscription), Ok(path), Ok(args) ->
          case json.as_object(args) {
            Ok(_) -> Ok(Subscribe(id, subscription, path, args))
            Error(_) -> Error(#(Some(id), "subscribe requires object args"))
          }
        _, _, _, _ -> Error(#(Some(id), "malformed subscribe command"))
      }
    "unsubscribe" ->
      case
        json.only_fields(value, ["id", "op", "subscriptionId", "path", "args"]),
        subscription_id(value),
        optional_string(value, "path"),
        optional_object(value, "args")
      {
        True, Ok(subscription), True, True -> Ok(Unsubscribe(id, subscription))
        _, _, _, _ -> Error(#(Some(id), "malformed unsubscribe command"))
      }
    "debugDisconnect" ->
      case json.only_fields(value, ["id", "op"]) {
        True -> Ok(DebugDisconnect(id))
        False -> Error(#(Some(id), "malformed debugDisconnect command"))
      }
    "close" ->
      case json.only_fields(value, ["id", "op"]) {
        True -> Ok(Close(id))
        False -> Error(#(Some(id), "malformed close command"))
      }
    _ -> Ok(Unknown(id))
  }
}

fn call_command(
  id: String,
  kind: convex.CallKind,
  value: Json,
) -> Result(Command, #(Option(String), String)) {
  case
    json.only_fields(value, ["id", "op", "path", "args"]),
    json.string_field(value, "path"),
    json.field(value, "args")
  {
    True, Ok(path), Ok(args) ->
      case string.length(path) >= 3, json.as_object(args) {
        True, Ok(_) -> Ok(Call(id, kind, path, args))
        _, _ -> Error(#(Some(id), "malformed function command"))
      }
    _, _, _ -> Error(#(Some(id), "malformed function command"))
  }
}

fn optional_id(value: Json) -> Option(String) {
  case json.string_field(value, "id") {
    Ok(id) ->
      case valid_id(id) {
        True -> Some(id)
        False -> None
      }
    Error(_) -> None
  }
}

fn subscription_id(value: Json) -> Result(String, Nil) {
  use id <- result.try(json.string_field(value, "subscriptionId"))
  case valid_id(id) {
    True -> Ok(id)
    False -> Error(Nil)
  }
}

fn valid_id(id: String) -> Bool {
  case bit_array.byte_size(bit_array.from_string(id)) <= 512 {
    False -> False
    True -> {
      let length = json.codepoint_length(id)
      length > 0 && length <= 128 && string.trim(id) != ""
    }
  }
}

fn optional_string(value: Json, field: String) -> Bool {
  case json.field(value, field) {
    Error(_) -> True
    Ok(JsonString(_)) -> True
    _ -> False
  }
}

fn optional_object(value: Json, field: String) -> Bool {
  case json.field(value, field) {
    Error(_) -> True
    Ok(inner) -> json.as_object(inner) |> result.is_ok
  }
}

fn execute(
  controller: Controller,
  command: Command,
) -> #(Controller, EmitResult, Bool) {
  case command {
    Hello(id) -> #(
      controller,
      emit(
        controller,
        JsonObject([
          #("protocolVersion", JsonInt(1)),
          #("id", JsonString(id)),
          #("type", JsonString("ready")),
          #("language", JsonString(language_id)),
          #("implementation", JsonString(implementation)),
          #("runtime", JsonString(runtime_description())),
        ]),
      ),
      False,
    )

    Call(id, kind, path, args) -> {
      let reply = case convex.call(controller.client, kind, path, args) {
        Ok(result) -> result_event(id, result.value, result.logs)
        Error(error) -> call_error_event(id, error)
      }
      #(controller, emit(controller, reply), False)
    }

    SetAuth(id, token) ->
      case convex.set_auth(controller.client, token) {
        Ok(client) -> #(
          Controller(..controller, client: client),
          emit(controller, ack(id)),
          False,
        )
        Error(error) -> #(
          controller,
          emit(controller, error_event(Some(id), error.name, error.message)),
          False,
        )
      }

    Subscribe(id, requested, path, args) -> {
      // Replacing an identifier is a barrier: the previous subscription is
      // removed first, so no event from it can arrive after this
      // acknowledgement wearing the same identifier.
      let Replacement(subscriptions, outcome) =
        replace_mapping(
          controller.client,
          controller.subscriptions,
          requested,
          path,
          args,
          controller.sink,
        )
      let controller = Controller(..controller, subscriptions: subscriptions)
      case outcome {
        Error(error) -> #(
          controller,
          emit(controller, error_event(Some(id), error.name, error.message)),
          False,
        )
        Ok(_) -> #(controller, emit(controller, ack(id)), False)
      }
    }

    Unsubscribe(id, requested) ->
      case drop_requested(controller, requested) {
        Ok(controller) -> #(controller, emit(controller, ack(id)), False)
        Error(error) -> #(
          controller,
          emit(controller, error_event(Some(id), error.name, error.message)),
          False,
        )
      }

    DebugDisconnect(id) ->
      case convex.debug_disconnect(controller.client) {
        Ok(_) -> #(controller, emit(controller, ack(id)), False)
        Error(error) -> #(
          controller,
          emit(controller, error_event(Some(id), error.name, error.message)),
          False,
        )
      }

    Close(id) ->
      case convex.close(controller.client) {
        Error(error) -> #(
          controller,
          emit(controller, error_event(Some(id), error.name, error.message)),
          False,
        )
        Ok(_) -> #(
          Controller(..controller, subscriptions: dict.new()),
          emit(controller, closed_event(id)),
          True,
        )
      }

    Unknown(id) -> #(
      controller,
      emit(
        controller,
        error_event(Some(id), "ProtocolError", "unknown operation"),
      ),
      False,
    )
  }
}

/// Remove whichever real subscription is currently wearing this controller
/// identifier, waiting for the client to confirm before returning.
fn drop_requested(
  controller: Controller,
  requested: String,
) -> Result(Controller, convex_error.ConvexError) {
  use subscriptions <- result.try(drop_requested_from(
    controller.client,
    controller.subscriptions,
    requested,
  ))
  Ok(Controller(..controller, subscriptions: subscriptions))
}

/// Replace one controller-facing identifier through the same barrier used by
/// the real subscribe command. This stays internal to the package; the Live
/// socket fixture calls it so replacement ordering is proved without a second
/// test-only implementation of the adapter logic.
@internal
pub type Replacement {
  Replacement(
    subscriptions: Dict(String, String),
    outcome: Result(Nil, convex_error.ConvexError),
  )
}

@internal
pub fn replace_mapping(
  client: Client,
  subscriptions: Dict(String, String),
  requested: String,
  path: String,
  args: Json,
  sink: Subject(SubscriptionEvent),
) -> Replacement {
  case drop_requested_from(client, subscriptions, requested) {
    Error(error) -> Replacement(subscriptions, Error(error))
    Ok(subscriptions) ->
      case convex.subscribe(client, path, args, sink) {
        Error(error) -> Replacement(subscriptions, Error(error))
        Ok(real) ->
          Replacement(dict.insert(subscriptions, real, requested), Ok(Nil))
      }
  }
}

fn drop_requested_from(
  client: Client,
  subscriptions: Dict(String, String),
  requested: String,
) -> Result(Dict(String, String), convex_error.ConvexError) {
  let matches =
    subscriptions
    |> dict.to_list
    |> list.filter_map(fn(entry) {
      let #(real, wanted) = entry
      case wanted == requested {
        True -> Ok(real)
        False -> Error(Nil)
      }
    })
  drop_real_subscriptions(matches, client, subscriptions)
}

fn drop_real_subscriptions(
  matches: List(String),
  client: Client,
  subscriptions: Dict(String, String),
) -> Result(Dict(String, String), convex_error.ConvexError) {
  case matches {
    [] -> Ok(subscriptions)
    [real, ..rest] -> {
      use _ <- result.try(convex.unsubscribe(client, real))
      drop_real_subscriptions(rest, client, dict.delete(subscriptions, real))
    }
  }
}

fn runtime_description() -> String {
  "Gleam " <> gleam_version <> " on Erlang/OTP " <> convex_sys.otp_release()
}

fn ack(id: String) -> Json {
  JsonObject([#("id", JsonString(id)), #("type", JsonString("ack"))])
}

/// Serialize the successful call shape the shared schema validates. Keeping
/// this as the production builder lets the language-local adapter test inspect
/// the exact event rather than a second hand-written approximation.
@internal
pub fn result_event(id: String, value: Json, logs: List(String)) -> Json {
  JsonObject([
    #("id", JsonString(id)),
    #("type", JsonString("result")),
    #("value", value),
    #("logs", JsonArray(list.map(logs, JsonString))),
  ])
}

@internal
pub fn call_error_event(id: String, error: convex_error.ConvexError) -> Json {
  JsonObject([
    #("id", JsonString(id)),
    #("type", JsonString("error")),
    #("error", convex_error.to_json(error)),
  ])
}

@internal
pub fn closed_event(id: String) -> Json {
  JsonObject([#("id", JsonString(id)), #("type", JsonString("closed"))])
}

/// Optional members are omitted rather than serialised as null, because the
/// shared schema validates event shapes strictly.
fn error_event(id: Option(String), name: String, message: String) -> Json {
  let error =
    JsonObject([#("name", JsonString(name)), #("message", JsonString(message))])
  case id {
    None -> JsonObject([#("type", JsonString("error")), #("error", error)])
    Some(id) ->
      JsonObject([
        #("id", JsonString(id)),
        #("type", JsonString("error")),
        #("error", error),
      ])
  }
}

@internal
pub fn subscription_event(
  requested: String,
  event: convex_live.LiveEvent,
) -> Json {
  case event {
    LiveValue(value, logs) ->
      JsonObject([
        #("type", JsonString("subscription")),
        #("subscriptionId", JsonString(requested)),
        #("value", value),
        #("logs", JsonArray(list.map(logs, JsonString))),
      ])
    LiveFailure(error) ->
      JsonObject([
        #("type", JsonString("subscription")),
        #("subscriptionId", JsonString(requested)),
        #("error", convex_error.to_json(error)),
      ])
  }
}

// ---------------------------------------------------------------------------
// Subscription bridge
// ---------------------------------------------------------------------------

/// The client delivers Live events on their own typed subject. This process
/// forwards them into the controller's single mailbox so the controller never
/// has to choose between two sources while it is busy with a command.
fn start_bridge(events: Subject(Event)) -> Subject(SubscriptionEvent) {
  let handshake = process.new_subject()
  let _pid =
    process.start(
      fn() {
        let sink = process.new_subject()
        process.send(handshake, sink)
        bridge_loop(events, sink)
      },
      False,
    )
  let assert Ok(sink) = process.receive(handshake, 5000)
  sink
}

fn bridge_loop(events: Subject(Event), sink: Subject(SubscriptionEvent)) -> Nil {
  case process.receive(sink, 60_000) {
    Error(_) -> bridge_loop(events, sink)
    Ok(event) -> {
      process.send(events, Live(event))
      bridge_loop(events, sink)
    }
  }
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

type ReaderState {
  ReaderState(chunks: List(BitArray), bytes: Int, discarding: Bool)
}

/// Read commands and hand them over one at a time. Waiting for each
/// acknowledgement is what stops a fast controller from filling this
/// process's mailbox with unread work.
fn start_reader(events: Subject(Event), channel: Channel) -> process.Pid {
  process.start(
    fn() { reader_loop(events, channel, ReaderState([], 0, False)) },
    False,
  )
}

fn reader_loop(
  events: Subject(Event),
  channel: Channel,
  state: ReaderState,
) -> Nil {
  case read(channel) {
    Error(reason) -> {
      let ack = process.new_subject()
      process.send(events, InputFailed(reason, ack))
      let _ = process.receive(ack, ack_timeout)
      Nil
    }
    // NDJSON requires a terminating newline, so a trailing fragment at end of
    // input is discarded rather than guessed at.
    Ok(None) -> process.send(events, InputClosed)
    Ok(Some(chunk)) ->
      case consume(events, state, chunk) {
        Error(Nil) -> Nil
        Ok(state) -> reader_loop(events, channel, state)
      }
  }
}

fn read(channel: Channel) -> Result(Option(BitArray), String) {
  case channel {
    StdIo ->
      case convex_sys.stdin_read(read_chunk) {
        convex_sys.ReadChunk(bytes) -> Ok(Some(bytes))
        convex_sys.ReadEnd -> Ok(None)
        convex_sys.ReadFailed(reason) -> Error(reason)
      }
    Tcp(socket) ->
      case convex_sys.recv(socket, 0, 60_000) {
        convex_sys.Received(bytes) -> Ok(Some(bytes))
        convex_sys.RecvClosed -> Ok(None)
        convex_sys.RecvTimeout -> Ok(Some(<<>>))
        convex_sys.RecvFailed(reason) -> Error(reason)
      }
  }
}

/// Split whatever has arrived into complete lines. `Error(Nil)` means the
/// controller stopped acknowledging, so this reader has nothing left to do.
fn consume(
  events: Subject(Event),
  state: ReaderState,
  chunk: BitArray,
) -> Result(ReaderState, Nil) {
  case bit_array.byte_size(chunk) == 0, state.discarding {
    True, _ -> Ok(state)
    False, True ->
      case convex_sys.split_newline(chunk) {
        convex_sys.NoLine -> Ok(ReaderState([], 0, True))
        convex_sys.LineFound(_discarded, rest) ->
          consume(events, ReaderState([], 0, False), rest)
      }
    False, False -> parse_lines(events, state.chunks, state.bytes, chunk)
  }
}

fn parse_lines(
  events: Subject(Event),
  chunks: List(BitArray),
  bytes: Int,
  chunk: BitArray,
) -> Result(ReaderState, Nil) {
  case convex_sys.split_newline(chunk) {
    convex_sys.LineFound(prefix, rest) -> {
      let line_bytes = bytes + bit_array.byte_size(prefix)
      case line_bytes > max_command_bytes {
        True -> {
          use _ <- result.try(deliver(events, Oversized))
          parse_lines(events, [], 0, rest)
        }
        False -> {
          let line =
            convex_sys.concat_binaries(list.reverse([prefix, ..chunks]))
          use _ <- result.try(deliver(events, Incoming(line, _)))
          parse_lines(events, [], 0, rest)
        }
      }
    }
    convex_sys.NoLine -> {
      let total = bytes + bit_array.byte_size(chunk)
      case total > max_command_bytes {
        // The line is already too long to be legal, so its remaining bytes are
        // dropped without being retained.
        True -> {
          use _ <- result.try(deliver(events, Oversized))
          Ok(ReaderState([], 0, True))
        }
        False -> Ok(ReaderState([chunk, ..chunks], total, False))
      }
    }
  }
}

fn deliver(
  events: Subject(Event),
  build: fn(Subject(Nil)) -> Event,
) -> Result(Nil, Nil) {
  let ack = process.new_subject()
  process.send(events, build(ack))
  let outcome = process.receive(ack, ack_timeout)
  // The controller has finished with this command, so the reader must not
  // retain its assembled binary while it waits for the next line.
  release_completed_command()
  outcome
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

pub type EmitResult {
  Emitted
  Overflowed
}

type WriterMessage {
  Enqueue(payload: BitArray, reply: Subject(EmitResult))
  SendDone(result: Result(Nil, String))
  FlushWhenIdle(reply: Subject(Nil))
  StopWriter(reply: Subject(WriterStop))
}

type WriterStop {
  WriterStopped(
    released_count: Int,
    released_bytes: Int,
    remaining_count: Int,
    remaining_bytes: Int,
  )
}

type Writer {
  Writer(
    events: Subject(Event),
    sender: Subject(BitArray),
    sender_pid: process.Pid,
    queue: List(#(BitArray, Int)),
    count: Int,
    bytes: Int,
    inflight: Option(Int),
    waiters: List(Subject(Nil)),
  )
}

/// The writer owns the whole output budget. Its accounting includes the
/// payload the sender is physically writing, so a blocked socket write can
/// never hide memory from the bound.
fn start_writer(
  events: Subject(Event),
  channel: Channel,
) -> Subject(WriterMessage) {
  let handshake = process.new_subject()
  let _pid =
    process.start(
      fn() {
        let inbox = process.new_subject()
        process.send(handshake, inbox)
        let #(sender_pid, sender) = start_sender(inbox, channel)
        writer_loop(
          Writer(
            events: events,
            sender: sender,
            sender_pid: sender_pid,
            queue: [],
            count: 0,
            bytes: 0,
            inflight: None,
            waiters: [],
          ),
          inbox,
        )
      },
      False,
    )
  let assert Ok(inbox) = process.receive(handshake, 5000)
  inbox
}

fn writer_loop(writer: Writer, inbox: Subject(WriterMessage)) -> Nil {
  case process.receive(inbox, 60_000) {
    Error(_) -> writer_loop(writer, inbox)
    Ok(StopWriter(reply)) -> {
      // Killing the sender before anything else bounds shutdown even when the
      // peer has stopped reading and a write is blocked in the kernel. Ending
      // this owner then drops every queued and in-flight binary together. The
      // pressure probe asks for the before/after counts so that cleanup is an
      // observed final-adapter property rather than an assumption.
      let _ = convex_sys.kill_and_wait(writer.sender_pid, 1000)
      let cleared =
        Writer(
          ..writer,
          queue: [],
          count: 0,
          bytes: 0,
          inflight: None,
          waiters: [],
        )
      process.send(
        reply,
        WriterStopped(writer.count, writer.bytes, cleared.count, cleared.bytes),
      )
      Nil
    }
    Ok(Enqueue(payload, reply)) -> {
      let size = bit_array.byte_size(payload)
      case
        writer.count < max_output_count
        && writer.bytes + size <= max_output_bytes
      {
        False -> {
          process.send(reply, Overflowed)
          writer_loop(writer, inbox)
        }
        True -> {
          process.send(reply, Emitted)
          writer_loop(
            dispatch(
              Writer(
                ..writer,
                queue: list.append(writer.queue, [#(payload, size)]),
                count: writer.count + 1,
                bytes: writer.bytes + size,
              ),
            ),
            inbox,
          )
        }
      }
    }
    Ok(SendDone(outcome)) -> {
      let released = option.unwrap(writer.inflight, 0)
      let writer =
        Writer(
          ..writer,
          count: writer.count - 1,
          bytes: writer.bytes - released,
          inflight: None,
        )
      case outcome {
        Ok(_) -> Nil
        Error(reason) -> process.send(writer.events, OutputFailed(reason))
      }
      writer_loop(notify(dispatch(writer)), inbox)
    }
    Ok(FlushWhenIdle(reply)) ->
      case writer.count {
        0 -> {
          process.send(reply, Nil)
          writer_loop(writer, inbox)
        }
        _ ->
          writer_loop(
            Writer(..writer, waiters: [reply, ..writer.waiters]),
            inbox,
          )
      }
  }
}

fn dispatch(writer: Writer) -> Writer {
  case writer.inflight, writer.queue {
    None, [#(payload, size), ..rest] -> {
      process.send(writer.sender, payload)
      Writer(..writer, queue: rest, inflight: Some(size))
    }
    _, _ -> writer
  }
}

fn notify(writer: Writer) -> Writer {
  case writer.count {
    0 -> {
      list.each(writer.waiters, fn(waiter) { process.send(waiter, Nil) })
      Writer(..writer, waiters: [])
    }
    _ -> writer
  }
}

/// One sender may block in a write without growing any mailbox, because the
/// writer will not hand it a second payload until this one completes.
fn start_sender(
  writer: Subject(WriterMessage),
  channel: Channel,
) -> #(process.Pid, Subject(BitArray)) {
  let handshake = process.new_subject()
  let pid =
    process.start(
      fn() {
        let inbox = process.new_subject()
        process.send(handshake, inbox)
        sender_loop(writer, channel, inbox)
      },
      False,
    )
  let assert Ok(inbox) = process.receive(handshake, 5000)
  #(pid, inbox)
}

fn sender_loop(
  writer: Subject(WriterMessage),
  channel: Channel,
  inbox: Subject(BitArray),
) -> Nil {
  case process.receive(inbox, 60_000) {
    Error(_) -> sender_loop(writer, channel, inbox)
    Ok(payload) -> {
      let outcome = case channel {
        StdIo -> convex_sys.stdout_write(payload)
        Tcp(socket) -> convex_sys.send(socket, payload, 1000)
      }
      process.send(writer, SendDone(outcome))
      sender_loop(writer, channel, inbox)
    }
  }
}

fn emit(controller: Controller, event: Json) -> EmitResult {
  let payload = bit_array.from_string(json.to_string(event) <> "\n")
  let reply = process.new_subject()
  process.send(controller.writer, Enqueue(payload, reply))
  case process.receive(reply, emit_timeout) {
    Ok(outcome) -> outcome
    Error(_) -> Overflowed
  }
}

fn flush(writer: Subject(WriterMessage), timeout: Int) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(writer, FlushWhenIdle(reply))
  process.receive(reply, timeout)
}

fn stop_writer(writer: Subject(WriterMessage)) -> Result(WriterStop, Nil) {
  let reply = process.new_subject()
  process.send(writer, StopWriter(reply))
  process.receive(reply, 2000)
}
