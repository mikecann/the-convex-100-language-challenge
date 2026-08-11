module c3_live;

// The C shim uses libcurl for verified TLS and adds only RFC6455 framing.
// These narrow calls expose complete UTF-8 bytes to C3, where Convex state lives.
extern fn char* c3_ws_connect(char* url, char* ca_path, CLong timeout_millis);
extern fn CInt c3_ws_is_active(char* transport);
extern fn CInt c3_ws_send_text(char* transport, char* data, usz length, CLong timeout_millis);
extern fn CInt c3_ws_receive_text(char* transport, char* output, usz capacity,
                                  usz* length, CLong timeout_millis);
extern fn CInt c3_ws_close(char* transport, CLong timeout_millis);
extern fn void c3_ws_free(char* transport);

// The WebSocket shim owns only RFC6455 bytes. C3 owns this state:
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

struct WebSocket
{
    char* transport;
}

fn bool websocket_connect(WebSocket* websocket, String url, String ca_path, CLong timeout_millis)
{
    websocket.transport = c3_ws_connect(url.ptr, ca_path.ptr, timeout_millis);
    return websocket.transport != null;
}

fn bool websocket_is_active(WebSocket* websocket)
{
    return websocket.transport != null && c3_ws_is_active(websocket.transport) != 0;
}

fn bool websocket_send(WebSocket* websocket, String payload, CLong timeout_millis)
{
    return websocket_is_active(websocket)
        && c3_ws_send_text(websocket.transport, payload.ptr, payload.len, timeout_millis) != 0;
}

fn CInt websocket_receive(WebSocket* websocket, char[] output, usz* length,
                          CLong timeout_millis)
{
    if (!websocket_is_active(websocket)) return -1;
    return c3_ws_receive_text(websocket.transport, output.ptr, output.len,
                              length, timeout_millis);
}

fn bool websocket_close(WebSocket* websocket, CLong timeout_millis)
{
    if (websocket.transport == null) return true;
    bool closed = c3_ws_close(websocket.transport, timeout_millis) != 0;
    c3_ws_free(websocket.transport);
    websocket.transport = null;
    return closed;
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
