extends SceneTree

# Deterministic Live behaviour against a real WebSocket peer.
#
# These cover the failure modes ordinary happy-path tests miss: atomic
# transition application, invalidation before acknowledgement, unchanged
# rehydration after a reconnect, structured failures that do not strand a
# subscription, and the connection metadata the pinned profile carries.

const PUMP_DELAY_MSEC := 1
const WAIT_MSEC := 8000
const SETTLE_MSEC := 400
const RECONNECTS := 5


func _init() -> void:
	var harness := ConvexTestHarness.new("live")
	_test_subscribe_and_update(harness)
	_test_query_failure_and_recovery(harness)
	_test_unsubscribe_invalidation(harness)
	_test_reconnect_five_times(harness)
	_test_protocol_error_recovery(harness)
	_test_transition_validation(harness)
	_test_subscription_queue_bounds(harness)
	quit(harness.report())


func _test_subscribe_and_update(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {})

	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	harness.succeeded(subscribed, "subscribe returns a subscription")
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	var initial := subscription.try_next_update()
	harness.equal(initial["value"], {"count": 0.0}, "the initial Live value is the query's value")

	harness.equal(fixture.query_ids(), [0], "the query set holds exactly the active query")
	var query := fixture.query_of(0)
	harness.equal(query["udfPath"], "demo:state", "the Add carries the function path")
	harness.equal(query["args"], [{"room": "alpha"}], "the Add carries the arguments array")
	harness.check(live.query_set_version() == 1, "the query set version advanced once")

	var connect_message := fixture.last_connect()
	var first: bool = connect_message.get("connectionCount") == 0
	harness.check(first, "the first Connect reports no previous connections")
	harness.equal(connect_message.get("lastCloseReason"), "InitialConnect", "the reason is initial")
	var claims_timestamp: bool = connect_message.has("maxObservedTimestamp")
	harness.check(not claims_timestamp, "no observed timestamp is claimed before a Transition")

	fixture.send_query_updated(0, {"count": 1.0})
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "an external change is delivered")
	var update := subscription.try_next_update()
	harness.equal(update["value"], {"count": 1.0}, "the delivered value is the new one")
	harness.check(live.max_observed_timestamp() != "", "the observed timestamp advanced")

	# The same value again is a rehydration, not news. Suppressing it is what
	# makes a reconnect invisible to a query whose state did not change.
	fixture.send_query_updated(0, {"count": 1.0})
	_pump(fixture, live, SETTLE_MSEC)
	harness.check(subscription.pending() == 0, "an unchanged value is not delivered twice")

	live.close()
	fixture.stop()


func _test_query_failure_and_recovery(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:requiresNonzero", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {})
	var subscribed := live.subscribe("demo:requiresNonzero", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	subscription.try_next_update()

	fixture.send_query_failed(0, "room is empty", {"code": "ROOM_EMPTY"})
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the query failure arrives")
	var failure := subscription.try_next_update()
	harness.failed(failure, "FunctionError", "a reactive query failure stays a function error")
	harness.equal(failure["error"]["data"], {"code": "ROOM_EMPTY"}, "error data survives")
	harness.check(not subscription.is_finished(), "a failed query stays subscribed")

	# The repaired value repeats the value from before the failure. It must
	# still be delivered: the failure cleared what the caller was holding.
	fixture.send_query_updated(0, {"count": 0.0})
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the repaired value arrives")
	var repaired := subscription.try_next_update()
	harness.equal(repaired["value"], {"count": 0.0}, "recovery is delivered after a failure")

	live.close()
	fixture.stop()


func _test_unsubscribe_invalidation(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	subscription.try_next_update()

	# Queue an update and deliberately leave it undrained, so there is a real
	# stale event waiting when the unsubscribe happens.
	fixture.send_query_updated(0, {"count": 5.0})
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "an update is waiting")
	var stopped := live.unsubscribe(subscription.query_id())
	harness.succeeded(stopped, "unsubscribe acknowledges")
	# The relay is invalidated before the acknowledgement, so the queued
	# update cannot cross it.
	var stale := subscription.try_next_update()
	harness.check(stale.is_empty(), "no stale update survives the ack")
	harness.check(subscription.is_finished(), "the relay is finished")

	var removed := func(): return fixture.query_ids().is_empty()
	harness.check(_wait_for(fixture, live, removed, WAIT_MSEC), "the Remove reaches the server")
	fixture.send_query_updated(0, {"count": 6.0})
	_pump(fixture, live, SETTLE_MSEC)
	harness.check(subscription.pending() == 0, "a removed query delivers nothing later")

	live.close()
	fixture.stop()


# Five real reconnects, each proving the exact sequence the contract asks for:
# a value, a disconnect acknowledgement, a suppressed rehydration, and then
# the next external change.
func _test_reconnect_five_times(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	var current := {"count": 0.0}
	fixture.set_auto_value("demo:state", current)
	var live := ConvexLive.new(fixture.url(), {})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	harness.equal(subscription.try_next_update()["value"], current, "the journey starts at zero")

	for round_index in RECONNECTS:
		var previous_connections := fixture.connection_total()
		var previous_timestamp := live.max_observed_timestamp()
		# The server would rehydrate the reconnected query with the value the
		# caller already holds.
		fixture.set_auto_value("demo:state", current)
		var dropped := live.debug_disconnect()
		harness.succeeded(dropped, "debugDisconnect acknowledges after retiring the socket")

		var replayed := func(): return _is_replayed(fixture, previous_connections)
		var label := "connection %d is re-established with its query set" % (round_index + 1)
		harness.check(_wait_for(fixture, live, replayed, WAIT_MSEC), label)
		_pump(fixture, live, SETTLE_MSEC)
		harness.check(subscription.pending() == 0, "the unchanged rehydration is suppressed")
		harness.check(live.backoff_msec() == ConvexLive.INITIAL_BACKOFF_MSEC, "backoff reset")

		var connect_message := fixture.last_connect()
		var counted: bool = connect_message.get("connectionCount") == previous_connections
		harness.check(counted, "Connect reports the number of retired connections")
		harness.equal(
			connect_message.get("lastCloseReason"), "DebugDisconnect", "the reason is kept"
		)
		var resumed: bool = connect_message.get("maxObservedTimestamp") == previous_timestamp
		harness.check(resumed, "Connect resumes from the highest observed timestamp")

		current = {"count": float(round_index + 1)}
		fixture.send_query_updated(0, current)
		harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the next change arrives")
		harness.equal(
			subscription.try_next_update()["value"], current, "the new value is delivered"
		)

	harness.check(live.connection_count() == RECONNECTS, "every reconnect was a real connection")
	live.close()
	fixture.stop()


func _test_protocol_error_recovery(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	subscription.try_next_update()

	fixture.send_raw({"type": "Nonsense"})
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the protocol error is reported")
	var failure := subscription.try_next_update()
	harness.failed(failure, "ProtocolError", "unknown server traffic is a protocol error")

	# The subscription is not stranded: the owner rebuilds the connection,
	# replays the query set, and a later valid value still reaches the caller.
	var replayed := func(): return _is_replayed(fixture, 1)
	harness.check(_wait_for(fixture, live, replayed, WAIT_MSEC), "the connection is rebuilt")
	fixture.send_query_updated(0, {"count": 4.0})
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "a later value is delivered")
	harness.equal(subscription.try_next_update()["value"], {"count": 4.0}, "recovery delivers")

	live.close()
	fixture.stop()


func _test_transition_validation(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	subscription.try_next_update()
	var observed := live.max_observed_timestamp()

	# One bad modification poisons the whole Transition: the good value beside
	# it must not be delivered, and the observed timestamp must not move.
	var poisoned := {"type": "Transition", "startVersion": fixture.version()}
	poisoned["endVersion"] = _version_at(500)
	poisoned["modifications"] = [_updated(0, {"count": 7.0}), {"type": "Nope", "queryId": 0}]
	fixture.send_raw(poisoned)
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the bad Transition is reported")
	var rejected := subscription.try_next_update()
	harness.failed(rejected, "ProtocolError", "an unknown modification is a protocol error")
	harness.check(subscription.pending() == 0, "the good modification beside it was not applied")
	harness.equal(live.max_observed_timestamp(), observed, "a rejected Transition moves nothing")

	live.close()
	fixture.stop()


# The relay queue is bounded by both a count and a byte budget, and it keeps
# the newest state rather than growing for a consumer that stopped reading.
func _test_subscription_queue_bounds(harness: ConvexTestHarness) -> void:
	var live := ConvexLive.new("http://127.0.0.1:1", {})
	var counted := ConvexSubscription.new(live, 0)
	for index in ConvexSubscription.MAX_QUEUED_UPDATES + 4:
		counted.apply_update_from_owner(ConvexResult.ok({"n": index}), 16)
	harness.check(
		counted.pending() == ConvexSubscription.MAX_QUEUED_UPDATES, "the count is bounded"
	)
	harness.check(counted.dropped() == 4, "the overflow is counted, not hidden")
	var oldest_kept := counted.try_next_update()
	harness.equal(oldest_kept["value"], {"n": 4}, "the oldest updates are the ones lost")

	var weighed := ConvexSubscription.new(live, 1)
	var megabyte := 1024 * 1024
	for index in 4:
		weighed.apply_update_from_owner(ConvexResult.ok({"n": index}), megabyte)
	# Each 1 MiB update is conservatively charged 4x plus a fixed 4096 byte
	# entry overhead (4198400 bytes), against a 16 MiB budget: three fit
	# (12595200 bytes), and the fourth evicts exactly the oldest one rather
	# than clearing the whole queue.
	harness.check(weighed.pending() == 3, "the byte budget bounds a small number of huge updates")
	harness.check(weighed.dropped() == 1, "oversized backlog is dropped and counted")
	var weighed_oldest_kept := weighed.try_next_update()
	harness.equal(
		weighed_oldest_kept["value"], {"n": 1}, "the byte budget also drops the oldest first"
	)


static func _updated(query_id: int, value: Variant) -> Dictionary:
	var modification := {"type": "QueryUpdated", "queryId": query_id}
	modification["value"] = value
	modification["logLines"] = []
	return modification


static func _version_at(timestamp: int) -> Dictionary:
	var version := {"querySet": 1, "identity": 0}
	version["ts"] = ConvexLiveFixture.encode_timestamp(timestamp)
	return version


# A reconnect is only complete when the server has both accepted a new socket
# and received the replayed query set on it.
static func _is_replayed(fixture: ConvexLiveFixture, previous_connections: int) -> bool:
	if fixture.connection_total() <= previous_connections:
		return false
	return fixture.query_ids().size() == 1


func _pump(fixture: ConvexLiveFixture, live: ConvexLive, msec: int) -> void:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		fixture.poll()
		live.poll()
		OS.delay_msec(PUMP_DELAY_MSEC)


func _wait_for(fixture: ConvexLiveFixture, live: ConvexLive, test: Callable, msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		fixture.poll()
		live.poll()
		if test.call():
			return true
		OS.delay_msec(PUMP_DELAY_MSEC)
	return false
