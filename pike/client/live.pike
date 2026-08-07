// The Convex Live sync state machine, in Pike.
//
// This fragment is textually included by convex.pike. It implements the pinned
// unversioned /api/sync profile: the Connect handshake, query-set versions,
// Transition validation, hydration suppression, reconnect and replay, and the
// metadata a reconnecting client must carry. One owner object is the only thing
// that reads the socket, writes the socket, changes the query set, or schedules
// a reconnect; subscribers and the adapter send it commands and read relays.
#ifndef CONVEX_LIVE_PIKE
#define CONVEX_LIVE_PIKE

// Eight zero bytes, base64 encoded: the timestamp a fresh connection starts at.
constant SYNC_INITIAL_TIMESTAMP = "AAAAAAAAAAA=";
constant LIVE_CONNECT_TIMEOUT_MS = 15000;
constant LIVE_INITIAL_BACKOFF_MS = 100;
constant LIVE_MAX_BACKOFF_MS = 15000;
// A silently blackholed connection looks identical to an idle one from the
// socket's point of view. Convex talks often enough that this much quiet means
// the connection is gone, so replace it rather than waiting forever on it.
constant LIVE_SERVER_INACTIVITY_MS = 30000;

// The relay a subscriber reads is bounded by both a count and a conservative
// byte budget, because one Convex value may approach the frame limit and a
// 16-item queue of those would not be a memory bound at all.
constant MAX_SUBSCRIPTION_UPDATES = 16;
constant MAX_SUBSCRIPTION_BYTES = 2 * 1024 * 1024;

mapping zero_version()
{
  return ([ "querySet": 0, "identity": 0, "ts": SYNC_INITIAL_TIMESTAMP ]);
}

// Convex timestamps are base64 over eight little-endian bytes. Validate the
// exact shape before it can enter connection state, so a truncated or textual
// value can never be carried into a later Connect as maxObservedTimestamp.
string require_timestamp(mixed value, string what)
{
  string encoded = require_string(value, what, "live");
  string bytes;
  mixed failed = catch { bytes = MIME.decode_base64(encoded); };
  if (failed || !stringp(bytes) || sizeof(bytes) != 8)
    throw(protocol_error(what + " is not a canonical Convex timestamp",
                         "live"));
  return encoded;
}

// Returns 1 when `candidate` is strictly newer than `current`.
int timestamp_is_newer(string candidate, string current)
{
  string left = MIME.decode_base64(candidate);
  string right = MIME.decode_base64(current);
  for (int index = 7; index >= 0; index--) {
    if (left[index] != right[index])
      return left[index] > right[index];
  }
  return 0;
}

mapping require_version(mixed value, string what)
{
  mapping raw = require_object(value, what, "live");
  return ([
    "querySet": require_uint32(raw->querySet, what + ".querySet", "live"),
    "identity": require_uint32(raw->identity, what + ".identity", "live"),
    "ts": require_timestamp(raw->ts, what + ".ts"),
  ]);
}

int versions_equal(mapping left, mapping right)
{
  return left->querySet == right->querySet &&
         left->identity == right->identity && left->ts == right->ts;
}

// One thing a subscriber observes: either a value or a classified failure,
// never both, always with whatever log lines Convex attached.
class LiveUpdate
{
  int has_value;
  mixed value;
  ConvexError failure;
  array(string) logs = ({});
  int cost;

  protected void create(int carries_value, mixed update_value,
                        ConvexError update_failure,
                        void|array(string) update_logs)
  {
    has_value = carries_value;
    value = update_value;
    failure = update_failure;
    logs = update_logs || ({});
    // Account the encoded payload plus a fixed allowance for the Pike value
    // graph, so the relay's byte bound is a memory bound rather than a string
    // length bound.
    string encoded = "";
    if (has_value)
      encoded = json_bytes(value);
    else if (failure)
      encoded = failure->message;
    cost = accounted_bytes(encoded);
  }
}

LiveUpdate value_update(mixed value, void|array(string) logs)
{
  return LiveUpdate(1, value, 0, logs);
}

LiveUpdate failure_update(ConvexError failure, void|array(string) logs)
{
  return LiveUpdate(0, 0, failure, logs || failure->logs);
}

class Subscription
{
  object owner;
  int query_id;
  string path;
  mapping args;

  // When a callback is installed the subscriber is pushed to directly and the
  // relay stays empty. The adapter uses that path; the example uses the relay.
  function(LiveUpdate:void) callback;
  array(LiveUpdate) queue = ({});
  int queued_bytes;
  int active = 1;
  int has_last;
  LiveUpdate last;

  protected void create(object live_owner, int id, string query_path,
                        mapping query_args)
  {
    owner = live_owner;
    query_id = id;
    path = query_path;
    args = query_args;
  }

  void set_callback(function(LiveUpdate:void) handler)
  {
    callback = handler;
    if (!handler)
      return;
    // A subscriber that installs its callback after subscribing is still owed
    // anything published in between, such as a connect failure raised while the
    // owner was opening the socket. Hand the relay over rather than stranding
    // those updates in a queue nobody will ever read.
    array(LiveUpdate) waiting = queue;
    queue = ({});
    queued_bytes = 0;
    foreach (waiting, LiveUpdate update)
      handler(update);
  }

  // Convex rehydrates a query on every new connection. An unchanged value is
  // not an event, so it is compared structurally against the last one published
  // and dropped when identical.
  int same_as_last(LiveUpdate update)
  {
    if (!has_last)
      return 0;
    if (!!last->failure != !!update->failure)
      return 0;
    if (update->failure)
      return last->failure->kind == update->failure->kind &&
             last->failure->message == update->failure->message &&
             last->failure->carries_data == update->failure->carries_data &&
             equal(last->failure->data, update->failure->data);
    return equal(last->value, update->value);
  }

  int publish(LiveUpdate update)
  {
    if (!active)
      return 0;
    if (same_as_last(update))
      return 0;
    last = update;
    has_last = 1;
    deliver(update);
    return 1;
  }

  // Transport and protocol failures describe the connection rather than the
  // query's value, so they bypass the repeat filter and never update `last`.
  void publish_failure(LiveUpdate update)
  {
    if (!active)
      return;
    deliver(update);
  }

  void deliver(LiveUpdate update)
  {
    if (callback) {
      callback(update);
      return;
    }
    if (sizeof(queue) >= MAX_SUBSCRIPTION_UPDATES ||
        queued_bytes + update->cost > MAX_SUBSCRIPTION_BYTES) {
      // Fail closed. A stopped reader must not be able to turn a bounded relay
      // into unbounded process memory, and silently dropping the oldest update
      // would make a gap look like a delivered sequence.
      LiveUpdate overflow = failure_update(
        transport_error("Live relay overflowed before the consumer read it",
                        "live"));
      queue = ({ overflow });
      queued_bytes = overflow->cost;
      active = 0;
      return;
    }
    queue += ({ update });
    queued_bytes += update->cost;
  }

  LiveUpdate try_next_update()
  {
    if (!sizeof(queue))
      return 0;
    LiveUpdate update = queue[0];
    queue = queue[1..];
    queued_bytes -= update->cost;
    return update;
  }

  // Wait for the next update against an absolute deadline, pumping the owner so
  // reconnects and frame deadlines keep running while the caller waits.
  LiveUpdate next_update(void|int timeout_ms)
  {
    int deadline = now_ms() + (timeout_ms || 10000);
    while (1) {
      LiveUpdate update = try_next_update();
      if (update)
        return update;
      if (!active)
        throw(closed_error("Live subscription is closed", "live"));
      if (now_ms() >= deadline)
        throw(transport_error("timed out waiting for a Live update", "live"));
      owner->poll();
      Pike.DefaultBackend(0.02);
    }
  }

  // Retire this relay. Callers rely on it taking effect before they publish any
  // acknowledgement, so a queued or in-flight update cannot cross the boundary.
  void invalidate()
  {
    active = 0;
    callback = 0;
    queue = ({});
    queued_bytes = 0;
  }

  void close()
  {
    owner->unsubscribe(query_id);
  }
}

class LiveOwner
{
  mapping ws_target;
  string client_version;
  // Injectable so deterministic tests can drive the whole state machine with an
  // in-process channel and no network.
  function(mapping:Channel) channel_factory;

  mapping(int:Subscription) subscriptions = ([]);
  int next_query_id;
  int query_set_version;
  mapping remote_version = zero_version();

  // Reconnect metadata the pinned profile expects a returning client to carry.
  int connection_count;
  string last_close_reason = "InitialConnect";
  string max_observed_timestamp = "";

  int backoff_ms = LIVE_INITIAL_BACKOFF_MS;
  int reconnect_at;
  int connect_deadline;
  int last_server_message;

  WebSocketConnection socket;
  int socket_generation;
  int publish_on_close = 1;
  int closed;

  protected void create(string deployment_url, string announced_version,
                        void|function(mapping:Channel) factory)
  {
    mapping deployment = parse_url(deployment_url, "live");
    string scheme = deployment->tls ? "wss" : "ws";
    ws_target = parse_url(
      sprintf("%s://%s%s", scheme, deployment->authority,
              combine_sync_path(deployment->path)), "live");
    client_version = announced_version;
    channel_factory = factory || default_channel_factory;
  }

  string combine_sync_path(string base)
  {
    while (sizeof(base) && base[-1] == '/')
      base = base[..sizeof(base) - 2];
    return base + "/api/sync";
  }

  Channel default_channel_factory(mapping target)
  {
    return SocketChannel(target->host, target->port, target->tls);
  }

  Subscription subscribe(string path, mapping args)
  {
    if (closed)
      throw(closed_error("Live client is closed", "live"));
    int query_id = next_query_id++;
    Subscription subscription = Subscription(this, query_id, path, args);
    subscriptions[query_id] = subscription;
    if (socket && socket->is_open())
      try_modify(({ add_modification(subscription) }));
    else
      poll();
    return subscription;
  }

  void unsubscribe(int query_id)
  {
    Subscription subscription = subscriptions[query_id];
    if (!subscription)
      return;
    // Remove and invalidate before any wire traffic. Whatever the socket does
    // next, no further event can reach this relay, so the caller's
    // acknowledgement is safe to publish as soon as this returns.
    m_delete(subscriptions, query_id);
    subscription->invalidate();
    try_modify(({ ([ "type": "Remove", "queryId": query_id ]) }));
  }

  // Adapter-only. Retires the live connection and schedules its replacement
  // before returning, so the controller's acknowledgement can never precede the
  // reconnect work it is meant to prove.
  void debug_disconnect()
  {
    if (!socket)
      throw(transport_error("Live WebSocket is not connected", "live"));
    backoff_ms = LIVE_INITIAL_BACKOFF_MS;
    retire("DebugDisconnect", 0);
    if (sizeof(subscriptions) && !reconnect_at)
      throw(transport_error("debugDisconnect did not schedule a reconnect",
                            "live"));
  }

  mapping add_modification(Subscription subscription)
  {
    return ([
      "type": "Add",
      "queryId": subscription->query_id,
      "udfPath": subscription->path,
      "args": ({ subscription->args }),
    ]);
  }

  void send(mapping message)
  {
    if (!socket || !socket->is_open())
      throw(transport_error("Live socket is not open", "live"));
    socket->send_text(json_bytes(message));
  }

  void modify(array(mapping) modifications)
  {
    int next_version = query_set_version + 1;
    send(([
      "type": "ModifyQuerySet",
      "baseVersion": query_set_version,
      "newVersion": next_version,
      "modifications": modifications,
    ]));
    query_set_version = next_version;
  }

  int try_modify(array(mapping) modifications)
  {
    if (!socket || !socket->is_open())
      return 0;
    mixed failed = catch { modify(modifications); };
    if (!failed)
      return 1;
    // A failed frame write is ambiguous: the server may have applied all, part,
    // or none of it. Retire the connection so the replacement replays exactly
    // the still-active set from a known query-set version of zero.
    retire("Live query set write failed", 1);
    return 0;
  }

  void poll(void|int stamp)
  {
    int now = stamp || now_ms();
    if (closed)
      return;
    if (socket) {
      if (!socket->is_open() && connect_deadline && now >= connect_deadline)
        socket->abort("Live connection did not complete in time");
      else
        socket->enforce_deadlines(now);
    }
    // Retire a connection the server has stopped talking on. The replacement
    // replays the active query set, so a dead path costs one reconnect rather
    // than every subscription it was carrying.
    if (socket && socket->is_open() && last_server_message &&
        now - last_server_message >= LIVE_SERVER_INACTIVITY_MS)
      retire("InactiveServer", 1);
    if (socket || closed || !sizeof(subscriptions))
      return;
    if (reconnect_at && now < reconnect_at)
      return;
    open_connection(now);
  }

  void open_connection(int now)
  {
    socket_generation++;
    int generation = socket_generation;
    reconnect_at = 0;
    connect_deadline = now + LIVE_CONNECT_TIMEOUT_MS;

    Channel channel;
    mixed failed = catch { channel = channel_factory(ws_target); };
    if (failed) {
      ConvexError failure = as_convex_error(failed, "live");
      publish_error(failure);
      schedule_reconnect();
      return;
    }

    WebSocketConnection connection = WebSocketConnection(
      channel, ws_target, client_version,
      lambda() { on_socket_open(generation); },
      lambda(string payload) { on_socket_message(generation, payload); },
      lambda(string reason) { on_socket_closed(generation, reason); });
    // The constructor can already have retired the connection if the first
    // write failed; on_socket_closed then owns the reconnect schedule.
    if (!connection->is_closed())
      socket = connection;
  }

  void on_socket_open(int generation)
  {
    if (generation != socket_generation || !socket)
      return;
    connect_deadline = 0;
    last_server_message = now_ms();
    // A completed handshake proves this path is healthy. Resetting here stops a
    // long-idle client from inheriting the maximum delay of an old outage.
    backoff_ms = LIVE_INITIAL_BACKOFF_MS;
    query_set_version = 0;
    remote_version = zero_version();

    mapping connect = ([
      "type": "Connect",
      "sessionId": random_session_id(),
      "connectionCount": connection_count,
      "lastCloseReason": last_close_reason,
      "clientTs": 0,
    ]);
    if (sizeof(max_observed_timestamp))
      connect->maxObservedTimestamp = max_observed_timestamp;

    mixed failed = catch {
      send(connect);
      array(mapping) additions = ({});
      // Replay in query-id order so a transcript of two connections is directly
      // comparable.
      foreach (sort(indices(subscriptions)), int query_id)
        additions += ({ add_modification(subscriptions[query_id]) });
      if (sizeof(additions))
        modify(additions);
    };
    if (failed)
      retire(as_convex_error(failed, "live")->message, 1);
  }

  void on_socket_message(int generation, string payload)
  {
    if (generation != socket_generation)
      return;
    // Any well-formed frame, including a Ping, proves the server is still
    // there. Record it before validation so a rejected message still counts as
    // contact and the inactivity watchdog stays a liveness test, not a
    // correctness one.
    last_server_message = now_ms();
    mixed failed = catch { handle_message(payload); };
    if (!failed)
      return;
    ConvexError failure = as_convex_error(failed, "live");
    publish_error(failure);
    // The subscriptions survive: a protocol fault retires this connection, and
    // the next one must be able to deliver a later valid value.
    retire(failure->message, 0);
  }

  void on_socket_closed(int generation, string reason)
  {
    if (generation != socket_generation)
      return;
    socket = 0;
    connect_deadline = 0;
    last_server_message = 0;
    last_close_reason = sizeof(reason) ? reason : "TransportClosed";
    connection_count++;
    query_set_version = 0;
    remote_version = zero_version();
    if (publish_on_close)
      publish_error(transport_error(last_close_reason, "live"));
    schedule_reconnect();
  }

  void schedule_reconnect()
  {
    if (closed || !sizeof(subscriptions)) {
      reconnect_at = 0;
      return;
    }
    reconnect_at = now_ms() + backoff_ms;
    backoff_ms = min(backoff_ms * 2, LIVE_MAX_BACKOFF_MS);
  }

  void retire(string reason, int publish)
  {
    if (!socket)
      return;
    WebSocketConnection connection = socket;
    publish_on_close = publish;
    connection->abort(reason);
    publish_on_close = 1;
  }

  void publish_error(ConvexError failure)
  {
    foreach (values(subscriptions), Subscription subscription)
      subscription->publish_failure(failure_update(failure));
  }

  void handle_message(string payload)
  {
    mixed decoded = json_parse_bytes(payload, "Live message", "live");
    mapping message = require_object(decoded, "Live message", "live");
    string type = require_string(message->type, "Live message type", "live");

    if (type == "Transition") {
      handle_transition(message);
      return;
    }
    if (type == "Ping" || type == "MutationResponse" ||
        type == "ActionResponse")
      return;
    if (type == "TransitionChunk")
      throw(protocol_error("chunked Transitions are not implemented", "live"));
    if (type == "FatalError" || type == "AuthError")
      throw(protocol_error(
        sprintf("%s: %s", type,
                stringp(message->error) ? message->error : "no detail"),
        "live"));
    throw(protocol_error("unsupported Live message " + type, "live"));
  }

  void handle_transition(mapping message)
  {
    mapping start = require_version(message->startVersion, "startVersion");
    if (!versions_equal(start, remote_version))
      throw(protocol_error("Transition does not continue the local state",
                           "live"));
    mapping end = require_version(message->endVersion, "endVersion");
    array modifications = require_array(message->modifications,
                                        "Transition modifications", "live");

    // Validate the whole Transition before any of it is applied. A rejected
    // modification therefore cannot advance the version, move the observed
    // timestamp, or leave half a transaction visible to subscribers.
    mapping(int:LiveUpdate) pending = ([]);
    foreach (modifications, mixed raw) {
      mapping modification = require_object(raw, "Transition modification",
                                            "live");
      int query_id = require_uint32(modification->queryId,
                                    "modification queryId", "live");
      string kind = require_string(modification->type, "modification type",
                                   "live");
      if (kind == "QueryUpdated") {
        if (zero_type(modification->value))
          throw(protocol_error("QueryUpdated omitted value", "live"));
        pending[query_id] = value_update(
          modification->value,
          require_log_lines(modification->logLines, "live"));
      } else if (kind == "QueryFailed") {
        ConvexError failure = function_error(
          require_string(modification->errorMessage, "QueryFailed errorMessage",
                         "live"), "live");
        if (!zero_type(modification->errorData))
          failure = failure->with_data(modification->errorData);
        array(string) logs = require_log_lines(modification->logLines, "live");
        pending[query_id] = failure_update(failure->with_logs(logs), logs);
      } else if (kind == "QueryRemoved") {
        // A removed query has no state left to publish in this Transition.
        m_delete(pending, query_id);
      } else {
        throw(protocol_error("unsupported Transition modification " + kind,
                             "live"));
      }
    }

    if (!sizeof(max_observed_timestamp) ||
        timestamp_is_newer(end->ts, max_observed_timestamp))
      max_observed_timestamp = end->ts;
    remote_version = end;
    // A valid Transition is the strongest health signal the protocol offers.
    backoff_ms = LIVE_INITIAL_BACKOFF_MS;

    foreach (sort(indices(pending)), int query_id) {
      Subscription subscription = subscriptions[query_id];
      if (!subscription)
        continue;
      // A QueryFailed is a real, reportable state of the query, so it goes
      // through the same repeat filter as a value.
      subscription->publish(pending[query_id]);
    }
  }

  void close()
  {
    if (closed)
      return;
    closed = 1;
    reconnect_at = 0;
    foreach (values(subscriptions), Subscription subscription)
      subscription->invalidate();
    subscriptions = ([]);
    if (!socket)
      return;
    WebSocketConnection connection = socket;
    publish_on_close = 0;
    connection->begin_close(1000, "client closed");
    // Give a cooperative peer a bounded chance to answer, then retire the
    // connection regardless. Close must not depend on the peer at all.
    pump_until(lambda() { return connection->is_closed(); },
               now_ms() + CLOSE_HANDSHAKE_TIMEOUT_MS);
    connection->abort("client closed");
    publish_on_close = 1;
  }
}

#endif
