module c3_live;

// The eventual WebSocket shim owns only RFC6455 bytes. C3 owns this state:
// query identity, delivery queues, generations, and reconnect scheduling.
const usz MAX_BUFFERED_EVENTS = 16;
const usz MAX_BUFFERED_BYTES = 262144;

struct LiveEvent
{
    String payload;
    usz bytes;
}

struct Subscription
{
    usz query_id;
    usz generation;
    LiveEvent[MAX_BUFFERED_EVENTS] events;
    usz head;
    usz count;
    usz buffered_bytes;
    bool closed;
}

struct Manager
{
    usz query_set_version;
    usz connection_count;
    usz reconnect_generation;
    bool connected;
}

fn void manager_init(Manager* manager)
{
    manager.reconnect_generation = 1;
}

// The owner calls this only after a successful RFC6455 handshake. Every
// active Add is replayed against a fresh query-set version by the caller.
fn void manager_connected(Manager* manager)
{
    manager.connected = true;
    manager.query_set_version = 0;
}

fn usz manager_next_query_set_version(Manager* manager)
{
    manager.query_set_version++;
    return manager.query_set_version;
}

// debugDisconnect retires the old generation before its acknowledgement.
// Any relay holding an older generation must discard rather than emit it.
fn void manager_debug_disconnect(Manager* manager)
{
    manager.connected = false;
    manager.connection_count++;
    manager.reconnect_generation++;
    manager.query_set_version = 0;
}

fn void subscription_init(Subscription* subscription, usz query_id)
{
    subscription.query_id = query_id;
    subscription.generation = 1;
}

// C3 enforces both a count and byte cap. Dropping the oldest undelivered
// value keeps a stopped adapter controller from retaining unbounded memory.
fn bool subscription_deliver(Subscription* subscription, String payload)
{
    if (subscription.closed) return false;
    usz bytes = payload.len;
    if (bytes > MAX_BUFFERED_BYTES) return false;
    while (subscription.count == MAX_BUFFERED_EVENTS
        || subscription.buffered_bytes + bytes > MAX_BUFFERED_BYTES)
    {
        if (!subscription.count) return false;
        subscription.buffered_bytes -= subscription.events[subscription.head].bytes;
        subscription.head = (subscription.head + 1) % MAX_BUFFERED_EVENTS;
        subscription.count--;
    }
    usz slot = (subscription.head + subscription.count) % MAX_BUFFERED_EVENTS;
    subscription.events[slot] = { payload, bytes };
    subscription.count++;
    subscription.buffered_bytes += bytes;
    return true;
}

fn bool subscription_take(Subscription* subscription, LiveEvent* event)
{
    if (!subscription.count) return false;
    *event = subscription.events[subscription.head];
    subscription.buffered_bytes -= event.bytes;
    subscription.head = (subscription.head + 1) % MAX_BUFFERED_EVENTS;
    subscription.count--;
    return true;
}

// Remove and same-ID replacement call this before publishing their ack. A
// relay that dequeued before the acknowledgement sees the new generation and
// must discard its stale event.
fn void subscription_invalidate(Subscription* subscription)
{
    subscription.generation++;
    subscription.head = 0;
    subscription.count = 0;
    subscription.buffered_bytes = 0;
    subscription.closed = true;
}
