"""Exact adapter event shapes, checked before shared conformance sees them."""

from convex import Update
from events import (
    error_event,
    ready_event,
    result_event,
    simple_event,
    subscription_event,
)
from json import J_OBJECT, parse


fn check(condition: Bool, label: String) raises:
    if not condition:
        raise Error("FAIL " + label)


fn is_valid_json(text: String) -> Bool:
    try:
        var doc = parse(text)
        return doc.kind(doc.root) == J_OBJECT
    except:
        return False


fn main() raises:
    var ready = ready_event(
        String("h1"),
        String("mojo"),
        String("native-mojo"),
        String("Mojo 0.26.2.0"),
    )
    check(
        ready
        == '{"protocolVersion":1,"id":"h1","type":"ready","language":"mojo",'
        + '"implementation":"native-mojo","runtime":"Mojo 0.26.2.0"}',
        "ready event",
    )
    check(is_valid_json(ready), "ready event parses")

    # A success carries its value, and its logs only when there are any.
    check(
        result_event(String("q1"), String('{"count":0}'), String())
        == '{"id":"q1","type":"result","value":{"count":0}}',
        "result without logs omits the field",
    )
    check(
        result_event(String("q1"), String("null"), String('["one"]'))
        == '{"id":"q1","type":"result","value":null,"logs":["one"]}',
        "result with logs",
    )

    # A structured function error keeps its data; an error with none must not
    # serialize `"data":null`.
    check(
        error_event(
            String("f1"),
            String(),
            String("FunctionError"),
            String("boom"),
            String('{"code":"X"}'),
            String(),
        )
        == '{"type":"error","id":"f1","error":{"name":"FunctionError",'
        + '"message":"boom","data":{"code":"X"}}}',
        "structured error event",
    )
    var bare = error_event(
        String("f2"),
        String(),
        String("TransportError"),
        String("gone"),
        String(),
        String(),
    )
    check(bare.find("null") < 0, "an absent data field is omitted, not null")

    # A malformed command has no id at all, so the id must not appear.
    var anonymous = error_event(
        String(),
        String(),
        String("ProtocolError"),
        String("malformed adapter command"),
        String(),
        String(),
    )
    check(anonymous.find('"id"') < 0, "an absent id is omitted")
    check(is_valid_json(anonymous), "anonymous error parses")

    # A subscription failure is a subscription event, not a command error.
    var failure = Update()
    failure.failed = True
    failure.error_name = String("FunctionError")
    failure.error_message = String("Increment the room")
    failure.error_data_json = String('{"code":"ROOM_EMPTY"}')
    check(
        subscription_event(String("s1"), failure)
        == '{"type":"subscription","subscriptionId":"s1","error":'
        + '{"name":"FunctionError","message":"Increment the room",'
        + '"data":{"code":"ROOM_EMPTY"}}}',
        "subscription error event",
    )

    var value = Update()
    value.value_json = String('{"count":1}')
    check(
        subscription_event(String("s1"), value)
        == '{"type":"subscription","subscriptionId":"s1","value":{"count":1}}',
        "subscription value event",
    )

    check(
        simple_event(String("c1"), String("closed"))
        == '{"id":"c1","type":"closed"}',
        "close event",
    )
    check(
        simple_event(String("a1"), String("ack")) == '{"id":"a1","type":"ack"}',
        "ack event",
    )

    print("PASS mojo adapter events")
