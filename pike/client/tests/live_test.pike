#!/usr/bin/env pike
// Tests for the Convex Live sync state machine.
//
// The owner is wired to in-process channels, so every rule the pinned profile
// depends on: handshake metadata, query-set versions, Transition validation,
// hydration suppression, five real reconnects with replay, the unsubscribe
// barrier, and bounded relays are all asserted here rather than inferred from a
// deployment that happened to behave.
#include "../convex.pike"
#include "support.pike"

mapping updated_modification(int query_id, mixed value)
{
  return ([
    "type": "QueryUpdated",
    "queryId": query_id,
    "value": value,
    "logLines": ({}),
  ]);
}

mapping failed_modification(int query_id, string message, mixed data)
{
  mapping modification = ([
    "type": "QueryFailed",
    "queryId": query_id,
    "errorMessage": message,
    "logLines": ({}),
  ]);
  if (!zero_type(data))
    modification->errorData = data;
  return modification;
}

// Track the server's side of the version handshake so each Transition
// continues the last one, exactly as the real backend does.
mapping new_wire_state()
{
  return ([ "version": zero_version(), "clock": 0 ]);
}

void reset_wire_state(mapping state)
{
  state->version = zero_version();
}

void push(LiveFixture fixture, mapping state, array(mapping) modifications)
{
  state->clock++;
  mapping next = wire_version(state->version->querySet + 1, 0,
                         timestamp_for(state->clock));
  fixture->deliver(transition(state->version, next, modifications));
  state->version = next;
}

mapping find_message(array(mapping) messages, string type)
{
  foreach (messages, mapping message)
    if (message->type == type)
      return message;
  return 0;
}

void test_handshake_and_query_set()
{
  LiveFixture fixture = LiveFixture("https://example.convex.cloud");
  Subscription subscription = fixture->owner->subscribe("demo:state",
                                                        ([ "room": "r" ]));
  check_equal(fixture->connection_attempts(), 1,
              "subscribing opens exactly one connection");
  fixture->accept_handshake();

  array(mapping) messages = fixture->sent();
  mapping connect = find_message(messages, "Connect");
  ok(!zero_type(connect), "the client opens with a Connect message");
  check_equal(connect->connectionCount, 0,
              "the first connection reports zero previous connections");
  check_equal(connect->lastCloseReason, "InitialConnect",
              "the first connection reports why it is the first");
  check_equal(connect->clientTs, 0, "clientTs starts at zero");
  ok(zero_type(connect->maxObservedTimestamp),
     "a first connection has no observed timestamp to carry");
  ok(sizeof(connect->sessionId) == 36,
     "the session id is a formatted UUID");

  mapping modify = find_message(messages, "ModifyQuerySet");
  ok(!zero_type(modify), "the client registers its query set");
  check_equal(modify->baseVersion, 0, "the query set starts at version zero");
  check_equal(modify->newVersion, 1, "the query set advances by one");
  check_equal(modify->modifications,
              ({ ([ "type": "Add", "queryId": 0, "udfPath": "demo:state",
                    "args": ({ ([ "room": "r" ]) }) ]) }),
              "the Add names the function, its query id, and its arguments");
  ok(subscription->active, "the subscription is live");
}

void test_initial_and_external_updates()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  Subscription subscription = fixture->owner->subscribe("demo:state",
                                                        ([ "room": "r" ]));
  fixture->accept_handshake();

  push(fixture, state, ({ updated_modification(0, ([ "count": 0 ])) }));
  LiveUpdate initial = subscription->try_next_update();
  ok(!zero_type(initial), "the initial hydration is delivered");
  check_equal(initial->value, ([ "count": 0 ]), "the initial value is zero");

  push(fixture, state, ({ updated_modification(0, ([ "count": 1 ])) }));
  LiveUpdate changed = subscription->try_next_update();
  ok(!zero_type(changed), "an external change is delivered");
  check_equal(changed->value, ([ "count": 1 ]), "the changed value is one");

  // Convex may resend an unchanged value, and a repeat is not an event.
  push(fixture, state, ({ updated_modification(0, ([ "count": 1 ])) }));
  ok(!subscription->try_next_update(), "an unchanged repeat is suppressed");

  check_equal(fixture->owner->max_observed_timestamp, timestamp_for(3),
              "the newest transition timestamp is retained");
}

void test_query_failure_and_recovery()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  Subscription subscription =
    fixture->owner->subscribe("demo:requiresNonzero", ([ "room": "r" ]));
  fixture->accept_handshake();

  push(fixture, state,
       ({ failed_modification(0, "Increment the room",
                              ([ "code": "ROOM_EMPTY" ])) }));
  LiveUpdate failure = subscription->try_next_update();
  ok(!zero_type(failure) && !zero_type(failure->failure),
     "a failing query reports a failure");
  check_equal(failure->failure->kind, FUNCTION_ERROR,
              "a rejected query is a FunctionError, not a transport fault");
  check_equal(failure->failure->data, ([ "code": "ROOM_EMPTY" ]),
              "the structured error payload reaches the subscriber");

  // The subscription is not stranded: the same query recovers in place.
  push(fixture, state, ({ updated_modification(0, ([ "count": 1 ])) }));
  LiveUpdate repaired = subscription->try_next_update();
  ok(repaired && repaired->has_value, "the same subscription recovers");
  check_equal(repaired->value, ([ "count": 1 ]), "the repaired value arrives");
}

void test_transition_validation()
{
  LiveFixture fixture = LiveFixture();
  Subscription subscription = fixture->owner->subscribe("demo:state", ([]));
  fixture->accept_handshake();

  // A Transition that does not continue the local state is drift, not data.
  fixture->deliver(transition(wire_version(7, 0, timestamp_for(9)),
                              wire_version(8, 0, timestamp_for(10)),
                              ({ updated_modification(0, ([ "count": 5 ])) })));
  LiveUpdate reported = subscription->try_next_update();
  ok(!zero_type(reported) && !zero_type(reported->failure),
     "a mismatched Transition is reported");
  check_equal(reported->failure->kind, PROTOCOL_ERROR,
              "protocol drift is classified as a protocol error");
  ok(!fixture->owner->socket, "protocol drift retires the connection");

  // Recovery: the replacement connection replays the query and delivers a
  // later valid value, so one bad frame does not strand the subscription.
  fixture->owner->poll(fixture->owner->reconnect_at + 1);
  check_equal(fixture->connection_attempts(), 2,
              "a replacement connection is opened");
  fixture->accept_handshake();
  mapping replay = find_message(fixture->sent(), "ModifyQuerySet");
  ok(!zero_type(replay), "the replacement connection replays the query set");
  check_equal(replay->modifications[0]->queryId, 0,
              "the replayed Add keeps the original query id");

  mapping state = new_wire_state();
  push(fixture, state, ({ updated_modification(0, ([ "count": 5 ])) }));
  LiveUpdate recovered = subscription->try_next_update();
  ok(recovered && recovered->has_value,
     "the subscription delivers a later valid value");
}

void test_malformed_modifications()
{
  LiveFixture fixture = LiveFixture();
  Subscription subscription = fixture->owner->subscribe("demo:state", ([]));
  fixture->accept_handshake();
  fixture->deliver(transition(
    zero_version(), wire_version(1, 0, timestamp_for(1)),
    ({ ([ "type": "QueryUpdated", "queryId": 0, "logLines": ({}) ]) })));
  LiveUpdate reported = subscription->try_next_update();
  ok(reported && reported->failure && reported->failure->kind == PROTOCOL_ERROR,
     "a QueryUpdated without a value is rejected");

  LiveFixture unknown = LiveFixture();
  Subscription other = unknown->owner->subscribe("demo:state", ([]));
  unknown->accept_handshake();
  unknown->deliver(transition(
    zero_version(), wire_version(1, 0, timestamp_for(1)),
    ({ ([ "type": "QueryInvented", "queryId": 0 ]) })));
  LiveUpdate strange = other->try_next_update();
  ok(!zero_type(strange) && !zero_type(strange->failure),
     "an unknown modification type is rejected");

  LiveFixture chunked = LiveFixture();
  Subscription third = chunked->owner->subscribe("demo:state", ([]));
  chunked->accept_handshake();
  chunked->deliver(([ "type": "TransitionChunk" ]));
  LiveUpdate deferred = third->try_next_update();
  ok(!zero_type(deferred) && !zero_type(deferred->failure),
     "a chunked Transition is refused rather than half-applied");
}

void test_unsubscribe_barrier()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  Subscription subscription = fixture->owner->subscribe("demo:state", ([]));
  fixture->accept_handshake();
  push(fixture, state, ({ updated_modification(0, ([ "count": 0 ])) }));
  ok(!zero_type(subscription->try_next_update()),
     "the subscription is delivering");

  fixture->sent();
  subscription->close();
  ok(!subscription->active,
     "the relay is invalidated before the caller can acknowledge");
  mapping removal = find_message(fixture->sent(), "ModifyQuerySet");
  ok(!zero_type(removal), "a Remove is sent for the retired query");
  check_equal(removal->modifications,
              ({ ([ "type": "Remove", "queryId": 0 ]) }),
              "the Remove names the retired query id");

  // Anything still in flight for that query must not cross the barrier.
  push(fixture, state, ({ updated_modification(0, ([ "count": 1 ])) }));
  ok(!subscription->try_next_update(),
     "no stale update can reach an unsubscribed relay");
}

void test_five_reconnects()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  LiveOwner owner = fixture->owner;
  Subscription subscription = owner->subscribe("demo:state", ([ "room": "r" ]));
  fixture->accept_handshake();
  fixture->sent();
  push(fixture, state, ({ updated_modification(0, ([ "count": 0 ])) }));
  LiveUpdate initial = subscription->try_next_update();
  check_equal(initial->value, ([ "count": 0 ]), "the journey starts at zero");

  for (int attempt = 1; attempt <= 5; attempt++) {
    owner->debug_disconnect();
    ok(!subscription->try_next_update(),
       sprintf("disconnect %d publishes no subscription event", attempt));
    ok(!owner->socket,
       sprintf("disconnect %d retires the old socket", attempt));
    ok(owner->reconnect_at,
       sprintf("disconnect %d schedules reconnect work before returning",
               attempt));

    owner->poll(owner->reconnect_at + 1);
    check_equal(fixture->connection_attempts(), attempt + 1,
                sprintf("reconnect %d opens a new connection", attempt));
    fixture->accept_handshake();
    reset_wire_state(state);

    array(mapping) messages = fixture->sent();
    mapping connect = find_message(messages, "Connect");
    check_equal(connect->connectionCount, attempt,
                sprintf("reconnect %d reports its connection count", attempt));
    check_equal(connect->lastCloseReason, "DebugDisconnect",
                sprintf("reconnect %d reports why the last ended", attempt));
    check_equal(connect->maxObservedTimestamp, timestamp_for(state->clock),
                sprintf("reconnect %d carries the newest observed timestamp",
                        attempt));
    mapping modify = find_message(messages, "ModifyQuerySet");
    check_equal(modify->modifications[0]->queryId, 0,
                sprintf("reconnect %d resends the active Add", attempt));
    check_equal(modify->baseVersion, 0,
                sprintf("reconnect %d restarts the query set version",
                        attempt));

    // Convex rehydrates on every connection. The unchanged value must not look
    // like a change, so the exact observed sequence stays 0 then 1.
    push(fixture, state,
         ({ updated_modification(0, ([ "count": attempt - 1 ])) }));
    ok(!subscription->try_next_update(),
       sprintf("reconnect %d suppresses the unchanged rehydration", attempt));

    push(fixture, state, ({ updated_modification(0, ([ "count": attempt ])) }));
    LiveUpdate changed = subscription->try_next_update();
    ok(changed && changed->has_value,
       sprintf("reconnect %d delivers the external change", attempt));
    check_equal(changed->value, ([ "count": attempt ]),
                sprintf("reconnect %d delivers the expected value", attempt));
  }
  check_equal(owner->connection_count, 5,
              "five real reconnects were performed");
}

void test_backoff_resets_on_health()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  LiveOwner owner = fixture->owner;
  Subscription subscription = owner->subscribe("demo:state", ([]));

  // Three failed connections in a row grow the delay.
  for (int attempt = 0; attempt < 3; attempt++) {
    fixture->channel()->die("refused");
    owner->poll(owner->reconnect_at + 1);
  }
  ok(owner->backoff_ms > LIVE_INITIAL_BACKOFF_MS,
     "repeated transport failures back off");

  // Each failure was reported to the subscriber rather than swallowed.
  int reported;
  LiveUpdate update = subscription->try_next_update();
  while (update) {
    ok(update->failure && update->failure->kind == TRANSPORT_ERROR,
       "each transport failure is reported as a structured event");
    reported++;
    update = subscription->try_next_update();
  }
  check_equal(reported, 3, "every failed connection was reported once");

  // A completed handshake proves the path is healthy again.
  fixture->accept_handshake();
  check_equal(owner->backoff_ms, LIVE_INITIAL_BACKOFF_MS,
              "a successful handshake resets the backoff");
  push(fixture, state, ({ updated_modification(0, ([ "count": 0 ])) }));
  check_equal(owner->backoff_ms, LIVE_INITIAL_BACKOFF_MS,
              "a valid transition keeps the backoff at its floor");
  LiveUpdate healthy = subscription->try_next_update();
  ok(healthy && healthy->has_value,
     "the subscription was never stranded by the outage");
}

void test_relay_overflow()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  Subscription subscription = fixture->owner->subscribe("demo:state", ([]));
  fixture->accept_handshake();

  // A consumer that never reads. The relay must fail closed rather than grow.
  for (int index = 0; index <= MAX_SUBSCRIPTION_UPDATES + 1; index++)
    push(fixture, state, ({ updated_modification(0, ([ "count": index ])) }));

  LiveUpdate first = subscription->try_next_update();
  ok(!zero_type(first) && !zero_type(first->failure),
     "a stopped reader gets a structured failure");
  check_equal(first->failure->kind, TRANSPORT_ERROR,
              "relay overflow is a transport failure");
  ok(!subscription->try_next_update(),
     "the overflowed relay holds nothing else");
  ok(!subscription->active, "an overflowed relay is retired");
}

void test_callback_hand_over()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  Subscription subscription = fixture->owner->subscribe("demo:state", ([]));
  fixture->accept_handshake();
  push(fixture, state, ({ updated_modification(0, ([ "count": 0 ])) }));

  // The adapter installs its callback after subscribe() returns, so anything
  // published in between is still owed to it. Stranding those updates in a
  // queue nobody reads would silently lose a connect failure.
  mapping seen = ([ "updates": ({}) ]);
  subscription->set_callback(lambda(LiveUpdate update) {
                               seen->updates += ({ update });
                             });
  check_equal(sizeof(seen->updates), 1,
              "an update queued before the callback is handed over");
  check_equal(seen->updates[0]->value, ([ "count": 0 ]),
              "the handed-over update keeps its value");
  ok(!subscription->try_next_update(),
     "the hand-over empties the relay instead of duplicating it");

  push(fixture, state, ({ updated_modification(0, ([ "count": 1 ])) }));
  check_equal(sizeof(seen->updates), 2,
              "later updates go straight to the callback");
}

void test_inactive_server_is_replaced()
{
  LiveFixture fixture = LiveFixture();
  mapping state = new_wire_state();
  LiveOwner owner = fixture->owner;
  Subscription subscription = owner->subscribe("demo:state", ([ "room": "r" ]));
  fixture->accept_handshake();
  fixture->sent();
  push(fixture, state, ({ updated_modification(0, ([ "count": 0 ])) }));
  ok(!zero_type(subscription->try_next_update()),
     "the connection is delivering");

  // A blackholed connection is indistinguishable from an idle one at the
  // socket, so the only way out is a liveness deadline on the server's traffic.
  int quiet = owner->last_server_message + LIVE_SERVER_INACTIVITY_MS;
  owner->poll(quiet - 1);
  ok(!zero_type(owner->socket),
     "a connection inside the quiet window is kept");

  owner->poll(quiet + 1);
  check_equal(owner->last_close_reason, "InactiveServer",
              "the retirement records why the connection ended");
  LiveUpdate reported = subscription->try_next_update();
  ok(reported && reported->failure &&
       reported->failure->kind == TRANSPORT_ERROR,
     "the inactivity close is reported as a structured transport failure");

  // The replacement may have opened inside that same poll or may still be
  // waiting out the backoff; one poll past the schedule settles both.
  owner->poll(max(owner->reconnect_at + 1, quiet + 2));
  check_equal(fixture->connection_attempts(), 2,
              "the silent connection is replaced exactly once");
  fixture->accept_handshake();
  reset_wire_state(state);
  mapping connect = find_message(fixture->sent(), "Connect");
  check_equal(connect->lastCloseReason, "InactiveServer",
              "the replacement tells the server why the last one ended");

  push(fixture, state, ({ updated_modification(0, ([ "count": 1 ])) }));
  LiveUpdate recovered = subscription->try_next_update();
  ok(recovered && recovered->has_value,
     "the subscription delivers again after the silent connection was "
     "replaced");
}

void test_close_is_bounded()
{
  LiveFixture fixture = LiveFixture();
  LiveOwner owner = fixture->owner;
  Subscription subscription = owner->subscribe("demo:state", ([]));
  fixture->accept_handshake();
  fixture->sent();

  // The fake peer never answers the close handshake. The deadline must end it.
  int started = now_ms();
  owner->close();
  int elapsed = now_ms() - started;
  ok(elapsed <= CLOSE_HANDSHAKE_TIMEOUT_MS + 2000,
     sprintf("close is bounded by its deadline (%d ms)", elapsed));
  ok(!owner->socket, "close retires the connection");
  ok(!subscription->active, "close invalidates every relay");
  expect_error(lambda() { owner->subscribe("demo:state", ([])); },
               CLOSED_ERROR, "a closed owner refuses new subscriptions");
}

int main()
{
  test_handshake_and_query_set();
  test_initial_and_external_updates();
  test_query_failure_and_recovery();
  test_transition_validation();
  test_malformed_modifications();
  test_unsubscribe_barrier();
  test_five_reconnects();
  test_backoff_resets_on_health();
  test_relay_overflow();
  test_callback_hand_over();
  test_inactive_server_is_replaced();
  test_close_is_bounded();
  return finish("live sync state machine");
}
