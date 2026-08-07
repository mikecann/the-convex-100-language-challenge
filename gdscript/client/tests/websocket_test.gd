extends SceneTree

# Transport-level Live behaviour: deadlines, message reassembly, and what
# happens to a connection that is abandoned rather than closed politely.
#
# Godot's WebSocketPeer owns RFC 6455 itself. It performs the HTTP 101
# handshake, masks outgoing frames, reassembles continuation frames, validates
# UTF-8 payloads, and answers ping and close control frames, and it does not
# expose partially parsed frames to GDScript at all. This client therefore
# cannot resume a half-read frame after a deadline even in principle: it
# discards the peer, and the next attempt is a brand new socket with no
# inherited parser state. These tests assert the deadlines and that
# abandonment, which is the part the client is genuinely responsible for.

const PUMP_DELAY_MSEC := 1
const WAIT_MSEC := 8000
const SHORT_CONNECT_MSEC := 400
const SHORT_CLOSE_MSEC := 600
const SHORT_MESSAGE_MSEC := 400


func _init() -> void:
	var harness := ConvexTestHarness.new("websocket")
	_test_large_message_reassembly(harness)
	_test_binary_frame_is_refused(harness)
	_test_connect_deadline(harness)
	_test_complete_message_deadline(harness)
	_test_close_is_bounded_with_an_idle_peer(harness)
	_test_close_is_prompt_with_a_cooperative_peer(harness)
	quit(harness.report())


# One Convex value large enough to cross many TCP segments, carrying multibyte
# text, has to arrive as a single intact message.
func _test_large_message_reassembly(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	var live := ConvexLive.new(fixture.url(), {})
	var subscribed := live.subscribe("demo:echo", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var connected := func(): return fixture.query_ids().size() == 1
	harness.check(_wait_for(fixture, live, connected, WAIT_MSEC), "the query set is sent")

	var payload := "snø ☃ 🚀 ".repeat(20000)
	fixture.send_query_updated(0, {"text": payload})
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the large value arrives")
	var update := subscription.try_next_update()
	harness.succeeded(update, "a multi-segment message decodes")
	harness.equal(update["value"]["text"], payload, "multibyte text survives reassembly")

	live.close()
	fixture.stop()


# WebSocketPeer hides a partially received frame, so the only deadline the
# owner can enforce is absolute time since the last complete message. A silent
# peer exercises that same bounded retirement path deterministically.
func _test_complete_message_deadline(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {"message_deadline_msec": SHORT_MESSAGE_MSEC})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")
	subscription.try_next_update()
	var started := Time.get_ticks_msec()
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "an idle message deadline fires")
	var failure := subscription.try_next_update()
	harness.failed(failure, "TransportError", "the complete-message deadline is structured")
	var elapsed := Time.get_ticks_msec() - started
	harness.check(elapsed < SHORT_MESSAGE_MSEC * 4, "the message deadline bounded it")
	live.close()
	fixture.stop()


func _test_binary_frame_is_refused(harness: ConvexTestHarness) -> void:
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

	fixture.send_binary(PackedByteArray([0x7B, 0x7D]))
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the binary frame is reported")
	var refused := subscription.try_next_update()
	harness.failed(refused, "ProtocolError", "a binary Live frame is protocol drift")

	live.close()
	fixture.stop()


# A peer that accepts TCP and never completes the WebSocket handshake must
# cost the connect deadline and no more, and must leave the subscription able
# to try again.
func _test_connect_deadline(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_upgrading(false)
	var live := ConvexLive.new(fixture.url(), {"connect_deadline_msec": SHORT_CONNECT_MSEC})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var started := Time.get_ticks_msec()
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the stalled handshake is reported")
	var elapsed := Time.get_ticks_msec() - started
	var failure := subscription.try_next_update()
	harness.failed(failure, "TransportError", "a stalled handshake is a transport failure")
	harness.check(elapsed < SHORT_CONNECT_MSEC * 4, "the deadline bounded it (%d ms)" % elapsed)
	# The failed attempt schedules a retry, and the delay grows rather than
	# spinning on a peer that is not answering.
	harness.check(live.backoff_msec() > ConvexLive.INITIAL_BACKOFF_MSEC, "the backoff grew")
	harness.check(not subscription.is_finished(), "the subscription survives a failed connect")

	live.close()
	fixture.stop()


# The peer is left completely unpolled, so the closing handshake can never
# finish. The assertion is the deadline, not that a cooperative peer answered.
func _test_close_is_bounded_with_an_idle_peer(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	var live := ConvexLive.new(fixture.url(), {"close_deadline_msec": SHORT_CLOSE_MSEC})
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")

	var started := Time.get_ticks_msec()
	var closed := live.close()
	var elapsed := Time.get_ticks_msec() - started
	harness.succeeded(closed, "close returns even though the peer never answered")
	harness.check(elapsed < SHORT_CLOSE_MSEC * 4, "close respected its deadline (%d ms)" % elapsed)
	harness.check(subscription.is_finished(), "close invalidates every relay")
	harness.check(not live.is_socket_open(), "the socket is gone after close")

	fixture.stop()


func _test_close_is_prompt_with_a_cooperative_peer(harness: ConvexTestHarness) -> void:
	var fixture := ConvexLiveFixture.new()
	if not harness.succeeded(fixture.start(), "the Live fixture starts"):
		return
	fixture.set_auto_value("demo:state", {"count": 0.0})
	# The fixture is polled from the client's own wait, so the closing
	# handshake completes and close returns well inside the deadline. Without
	# this the previous test could pass on a fixed sleep.
	var options := {"close_deadline_msec": 4000, "pump": fixture.poll}
	var live := ConvexLive.new(fixture.url(), options)
	var subscribed := live.subscribe("demo:state", {"room": "alpha"})
	var subscription: ConvexSubscription = subscribed["value"]
	var arrived := func(): return subscription.pending() > 0
	harness.check(_wait_for(fixture, live, arrived, WAIT_MSEC), "the initial value arrives")

	var started := Time.get_ticks_msec()
	live.close()
	var elapsed := Time.get_ticks_msec() - started
	harness.check(elapsed < 2000, "an answering peer closes promptly (%d ms)" % elapsed)

	fixture.stop()


func _wait_for(fixture: ConvexLiveFixture, live: ConvexLive, test: Callable, msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		fixture.poll()
		live.poll()
		if test.call():
			return true
		OS.delay_msec(PUMP_DELAY_MSEC)
	return false
