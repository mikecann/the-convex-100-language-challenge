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
