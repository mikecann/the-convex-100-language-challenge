//// Convex Live: the reactive half of the client.
////
//// One owner process holds every piece of sync state: the query set version,
//// the server's last transition version, each subscription's last value, and
//// the reconnect schedule. Nothing else may touch that state, so a query-set
//// version can never be written twice or skipped.
////
//// A second process per connection owns the socket. It is a byte pipe: it
//// connects, performs the WebSocket handshake, forwards raw bytes to the
//// owner, and writes frames the owner hands it. Frame decoding stays in the
//// owner, which is what lets a read timeout be harmless part-way through a
//// frame. The parser state is in the owner and simply waits for more bytes.
////
//// A third process per subscription, the relay, carries one event at a time
//// towards the subscriber. It must ask the owner for permission immediately
//// before delivery, so unsubscribing or replacing a subscription is a real
//// barrier rather than a timing assumption: the owner erases the generation
//// first, and any event the relay is still holding is then discarded.

import convex_error.{type ConvexError}
import convex_http.{type Url}
import convex_json.{type Json, JsonArray, JsonInt, JsonObject, JsonString} as json
import convex_sys
import convex_ws as ws
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject, type Timer}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

/// The zero timestamp every connection starts from, base64 of eight zero
/// bytes, exactly as the pinned sync profile spells it.
const initial_timestamp = "AAAAAAAAAAA="

const sync_path = "/api/sync"

const client_header = "gleam-0.1.0"

/// Newest undelivered events retained per subscription, and the byte budget
/// that bounds them. The event a relay is physically holding counts against
/// both, so a slow subscriber cannot hide memory from the accounting.
const max_queue_count = 16

/// Charges encoded bytes four times plus a fixed record allowance. The bound
/// covers decoded BEAM terms as well as the JSON text used to size them.
const max_queue_bytes = 8_388_608

const event_overhead = 1024

const max_subscriptions = 8

const max_subscription_bytes = 8_388_608

const max_retiring_queries = 128

const initial_backoff = 100

const max_backoff = 15_000

/// How long a connection may take to reach an accepted WebSocket upgrade.
const handshake_timeout = 5000

/// How long the connection process blocks in one read before looking at its
/// command mailbox again. Buffered bytes and partial frames live in the owner,
/// so returning from a read early costs nothing.
const read_poll = 200

/// Once the first byte of a message arrives, continuous dribbling must not
/// keep its parser state forever.
const message_timeout = 3000

/// Bound on retiring a worker. Killing is a barrier; this is how long we are
/// willing to wait for the death certificate.
const retire_timeout = 1000

/// A brief idle grace period lets the adapter replace one identifier with
/// another over the same socket after it has observed the required Remove.
/// It still releases a client that genuinely has no subscriptions.
const idle_close_delay = 1000

/// What a subscriber receives.
pub type LiveEvent {
  /// A new value for the query, with any log lines the query produced.
  LiveValue(value: Json, logs: List(String))
  /// The query failed, the connection dropped, or the peer drifted from the
  /// pinned protocol. The subscription stays alive and can recover.
  LiveFailure(error: ConvexError)
}

/// One delivery to a subscriber's mailbox.
pub type SubscriptionEvent {
  SubscriptionEvent(
    subscription_id: String,
    event: LiveEvent,
    acknowledged: Subject(Nil),
  )
}

/// A handle on the Live owner.
pub opaque type Live {
  Live(commands: Subject(Command))
}

// TEST_ONLY_BEGIN
/// A test-only pause point. `convex.new` never supplies one; the deterministic
/// relay tests use it to hold an event after it has been dequeued and prove no
/// stale value can cross an unsubscribe acknowledgement.
pub type RelayGate =
  Subject(GateMessage)

pub type GateMessage {
  /// The relay has taken an event and is waiting to be released.
  GateHeld(release: Subject(Nil), subscription_id: String, event: LiveEvent)
}
// TEST_ONLY_END

pub opaque type Command {
  DoSubscribe(
    path: String,
    args: Json,
    sink: Subject(SubscriptionEvent),
    reply: Subject(Result(String, Nil)),
  )
  DoUnsubscribe(subscription_id: String, reply: Subject(Nil))
  DoDebugDisconnect(reply: Subject(Nil))
  DoClose(reply: Subject(Nil))
  /// A relay is holding an event and asks whether it may still be delivered.
  RelayDelivery(
    subscription_id: String,
    generation: Int,
    token: Int,
    event: LiveEvent,
    reply: Subject(Bool),
  )
  /// A relay has finished with an event and can take the next one.
  RelayReady(subscription_id: String, generation: Int, token: Int)
  ConnUp(connection: Int, inbox: Subject(ConnCommand), leftover: BitArray)
  ConnBytes(connection: Int, bytes: BitArray, acknowledged: Subject(Nil))
  ConnDown(connection: Int, reason: String)
  ConnShutdownDone(connection: Int, reply: Subject(Nil))
  HandshakeExpired(connection: Int)
  FrameExpired(connection: Int, token: Int)
  ReconnectDue(token: Int)
  IdleClose(token: Int)
}

/// What the owner can ask a connection process to do.
pub type ConnCommand {
  ConnSend(frame: BitArray)
  /// A final Remove must reach the kernel before the owner retires the last
  /// connection, otherwise an eager close can erase it from the wire.
  ConnSendAndAcknowledge(frame: BitArray, reply: Subject(Result(Nil, String)))
  /// Reply to a peer Close, then retire this socket and let the owner reconnect.
  ConnReplyAndClose(frame: BitArray, reason: String)
  ConnShutdown(frame: BitArray, reply: Subject(Nil))
  ConnStop
}

type DrainOutcome {
  ContinueReading
  StopRequested
  CloseRequested(reason: String)
  ShutdownRequested(reply: Subject(Nil))
  SendFailed(reason: String)
}

type RelayMessage {
  RelayEvent(
    subscription_id: String,
    generation: Int,
    token: Int,
    event: LiveEvent,
    sink: Subject(SubscriptionEvent),
  )
}

type Connection {
  Connection(
    id: Int,
    pid: Pid,
    inbox: Option(Subject(ConnCommand)),
    ready: Bool,
    decoder: ws.Decoder,
    frame_timer: Option(Timer),
    frame_token: Int,
  )
}

type Subscription {
  Subscription(
    query_id: Int,
    path: String,
    args: Json,
    sink: Subject(SubscriptionEvent),
    generation: Int,
    relay_pid: Pid,
    relay_inbox: Subject(RelayMessage),
    last: Option(Json),
    queue: List(#(LiveEvent, Int)),
    queue_count: Int,
    queue_bytes: Int,
    relay_busy: Bool,
    inflight_token: Option(Int),
    inflight_bytes: Int,
    /// Next delivery token. Tokens only need to be unique within one
    /// subscription, so a per-subscription counter is enough.
    next_token: Int,
    charge: Int,
  )
}

type State {
  State(
    self: Subject(Command),
    url: Url,
    verify_peer: Bool,
    // TEST_ONLY_BEGIN
    gate: Option(RelayGate),
    // TEST_ONLY_END
    connection: Option(Connection),
    next_connection_id: Int,
    subscriptions: Dict(String, Subscription),
    active_bytes: Int,
    retiring: List(Int),
    next_query_id: Int,
    session_identifier: String,
    /// The version this client has written up to.
    query_set: Int,
    /// The version the server last confirmed.
    remote_query_set: Int,
    remote_identity: Int,
    remote_timestamp: String,
    max_observed_timestamp: Option(String),
    connection_count: Int,
    last_close_reason: String,
    backoff: Int,
    reconnect: Option(Timer),
    reconnect_token: Int,
    handshake: Option(Timer),
    idle_close: Option(Timer),
    idle_close_token: Int,
    /// Generations are handed out from here. A subscription's generation is
    /// what a relay must still match to be allowed to deliver.
    next_generation: Int,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the single owner for a deployment. One client has exactly one owner,
/// so subscriptions share one WebSocket and one query set.
// PROD pub fn start(url: Url, verify_peer: Bool) -> Result(Live, String) {
// TEST_ONLY_BEGIN
pub fn start(
  url: Url,
  verify_peer: Bool,
  gate: Option(RelayGate),
) -> Result(Live, String) {
// TEST_ONLY_END
  let handshake = process.new_subject()
  let _pid =
    process.start(
      fn() {
        let self = process.new_subject()
        process.send(handshake, self)
        // PROD loop(initial_state(self, url, verify_peer))
        // TEST_ONLY_BEGIN
        loop(initial_state(self, url, verify_peer, gate))
        // TEST_ONLY_END
      },
      False,
    )
  case process.receive(handshake, 5000) {
    Ok(commands) -> Ok(Live(commands: commands))
    Error(_) -> Error("Live owner did not start")
  }
}

/// Add a query to the subscribed set and return its client-side identifier.
pub fn subscribe(
  live: Live,
  path: String,
  args: Json,
  sink: Subject(SubscriptionEvent),
) -> Result(String, Nil) {
  let reply = process.new_subject()
  process.send(live.commands, DoSubscribe(path, args, sink, reply))
  case process.receive(reply, 5000) {
    Ok(outcome) -> outcome
    Error(_) -> Error(Nil)
  }
}

/// Remove a query. When this returns, no further event for that subscription
/// can reach the sink, including one a relay had already dequeued.
pub fn unsubscribe(live: Live, subscription_id: String) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(live.commands, DoUnsubscribe(subscription_id, reply))
  process.receive(reply, 5000)
}

/// Adapter-only: drop the current connection and reconnect.
///
/// This is how the shared conformance controller proves real reconnects. It is
/// not part of the educational client API, and the acknowledgement is only
/// sent after the old connection is retired and the replacement is scheduled.
pub fn debug_disconnect(live: Live) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(live.commands, DoDebugDisconnect(reply))
  process.receive(reply, 5000)
}

/// Stop the owner, its connection, and every relay.
pub fn close(live: Live) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(live.commands, DoClose(reply))
  process.receive(reply, 5000)
}

// ---------------------------------------------------------------------------
// Owner
// ---------------------------------------------------------------------------

// PROD fn initial_state(self: Subject(Command), url: Url, verify_peer: Bool) -> State {
// TEST_ONLY_BEGIN
fn initial_state(
  self: Subject(Command),
  url: Url,
  verify_peer: Bool,
  gate: Option(RelayGate),
) -> State {
// TEST_ONLY_END
  State(
    self: self,
    url: url,
    verify_peer: verify_peer,
    // TEST_ONLY_BEGIN
    gate: gate,
    // TEST_ONLY_END
    connection: None,
    next_connection_id: 1,
    subscriptions: dict.new(),
    active_bytes: 0,
    retiring: [],
    next_query_id: 0,
    session_identifier: session_id(),
    query_set: 0,
    remote_query_set: 0,
    remote_identity: 0,
    remote_timestamp: initial_timestamp,
    max_observed_timestamp: None,
    connection_count: 0,
    last_close_reason: "InitialConnect",
    backoff: initial_backoff,
    reconnect: None,
    reconnect_token: 0,
    handshake: None,
    idle_close: None,
    idle_close_token: 0,
    next_generation: 1,
  )
}

/// The owner's mailbox loop. A receive timeout is not an event; it just means
/// nothing happened, so the loop re-arms rather than treating it as a failure.
fn loop(state: State) -> Nil {
  case process.receive(state.self, 60_000) {
    Error(_) -> loop(state)
    Ok(command) ->
      case handle(command, state) {
        Some(state) -> loop(state)
        None -> Nil
      }
  }
}

fn handle(command: Command, state: State) -> Option(State) {
  case command {
    DoSubscribe(path, args, sink, reply) -> {
      let state = cancel_idle_close(state)
      let query_id = state.next_query_id
      let charge = subscription_charge(path, args)
      case
        dict.size(state.subscriptions) >= max_subscriptions,
        state.active_bytes + charge > max_subscription_bytes,
        query_id > 4_294_967_294
      {
        True, _, _ | _, True, _ | _, _, True -> {
          process.send(reply, Error(Nil))
          Some(state)
        }
        False, False, False -> {
          let id = int.to_string(query_id)
          // PROD let #(relay_pid, relay_inbox) = start_relay(state.self)
          // TEST_ONLY_BEGIN
          let #(relay_pid, relay_inbox) = start_relay(state.self, state.gate)
          // TEST_ONLY_END
          let subscription =
            Subscription(
              query_id: query_id,
              path: path,
              args: args,
              sink: sink,
              generation: state.next_generation,
              relay_pid: relay_pid,
              relay_inbox: relay_inbox,
              last: None,
              queue: [],
              queue_count: 0,
              queue_bytes: 0,
              relay_busy: False,
              inflight_token: None,
              inflight_bytes: 0,
              next_token: 1,
              charge: charge,
            )
          let state =
            State(
              ..state,
              next_query_id: query_id + 1,
              next_generation: state.next_generation + 1,
              active_bytes: state.active_bytes + charge,
              subscriptions: dict.insert(state.subscriptions, id, subscription),
            )
          process.send(reply, Ok(id))
          Some(ensure_connected(send_modify(Add, subscription, state)))
        }
      }
    }

    DoUnsubscribe(id, reply) ->
      case dict.get(state.subscriptions, id) {
        Error(_) -> {
          process.send(reply, Nil)
          Some(state)
        }
        Ok(subscription) -> {
          // Retire the relay before acknowledging. Once it is dead it cannot
          // obtain delivery permission, so no stale event can cross this line.
          retire(subscription.relay_pid)
          let state =
            State(
              ..state,
              active_bytes: state.active_bytes - subscription.charge,
              subscriptions: dict.delete(state.subscriptions, id),
            )
          let state = case dict.is_empty(state.subscriptions) {
            True -> remove_then_idle_close(subscription, state)
            False -> ensure_connected(retire_remote_query(subscription, state))
          }
          process.send(reply, Nil)
          Some(state)
        }
      }

    DoDebugDisconnect(reply) -> {
      // Retire the old connection first, then schedule the replacement, and
      // only then acknowledge. The controller relies on that ordering.
      let state = disconnect("adapter debug disconnect", state)
      let state = ensure_connected(state)
      process.send(reply, Nil)
      Some(state)
    }

    DoClose(reply) -> {
      case state.connection {
        Some(Connection(inbox: Some(inbox), ready: True, ..)) -> {
          // The connection process sends this after any byte batch already in
          // flight has been acknowledged, so shutdown cannot deadlock the owner.
          process.send(
            inbox,
            ConnShutdown(ws.close_frame(1000, ""), reply),
          )
          Some(state)
        }
        _ -> finish_close(reply, state)
      }
    }

    RelayDelivery(id, generation, token, _event, reply) -> {
      // Permission is granted only if this subscription still exists, still
      // has the same generation, and is still waiting on this exact event.
      let allowed = case dict.get(state.subscriptions, id) {
        Ok(subscription) ->
          subscription.generation == generation
          && subscription.inflight_token == Some(token)
        Error(_) -> False
      }
      process.send(reply, allowed)
      Some(state)
    }

    RelayReady(id, generation, token) ->
      case dict.get(state.subscriptions, id) {
        Error(_) -> Some(state)
        Ok(subscription) ->
          case
            subscription.generation == generation
            && subscription.inflight_token == Some(token)
          {
            // A ready message from a retired relay must not clear the charge
            // held by its replacement.
            False -> Some(state)
            True -> {
              let subscription =
                Subscription(
                  ..subscription,
                  relay_busy: False,
                  inflight_token: None,
                  inflight_bytes: 0,
                )
              Some(put_subscription(state, id, dispatch_next(id, subscription)))
            }
          }
      }

    ConnUp(connection, inbox, leftover) ->
      case current_connection(state, connection) {
        None -> Some(state)
        Some(active) -> {
          // A completed upgrade is a healthy transport boundary, so a later
          // brief outage does not inherit backoff from earlier failures.
          let state =
            State(
              ..cancel_handshake(state),
              backoff: initial_backoff,
              connection: Some(
                Connection(..active, inbox: Some(inbox), ready: True),
              ),
            )
          let state = send_json(connect_message(state), state)
          let state = resend_all(state)
          Some(consume(connection, leftover, state))
        }
      }

    ConnBytes(connection, bytes, acknowledged) ->
      case current_connection(state, connection) {
        None -> {
          process.send(acknowledged, Nil)
          Some(state)
        }
        Some(_) -> {
          let state = consume(connection, bytes, state)
          process.send(acknowledged, Nil)
          Some(state)
        }
      }

    ConnDown(connection, reason) ->
      case current_connection(state, connection) {
        None -> Some(state)
        Some(_) -> Some(transport_reconnect(reason, state))
      }

    ConnShutdownDone(connection, reply) ->
      case current_connection(state, connection) {
        None -> finish_close(reply, state)
        Some(_) -> finish_close(reply, state)
      }

    HandshakeExpired(connection) ->
      case current_connection(state, connection) {
        None -> Some(state)
        Some(active) ->
          case active.ready {
            True -> Some(state)
            False ->
              Some(transport_reconnect(
                "WebSocket handshake timed out",
                State(..state, handshake: None),
              ))
          }
      }

    FrameExpired(connection, token) ->
      case current_connection(state, connection) {
        Some(active) ->
          case
            active.frame_token == token && ws.is_mid_message(active.decoder)
          {
            True ->
              Some(protocol_reconnect(
                "WebSocket message deadline exceeded",
                state,
              ))
            False -> Some(state)
          }
        None -> Some(state)
      }

    ReconnectDue(token) ->
      case token == state.reconnect_token {
        False -> Some(state)
        True -> Some(ensure_connected(State(..state, reconnect: None)))
      }

    IdleClose(token) ->
      case token == state.idle_close_token, dict.is_empty(state.subscriptions) {
        True, True -> Some(disconnect("no active subscriptions", state))
        _, _ -> Some(state)
      }
  }
}

/// Ignore anything that arrives from a connection the owner has already
/// retired. Late messages from a dead connection are normal, not errors.
fn current_connection(state: State, id: Int) -> Option(Connection) {
  case state.connection {
    None -> None
    Some(connection) ->
      case connection.id == id {
        True -> Some(connection)
        False -> None
      }
  }
}

fn put_subscription(
  state: State,
  id: String,
  subscription: Subscription,
) -> State {
  State(
    ..state,
    subscriptions: dict.insert(state.subscriptions, id, subscription),
  )
}

fn subscription_charge(path: String, args: Json) -> Int {
  bit_array.byte_size(bit_array.from_string(path))
  + bit_array.byte_size(bit_array.from_string(json.to_string(args)))
  + 512
}

fn retire_remote_query(subscription: Subscription, state: State) -> State {
  case is_ready(state), list.length(state.retiring) >= max_retiring_queries {
    False, _ -> state
    True, True -> disconnect("retiring query capacity reached", state)
    True, False ->
      send_modify(
        Remove,
        subscription,
        State(..state, retiring: [subscription.query_id, ..state.retiring]),
      )
  }
}

// ---------------------------------------------------------------------------
// Connection lifecycle
// ---------------------------------------------------------------------------

/// Open a connection when one is wanted. With no subscriptions there is
/// nothing to sync, so an idle client holds no socket.
fn ensure_connected(state: State) -> State {
  case state.connection, dict.is_empty(state.subscriptions) {
    Some(_), _ -> state
    None, True -> state
    None, False -> {
      let id = state.next_connection_id
      let owner = state.self
      let url = state.url
      let verify = state.verify_peer
      let pid =
        process.start(fn() { connection_main(owner, id, url, verify) }, False)
      let timer =
        process.send_after(state.self, handshake_timeout, HandshakeExpired(id))
      State(
        ..state,
        next_connection_id: id + 1,
        handshake: Some(timer),
        connection: Some(Connection(
          id: id,
          pid: pid,
          inbox: None,
          ready: False,
          decoder: ws.new_decoder(),
          frame_timer: None,
          frame_token: 0,
        )),
      )
    }
  }
}

/// The connection process: connect, upgrade, then pipe bytes both ways.
fn connection_main(
  owner: Subject(Command),
  id: Int,
  url: Url,
  verify_peer: Bool,
) -> Nil {
  let inbox = process.new_subject()
  let deadline = convex_sys.monotonic_ms() + handshake_timeout
  case
    convex_sys.connect(
      url.transport,
      url.host,
      url.port,
      handshake_timeout,
      verify_peer,
    )
  {
    Error(reason) -> process.send(owner, ConnDown(id, reason))
    Ok(socket) ->
      case
        ws.handshake(
          socket,
          url.authority,
          url.base_path <> sync_path,
          [#("convex-client", client_header)],
          deadline,
        )
      {
        Error(reason) -> {
          convex_sys.close(socket)
          process.send(owner, ConnDown(id, reason))
        }
        Ok(leftover) -> {
          process.send(owner, ConnUp(id, inbox, leftover))
          connection_loop(owner, id, socket, inbox)
        }
      }
  }
}

fn connection_loop(
  owner: Subject(Command),
  id: Int,
  socket: convex_sys.Socket,
  inbox: Subject(ConnCommand),
) -> Nil {
  case drain_commands(socket, inbox) {
    StopRequested -> convex_sys.close(socket)
    CloseRequested(reason) -> {
      convex_sys.close(socket)
      process.send(owner, ConnDown(id, reason))
    }
    ShutdownRequested(reply) -> {
      convex_sys.close(socket)
      process.send(owner, ConnShutdownDone(id, reply))
    }
    SendFailed(reason) -> {
      convex_sys.close(socket)
      process.send(owner, ConnDown(id, reason))
    }
    ContinueReading ->
      case convex_sys.recv(socket, 0, read_poll) {
        convex_sys.Received(bytes) -> {
          let acknowledged = process.new_subject()
          process.send(owner, ConnBytes(id, bytes, acknowledged))
          case process.receive(acknowledged, 5000) {
            Ok(_) -> connection_loop(owner, id, socket, inbox)
            Error(_) -> {
              convex_sys.close(socket)
              process.send(
                owner,
                ConnDown(id, "Live owner stopped acknowledging bytes"),
              )
            }
          }
        }
        // Nothing arrived in this window. The owner holds the decoder, so
        // there is no parser state here to lose.
        convex_sys.RecvTimeout -> connection_loop(owner, id, socket, inbox)
        convex_sys.RecvClosed -> {
          convex_sys.close(socket)
          process.send(owner, ConnDown(id, "WebSocket closed by peer"))
        }
        convex_sys.RecvFailed(reason) -> {
          convex_sys.close(socket)
          process.send(owner, ConnDown(id, reason))
        }
      }
  }
}

/// Write every queued frame before the next read. A terminal outcome tells the
/// connection loop whether it should stop quietly, report failure, or complete
/// one side of the WebSocket closing handshake.
fn drain_commands(
  socket: convex_sys.Socket,
  inbox: Subject(ConnCommand),
) -> DrainOutcome {
  case process.receive(inbox, 0) {
    Error(_) -> ContinueReading
    Ok(ConnStop) -> StopRequested
    Ok(ConnSend(frame)) ->
      case convex_sys.send(socket, frame, 3000) {
        Ok(_) -> drain_commands(socket, inbox)
        Error(reason) -> SendFailed(reason)
      }
    Ok(ConnSendAndAcknowledge(frame, reply)) ->
      case convex_sys.send(socket, frame, 3000) {
        Ok(_) -> {
          process.send(reply, Ok(Nil))
          drain_commands(socket, inbox)
        }
        Error(reason) -> {
          process.send(reply, Error(reason))
          SendFailed(reason)
        }
      }
    Ok(ConnReplyAndClose(frame, reason)) ->
      case convex_sys.send(socket, frame, 1000) {
        Ok(_) -> CloseRequested(reason)
        Error(send_reason) -> SendFailed(send_reason)
      }
    Ok(ConnShutdown(frame, reply)) -> {
      // `send_timeout_close` bounds a peer that never reads its final frame.
      let _ = convex_sys.send(socket, frame, 1000)
      ShutdownRequested(reply)
    }
  }
}

fn finish_close(reply: Subject(Nil), state: State) -> Option(State) {
  let state = disconnect("client closed", state)
  dict.each(state.subscriptions, fn(_id, subscription) {
    retire(subscription.relay_pid)
  })
  process.send(reply, Nil)
  None
}

/// Retire the current connection and reset the per-connection sync state. The
/// query set version restarts at zero because the next connection negotiates
/// it from scratch.
fn disconnect(reason: String, state: State) -> State {
  let state = cancel_idle_close(cancel_reconnect(cancel_handshake(state)))
  case state.connection {
    None -> Nil
    Some(connection) -> {
      case connection.frame_timer {
        Some(timer) -> {
          let _ = process.cancel_timer(timer)
          Nil
        }
        None -> Nil
      }
      // Killing the socket's owning process closes the socket, which is what
      // makes shutdown bounded even against a peer that never responds.
      case connection.inbox {
        Some(inbox) -> process.send(inbox, ConnStop)
        None -> Nil
      }
      retire(connection.pid)
    }
  }
  State(
    ..state,
    connection: None,
    query_set: 0,
    remote_query_set: 0,
    remote_identity: 0,
    remote_timestamp: initial_timestamp,
    retiring: [],
    connection_count: state.connection_count + 1,
    last_close_reason: reason,
  )
}

fn schedule_reconnect(reason: String, state: State) -> State {
  case dict.is_empty(state.subscriptions), state.reconnect {
    True, _ -> State(..state, last_close_reason: reason)
    False, Some(_) -> State(..state, last_close_reason: reason)
    False, None -> {
      let token = state.reconnect_token + 1
      let timer =
        process.send_after(state.self, state.backoff, ReconnectDue(token))
      State(
        ..state,
        reconnect: Some(timer),
        reconnect_token: token,
        backoff: int.min(max_backoff, state.backoff * 2),
        last_close_reason: reason,
      )
    }
  }
}

fn cancel_handshake(state: State) -> State {
  case state.handshake {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      State(..state, handshake: None)
    }
    None -> state
  }
}

fn cancel_reconnect(state: State) -> State {
  case state.reconnect {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      State(..state, reconnect: None)
    }
    None -> state
  }
}

fn cancel_idle_close(state: State) -> State {
  case state.idle_close {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      State(..state, idle_close: None)
    }
    None -> state
  }
}

/// A protocol failure is drift: report it to every subscription, then rebuild
/// the connection from a known state.
fn protocol_reconnect(message: String, state: State) -> State {
  let state = broadcast(convex_error.protocol_error(message), state)
  schedule_reconnect(message, disconnect(message, state))
}

/// A transport failure is also an observable subscription event. The
/// adapter-forced disconnect deliberately does not come through here: it is an
/// acknowledged test action, not a failure.
fn transport_reconnect(reason: String, state: State) -> State {
  let state = broadcast(convex_error.transport_error(reason), state)
  schedule_reconnect(reason, disconnect(reason, state))
}

fn broadcast(error: ConvexError, state: State) -> State {
  dict.fold(state.subscriptions, state, fn(state, id, subscription) {
    put_subscription(state, id, enqueue(id, LiveFailure(error), subscription))
  })
}

// ---------------------------------------------------------------------------
// Sync protocol
// ---------------------------------------------------------------------------

type Modification {
  Add
  Remove
}

fn connect_message(state: State) -> Json {
  let base = [
    #("type", JsonString("Connect")),
    #("sessionId", JsonString(state.session_identifier)),
    #("connectionCount", JsonInt(state.connection_count)),
    #("lastCloseReason", JsonString(state.last_close_reason)),
    #("clientTs", JsonInt(0)),
  ]
  case state.max_observed_timestamp {
    None -> JsonObject(base)
    Some(timestamp) ->
      JsonObject(
        list.append(base, [#("maxObservedTimestamp", JsonString(timestamp))]),
      )
  }
}

/// A version 4 UUID built from strong random bytes, in the shape the sync
/// protocol expects for a session identifier.
fn session_id() -> String {
  let bytes = convex_sys.random_bytes(16)
  let assert <<
    a:size(32)-big-int,
    b:size(16)-big-int,
    c:size(16)-big-int,
    d:size(16)-big-int,
    e:size(48)-big-int,
  >> = bytes
  let c = int.bitwise_or(int.bitwise_and(c, 0x0FFF), 0x4000)
  let d = int.bitwise_or(int.bitwise_and(d, 0x3FFF), 0x8000)
  string.join([hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)], "-")
}

fn hex(value: Int, width: Int) -> String {
  let digits = string.lowercase(int.to_base16(value))
  string.repeat("0", int.max(0, width - string.length(digits))) <> digits
}

/// Write one query-set modification. Every write advances the version by
/// exactly one, which is why only the owner may build these.
fn send_modify(
  kind: Modification,
  subscription: Subscription,
  state: State,
) -> State {
  case is_ready(state), state.query_set >= 4_294_967_295 {
    False, _ -> state
    _, True -> protocol_reconnect("Live query-set version is exhausted", state)
    True, False -> {
      let modification = case kind {
        Add ->
          JsonObject([
            #("type", JsonString("Add")),
            #("queryId", JsonInt(subscription.query_id)),
            #("udfPath", JsonString(subscription.path)),
            #("args", JsonArray([subscription.args])),
          ])
        Remove ->
          JsonObject([
            #("type", JsonString("Remove")),
            #("queryId", JsonInt(subscription.query_id)),
          ])
      }
      let message =
        JsonObject([
          #("type", JsonString("ModifyQuerySet")),
          #("baseVersion", JsonInt(state.query_set)),
          #("newVersion", JsonInt(state.query_set + 1)),
          #("modifications", JsonArray([modification])),
        ])
      send_json(message, State(..state, query_set: state.query_set + 1))
    }
  }
}

/// Remove the last query as an acknowledged connection command, then close an
/// otherwise idle socket after a short replacement grace period. `ConnSend` is
/// intentionally asynchronous for normal traffic, but using it here would
/// race the final close and make the required `Remove` disappear from the wire.
fn remove_then_idle_close(subscription: Subscription, state: State) -> State {
  case state.connection {
    Some(Connection(inbox: Some(inbox), ready: True, ..)) -> {
      let reply = process.new_subject()
      let modification =
        JsonObject([
          #("type", JsonString("Remove")),
          #("queryId", JsonInt(subscription.query_id)),
        ])
      let message =
        JsonObject([
          #("type", JsonString("ModifyQuerySet")),
          #("baseVersion", JsonInt(state.query_set)),
          #("newVersion", JsonInt(state.query_set + 1)),
          #("modifications", JsonArray([modification])),
        ])
      process.send(
        inbox,
        ConnSendAndAcknowledge(ws.text_frame(json.to_string(message)), reply),
      )
      case process.receive(reply, 3000) {
        Ok(Ok(_)) ->
          case list.length(state.retiring) >= max_retiring_queries {
            True ->
              disconnect(
                "retiring query capacity reached",
                State(..state, query_set: state.query_set + 1),
              )
            False ->
              schedule_idle_close(
                State(
                  ..state,
                  query_set: state.query_set + 1,
                  retiring: [subscription.query_id, ..state.retiring],
                ),
              )
          }
        Ok(Error(reason)) -> transport_reconnect(reason, state)
        Error(_) ->
          transport_reconnect("timed out sending final query removal", state)
      }
    }
    _ -> disconnect("no active subscriptions", state)
  }
}

fn schedule_idle_close(state: State) -> State {
  let token = state.idle_close_token + 1
  let timer = process.send_after(state.self, idle_close_delay, IdleClose(token))
  State(..state, idle_close: Some(timer), idle_close_token: token)
}

/// Every connection re-adds the active subscriptions, because the server keeps
/// no memory of a connection that has gone away.
fn resend_all(state: State) -> State {
  state.subscriptions
  |> dict.to_list
  |> list.sort(fn(left, right) {
    let #(_, first) = left
    let #(_, second) = right
    int.compare(first.query_id, second.query_id)
  })
  |> list.fold(state, fn(state, entry) {
    let #(_, subscription) = entry
    send_modify(Add, subscription, state)
  })
}

fn is_ready(state: State) -> Bool {
  case state.connection {
    Some(connection) -> connection.ready
    None -> False
  }
}

fn send_json(message: Json, state: State) -> State {
  case state.connection {
    Some(Connection(inbox: Some(inbox), ready: True, ..)) -> {
      process.send(inbox, ConnSend(ws.text_frame(json.to_string(message))))
      state
    }
    _ -> state
  }
}

/// Feed freshly read bytes into the connection's decoder and act on every
/// complete message it yields.
fn consume(connection: Int, bytes: BitArray, state: State) -> State {
  case current_connection(state, connection) {
    None -> state
    Some(active) -> {
      let decoder = ws.feed(active.decoder, bytes)
      drain_frames(connection, decoder, state)
    }
  }
}

fn drain_frames(connection: Int, decoder: ws.Decoder, state: State) -> State {
  case ws.next(decoder) {
    ws.NeedMore(decoder) -> store_decoder(connection, decoder, state)
    ws.Failed(reason) -> protocol_reconnect(reason, state)
    ws.Decoded(message, decoder) -> {
      let state = store_decoder(connection, decoder, state)
      case handle_message(connection, message, state) {
        // A message that retires the connection also discards its decoder.
        Error(state) -> state
        Ok(state) -> drain_frames(connection, decoder, state)
      }
    }
  }
}

fn store_decoder(connection: Int, decoder: ws.Decoder, state: State) -> State {
  case current_connection(state, connection) {
    None -> state
    Some(active) -> {
      let active = case ws.is_mid_message(decoder), active.frame_timer {
        True, None -> {
          let token = active.frame_token + 1
          let timer =
            process.send_after(
              state.self,
              message_timeout,
              FrameExpired(connection, token),
            )
          Connection(
            ..active,
            decoder: decoder,
            frame_timer: Some(timer),
            frame_token: token,
          )
        }
        True, Some(_) -> Connection(..active, decoder: decoder)
        False, Some(timer) -> {
          let _ = process.cancel_timer(timer)
          Connection(
            ..active,
            decoder: decoder,
            frame_timer: None,
            frame_token: active.frame_token + 1,
          )
        }
        False, None -> Connection(..active, decoder: decoder)
      }
      State(..state, connection: Some(active))
    }
  }
}

/// Act on one WebSocket message. `Error(state)` stops decoding the current byte
/// batch. Protocol errors retire the connection immediately; a peer Close first
/// queues the required Close reply, then the connection process retires it.
fn handle_message(
  connection: Int,
  message: ws.Message,
  state: State,
) -> Result(State, State) {
  case message {
    ws.TextMessage(text) -> handle_sync_text(text, state)
    ws.BinaryMessage(_) ->
      Error(protocol_reconnect("unexpected binary sync frame", state))
    ws.Ping(payload) -> {
      case current_connection(state, connection) {
        Some(Connection(inbox: Some(inbox), ..)) ->
          process.send(inbox, ConnSend(ws.pong_frame(payload)))
        _ -> Nil
      }
      Ok(state)
    }
    ws.Pong(_) -> Ok(state)
    ws.Close(code, reason) -> {
      let detail =
        "WebSocket close " <> int.to_string(code) <> ": " <> reason
      case current_connection(state, connection) {
        Some(Connection(inbox: Some(inbox), ..)) -> {
          // The connection process is waiting for this byte batch to be
          // acknowledged. Queue the reply now; it writes immediately after the
          // acknowledgement and reports ConnDown only once the socket is shut.
          process.send(
            inbox,
            ConnReplyAndClose(ws.close_reply_frame(code, reason), detail),
          )
          Error(state)
        }
        _ -> Error(transport_reconnect(detail, state))
      }
    }
  }
}

fn handle_sync_text(text: String, state: State) -> Result(State, State) {
  case json.parse(text) {
    Error(_) -> Error(protocol_reconnect("invalid sync JSON", state))
    Ok(message) ->
      case json.string_field(message, "type") {
        Ok("Transition") -> apply_transition(message, state)
        Ok("Ping") -> Ok(state)
        Ok("FatalError") ->
          Error(protocol_reconnect(fatal_message(message), state))
        Ok(other) ->
          Error(protocol_reconnect("unexpected sync message " <> other, state))
        Error(_) -> Error(protocol_reconnect("sync message has no type", state))
      }
  }
}

fn fatal_message(message: Json) -> String {
  case json.string_field(message, "error") {
    Ok(detail) -> detail
    Error(_) -> "server reported a fatal sync error"
  }
}

/// A Transition is atomic: validate the whole message, then apply it.
///
/// Validating first matters because a malformed tail must not be able to leak
/// an earlier value from the same Transition or to advance the version
/// counters half way.
fn apply_transition(message: Json, state: State) -> Result(State, State) {
  case transition_parts(message, state) {
    Error(reason) -> Error(protocol_reconnect(reason, state))
    Ok(#(end_query_set, end_identity, end_timestamp, changes)) -> {
      let state =
        State(
          ..state,
          remote_query_set: end_query_set,
          remote_identity: end_identity,
          remote_timestamp: end_timestamp,
          max_observed_timestamp: observed_max(
            state.max_observed_timestamp,
            end_timestamp,
          ),
          // A valid server transition proves the connection works.
          backoff: initial_backoff,
        )
      Ok(
        list.fold(changes, state, fn(state, change) {
          apply_change(change, state)
        }),
      )
    }
  }
}

type Change {
  ChangedValue(query_id: Int, value: Json, logs: List(String))
  ChangedFailure(query_id: Int, error: ConvexError)
  ChangedRemoved(query_id: Int)
}

fn transition_parts(
  message: Json,
  state: State,
) -> Result(#(Int, Int, String, List(Change)), String) {
  use start <- result.try(
    json.field(message, "startVersion")
    |> result.replace_error("Transition has no startVersion"),
  )
  use end <- result.try(
    json.field(message, "endVersion")
    |> result.replace_error("Transition has no endVersion"),
  )
  use modifications <- result.try(
    json.field(message, "modifications")
    |> result.try(json.as_array)
    |> result.replace_error("Transition has no modifications"),
  )
  use #(start_query_set, start_identity, start_timestamp) <- result.try(version(
    start,
  ))
  use #(end_query_set, end_identity, end_timestamp) <- result.try(version(end))
  use start_number <- result.try(
    timestamp_number(start_timestamp)
    |> result.replace_error("Transition has an invalid start timestamp"),
  )
  use end_number <- result.try(
    timestamp_number(end_timestamp)
    |> result.replace_error("Transition has an invalid end timestamp"),
  )
  use _ <- result.try(
    case
      start_query_set == state.remote_query_set
      && start_identity == state.remote_identity
      && start_timestamp == state.remote_timestamp
    {
      True -> Ok(Nil)
      False -> Error("Transition does not continue the current version")
    },
  )
  use _ <- result.try(case end_number >= start_number {
    True -> Ok(Nil)
    False -> Error("Transition timestamp went backwards")
  })
  use _ <- result.try(
    case
      end_query_set >= start_query_set,
      end_query_set <= state.query_set,
      end_identity >= start_identity
    {
      True, True, True -> Ok(Nil)
      _, _, _ ->
        Error("Transition version moved backwards or acknowledged unsent work")
    },
  )
  use changes <- result.try(list.try_map(modifications, modification))
  use changes <- result.try(validate_changes(changes, state, []))
  Ok(#(end_query_set, end_identity, end_timestamp, changes))
}

fn version(value: Json) -> Result(#(Int, Int, String), String) {
  use query_set <- result.try(
    json.u32_field(value, "querySet")
    |> result.replace_error("sync version has an invalid querySet"),
  )
  use identity <- result.try(
    json.u32_field(value, "identity")
    |> result.replace_error("sync version has an invalid identity"),
  )
  use timestamp <- result.try(
    json.string_field(value, "ts")
    |> result.replace_error("sync version has an invalid ts"),
  )
  Ok(#(query_set, identity, timestamp))
}

fn modification(value: Json) -> Result(Change, String) {
  use query_id <- result.try(
    json.u32_field(value, "queryId")
    |> result.replace_error("modification has an invalid queryId"),
  )
  use logs <- result.try(
    json.log_lines(value)
    |> result.replace_error("modification has invalid logLines"),
  )
  case json.string_field(value, "type") {
    Ok("QueryUpdated") ->
      case json.field(value, "value") {
        Ok(inner) -> Ok(ChangedValue(query_id, inner, logs))
        Error(_) -> Error("QueryUpdated has no value")
      }
    Ok("QueryFailed") ->
      case json.string_field(value, "errorMessage") {
        Error(_) -> Error("QueryFailed has no errorMessage")
        Ok(detail) ->
          Ok(ChangedFailure(
            query_id,
            convex_error.function_error(
              detail,
              // Absence and an explicit null mean different things to Convex.
              case json.has_field(value, "errorData") {
                True -> option.from_result(json.field(value, "errorData"))
                False -> None
              },
              logs,
            ),
          ))
      }
    Ok("QueryRemoved") -> Ok(ChangedRemoved(query_id))
    _ -> Error("unknown query-set modification")
  }
}

fn validate_changes(
  changes: List(Change),
  state: State,
  seen: List(Int),
) -> Result(List(Change), String) {
  case changes {
    [] -> Ok([])
    [change, ..rest] -> {
      let query_id = change_query_id(change)
      use _ <- result.try(case list.contains(seen, query_id) {
        True -> Error("Transition repeats a query identifier")
        False -> Ok(Nil)
      })
      use _ <- result.try(
        case
          find_subscription(state, query_id),
          list.contains(state.retiring, query_id),
          change
        {
          Ok(_), _, ChangedRemoved(_) -> Error("server removed an active query")
          Ok(_), _, _ -> Ok(Nil)
          Error(_), True, _ -> Ok(Nil)
          Error(_), False, _ -> Error("Transition references an unknown query")
        },
      )
      use validated <- result.try(
        validate_changes(rest, state, [query_id, ..seen]),
      )
      Ok([change, ..validated])
    }
  }
}

fn change_query_id(change: Change) -> Int {
  case change {
    ChangedValue(query_id, _, _) -> query_id
    ChangedFailure(query_id, _) -> query_id
    ChangedRemoved(query_id) -> query_id
  }
}

fn apply_change(change: Change, state: State) -> State {
  case find_subscription(state, change_query_id(change)) {
    Error(_) ->
      case change {
        ChangedRemoved(query_id) ->
          State(
            ..state,
            retiring: list.filter(state.retiring, fn(id) { id != query_id }),
          )
        _ -> state
      }
    Ok(#(id, subscription)) ->
      case change {
        ChangedRemoved(_) -> state
        ChangedFailure(_, error) ->
          put_subscription(
            state,
            id,
            enqueue(
              id,
              LiveFailure(error),
              Subscription(..subscription, last: None),
            ),
          )
        ChangedValue(_, value, logs) ->
          // An unchanged value after a reconnect is rehydration, not news.
          case subscription.last == Some(value) {
            True -> state
            False ->
              put_subscription(
                state,
                id,
                enqueue_value(id, value, logs, subscription),
              )
          }
      }
  }
}

fn find_subscription(
  state: State,
  query_id: Int,
) -> Result(#(String, Subscription), Nil) {
  state.subscriptions
  |> dict.to_list
  |> list.find_map(fn(entry) {
    let #(id, subscription) = entry
    case subscription.query_id == query_id {
      True -> Ok(#(id, subscription))
      False -> Error(Nil)
    }
  })
}

/// Convex timestamps are base64 of a little-endian unsigned 64-bit value.
/// Re-encoding proves the text was canonical, so a padded or mangled variant
/// is rejected rather than compared as a string.
pub fn timestamp_number(timestamp: String) -> Result(Int, Nil) {
  use bytes <- result.try(convex_sys.base64_decode(timestamp))
  case bytes {
    <<number:size(64)-unsigned-little-int>> ->
      case convex_sys.base64_encode(bytes) == timestamp {
        True -> Ok(number)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn observed_max(current: Option(String), candidate: String) -> Option(String) {
  case current {
    None -> Some(candidate)
    Some(current) ->
      case timestamp_number(current), timestamp_number(candidate) {
        Ok(left), Ok(right) ->
          case int.compare(left, right) {
            order.Lt -> Some(candidate)
            _ -> Some(current)
          }
        _, _ -> Some(candidate)
      }
  }
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

// PROD fn start_relay(owner: Subject(Command)) -> #(Pid, Subject(RelayMessage)) {
// TEST_ONLY_BEGIN
fn start_relay(
  owner: Subject(Command),
  gate: Option(RelayGate),
) -> #(Pid, Subject(RelayMessage)) {
// TEST_ONLY_END
  let handshake = process.new_subject()
  let pid =
    process.start(
      fn() {
        let inbox = process.new_subject()
        process.send(handshake, inbox)
        // PROD relay_loop(owner, inbox)
        // TEST_ONLY_BEGIN
        relay_loop(owner, inbox, gate)
        // TEST_ONLY_END
      },
      False,
    )
  let assert Ok(inbox) = process.receive(handshake, 5000)
  #(pid, inbox)
}

// PROD fn relay_loop(owner: Subject(Command), inbox: Subject(RelayMessage)) -> Nil {
// TEST_ONLY_BEGIN
fn relay_loop(
  owner: Subject(Command),
  inbox: Subject(RelayMessage),
  gate: Option(RelayGate),
) -> Nil {
// TEST_ONLY_END
  case process.receive(inbox, 60_000) {
    // PROD Error(_) -> relay_loop(owner, inbox)
    // TEST_ONLY_BEGIN
    Error(_) -> relay_loop(owner, inbox, gate)
    // TEST_ONLY_END
    Ok(RelayEvent(id, generation, token, event, sink)) -> {
      // TEST_ONLY_BEGIN
      hold(gate, id, event)
      // TEST_ONLY_END
      let reply = process.new_subject()
      process.send(owner, RelayDelivery(id, generation, token, event, reply))
      case wait_for_permission(reply) {
        True -> {
          let acknowledged = process.new_subject()
          process.send(sink, SubscriptionEvent(id, event, acknowledged))
          wait_for_acknowledgement(acknowledged)
          process.send(owner, RelayReady(id, generation, token))
          // PROD relay_loop(owner, inbox)
          // TEST_ONLY_BEGIN
          relay_loop(owner, inbox, gate)
          // TEST_ONLY_END
        }
        False -> Nil
      }
    }
  }
}

fn wait_for_permission(reply: Subject(Bool)) -> Bool {
  case process.receive(reply, 60_000) {
    Ok(allowed) -> allowed
    Error(_) -> wait_for_permission(reply)
  }
}

fn wait_for_acknowledgement(acknowledged: Subject(Nil)) -> Nil {
  case process.receive(acknowledged, 60_000) {
    Ok(_) -> Nil
    Error(_) -> wait_for_acknowledgement(acknowledged)
  }
}

// TEST_ONLY_BEGIN
/// The deterministic tests pause a relay here, after it has taken an event but
/// before it asks for permission. Production clients pass `None`.
fn hold(gate: Option(RelayGate), id: String, event: LiveEvent) -> Nil {
  case gate {
    None -> Nil
    Some(gate) -> {
      let release = process.new_subject()
      process.send(gate, GateHeld(release, id, event))
      let _ = process.receive(release, 60_000)
      Nil
    }
  }
}
// TEST_ONLY_END

/// Hand an event to the relay if it is idle, otherwise queue it under the
/// count and byte bounds.
fn enqueue(
  id: String,
  event: LiveEvent,
  subscription: Subscription,
) -> Subscription {
  let bytes = event_bytes(event)
  case bytes > max_queue_bytes {
    // Never make an accepted transition disappear. Replace an event which
    // cannot fit the delivery budget with a small observable protocol failure.
    True ->
      enqueue(
        id,
        LiveFailure(convex_error.protocol_error(
          "Live event exceeds the delivery byte budget",
        )),
        subscription,
      )
    False ->
      case subscription.relay_busy {
        False -> send_to_relay(id, event, bytes, subscription)
        True ->
          Subscription(
            ..subscription,
            queue: list.append(subscription.queue, [#(event, bytes)]),
            queue_count: subscription.queue_count + 1,
            queue_bytes: subscription.queue_bytes + bytes,
          )
          |> trim(id, _)
          |> dispatch_if_idle(id, _)
      }
  }
}

/// Record `last` only after proving the value can enter the bounded delivery
/// path. Otherwise a reconnect would suppress the same value even though the
/// subscriber never observed it.
fn enqueue_value(
  id: String,
  value: Json,
  logs: List(String),
  subscription: Subscription,
) -> Subscription {
  let event = LiveValue(value, logs)
  case event_bytes(event) > max_queue_bytes {
    True -> enqueue(id, event, subscription)
    False ->
      enqueue(id, event, Subscription(..subscription, last: Some(value)))
  }
}

/// Start queued work whenever no consumer acknowledgement is outstanding.
fn dispatch_if_idle(id: String, subscription: Subscription) -> Subscription {
  case subscription.relay_busy {
    True -> subscription
    False -> dispatch_next(id, subscription)
  }
}

/// Hand one event to the relay and record the delivery token that will be
/// checked when the relay comes back asking for permission.
fn send_to_relay(
  id: String,
  event: LiveEvent,
  bytes: Int,
  subscription: Subscription,
) -> Subscription {
  let token = subscription.next_token
  process.send(
    subscription.relay_inbox,
    RelayEvent(id, subscription.generation, token, event, subscription.sink),
  )
  Subscription(
    ..subscription,
    next_token: token + 1,
    relay_busy: True,
    inflight_token: Some(token),
    inflight_bytes: bytes,
  )
}

/// Enforce the count and byte bounds, dropping the oldest events first so a
/// slow subscriber sees the newest state rather than a stale prefix.
fn trim(id: String, subscription: Subscription) -> Subscription {
  let total_bytes = subscription.queue_bytes + subscription.inflight_bytes
  let total_count =
    subscription.queue_count
    + case subscription.relay_busy {
      True -> 1
      False -> 0
    }
  case total_count <= max_queue_count && total_bytes <= max_queue_bytes {
    True -> subscription
    False ->
      case subscription.queue {
        [#(_dropped, dropped_bytes), ..rest] ->
          trim(
            id,
            Subscription(
              ..subscription,
              queue: rest,
              queue_count: subscription.queue_count - 1,
              queue_bytes: subscription.queue_bytes - dropped_bytes,
            ),
          )
        // The one in-flight event is waiting for the consumer's explicit
        // acknowledgement. It cannot be evicted from the relay process, but
        // it was rejected before dispatch if it exceeded the whole budget.
        [] -> subscription
      }
  }
}

/// Give the relay the next queued event once it reports itself idle.
fn dispatch_next(id: String, subscription: Subscription) -> Subscription {
  case subscription.queue {
    [] -> subscription
    [#(event, bytes), ..rest] ->
      send_to_relay(
        id,
        event,
        bytes,
        Subscription(
          ..subscription,
          queue: rest,
          queue_count: subscription.queue_count - 1,
          queue_bytes: subscription.queue_bytes - bytes,
        ),
      )
  }
}

/// Size an event by its encoded form, which is what the adapter will actually
/// write, rather than by an in-memory estimate.
fn event_bytes(event: LiveEvent) -> Int {
  let encoded = case event {
    LiveValue(value, logs) ->
      json.to_string(
        JsonObject([
          #("value", value),
          #("logs", JsonArray(list.map(logs, JsonString))),
        ]),
      )
    LiveFailure(error) -> json.to_string(convex_error.to_json(error))
  }
  { bit_array.byte_size(bit_array.from_string(encoded)) * 4 } + event_overhead
}

fn retire(pid: Pid) -> Nil {
  let _ = convex_sys.kill_and_wait(pid, retire_timeout)
  Nil
}
