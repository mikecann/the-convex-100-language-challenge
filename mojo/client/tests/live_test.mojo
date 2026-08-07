"""Deterministic coverage for the Live paths ordinary happy-path runs miss.

Nothing here talks to Convex. Frames are fed straight into a connection
buffer, and sync messages are handed to the client's own message handler, so
fragmentation, control frames, protocol drift, rehydration suppression,
delivery bounds and read deadlines are all exercised with exact inputs.
"""

from std.ffi import external_call, c_int
from std.memory import UnsafePointer, alloc

from convex import (
    Client,
    QUEUE_BYTE_BUDGET,
    QUEUE_CAPACITY,
    Update,
    default_ca_file,
)
from json import parse
from net import Conn, now_ms, set_nonblocking
from websocket import OP_CLOSE, OP_PING, OP_TEXT, WebSocket


fn check(condition: Bool, label: String) raises:
    if not condition:
        raise Error("FAIL " + label)


fn socket_pair() raises -> List[Int32]:
    """Two connected descriptors, so a stalled peer can be built without a server.
    """
    var cell = alloc[Int32](2)
    var made = external_call["socketpair", c_int](
        Int32(1), Int32(1), Int32(0), cell
    )
    if made != 0:
        cell.free()
        raise Error("could not create a socket pair")
    var out = List[Int32]()
    out.append(cell[0])
    out.append(cell[1])
    cell.free()
    # The connection layer expects non-blocking descriptors: every wait it
    # performs is a poll against a deadline, never a blocking read.
    set_nonblocking(out[0])
    return out^


fn buffered_socket(var bytes: List[UInt8]) raises -> WebSocket:
    """A WebSocket primed with exact frame bytes.

    The descriptor is one end of a socket pair rather than nothing at all, so
    a pong the decoder owes a ping has somewhere real to go. The far end is
    never read, which is also how a stalled peer is modelled below.
    """
    var pair = socket_pair()
    var conn = Conn()
    conn.fd = pair[0]
    conn.buffer = bytes^
    conn.closed = False
    return WebSocket(conn^)


fn server_frame(
    final: Bool, opcode: Int, payload: Span[UInt8, _]
) -> List[UInt8]:
    """Encode one unmasked server-to-client frame."""
    var out = List[UInt8]()
    out.append(UInt8((0x80 if final else 0x00) | opcode))
    out.append(UInt8(len(payload)))
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


fn bytes_of(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for value in values:
        out.append(UInt8(value))
    return out^


fn concat(var first: List[UInt8], second: List[UInt8]) -> List[UInt8]:
    for i in range(len(second)):
        first.append(second[i])
    return first^


fn detached_client() raises -> Client:
    """A client with no connection, for driving the sync state machine directly.
    """
    return Client(String("http://127.0.0.1:1"), default_ca_file())


fn transition(
    start_query_set: Int,
    start_ts: String,
    end_query_set: Int,
    end_ts: String,
    modifications: String,
) -> String:
    var out = String('{"type":"Transition","startVersion":{"querySet":')
    out += String(start_query_set)
    out += ',"identity":0,"ts":"'
    out += start_ts
    out += '"},"endVersion":{"querySet":'
    out += String(end_query_set)
    out += ',"identity":0,"ts":"'
    out += end_ts
    out += '"},"modifications":['
    out += modifications
    out += "]}"
    return out


fn test_fragmented_message() raises:
    # One logical message split across three frames, with a ping delivered in
    # the middle of it. The ping must not disturb the assembly buffer, and the
    # multi-byte codepoint straddling the fragment boundary must survive.
    # The three bytes of U+4E16 are deliberately split across two fragments.
    var bytes = server_frame(False, OP_TEXT, String('{"a":"h').as_bytes())
    bytes = concat(bytes^, server_frame(True, OP_PING, String("hi").as_bytes()))
    var middle = bytes_of(0x69, 0x20, 0xE4, 0xB8)
    bytes = concat(bytes^, server_frame(False, 0, Span(middle)))
    var tail = bytes_of(0x96, 0x22, 0x7D)
    bytes = concat(bytes^, server_frame(True, 0, Span(tail)))
    var socket = buffered_socket(bytes^)
    var message = socket.poll_message(now_ms() + 1000)
    check(message.present, "fragmented message assembled")
    check(message.text == '{"a":"hi 世"}', "fragmented payload")


fn test_partial_frame_preserves_state() raises:
    # Only the first half of a frame has arrived. The decoder must report that
    # nothing is ready and leave every byte in place, so the next attempt
    # resumes at the same boundary rather than reading a payload byte as an
    # opcode.
    var whole = server_frame(
        True, OP_TEXT, String('{"type":"Ping"}').as_bytes()
    )
    var half = List[UInt8]()
    for i in range(6):
        half.append(whole[i])
    var socket = buffered_socket(half^)
    var first = socket.poll_message(now_ms() + 50)
    check(not first.present, "partial frame is not a message")
    check(socket.conn.buffered() == 6, "partial frame bytes are preserved")
    for i in range(6, len(whole)):
        socket.conn.buffer.append(whole[i])
    var second = socket.poll_message(now_ms() + 50)
    check(second.present, "frame completes after the rest arrives")
    check(second.text == '{"type":"Ping"}', "resumed payload is intact")


fn test_masked_server_frame_is_rejected() raises:
    var bytes = List[UInt8]()
    bytes.append(0x81)
    bytes.append(0x80)  # mask bit set, zero length
    for _ in range(4):
        bytes.append(0)
    var socket = buffered_socket(bytes^)
    var rejected = False
    try:
        _ = socket.poll_message(now_ms() + 50)
    except:
        rejected = True
    check(rejected, "a masked server frame is rejected")


fn test_oversized_control_frame_is_rejected() raises:
    var bytes = List[UInt8]()
    bytes.append(0x89)  # final ping
    bytes.append(126)  # 126 bytes of payload, one over the control limit
    for _ in range(126):
        bytes.append(0x41)
    var socket = buffered_socket(bytes^)
    var rejected = False
    try:
        _ = socket.poll_message(now_ms() + 50)
    except:
        rejected = True
    check(rejected, "an oversized control frame is rejected")


fn test_invalid_utf8_is_rejected() raises:
    var bytes = List[UInt8]()
    bytes.append(0x81)
    bytes.append(2)
    bytes.append(0xC3)  # a lead byte with no continuation
    bytes.append(0x28)
    var socket = buffered_socket(bytes^)
    var rejected = False
    try:
        _ = socket.poll_message(now_ms() + 50)
    except:
        rejected = True
    check(rejected, "invalid UTF-8 in a message is rejected")


fn test_client_masking() raises:
    # RFC 6455 requires client frames to be masked. Read the bytes back off the
    # wire and prove the mask was applied rather than merely announced.
    var pair = socket_pair()
    var conn = Conn()
    conn.fd = pair[0]
    conn.closed = False
    var socket = WebSocket(conn^)
    socket.send_text(String("hello"), now_ms() + 1000)
    var scratch = alloc[UInt8](64)
    var got = external_call["read", Int](Int(pair[1]), scratch, 64)
    check(Int(got) == 11, "masked frame length")
    check(scratch[0] == 0x81, "final text frame")
    check(scratch[1] == UInt8(0x80 | 5), "mask bit and payload length")
    var plain = String("hello").as_bytes()
    var masked_matches_plain = True
    for i in range(5):
        if scratch[6 + i] != plain[i]:
            masked_matches_plain = False
    check(not masked_matches_plain, "payload is actually masked")
    for i in range(5):
        check(
            (scratch[6 + i] ^ scratch[2 + i % 4]) == plain[i],
            "payload unmasks to the original text",
        )
    scratch.free()
    _ = external_call["close", c_int](pair[1])


fn test_read_deadline_is_bounded() raises:
    # A peer that connects and then says nothing must not be able to hold a
    # read open past its deadline.
    var pair = socket_pair()
    var conn = Conn()
    conn.fd = pair[0]
    conn.closed = False
    var socket = WebSocket(conn^)
    var started = now_ms()
    var message = socket.poll_message(started + 200)
    var elapsed = now_ms() - started
    check(not message.present, "a silent peer yields no message")
    check(elapsed >= 150 and elapsed < 2000, "the read honoured its deadline")
    var closing = now_ms()
    socket.close(now_ms() + 1000)
    check(now_ms() - closing < 2000, "close is bounded against an idle peer")
    _ = external_call["close", c_int](pair[1])


fn test_delivery_is_bounded() raises:
    var client = detached_client()
    client.subscribe(String("s"), String("demo:state"), String("{}"))
    var index = client.find(String("s"))
    for i in range(QUEUE_CAPACITY + 8):
        var update = Update()
        update.value_json = String('{"n":') + String(i) + "}"
        client.subs[index].enqueue(update^)
    check(
        len(client.subs[index].queue) == QUEUE_CAPACITY,
        "the queue keeps its count bound",
    )
    var oldest = client.subs[index].take()
    check(oldest.value_json == '{"n":8}', "the oldest updates were dropped")

    # An event-count limit is not a memory limit. A handful of near-maximum
    # values has to be bounded by bytes as well.
    var big = detached_client()
    big.subscribe(String("s"), String("demo:state"), String("{}"))
    var slot = big.find(String("s"))
    var filler = String()
    for _ in range(4000):
        filler += "0123456789"
    for _ in range(10):
        var update = Update()
        update.value_json = filler
        big.subs[slot].enqueue(update^)
    check(
        big.subs[slot].queue_bytes <= QUEUE_BYTE_BUDGET,
        "the queue keeps its byte budget",
    )
    check(
        len(big.subs[slot].queue) < 10, "the byte budget dropped older values"
    )


fn test_unsubscribe_invalidates_queued_values() raises:
    # Retiring a registration must drop what it already queued, so no stale
    # value can be published after the acknowledgement.
    var client = detached_client()
    client.subscribe(String("s"), String("demo:state"), String("{}"))
    var index = client.find(String("s"))
    var update = Update()
    update.value_json = String('{"count":0}')
    client.subs[index].enqueue(update^)
    check(client.has_update(String("s")), "a value is queued")
    client.unsubscribe(String("s"))
    check(
        not client.has_update(String("s")), "unsubscribe invalidated the queue"
    )

    var replaced = detached_client()
    replaced.subscribe(String("s"), String("demo:state"), String("{}"))
    var slot = replaced.find(String("s"))
    var stale = Update()
    stale.value_json = String('{"count":41}')
    replaced.subs[slot].enqueue(stale^)
    replaced.subscribe(
        String("s"), String("demo:state"), String('{"room":"x"}')
    )
    check(
        not replaced.has_update(String("s")),
        "a same-ID replacement invalidated the old registration",
    )


fn test_sync_state_machine() raises:
    var client = detached_client()
    client.subscribe(String("s"), String("demo:state"), String("{}"))
    var query_id = client.subs[client.find(String("s"))].query_id
    client.subs[client.find(String("s"))].add_pending = False

    # An initial QueryUpdated is delivered and advances the query-set version.
    client.handle_message(
        transition(
            0,
            String("AAAAAAAAAAA="),
            1,
            String("AAAAAAAAAAB="),
            '{"type":"QueryUpdated","queryId":'
            + String(query_id)
            + ',"value":{"count":0},"logLines":[]}',
        )
    )
    var first = client.take_update(String("s"))
    check(first.value_json == '{"count":0}', "initial value delivered")
    check(client.remote_query_set == 1, "query-set version advanced")
    check(
        client.max_observed_ts == "AAAAAAAAAAB=", "max observed timestamp kept"
    )

    # An external write produces the next value.
    client.handle_message(
        transition(
            1,
            String("AAAAAAAAAAB="),
            1,
            String("AAAAAAAAAAC="),
            '{"type":"QueryUpdated","queryId":'
            + String(query_id)
            + ',"value":{"count":1}}',
        )
    )
    check(
        client.take_update(String("s")).value_json == '{"count":1}',
        "external update",
    )

    # A Transition whose start version does not match local state is drift, and
    # is refused rather than applied.
    var drifted = False
    try:
        client.handle_message(
            transition(
                7, String("AAAAAAAAAAC="), 8, String("AAAAAAAAAAD="), String()
            )
        )
    except error:
        drifted = String(error).find("start version") >= 0
    check(drifted, "a mismatched start version is rejected")


fn test_query_failure_then_recovery() raises:
    var client = detached_client()
    client.subscribe(String("s"), String("demo:requiresNonzero"), String("{}"))
    var query_id = client.subs[client.find(String("s"))].query_id
    client.subs[client.find(String("s"))].add_pending = False

    client.handle_message(
        transition(
            0,
            String("AAAAAAAAAAA="),
            1,
            String("AAAAAAAAAAB="),
            '{"type":"QueryFailed","queryId":'
            + String(query_id)
            + ',"errorMessage":"Increment the room",'
            + '"errorData":{"code":"ROOM_EMPTY"}}',
        )
    )
    var failed = client.take_update(String("s"))
    check(failed.failed, "the failure was delivered")
    check(failed.error_name == "FunctionError", "structured function error")
    check(
        failed.error_data_json == '{"code":"ROOM_EMPTY"}',
        "the error data survived",
    )

    # The same subscription must still be able to deliver a later valid value.
    client.handle_message(
        transition(
            1,
            String("AAAAAAAAAAB="),
            1,
            String("AAAAAAAAAAC="),
            '{"type":"QueryUpdated","queryId":'
            + String(query_id)
            + ',"value":{"count":1}}',
        )
    )
    check(
        client.take_update(String("s")).value_json == '{"count":1}',
        "the subscription recovered",
    )


fn test_rehydration_is_suppressed() raises:
    # After a reconnect every active query is replayed at its current value.
    # An unchanged replay is bookkeeping, not news, and must not be delivered
    # a second time; a changed one must be.
    var client = detached_client()
    client.subscribe(String("s"), String("demo:state"), String("{}"))
    var query_id = client.subs[client.find(String("s"))].query_id
    client.subs[client.find(String("s"))].add_pending = False
    client.handle_message(
        transition(
            0,
            String("AAAAAAAAAAA="),
            1,
            String("AAAAAAAAAAB="),
            '{"type":"QueryUpdated","queryId":'
            + String(query_id)
            + ',"value":{"count":0}}',
        )
    )
    _ = client.take_update(String("s"))

    client.retire(String("DebugDisconnect"))
    check(client.connection_count == 1, "the connection count advanced")
    check(
        client.last_close_reason == "DebugDisconnect",
        "the close reason is kept",
    )
    check(client.remote_query_set == 0, "the query-set version reset")
    client.subs[client.find(String("s"))].add_pending = False

    client.handle_message(
        transition(
            0,
            String("AAAAAAAAAAA="),
            1,
            String("AAAAAAAAAAB="),
            '{"type":"QueryUpdated","queryId":'
            + String(query_id)
            + ',"value":{"count":0}}',
        )
    )
    check(
        not client.has_update(String("s")),
        "an unchanged rehydration is suppressed",
    )
    client.handle_message(
        transition(
            1,
            String("AAAAAAAAAAB="),
            1,
            String("AAAAAAAAAAC="),
            '{"type":"QueryUpdated","queryId":'
            + String(query_id)
            + ',"value":{"count":1}}',
        )
    )
    check(
        client.take_update(String("s")).value_json == '{"count":1}',
        "the changed value after rehydration is delivered",
    )


fn test_transport_failure_reporting() raises:
    # A subscription still waiting for its Add has delivered nothing yet, so a
    # scripted reconnect stays silent while an unexpected failure is reported.
    var client = detached_client()
    client.subscribe(String("waiting"), String("demo:state"), String("{}"))
    client.publish_failure(
        String("TransportError"), String("socket died"), True
    )
    check(
        not client.has_update(String("waiting")),
        "a pending subscription is not told about a reconnect",
    )
    client.subs[client.find(String("waiting"))].add_pending = False
    client.publish_failure(
        String("TransportError"), String("socket died"), True
    )
    var reported = client.take_update(String("waiting"))
    check(reported.failed, "an established subscription is told")
    check(reported.error_name == "TransportError", "the failure is structured")


fn test_backoff_grows_and_is_capped() raises:
    # Repeated dial failures back off exponentially and stop at the ceiling.
    # `pump` puts the delay back to its floor after a successful handshake, so
    # a run of healthy connections never inherits an old maximum delay.
    var client = detached_client()
    var previous = client.backoff_ms
    client.note_failure(String("TransportError|first"))
    check(client.backoff_ms > previous, "backoff grows after a failure")
    for _ in range(20):
        client.note_failure(String("TransportError|again"))
    check(client.backoff_ms == 15000, "backoff is capped at 15 seconds")
    check(client.connection_count == 21, "every retired connection is counted")


fn test_unknown_server_message_is_protocol_drift() raises:
    var client = detached_client()
    var refused = False
    try:
        client.handle_message(String('{"type":"FatalError","error":"nope"}'))
    except error:
        refused = String(error).find("FatalError") >= 0
    check(refused, "an unknown server message is reported as drift")
    var typeless = False
    try:
        client.handle_message(String('{"nope":1}'))
    except:
        typeless = True
    check(typeless, "a message without a type is rejected")


fn main() raises:
    test_fragmented_message()
    test_partial_frame_preserves_state()
    test_masked_server_frame_is_rejected()
    test_oversized_control_frame_is_rejected()
    test_invalid_utf8_is_rejected()
    test_client_masking()
    test_read_deadline_is_bounded()
    test_delivery_is_bounded()
    test_unsubscribe_invalidates_queued_values()
    test_sync_state_machine()
    test_query_failure_then_recovery()
    test_rehydration_is_suppressed()
    test_transport_failure_reporting()
    test_backoff_grows_and_is_capped()
    test_unknown_server_message_is_protocol_drift()
    print("PASS mojo live")
