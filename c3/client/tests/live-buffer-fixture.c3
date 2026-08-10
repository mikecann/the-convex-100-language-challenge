module c3_live_fixture;
import std::io;
import c3_live;

fn void expect(bool value, String message)
{
    if (!value) builtin::panic(message, "live-buffer-fixture", "expect", 0);
}

fn void main()
{
    c3_live::Manager manager;
    c3_live::manager_init(&manager);
    c3_live::manager_connected(&manager);
    expect(c3_live::manager_next_query_set_version(&manager) == 1, "Add did not advance query-set version");
    c3_live::Subscription subscription;
    c3_live::subscription_init(&subscription, 7);
    expect(c3_live::subscription_deliver(&subscription, "initial"), "initial update rejected");
    expect(c3_live::subscription_deliver(&subscription, "external"), "external update rejected");
    c3_live::LiveEvent event;
    expect(c3_live::subscription_take(&subscription, &event) && event.payload == "initial", "initial update missing");
    expect(c3_live::subscription_take(&subscription, &event) && event.payload == "external", "external update missing");
    c3_live::subscription_invalidate(&subscription);
    expect(!c3_live::subscription_deliver(&subscription, "stale"), "stale relay crossed invalidation");
    c3_live::manager_debug_disconnect(&manager);
    expect(!manager.connected && manager.connection_count == 1 && manager.reconnect_generation == 2,
        "debugDisconnect did not retire the connection generation");
    io::printn("c3 live buffer fixture passed");
}
