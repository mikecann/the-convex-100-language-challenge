module c3_live_protocol_fixture;

import std::io;
import c3_live;

extern fn void fixture_reset();
extern fn CInt fixture_push(char* message);
extern fn CInt fixture_sent_contains(char* fragment);
extern fn CInt fixture_connect_count();
extern fn void fixture_advance(CLongLong millis);

fn void expect(bool value, String message)
{
    if (!value) builtin::panic(message, "live-protocol-fixture", "expect", 0);
}

fn void push(String message)
{
    expect(fixture_push(message.ptr) != 0, "fixture inbound queue rejected message");
}

fn void expect_sent(String fragment)
{
    expect(fixture_sent_contains(fragment.ptr) != 0, fragment);
}

fn String updated(usz start_query_set, usz end_query_set, String start_ts,
                  String end_ts, usz query_id, int count)
{
    return string::tformat(
        `{"type":"Transition","startVersion":{"querySet":%d,"identity":0,"ts":"%s"},"endVersion":{"querySet":%d,"identity":0,"ts":"%s"},"modifications":[{"type":"QueryUpdated","queryId":%d,"value":{"count":%d},"logLines":[]}]}`,
        start_query_set, start_ts, end_query_set, end_ts, query_id, count);
}

fn void expect_event(c3_live::Manager* manager, String fragment)
{
    c3_live::LiveEvent event;
    expect(c3_live::manager_take_event(manager, &event), "expected Live event");
    expect(event.payload.contains(fragment), fragment);
}

fn void main()
{
    fixture_reset();
    c3_live::Manager manager;
    c3_live::manager_init(&manager, "https://fixture.invalid");

    expect(c3_live::manager_subscribe(&manager, "sub", "demo:state", `{"room":"r"}`),
        "initial subscribe failed");
    expect_sent(`"type":"Connect"`);
    expect_sent(`"baseVersion":0,"newVersion":1`);
    expect_sent(`"type":"Add"`);

    push(updated(0, 1, "AAAAAAAAAAA=", "AQAAAAAAAAA=", 0, 0));
    CInt initial_tick = c3_live::manager_tick(&manager);
    if (initial_tick != 1)
    {
        io::eprintfn("initial tick=%d close=%s remote=%d/%d/%s", initial_tick,
            manager.last_close_reason, manager.remote_query_set,
            manager.remote_identity, manager.remote_timestamp)!!;
    }
    expect(initial_tick == 1, "initial Transition rejected");
    expect_event(&manager, `"count":0`);

    // Five real transport retirements reconnect and replay Add. The unchanged
    // hydration is suppressed; only the later changed value crosses the queue.
    String current_ts = "AQAAAAAAAAA=";
    for (int attempt = 1; attempt <= 5; attempt++)
    {
        expect(c3_live::manager_debug_disconnect(&manager), "debug reconnect failed");
        push(updated(0, 1, "AAAAAAAAAAA=", current_ts, 0, attempt - 1));
        expect(c3_live::manager_tick(&manager) == 1, "rehydration rejected");
        c3_live::LiveEvent suppressed;
        expect(!c3_live::manager_take_event(&manager, &suppressed),
            "unchanged hydration was emitted");
        String next_ts = string::tformat("timestamp-%d", attempt);
        push(updated(1, 1, current_ts, next_ts, 0, attempt));
        expect(c3_live::manager_tick(&manager) == 1, "changed update rejected");
        expect_event(&manager, string::tformat(`"count":%d`, attempt));
        current_ts = next_ts;
    }
    expect(manager.connection_count == 5 && fixture_connect_count() == 6,
        "five real reconnects were not observed");
    expect_sent(`"connectionCount":5`);
    expect_sent(`"maxObservedTimestamp"`);
    expect(manager.backoff_millis == 100, "healthy reconnect did not reset backoff");

    // QueryFailed is delivered as a structured FunctionError, then the same
    // subscription recovers on a later QueryUpdated.
    push(string::tformat(
        `{"type":"Transition","startVersion":{"querySet":1,"identity":0,"ts":"%s"},"endVersion":{"querySet":1,"identity":0,"ts":"failure-ts"},"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":"empty room","errorData":{"code":"ROOM_EMPTY"},"logLines":[]}]}`,
        current_ts));
    expect(c3_live::manager_tick(&manager) == 1, "QueryFailed rejected");
    expect_event(&manager, `"name":"FunctionError"`);
    push(updated(1, 1, "failure-ts", "recovered-ts", 0, 6));
    expect(c3_live::manager_tick(&manager) == 1, "QueryFailed recovery rejected");
    expect_event(&manager, `"count":6`);

    // A malformed Transition is atomic, emits ProtocolError, retires the old
    // generation, and reconnects after the bounded backoff.
    push(`{"type":"Transition","startVersion":{"querySet":1,"identity":0,"ts":"recovered-ts"},"endVersion":{"querySet":1,"identity":0,"ts":"bad-ts"},"modifications":[{"type":"Unknown","queryId":0}]}`);
    expect(c3_live::manager_tick(&manager) == -2, "malformed Transition was accepted");
    expect_event(&manager, `"name":"ProtocolError"`);
    expect(manager.backoff_millis == 200, "failure did not advance backoff");
    fixture_advance(100);
    c3_live::manager_tick(&manager);
    expect(manager.connected && manager.backoff_millis == 100,
        "successful recovery did not reset backoff");

    // Replacement clears an already queued old-generation value before its
    // acknowledgement can be published, then sends Remove before the new Add.
    push(updated(0, 1, "AAAAAAAAAAA=", "replacement-old", 0, 7));
    expect(c3_live::manager_tick(&manager) == 1, "replacement setup rejected");
    expect(c3_live::manager_subscribe(&manager, "sub", "demo:state", `{"room":"new"}`),
        "same-ID replacement failed");
    c3_live::LiveEvent stale;
    expect(!c3_live::manager_take_event(&manager, &stale), "stale relay crossed replacement ack");
    expect_sent(`"type":"Remove"`);

    expect(c3_live::manager_unsubscribe(&manager, "sub"), "unsubscribe failed");
    expect(!c3_live::manager_take_event(&manager, &stale), "stale relay crossed unsubscribe ack");
    expect(c3_live::manager_close(&manager), "bounded manager close failed");
    io::printn("c3 live protocol fixture passed");
}
