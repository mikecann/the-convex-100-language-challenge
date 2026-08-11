module c3_live;

import std::collections::object;
import std::core::string;
import std::encoding::json;
import std::io;

// The C shim uses libcurl for verified TLS and adds only RFC6455 framing.
// Convex messages, query-set versions, subscriptions, and reconnects stay here.
extern fn char* c3_ws_connect(char* url, char* ca_path, CLong timeout_millis);
extern fn CInt c3_ws_is_active(char* transport);
extern fn CInt c3_ws_send_text(char* transport, char* data, usz length, CLong timeout_millis);
extern fn CInt c3_ws_receive_text(char* transport, char* output, usz capacity,
                                  usz* length, CLong timeout_millis);
extern fn CInt c3_ws_close(char* transport, CLong timeout_millis);
extern fn void c3_ws_free(char* transport);
extern fn CInt c3_random_session_id(char* output, usz capacity);
extern fn CLongLong c3_monotonic_millis();

const usz MAX_SUBSCRIPTIONS = 32;
const usz MAX_BUFFERED_EVENTS = 16;
const usz MAX_BUFFERED_BYTES = 262144;
const usz MAX_LIVE_MESSAGE = 2097152;
const CLong IO_TIMEOUT_MS = 250;
// A tick may wait this long for the first byte. Once a frame starts, the same
// bounded window gives normal packet fragmentation time to complete before the
// transport retires the connection rather than losing parser alignment.
const CLong IDLE_POLL_MS = 250;
const String INITIAL_TS = "AAAAAAAAAAA=";

struct LiveEvent
{
    String payload;
    usz bytes;
}

struct Subscription
{
    bool occupied;
    bool closed;
    String subscription_id;
    String path;
    String args_json;
    usz query_id;
    usz generation;
    LiveEvent[MAX_BUFFERED_EVENTS] events;
    usz head;
    usz count;
    usz buffered_bytes;
    bool rehydrating;
    bool has_last_value;
    String last_value;
}

struct WebSocket
{
    char* transport;
}

struct Manager
{
    WebSocket websocket;
    String websocket_url;
    Subscription[MAX_SUBSCRIPTIONS] subscriptions;
    usz next_query_id;
    usz query_set_version;
    usz remote_query_set;
    usz remote_identity;
    String remote_timestamp;
    String max_observed_timestamp;
    String last_close_reason;
    char[] receive_buffer;
    usz connection_count;
    usz reconnect_generation;
    CLong backoff_millis;
    CLongLong reconnect_at;
    bool connected;
    bool closing;
}

fn String quote(String value) => value.tescape();
fn String object_json(Object* value) => string::tformat("%s", value);

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

fn void subscription_init(Subscription* subscription, usz query_id,
                          String subscription_id, String path, String args_json)
{
    usz generation = subscription.generation + 1;
    *subscription = {};
    subscription.occupied = true;
    subscription.query_id = query_id;
    subscription.generation = generation;
    subscription.subscription_id = subscription_id.copy(mem);
    subscription.path = path.copy(mem);
    subscription.args_json = args_json.copy(mem);
}

// Count and byte caps are both required. Dropping the oldest value prevents a
// stopped adapter reader from retaining unbounded Live data.
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
    subscription.events[slot] = { payload.copy(mem), bytes };
    subscription.count++;
    subscription.buffered_bytes += bytes;
    return true;
}

fn bool subscription_take(Subscription* subscription, LiveEvent* event)
{
    if (!subscription.count || subscription.closed) return false;
    *event = subscription.events[subscription.head];
    subscription.buffered_bytes -= event.bytes;
    subscription.head = (subscription.head + 1) % MAX_BUFFERED_EVENTS;
    subscription.count--;
    return true;
}

// Remove and same-ID replacement invalidate queued relays before the caller
// publishes its acknowledgement.
fn void subscription_invalidate(Subscription* subscription)
{
    subscription.generation++;
    subscription.head = 0;
    subscription.count = 0;
    subscription.buffered_bytes = 0;
    subscription.closed = true;
}

fn Subscription* find_subscription(Manager* manager, String subscription_id)
{
    foreach (&subscription : manager.subscriptions)
    {
        if (subscription.occupied && subscription.subscription_id == subscription_id)
        {
            return subscription;
        }
    }
    return null;
}

fn Subscription* find_query(Manager* manager, usz query_id)
{
    foreach (&subscription : manager.subscriptions)
    {
        if (subscription.occupied && !subscription.closed && subscription.query_id == query_id)
        {
            return subscription;
        }
    }
    return null;
}

fn Subscription* free_slot(Manager* manager)
{
    foreach (&subscription : manager.subscriptions)
    {
        if (!subscription.occupied || subscription.closed) return subscription;
    }
    return null;
}

fn bool has_active_subscriptions(Manager* manager)
{
    foreach (&subscription : manager.subscriptions)
    {
        if (subscription.occupied && !subscription.closed) return true;
    }
    return false;
}

fn void enqueue_subscription_error(Subscription* subscription, String name,
                                   String message, String data = "null")
{
    subscription_deliver(subscription,
        string::tformat(`{"type":"subscription","subscriptionId":%s,"error":{"name":%s,"message":%s,"data":%s}}`,
            quote(subscription.subscription_id), quote(name), quote(message), data));
}

fn void publish_error(Manager* manager, String name, String message)
{
    foreach (&subscription : manager.subscriptions)
    {
        if (subscription.occupied && !subscription.closed)
        {
            enqueue_subscription_error(subscription, name, message);
        }
    }
}

fn String add_message(Manager* manager, Subscription* subscription)
{
    return string::tformat(
        `{"type":"ModifyQuerySet","baseVersion":%d,"newVersion":%d,"modifications":[{"type":"Add","queryId":%d,"udfPath":%s,"args":[%s]}]}`,
        manager.query_set_version, manager.query_set_version + 1,
        subscription.query_id, quote(subscription.path), subscription.args_json);
}

fn String remove_message(Manager* manager, usz query_id)
{
    return string::tformat(
        `{"type":"ModifyQuerySet","baseVersion":%d,"newVersion":%d,"modifications":[{"type":"Remove","queryId":%d}]}`,
        manager.query_set_version, manager.query_set_version + 1, query_id);
}

fn void manager_init(Manager* manager, String deployment)
{
    *manager = {};
    manager.remote_timestamp = INITIAL_TS;
    manager.last_close_reason = "InitialConnect";
    manager.reconnect_generation = 1;
    manager.backoff_millis = 100;
    manager.receive_buffer = mem::new_array(char, MAX_LIVE_MESSAGE);
    if (deployment.starts_with("https://"))
    {
        manager.websocket_url = string::tformat("wss://%s/api/sync", deployment[8..]).copy(mem);
    }
    else if (deployment.starts_with("http://"))
    {
        manager.websocket_url = string::tformat("ws://%s/api/sync", deployment[7..]).copy(mem);
    }
}

fn void manager_retire(Manager* manager, String reason, bool report_error)
{
    websocket_close(&manager.websocket, IO_TIMEOUT_MS);
    manager.connected = false;
    manager.connection_count++;
    manager.reconnect_generation++;
    manager.query_set_version = 0;
    manager.remote_query_set = 0;
    manager.remote_identity = 0;
    manager.remote_timestamp = INITIAL_TS;
    manager.last_close_reason = reason.copy(mem);
    foreach (&subscription : manager.subscriptions)
    {
        if (subscription.occupied && !subscription.closed) subscription.rehydrating = true;
    }
    if (report_error) publish_error(manager, "TransportError", reason);
}

fn bool send_connect(Manager* manager)
{
    char[37] session_id;
    if (c3_random_session_id(&session_id[0], session_id.len) == 0) return false;
    String maximum = manager.max_observed_timestamp.len
        ? string::tformat(`,"maxObservedTimestamp":%s`, quote(manager.max_observed_timestamp))
        : "";
    String message = string::tformat(
        `{"type":"Connect","sessionId":"%s","connectionCount":%d,"lastCloseReason":%s%s,"clientTs":0}`,
        (String)session_id[:36], manager.connection_count, quote(manager.last_close_reason), maximum);
    return websocket_send(&manager.websocket, message, IO_TIMEOUT_MS);
}

fn bool manager_connect(Manager* manager)
{
    if (!manager.websocket_url.len) return false;
    if (!websocket_connect(&manager.websocket, manager.websocket_url,
        "/etc/ssl/certs/ca-certificates.crt", 10000)) return false;
    manager.query_set_version = 0;
    manager.remote_query_set = 0;
    manager.remote_identity = 0;
    manager.remote_timestamp = INITIAL_TS;
    if (!send_connect(manager)) { manager_retire(manager, "ConnectWriteFailed", false); return false; }
    foreach (&subscription : manager.subscriptions)
    {
        if (!subscription.occupied || subscription.closed) continue;
        if (!websocket_send(&manager.websocket, add_message(manager, subscription), IO_TIMEOUT_MS))
        {
            manager_retire(manager, "ReplayWriteFailed", false);
            return false;
        }
        manager.query_set_version++;
    }
    manager.connected = true;
    manager.backoff_millis = 100;
    manager.reconnect_at = 0;
    return true;
}

fn void schedule_reconnect(Manager* manager, String reason, String error_name)
{
    bool protocol = error_name == "ProtocolError";
    manager_retire(manager, reason, false);
    publish_error(manager, error_name, reason);
    manager.reconnect_at = c3_monotonic_millis() + manager.backoff_millis;
    manager.backoff_millis = manager.backoff_millis < 7500
        ? manager.backoff_millis * 2
        : 15000;
    if (protocol) manager.last_close_reason = "ProtocolError";
}

fn bool manager_subscribe(Manager* manager, String subscription_id,
                          String path, String args_json)
{
    Subscription* subscription = find_subscription(manager, subscription_id);
    if (subscription)
    {
        usz old_query_id = subscription.query_id;
        subscription_invalidate(subscription);
        if (manager.connected && !websocket_send(&manager.websocket,
            remove_message(manager, old_query_id), IO_TIMEOUT_MS))
        {
            schedule_reconnect(manager, "RemoveWriteFailed", "TransportError");
            return false;
        }
        if (manager.connected) manager.query_set_version++;
    }
    else
    {
        subscription = free_slot(manager);
        if (!subscription) return false;
    }
    subscription_init(subscription, manager.next_query_id++, subscription_id, path, args_json);
    if (!manager.connected)
    {
        if (!manager_connect(manager)) return false;
        return true;
    }
    if (!websocket_send(&manager.websocket, add_message(manager, subscription), IO_TIMEOUT_MS))
    {
        schedule_reconnect(manager, "AddWriteFailed", "TransportError");
        return false;
    }
    manager.query_set_version++;
    return true;
}

fn bool manager_unsubscribe(Manager* manager, String subscription_id)
{
    Subscription* subscription = find_subscription(manager, subscription_id);
    if (!subscription) return true;
    usz query_id = subscription.query_id;
    subscription_invalidate(subscription);
    if (manager.connected && !websocket_send(&manager.websocket,
        remove_message(manager, query_id), IO_TIMEOUT_MS))
    {
        schedule_reconnect(manager, "RemoveWriteFailed", "TransportError");
        return false;
    }
    if (manager.connected) manager.query_set_version++;
    return true;
}

fn bool manager_debug_disconnect(Manager* manager)
{
    if (!manager.connected) return false;
    // Retire first, then reconnect and replay every active Add. The caller may
    // acknowledge only after this returns true.
    manager_retire(manager, "DebugDisconnect", false);
    return manager_connect(manager);
}

// The C3 JSON decoder stores JSON numbers as doubles, including protocol
// counters written as `0`. Accept only exactly integral, non-negative values.
fn bool protocol_uint(Object* value, usz* output)
{
    if (value.type != double) return false;
    double number = value.f;
    if (number != number || number < 0.0 || number > 4294967295.0) return false;
    usz converted = (usz)number;
    if (number != (double)converted) return false;
    *output = converted;
    return true;
}

fn bool state_version(Object* root, String name, usz* query_set,
                      usz* identity, String* timestamp)
{
    if (!root.has_key(name)) return false;
    Object* version = root.get(name)!!;
    if (!version.is_map()) return false;
    if (!version.has_key("querySet") || !version.has_key("identity")
        || !version.has_key("ts")) return false;
    Object* query = version.get("querySet")!!;
    Object* identity_value = version.get("identity")!!;
    Object* timestamp_value = version.get("ts")!!;
    if (!protocol_uint(query, query_set) || !protocol_uint(identity_value, identity)
        || !timestamp_value.is_string())
    {
        io::eprintfn("C3 Live invalid version fields q=%s int=%s i=%s int=%s ts=%s string=%s",
            query, query.is_int(), identity_value, identity_value.is_int(),
            timestamp_value, timestamp_value.is_string())!!;
        return false;
    }
    *timestamp = timestamp_value.s;
    return timestamp.len && timestamp.len < 128;
}

fn bool modification_valid(Object* modification)
{
    if (!modification.is_map()) return false;
    if (!modification.has_key("type") || !modification.has_key("queryId")) return false;
    Object* type = modification.get("type")!!;
    Object* query_id = modification.get("queryId")!!;
    usz parsed_query_id;
    if (!type.is_string() || !protocol_uint(query_id, &parsed_query_id)) return false;
    if (type.s != "QueryUpdated" && type.s != "QueryFailed" && type.s != "QueryRemoved")
    {
        return false;
    }
    if (type.s == "QueryUpdated" && !modification.has_key("value")) return false;
    if (type.s == "QueryFailed")
    {
        if (!modification.has_key("errorMessage")) return false;
        Object* message = modification.get("errorMessage")!!;
        if (!message.is_string()) return false;
    }
    if (modification.has_key("logLines"))
    {
        Object* logs = modification.get("logLines")!!;
        if (!logs.is_array() && !logs.is_empty()) return false;
    }
    return true;
}

fn String logs_json(Object* modification)
{
    if (!modification.has_key("logLines")) return "[]";
    Object* logs = modification.get("logLines")!!;
    return logs.is_empty() ? "[]" : object_json(logs);
}

fn bool handle_transition(Manager* manager, Object* root)
{
    usz start_query_set, start_identity, end_query_set, end_identity;
    String start_timestamp, end_timestamp;
    if (!state_version(root, "startVersion", &start_query_set, &start_identity, &start_timestamp)
        || !state_version(root, "endVersion", &end_query_set, &end_identity, &end_timestamp))
    {
        io::eprintn("C3 Live rejected Transition version shape");
        return false;
    }
    if (!root.has_key("modifications")) return false;
    Object* modifications = root.get("modifications")!!;
    if (!modifications.is_array() && !modifications.is_empty())
    {
        io::eprintn("C3 Live rejected Transition modifications shape");
        return false;
    }
    if (start_query_set != manager.remote_query_set
        || start_identity != manager.remote_identity
        || start_timestamp != manager.remote_timestamp)
    {
        io::eprintfn("C3 Live version mismatch %d/%d/%s != %d/%d/%s",
            start_query_set, start_identity, start_timestamp,
            manager.remote_query_set, manager.remote_identity, manager.remote_timestamp)!!;
        return false;
    }

    // Validate the complete immutable transition before publishing any event.
    if (modifications.is_array())
    {
        foreach (modification : modifications.array)
        {
            if (!modification_valid(modification))
            {
                io::eprintfn("C3 Live rejected modification %s", modification)!!;
                return false;
            }
        }
    }

    if (modifications.is_array()) foreach (modification : modifications.array)
    {
        Object* query_id = modification.get("queryId")!!;
        usz parsed_query_id;
        if (!protocol_uint(query_id, &parsed_query_id)) return false;
        Subscription* subscription = find_query(manager, parsed_query_id);
        if (!subscription) continue;
        Object* type = modification.get("type")!!;
        if (type.s == "QueryRemoved") continue;
        if (type.s == "QueryUpdated")
        {
            Object* value = modification.get("value")!!;
            String value_json = object_json(value);
            bool unchanged = subscription.has_last_value && subscription.last_value == value_json;
            bool suppress = subscription.rehydrating && unchanged;
            subscription.last_value = value_json.copy(mem);
            subscription.has_last_value = true;
            subscription.rehydrating = false;
            if (!suppress) subscription_deliver(subscription,
                string::tformat(`{"type":"subscription","subscriptionId":%s,"value":%s,"logs":%s}`,
                    quote(subscription.subscription_id), value_json, logs_json(modification)));
        }
        else
        {
            Object* message = modification.get("errorMessage")!!;
            String data = modification.has_key("errorData")
                ? object_json(modification.get("errorData")!!)
                : "null";
            subscription.has_last_value = false;
            subscription.rehydrating = false;
            enqueue_subscription_error(subscription, "FunctionError", message.s, data);
        }
    }
    manager.remote_query_set = end_query_set;
    manager.remote_identity = end_identity;
    manager.remote_timestamp = end_timestamp.copy(mem);
    manager.max_observed_timestamp = end_timestamp.copy(mem);
    return true;
}

fn CInt manager_tick(Manager* manager)
{
    if (manager.closing) return 0;
    if (!manager.connected)
    {
        if (has_active_subscriptions(manager) && c3_monotonic_millis() >= manager.reconnect_at)
        {
            if (!manager_connect(manager))
            {
                manager.connection_count++;
                manager.last_close_reason = "ConnectFailed";
                manager.reconnect_at = c3_monotonic_millis() + manager.backoff_millis;
                manager.backoff_millis = manager.backoff_millis < 7500
                    ? manager.backoff_millis * 2
                    : 15000;
            }
        }
        return 0;
    }
    usz length = 0;
    CInt received = websocket_receive(&manager.websocket, manager.receive_buffer, &length, IDLE_POLL_MS);
    if (received == 0) return 0;
    if (received != 1)
    {
        schedule_reconnect(manager, received == 2 ? "ServerClosed" : "LiveReadFailed",
                           "TransportError");
        return -1;
    }
    Object*? parsed = json::parse(mem, (String)manager.receive_buffer[:length], JSON);
    if (catch ignored = parsed)
    {
        schedule_reconnect(manager, "InvalidLiveJSON", "ProtocolError");
        return -2;
    }
    Object* root = parsed;
    if (!root.is_map())
    {
        schedule_reconnect(manager, "LiveMessageMustBeObject", "ProtocolError");
        return -2;
    }
    Object* type = root.get("type") ?? null;
    if (!type || !type.is_string())
    {
        schedule_reconnect(manager, "LiveMessageOmittedType", "ProtocolError");
        return -2;
    }
    if (type.s == "Transition")
    {
        if (!handle_transition(manager, root))
        {
            schedule_reconnect(manager, "InvalidTransition", "ProtocolError");
            return -2;
        }
        return 1;
    }
    if (type.s == "Ping" || type.s == "MutationResponse" || type.s == "ActionResponse")
    {
        return 1;
    }
    schedule_reconnect(manager, "UnknownLiveMessage", "ProtocolError");
    return -2;
}

fn bool manager_take_event(Manager* manager, LiveEvent* event)
{
    foreach (&subscription : manager.subscriptions)
        if (subscription.occupied && !subscription.closed
            && subscription_take(subscription, event)) return true;
    return false;
}

fn bool manager_close(Manager* manager)
{
    manager.closing = true;
    foreach (&subscription : manager.subscriptions)
        if (subscription.occupied) subscription_invalidate(subscription);
    manager.connected = false;
    bool closed = websocket_close(&manager.websocket, IO_TIMEOUT_MS);
    if (manager.receive_buffer.ptr) mem::free(manager.receive_buffer.ptr);
    manager.receive_buffer = {};
    return closed;
}
