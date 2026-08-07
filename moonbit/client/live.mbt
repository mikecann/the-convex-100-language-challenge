// The Live worker: one owner for the Convex sync WebSocket.
//
// Exactly one task ever touches the socket, the query-set version counter, or
// the reconnect schedule. Callers of `subscribe`, `unsubscribe`, `close` and
// the adapter-only debug hook hand a command to that owner through a bounded
// queue and wait for it to be acknowledged. Nothing else is allowed near the
// connection, which is what makes the version chain and the acknowledgement
// ordering provable rather than hopeful.
//
// The owner is single threaded but not blocking: a per-connection reader task
// decodes frames and posts them onto the same command queue, so the owner sees
// one ordered stream of "a command arrived" and "the server said something".
// One queue means no select, and no select means no cancelling a half-read
// frame - a cancelled read is always followed by abandoning the connection.

///|
/// Largest Live message this client will assemble, in bytes.
pub const LIVE_MAX_MESSAGE_BYTES : Int = 2097152

///|
/// Deadline for one Live write, including the whole `ModifyQuerySet` frame.
/// Bounded so an idle or stalled peer cannot make `unsubscribe` or `close`
/// hang: the write is abandoned and the connection is retired instead.
const LIVE_WRITE_TIMEOUT_MS : Int = 2000

///|
/// Deadline for the TCP connect, TLS handshake, and WebSocket upgrade.
const LIVE_CONNECT_TIMEOUT_MS : Int = 8000

///|
/// Deadline a caller waits for the owner to acknowledge one command.
const LIVE_COMMAND_TIMEOUT_MS : Int = 9000

///|
/// Deadline for handing one command to the owner.
///
/// The command queue is deliberately bounded, so handing off can block when the
/// reader is producing faster than the owner consumes. Without this bound
/// `unsubscribe` and `close` would be bounded only on the owner's side: a full
/// queue could hold a caller before it ever reached the acknowledgement wait.
const LIVE_SUBMIT_TIMEOUT_MS : Int = 2000

///|
/// Longest close reason this client will report to the server.
///
/// The reason travels back to the deployment in the next `Connect`, and it can
/// quote text the peer chose, so an implausibly long one is replaced rather
/// than reflected. Replacing beats truncating: cutting a MoonBit string at a
/// fixed offset can split a surrogate pair.
const LIVE_CLOSE_REASON_MAX_CHARS : Int = 200

///|
/// Shortest and longest reconnect delays. The delay resets to the minimum after
/// a successful handshake, so a healthy connection that follows a bad run does
/// not inherit the old maximum.
const LIVE_BACKOFF_MIN_MS : Int = 100

///|
const LIVE_BACKOFF_MAX_MS : Int = 15000

///|
/// Pause before reconnecting after the adapter-only debug disconnect. Long
/// enough to make the reconnect a real one, short enough to keep conformance
/// runs quick.
const LIVE_DEBUG_RECONNECT_MS : Int = 100

///|
/// Convex's sync endpoint, upgraded from the deployment's HTTP origin.
const SYNC_ENDPOINT : String = "/api/sync"

///|
/// A caller waiting for the owner to finish one command.
struct Completion {
  mut settled : Bool
  /// Set when the caller stopped waiting. Because the wait is bounded, the
  /// owner can still reach a command whose caller has already given up, and it
  /// reads this to undo that command instead of leaving it registered.
  mut abandoned : Bool
  mut failure : ConvexError?
  cond : @cond_var.Cond
}

///|
fn Completion::new() -> Completion {
  {
    settled: false,
    abandoned: false,
    failure: None,
    cond: @cond_var.Cond::Cond(),
  }
}

///|
fn Completion::succeed(self : Completion) -> Unit {
  if !self.settled {
    self.settled = true
    self.cond.broadcast()
  }
}

///|
fn Completion::fail(self : Completion, failure : ConvexError) -> Unit {
  if !self.settled {
    self.settled = true
    self.failure = Some(failure)
    self.cond.broadcast()
  }
}

///|
/// Wait for the owner to settle this command.
///
/// The wait is bounded. If the owner is wedged the caller gets a
/// `TransportError` instead of blocking forever, which keeps `unsubscribe` and
/// `close` bounded from the caller's side as well as the owner's.
async fn Completion::wait(self : Completion) -> Unit {
  let deadline = @async.now() + LIVE_COMMAND_TIMEOUT_MS.to_int64()
  while !self.settled {
    let remaining = deadline - @async.now()
    guard remaining > 0L else {
      // Say so before giving up. The command is still queued and the owner may
      // yet reach it; marking it abandoned is what lets the owner undo work
      // nobody is waiting for any more.
      self.abandoned = true
      raise transport_error("timed out waiting for the Live worker")
    }
    @async.with_timeout_opt(remaining.to_int(), () => self.cond.wait())
    |> ignore
  }
  match self.failure {
    Some(failure) => raise failure
    None => ()
  }
}

///|
/// Work the owner performs. Every one of these mutates connection state, so
/// none of them may run anywhere but inside the owner loop.
priv enum Command {
  AddQuery(Subscription, Completion)
  RemoveQuery(Subscription, Completion)
  DebugDisconnect(Completion)
  Shutdown(Completion)
}

///|
/// The single ordered stream the owner consumes.
priv enum LiveEvent {
  Issued(Command)
  /// A decoded server message, tagged with the connection generation it was
  /// read from so that a message in flight when a connection was retired is
  /// discarded instead of being applied to its successor.
  Incoming(Int, Json)
  /// The reader gave up on the tagged connection. The kind separates "the peer
  /// said something this client cannot honour" from "the bytes stopped
  /// arriving", which are different problems even though both end the
  /// connection.
  Down(Int, ErrorKind, String)
}

///|
/// What the owner should do after handling one event.
priv enum SessionStep {
  Continue
  EndSession
}

///|
/// Owns the Live socket and every piece of state that depends on it.
pub struct LiveManager {
  mut client : Client?
  subscriptions : Array[Subscription]
  priv events : @aqueue.Queue[LiveEvent]
  session_id : String
  mut next_query_id : Int
  mut next_add_sequence : Int
  /// Local query-set version. Resets to zero on every new connection because
  /// the server's chain restarts with the socket.
  mut query_set_version : Int
  mut remote : StateVersion
  mut max_observed_timestamp : String?
  mut connection_count : Int
  mut last_close_reason : String
  /// Increments for every connection attempt and tags reader events.
  mut generation : Int
  mut connected : Bool
  mut stopped : Bool
  mut backoff_ms : Int
  mut reconnect_at : Int64
  /// Commands that must not be acknowledged until the old connection has been
  /// fully retired.
  deferred : Array[Completion]
}

///|
fn LiveManager::new() -> LiveManager {
  // 16 random bytes are enough for a session id. If the platform entropy
  // source is unavailable the session id falls back to a fixed nil UUID rather
  // than failing construction: a duplicate session id degrades Convex's
  // reconnect bookkeeping, it does not break correctness.
  let session_id = match @env.rand(16) {
    Some(raw) => format_session_id(raw)
    None => "00000000-0000-4000-8000-000000000000"
  }
  {
    client: None,
    subscriptions: [],
    events: @aqueue.Queue::Queue(kind=@aqueue.Kind::Blocking(256)),
    session_id,
    next_query_id: 0,
    next_add_sequence: 0,
    query_set_version: 0,
    remote: { query_set: 0L, identity: 0L, ts: INITIAL_TIMESTAMP },
    max_observed_timestamp: None,
    connection_count: 0,
    last_close_reason: "InitialConnect",
    generation: 0,
    connected: false,
    stopped: false,
    backoff_ms: LIVE_BACKOFF_MIN_MS,
    reconnect_at: 0L,
    deferred: [],
  }
}

///|
/// Number of connections this manager has opened. Carried into `Connect` and
/// asserted by the reconnect tests.
pub fn LiveManager::connection_count(self : LiveManager) -> Int {
  self.connection_count
}

///|
/// Why the previous connection went away. Carried into `Connect`.
pub fn LiveManager::last_close_reason(self : LiveManager) -> String {
  self.last_close_reason
}

///|
/// Highest database timestamp this client has observed, or `None` before the
/// first transition.
pub fn LiveManager::max_observed_timestamp(self : LiveManager) -> String? {
  self.max_observed_timestamp
}

///|
fn LiveManager::active_count(self : LiveManager) -> Int {
  let mut count = 0
  for subscription in self.subscriptions {
    if subscription.active && !subscription.remove_pending {
      count = count + 1
    }
  }
  count
}

///|
fn LiveManager::find(self : LiveManager, query_id : Int64) -> Subscription? {
  for subscription in self.subscriptions {
    if subscription.id.to_int64() == query_id {
      return Some(subscription)
    }
  }
  None
}

///|
/// Find a subscription that is still live, ignoring ones already retired.
fn LiveManager::find_active(
  self : LiveManager,
  query_id : Int64,
) -> Subscription? {
  match self.find(query_id) {
    Some(subscription) =>
      if subscription.active && !subscription.remove_pending {
        Some(subscription)
      } else {
        None
      }
    None => None
  }
}

// ---------------------------------------------------------------------------
// Caller-facing entry points. These only ever enqueue and wait.
// ---------------------------------------------------------------------------

///|
async fn LiveManager::submit(
  self : LiveManager,
  command : Command,
  completion : Completion,
) -> Unit {
  guard !self.stopped else { raise closed_error("Live worker has stopped") }
  // Both halves of the handoff are bounded. A full command queue must not be
  // able to hold `unsubscribe` or `close` any longer than a wedged owner can.
  @async.with_timeout(LIVE_SUBMIT_TIMEOUT_MS, () => {
    self.events.put(Issued(command))
  }) catch {
    error => {
      completion.abandoned = true
      raise as_convex_error(error, "Live worker did not accept the command")
    }
  }
  completion.wait()
}

///|
async fn LiveManager::add(
  self : LiveManager,
  path : String,
  args : Json,
) -> Subscription {
  self.next_query_id = self.next_query_id + 1
  self.next_add_sequence = self.next_add_sequence + 1
  let subscription = Subscription::{
    id: self.next_query_id,
    path,
    args,
    manager: self,
    add_sequence: self.next_add_sequence,
    active: true,
    add_pending: true,
    remove_pending: false,
    remove_done: false,
    rehydrating: false,
    has_last_value: false,
    last_value: None,
    queue: [],
    queued_bytes: 0,
    dropped: 0,
    ready: @cond_var.Cond::Cond(),
  }
  let completion = Completion::new()
  self.submit(AddQuery(subscription, completion), completion)
  subscription
}

///|
async fn LiveManager::remove(
  self : LiveManager,
  subscription : Subscription,
) -> Unit {
  if !subscription.active || subscription.remove_done {
    return
  }
  let completion = Completion::new()
  self.submit(RemoveQuery(subscription, completion), completion)
}

///|
/// Retire every subscription and close the socket. Safe to call twice.
async fn LiveManager::shutdown(self : LiveManager) -> Unit {
  if self.stopped {
    return
  }
  let completion = Completion::new()
  // Shutdown is best effort by design: a client that is already wedged must
  // still be able to finish closing, so a failure here is swallowed rather
  // than propagated into the caller's teardown path.
  self.submit(Shutdown(completion), completion) catch {
    _ => self.stopped = true
  }
}

// ---------------------------------------------------------------------------
// The owner. Everything below runs in exactly one task.
// ---------------------------------------------------------------------------

///|
/// The Live worker's main loop.
///
/// It alternates between two states. Disconnected: drain commands as they
/// arrive and open a connection once the backoff has elapsed and at least one
/// subscription wants one. Connected: run a session until the server, the
/// transport, or a command retires it.
async fn LiveManager::run(self : LiveManager) -> Unit {
  while !self.stopped {
    self.drain_offline_commands()
    if self.stopped {
      break
    }
    if self.active_count() == 0 {
      // Nothing to subscribe to: block until a command shows up rather than
      // spinning. A `Down` or `Incoming` from a retired connection is simply
      // discarded here.
      let waited = Some(self.events.get()) catch { _ => None }
      match waited {
        Some(event) => self.handle_offline_event(event)
        None => self.stopped = true
      }
      continue
    }
    let waiting = self.reconnect_at - @async.now()
    if waiting > 0L {
      // Sleep in short slices so a command that arrives during the backoff is
      // still handled promptly. `unsubscribe` while disconnected must not wait
      // for the whole backoff.
      @async.sleep(if waiting > 20L { 20 } else { waiting.to_int() })
      continue
    }
    self.run_session()
  }
  self.finish()
}

///|
/// Handle whatever commands are already queued without blocking.
fn LiveManager::drain_offline_commands(self : LiveManager) -> Unit {
  while true {
    let pending = self.events.try_get() catch { _ => None }
    match pending {
      Some(event) => self.handle_offline_event(event)
      None => break
    }
  }
}

///|
fn LiveManager::handle_offline_event(
  self : LiveManager,
  event : LiveEvent,
) -> Unit {
  match event {
    // Reader traffic from a connection that no longer exists.
    Incoming(_, _) => ()
    Down(_, _, _) => ()
    Issued(command) => self.apply_offline_command(command)
  }
}

///|
/// Apply a command with no connection available.
///
/// `Add` just registers: the next connection will send it. `Remove` completes
/// locally, because a subscription the server never learned about needs no
/// server-side removal. `DebugDisconnect` fails loudly rather than pretending
/// to have disconnected something.
fn LiveManager::apply_offline_command(
  self : LiveManager,
  command : Command,
) -> Unit {
  match command {
    AddQuery(subscription, completion) =>
      // Nobody is holding this subscription any more, so registering it would
      // leave the worker reconnecting forever on behalf of a consumer that gave
      // up. Retire it instead of accepting orphaned work.
      if completion.abandoned {
        self.retire(subscription)
      } else {
        self.subscriptions.push(subscription)
        completion.succeed()
      }
    RemoveQuery(subscription, completion) => {
      self.retire(subscription)
      completion.succeed()
    }
    DebugDisconnect(completion) =>
      completion.fail(transport_error("Live WebSocket is not connected"))
    Shutdown(completion) => {
      self.stopped = true
      for subscription in self.subscriptions {
        self.retire(subscription)
      }
      completion.succeed()
    }
  }
  self.compact()
}

///|
/// Invalidate a subscription and release everything it had queued.
///
/// This runs before the caller's acknowledgement is published, so a consumer
/// that is paused between dequeue and delivery can never emit an update for a
/// subscription that has already been acknowledged as removed.
fn LiveManager::retire(self : LiveManager, subscription : Subscription) -> Unit {
  ignore(self)
  subscription.remove_pending = true
  subscription.active = false
  subscription.remove_done = true
  while subscription.queue.length() > 0 {
    subscription.drop_oldest()
  }
  // `dropped` counts values a slow consumer missed; discarding a retired
  // subscription's backlog is not that, so the count is restored.
  subscription.dropped = 0
  subscription.ready.broadcast()
}

///|
/// Forget retired subscriptions.
///
/// Kept separate from `retire` so that retiring can happen while the
/// subscription list is being walked; compaction only ever runs between whole
/// commands, never inside an iteration.
fn LiveManager::compact(self : LiveManager) -> Unit {
  self.subscriptions.retain(entry => !entry.remove_done)
}

///|
/// Open one connection and run it until it must be retired.
async fn LiveManager::run_session(self : LiveManager) -> Unit {
  self.generation = self.generation + 1
  let generation = self.generation
  let connection = self.connect() catch {
    error => {
      let failure = as_convex_error(error, "Live connect failed")
      self.record_close(failure.info().message)
      self.schedule_reconnect()
      // No connection was ever established, so nothing is being held back on
      // one. Publishing here anyway keeps the invariant simple: every path out
      // of a session settles what it was holding.
      self.settle_deferred()
      return
    }
  }
  // A completed handshake is the signal that the peer is healthy, so the
  // backoff resets here rather than after the first transition.
  self.backoff_ms = LIVE_BACKOFF_MIN_MS
  self.connected = true
  @async.with_task_group(group => {
    group.spawn_bg(
      () => self.read_loop(connection, generation),
      no_wait=true,
      allow_failure=true,
    )
    self.owner_loop(connection, generation)
  }) catch {
    error => {
      let failure = as_convex_error(error, "Live session failed")
      self.record_close(failure.info().message)
    }
  }
  self.connected = false
  // The connection is retired before any deferred acknowledgement is published,
  // so a caller that sees the acknowledgement knows the old socket is gone.
  connection.close()
  self.settle_deferred()
}

///|
/// Establish the WebSocket and bring the server's query set up to date.
async fn LiveManager::connect(self : LiveManager) -> @websocket.Conn {
  guard self.client is Some(client) else {
    raise closed_error("Live worker has no client")
  }
  let headers : Map[String, String] = Map::new()
  headers["Convex-Client"] = CLIENT_VERSION
  @async.with_timeout(LIVE_CONNECT_TIMEOUT_MS, () => {
    // The HTTP client verifies the certificate chain and hostname against the
    // system trust store, then the WebSocket upgrade runs over that verified
    // connection. `from_http_client` validates the RFC 6455 handshake,
    // including `Sec-WebSocket-Accept`, before handing back a connection.
    let http = @http.Client(
      client.origin,
      headers~,
      trust=@tls.TrustedRoot::SystemRoot,
    )
    let connection = @websocket.Conn::from_http_client(http, SYNC_ENDPOINT)
    try {
      send_json(
        connection,
        connect_message(
          self.session_id,
          self.connection_count,
          self.last_close_reason,
          self.max_observed_timestamp,
        ),
      )
      self.resend_active_queries(connection)
    } catch {
      error => {
        connection.close()
        raise error
      }
    }
    connection
  })
}

///|
/// Replay the active query set onto a fresh connection.
///
/// Every connection starts from query-set version zero, so each one has to
/// resend every active `Add`. Subscriptions created after this snapshot keep
/// their `add_pending` flag and are sent individually by the owner loop.
async fn LiveManager::resend_active_queries(
  self : LiveManager,
  connection : @websocket.Conn,
) -> Unit {
  self.query_set_version = 0
  self.remote = { query_set: 0L, identity: 0L, ts: INITIAL_TIMESTAMP }
  let snapshot = self.next_add_sequence
  let modifications : Array[Json] = []
  for subscription in self.subscriptions {
    if subscription.active && !subscription.remove_pending {
      // A replayed value that equals the one the consumer already holds is not
      // a change, so mark the subscription as rehydrating and let the value
      // path suppress the duplicate.
      subscription.rehydrating = subscription.has_last_value
      modifications.push(
        add_modification(subscription.id, subscription.path, subscription.args),
      )
    }
  }
  if modifications.length() == 0 {
    return
  }
  send_json(
    connection,
    modify_query_set_message(self.query_set_version, modifications),
  )
  self.query_set_version = self.query_set_version + 1
  for subscription in self.subscriptions {
    if subscription.add_sequence <= snapshot {
      subscription.add_pending = false
    }
  }
}

///|
/// Serialise and send one protocol message under an absolute write deadline.
async fn send_json(connection : @websocket.Conn, message : Json) -> Unit {
  let text = message.stringify()
  @async.with_timeout(LIVE_WRITE_TIMEOUT_MS, () => connection.send_text(text))
}

///|
/// Send the closing handshake under the same deadline as any other write.
///
/// A peer that has stopped reading can fill this client's send buffer, and an
/// unbounded courtesy close would be exactly the kind of politeness that makes
/// shutdown hang.
async fn send_close_frame(connection : @websocket.Conn) -> Unit {
  @async.with_timeout(LIVE_WRITE_TIMEOUT_MS, () => connection.send_close())
}

///|
/// Read frames from one connection and post decoded messages to the owner.
///
/// This task never writes and never changes protocol state. If anything at all
/// goes wrong - a closed socket, a binary frame, an oversized message, invalid
/// JSON, or a cancelled read that stopped halfway through a frame - it reports
/// the connection as down and stops. The connection is then closed rather than
/// resumed, so a partially consumed frame can never be mistaken for a frame
/// boundary.
async fn LiveManager::read_loop(
  self : LiveManager,
  connection : @websocket.Conn,
  generation : Int,
) -> Unit {
  let outcome = try {
    for ;; {
      let message = connection.recv()
      guard message.kind is Text else {
        break (
          ErrorKind::ProtocolError,
          "Live server sent a non-text data frame",
        )
      }
      let text = read_bounded_text(
        message,
        LIVE_MAX_MESSAGE_BYTES,
        "Live message",
      )
      let decoded = @json.parse(text) catch {
        _ =>
          break (
            ErrorKind::ProtocolError,
            "Live server message was not valid JSON",
          )
      }
      self.events.put(Incoming(generation, decoded))
    }
  } catch {
    error =>
      if @async.is_being_cancelled() {
        // The owner is tearing this connection down on purpose. It already
        // knows why, so reporting a spurious failure would overwrite the real
        // close reason.
        return
      } else {
        let failure = as_convex_error(error, "Live read failed").info()
        (failure.kind, failure.message)
      }
  }
  if !@async.is_being_cancelled() {
    self.events.put(Down(generation, outcome.0, outcome.1)) catch {
      _ => ()
    }
  }
}

///|
/// Consume the ordered event stream for one connection.
async fn LiveManager::owner_loop(
  self : LiveManager,
  connection : @websocket.Conn,
  generation : Int,
) -> Unit {
  for ;; {
    let event = self.events.get()
    let step = match event {
      Incoming(tag, message) =>
        if tag != generation {
          Continue
        } else {
          self.apply_server_message(message)
        }
      Down(tag, kind, reason) =>
        if tag != generation {
          Continue
        } else {
          self.record_close(reason)
          self.notify_failure(kind, reason)
          self.schedule_reconnect()
          EndSession
        }
      Issued(command) => self.apply_command(connection, command)
    }
    if step is EndSession {
      return
    }
  }
}

///|
/// Apply one command while a connection is available.
async fn LiveManager::apply_command(
  self : LiveManager,
  connection : @websocket.Conn,
  command : Command,
) -> SessionStep {
  match command {
    AddQuery(subscription, completion) => {
      // The caller's bounded wait expired before this reached the owner. Retire
      // the subscription rather than telling the server about a query whose
      // consumer has already gone.
      if completion.abandoned {
        self.retire(subscription)
        return Continue
      }
      self.subscriptions.push(subscription)
      let sent = try {
        send_json(
          connection,
          modify_query_set_message(self.query_set_version, [
            add_modification(
              subscription.id,
              subscription.path,
              subscription.args,
            ),
          ]),
        )
        true
      } catch {
        error => {
          self.record_close(
            as_convex_error(error, "Live Add failed").info().message,
          )
          false
        }
      }
      if sent {
        self.query_set_version = self.query_set_version + 1
        subscription.add_pending = false
        completion.succeed()
        Continue
      } else {
        // The subscription stays registered with `add_pending` set, so the
        // next connection replays it. Acknowledging is honest: the client has
        // accepted the subscription even though this socket died.
        completion.succeed()
        self.schedule_reconnect()
        EndSession
      }
    }
    RemoveQuery(subscription, completion) => {
      // Invalidate first. Whether or not the `Remove` frame reaches the server,
      // this client will publish nothing more for the subscription, and the
      // acknowledgement below is only issued after that is already true.
      let was_active = subscription.active && !subscription.remove_done
      let query_id = subscription.id
      self.retire(subscription)
      if !was_active {
        completion.succeed()
        return Continue
      }
      let sent = try {
        send_json(
          connection,
          modify_query_set_message(self.query_set_version, [
            remove_modification(query_id),
          ]),
        )
        true
      } catch {
        error => {
          self.record_close(
            as_convex_error(error, "Live Remove failed").info().message,
          )
          false
        }
      }
      completion.succeed()
      self.compact()
      if sent {
        self.query_set_version = self.query_set_version + 1
        Continue
      } else {
        self.schedule_reconnect()
        EndSession
      }
    }
    DebugDisconnect(completion) => {
      self.record_close("DebugDisconnect")
      self.mark_rehydrating()
      self.reconnect_at = @async.now() + LIVE_DEBUG_RECONNECT_MS.to_int64()
      // Deferred: the acknowledgement is published by `run_session` after the
      // old connection has been closed and the reconnect has been scheduled.
      self.deferred.push(completion)
      EndSession
    }
    Shutdown(completion) => {
      self.stopped = true
      let modifications : Array[Json] = []
      for subscription in self.subscriptions {
        if subscription.active && !subscription.remove_pending {
          modifications.push(remove_modification(subscription.id))
        }
      }
      // Best effort: a peer that has stopped reading must not be able to stall
      // shutdown, and the deadline inside `send_json` guarantees it cannot.
      if modifications.length() > 0 {
        send_json(
          connection,
          modify_query_set_message(self.query_set_version, modifications),
        ) catch {
          _ => ()
        }
      }
      // The close handshake is sent whether or not there was a query set left
      // to retire, so a server always sees this client leave rather than a
      // connection that simply stopped answering.
      send_close_frame(connection) catch {
        _ => ()
      }
      for subscription in self.subscriptions {
        self.retire(subscription)
      }
      self.compact()
      self.record_close("ClientClosed")
      self.deferred.push(completion)
      EndSession
    }
  }
}

///|
/// Apply one decoded server message to the subscription state.
async fn LiveManager::apply_server_message(
  self : LiveManager,
  message : Json,
) -> SessionStep {
  let parsed = parse_server_message(message) catch {
    error => {
      let failure = as_convex_error(error, "Live protocol error")
      self.notify_failure(ErrorKind::ProtocolError, failure.info().message)
      self.record_close(failure.info().message)
      self.schedule_reconnect()
      return EndSession
    }
  }
  match parsed {
    Ping => Continue
    Ignored => Continue
    Fatal(reason) => {
      self.notify_failure(ErrorKind::ProtocolError, reason)
      self.record_close(reason)
      self.schedule_reconnect()
      EndSession
    }
    Transition(start, end, modifications) => {
      // The version chain is the only guarantee that no update was missed.
      // A transition that does not start where this client currently is means
      // something was dropped, so the connection is abandoned and rebuilt from
      // a known state rather than continuing from a guess.
      guard start.query_set == self.remote.query_set &&
        start.identity == self.remote.identity &&
        start.ts == self.remote.ts else {
        let reason = "Transition start version does not match the local version"
        self.notify_failure(ErrorKind::ProtocolError, reason)
        self.record_close(reason)
        self.schedule_reconnect()
        return EndSession
      }
      // `QueryRemoved` is the server's answer to a `Remove` this client sent,
      // and by the time it arrives the subscription has already been retired
      // locally, so the ordinary case finds nothing here. A `QueryRemoved` for a
      // subscription that is still live means the server dropped a query this
      // client is still watching: leaving it registered would strand a consumer
      // waiting for values the deployment has stopped computing. The connection
      // is rebuilt instead, because every connection resends the active `Add`
      // operations, which is exactly the recovery this needs.
      //
      // The scan runs before anything is applied so that one bad entry cannot
      // leave half of a transition applied to the subscription state.
      for modification in modifications {
        if modification is QueryRemoved(query_id) &&
          self.find_active(query_id) is Some(_) {
          let reason = "Live server removed a query this client is still subscribed to"
          self.notify_failure(ErrorKind::ProtocolError, reason)
          self.record_close(reason)
          self.schedule_reconnect()
          return EndSession
        }
      }
      for modification in modifications {
        self.apply_modification(modification)
      }
      self.remote = end
      self.max_observed_timestamp = Some(end.ts)
      // A valid server transition is evidence of a healthy peer, so a long
      // backoff earned by an earlier bad run is discarded.
      self.backoff_ms = LIVE_BACKOFF_MIN_MS
      Continue
    }
  }
}

///|
fn LiveManager::apply_modification(
  self : LiveManager,
  modification : Modification,
) -> Unit {
  match modification {
    // Already handled by the scan in `apply_server_message`: either it answers
    // a `Remove` this client sent, or the connection is being rebuilt and this
    // line is never reached.
    QueryRemoved(_) => ()
    QueryUpdated(query_id, value, logs) =>
      match self.find(query_id) {
        Some(subscription) =>
          if subscription.active && !subscription.remove_pending {
            subscription.publish_value(value, logs)
          }
        None => ()
      }
    QueryFailed(query_id, message, data, logs) =>
      match self.find(query_id) {
        Some(subscription) =>
          if subscription.active && !subscription.remove_pending {
            subscription.publish_error({
              kind: FunctionError,
              message,
              data,
              logs,
            })
          }
        None => ()
      }
  }
}

///|
/// Report a connection-level failure to the subscriptions it could have
/// affected.
///
/// Only subscriptions the server had already been told about are notified. A
/// subscription whose `Add` never reached the server has not failed - it simply
/// has not started yet - and reporting an error for it would make a normal
/// reconnect look like a fault.
///
/// Subscriptions survive: after the reconnect they receive a fresh value, which
/// is what makes both failure families recoverable rather than terminal.
fn LiveManager::notify_failure(
  self : LiveManager,
  kind : ErrorKind,
  message : String,
) -> Unit {
  for subscription in self.subscriptions {
    if subscription.active &&
      !subscription.remove_pending &&
      !subscription.add_pending {
      subscription.publish_error({ kind, message, data: None, logs: [] })
    }
  }
}

///|
fn LiveManager::mark_rehydrating(self : LiveManager) -> Unit {
  for subscription in self.subscriptions {
    if subscription.active && !subscription.remove_pending {
      subscription.rehydrating = subscription.has_last_value
    }
  }
}

///|
/// Record why a connection went away and count it. Both values are reported to
/// the server in the next `Connect`.
///
/// Only a connection that actually existed is counted. A connect attempt that
/// never completed its handshake still records why it failed, but numbering it
/// would tell the server about a connection it never saw, which is exactly the
/// bookkeeping `connectionCount` exists to keep straight.
fn LiveManager::record_close(self : LiveManager, reason : String) -> Unit {
  if self.connected {
    self.connection_count = self.connection_count + 1
  }
  self.last_close_reason = if reason.length() <= LIVE_CLOSE_REASON_MAX_CHARS {
    reason
  } else {
    "CloseReasonTooLong"
  }
  self.query_set_version = 0
  self.remote = { query_set: 0L, identity: 0L, ts: INITIAL_TIMESTAMP }
}

///|
/// Schedule the next connection attempt and grow the backoff.
fn LiveManager::schedule_reconnect(self : LiveManager) -> Unit {
  self.reconnect_at = @async.now() + self.backoff_ms.to_int64()
  let doubled = self.backoff_ms * 2
  self.backoff_ms = if doubled > LIVE_BACKOFF_MAX_MS {
    LIVE_BACKOFF_MAX_MS
  } else {
    doubled
  }
}

///|
/// Publish the acknowledgements that were held back until the old connection
/// was retired.
fn LiveManager::settle_deferred(self : LiveManager) -> Unit {
  while self.deferred.length() > 0 {
    let completion = self.deferred.remove(0)
    completion.succeed()
  }
}

///|
/// Final cleanup once the worker loop exits: retire every subscription and fail
/// every command still waiting, so no caller is left blocked on a worker that
/// no longer exists.
///
/// Retiring, rather than merely deactivating, is what releases the process-wide
/// Live budget. A subscription abandoned with updates still queued would keep
/// charging that budget for as long as anything held the handle, so an abnormal
/// finish - a wedged worker, a cancelled task group, a failed connect during
/// shutdown - would leak exactly the budget the ordinary unsubscribe path
/// releases, and the next client in the same process would start already short
/// of memory it is not using.
fn LiveManager::finish(self : LiveManager) -> Unit {
  self.stopped = true
  self.connected = false
  for subscription in self.subscriptions {
    self.retire(subscription)
  }
  self.compact()
  self.settle_deferred()
  while true {
    let pending = self.events.try_get() catch { _ => None }
    match pending {
      Some(Issued(command)) =>
        match command {
          // The subscription was never registered, so retiring it is what makes
          // a caller that is still holding the handle observe a closed
          // subscription rather than wait on updates that cannot come.
          AddQuery(subscription, completion) => {
            self.retire(subscription)
            completion.fail(closed_error("Live worker has stopped"))
          }
          // A removal against a stopped worker has already happened: nothing
          // will be published for that subscription again.
          RemoveQuery(_, completion) => completion.succeed()
          DebugDisconnect(completion) =>
            completion.fail(transport_error("Live WebSocket is not connected"))
          Shutdown(completion) => completion.succeed()
        }
      Some(_) => ()
      None => break
    }
  }
}
