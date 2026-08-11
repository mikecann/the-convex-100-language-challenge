module c3_live_fixture;
import std::io;
import c3_live;

fn void expect(bool value, String message)
{
    if (!value) builtin::panic(message, "live-buffer-fixture", "expect", 0);
}

fn void main()
{
    c3_live::WebSocket disconnected;
    expect(!c3_live::websocket_is_active(&disconnected), "zeroed WebSocket was active");
    expect(c3_live::websocket_close(&disconnected, 10), "zeroed WebSocket did not close cleanly");
    c3_live::Manager manager;
    c3_live::manager_init(&manager, "https://fixture.invalid");
    c3_live::Subscription subscription;
    c3_live::subscription_init(&subscription, 7, "sub-7", "demo:state", `{"room":"r"}`);
    expect(c3_live::subscription_deliver(&subscription, "initial"), "initial update rejected");
    expect(c3_live::subscription_deliver(&subscription, "external"), "external update rejected");
    c3_live::LiveEvent event;
    expect(c3_live::subscription_take(&subscription, &event) && event.payload == "initial", "initial update missing");
    c3_live::live_event_dispose(&event);
    expect(c3_live::subscription_take(&subscription, &event) && event.payload == "external", "external update missing");
    c3_live::live_event_dispose(&event);

    // Keep replacing a full queue with near-limit messages. This is the same
    // ownership pattern as a stopped adapter reader. The queue must remain at
    // its declared count and byte bounds instead of retaining every eviction.
    char[16384] large_payload;
    for (usz index = 0; index < large_payload.len; index++) large_payload[index] = 'x';
    String large_event = (String)large_payload[..];
    for (usz index = 0; index < 20000; index++)
    {
        expect(c3_live::subscription_deliver(&subscription, large_event),
            "bounded churn event rejected");
    }
    expect(subscription.count == c3_live::MAX_BUFFERED_EVENTS,
        "event count exceeded its bound");
    expect(subscription.buffered_bytes <= c3_live::MAX_BUFFERED_BYTES,
        "event bytes exceeded their bound");
    c3_live::subscription_invalidate(&subscription);
    expect(!c3_live::subscription_deliver(&subscription, "stale"), "stale relay crossed invalidation");
    expect(c3_live::manager_close(&manager), "manager did not close cleanly");
    io::printn("c3 live buffer fixture passed");
}
