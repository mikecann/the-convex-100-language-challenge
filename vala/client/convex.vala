using GLib;
using Gee;
using Soup;
using Json;

namespace Convex {
  public errordomain ClientError {
    TRANSPORT,
    PROTOCOL,
    FUNCTION,
    CLOSED
  }

  public class Result : GLib.Object {
    public Json.Node value { get; construct; }
    public string[] logs { get; construct; }
    public Result (Json.Node value, string[] logs = {}) { GLib.Object (value: value, logs: logs); }
  }

  public class FunctionError : GLib.Object {
    public string name { get; construct; }
    public string message { get; construct; }
    public Json.Node? data { get; construct; }
    public string[] logs { get; construct; }
    public FunctionError (string name, string message, Json.Node? data = null, string[] logs = {}) {
      GLib.Object (name: name, message: message, data: data, logs: logs);
    }
  }

  internal string node_text (Json.Node node) {
    var generator = new Generator ();
    generator.set_root (node);
    return generator.to_data (null);
  }

  internal Json.Node parse_json (string source) throws Error {
    var parser = new Parser ();
    parser.load_from_data (source, -1);
    return parser.get_root ().copy ();
  }

  internal string json_string (string value) {
    var builder = new Builder ();
    builder.begin_array (); builder.add_string_value (value); builder.end_array ();
    var text = node_text (builder.get_root ());
    return text.substring (1, text.length - 2);
  }

  internal uint uint32_number (Json.Node node, string field) throws ClientError {
    if (node.get_node_type () != NodeType.VALUE) {
      throw new ClientError.PROTOCOL (field + " is not numeric");
    }
    var value_type = node.get_value_type ();
    if (value_type != typeof (int64) && value_type != typeof (double)) {
      throw new ClientError.PROTOCOL (field + " is not numeric");
    }
    double number = node.get_double ();
    if (number != number || number < 0 || number > uint.MAX || number != (double) ((uint) number)) {
      throw new ClientError.PROTOCOL (field + " is outside uint32 range");
    }
    return (uint) number;
  }

  internal uint uint32_member (Json.Object object, string field) throws ClientError {
    if (!object.has_member (field)) throw new ClientError.PROTOCOL ("missing " + field);
    return uint32_number (object.get_member (field), field);
  }

  internal string[] logs_from (Json.Object? object) {
    if (object == null || !object.has_member ("logLines")) return {};
    var array = object.get_array_member ("logLines");
    var logs = new ArrayList<string> ();
    for (uint i = 0; i < array.get_length (); i++) logs.add (array.get_string_element (i));
    string[] answer = new string[logs.size];
    for (int i = 0; i < logs.size; i++) answer[i] = logs.get (i);
    return answer;
  }

  internal uint64 timestamp_value (string encoded) throws ClientError {
    uint8[] bytes = Base64.decode (encoded);
    if (bytes.length != 8) throw new ClientError.PROTOCOL ("timestamp is not a uint64");
    uint64 answer = 0;
    for (int i = 7; i >= 0; i--) answer = (answer << 8) | bytes[i];
    return answer;
  }

  public class Subscription : GLib.Object {
    internal uint query_id;
    internal string path;
    internal Json.Node args;
    internal bool active = true;
    internal string? last_signature;
    internal ArrayQueue<Update> queue = new ArrayQueue<Update> ();
    private const int MAX_PENDING_UPDATES = 16;
    private const size_t MAX_PENDING_BYTES = 8 * 1024 * 1024;
    private uint relay_generation = 1;
    private uint delivery_source = 0;
    private size_t pending_bytes = 0;
    // Reconnect snapshots are allowed to repeat the last value once. Later
    // same-value server transitions are still observable events.
    private bool suppress_next_unchanged = false;
    // This internal hook exists solely for a deterministic adapter regression:
    // it pauses after dequeue so unsubscribe/replacement can prove its ACK
    // barrier before the relay would otherwise publish a stale event.
    internal static DeliveryHook? before_delivery_for_test;
    public signal void updated (Json.Node? value, FunctionError? error);

    internal Subscription (uint query_id, string path, Json.Node args) {
      this.query_id = query_id; this.path = path; this.args = args;
    }

    internal size_t pending_count () { return queue.size; }
    internal size_t pending_byte_count () { return pending_bytes; }

    internal void invalidate () {
      if (!active) return;
      active = false;
      relay_generation++;
      if (delivery_source != 0) {
        Source.remove (delivery_source);
        delivery_source = 0;
      }
      while (!queue.is_empty) queue.poll ();
      pending_bytes = 0;
    }

    internal void prepare_rehydration () {
      suppress_next_unchanged = last_signature != null;
    }

    private void schedule_delivery () {
      if (delivery_source != 0 || queue.is_empty || !active) return;
      uint generation = relay_generation;
      delivery_source = Idle.add (() => {
        delivery_source = 0;
        if (!active || generation != relay_generation) {
          while (!queue.is_empty) queue.poll ();
          pending_bytes = 0;
          return false;
        }
        var next = queue.poll ();
        pending_bytes -= next.encoded_bytes;
        if (before_delivery_for_test != null) before_delivery_for_test (this);
        if (next.generation == relay_generation) updated (next.value, next.error);
        if (active && generation == relay_generation && !queue.is_empty) schedule_delivery ();
        return false;
      });
    }

    internal void publish (Json.Node? value, FunctionError? error) {
      if (!active) return;
      var signature = error != null ? "E:" + error.name + ":" + error.message + ":" + (error.data != null ? node_text (error.data) : "") : "V:" + node_text (value);
      if (signature == last_signature && suppress_next_unchanged) {
        suppress_next_unchanged = false;
        return;
      }
      suppress_next_unchanged = false;
      last_signature = signature;
      size_t encoded_bytes = value != null ? node_text (value).length : 64;
      if (error != null) encoded_bytes += error.name.length + error.message.length + (error.data != null ? node_text (error.data).length : 0);
      while ((queue.size >= MAX_PENDING_UPDATES || pending_bytes + encoded_bytes > MAX_PENDING_BYTES) && !queue.is_empty) {
        var discarded = queue.poll ();
        pending_bytes -= discarded.encoded_bytes;
      }
      if (encoded_bytes > MAX_PENDING_BYTES) {
        while (!queue.is_empty) queue.poll ();
        pending_bytes = 0;
        var bounded = new FunctionError ("ProtocolError", "Live update exceeds the bounded delivery byte budget");
        encoded_bytes = bounded.message.length + bounded.name.length + 64;
        queue.offer (new Update (null, bounded, relay_generation, encoded_bytes));
        pending_bytes = encoded_bytes;
      } else {
        queue.offer (new Update (value, error, relay_generation, encoded_bytes));
        pending_bytes += encoded_bytes;
      }
      schedule_delivery ();
    }
  }

  internal delegate void DeliveryHook (Subscription subscription);

  internal class Update : GLib.Object {
    public Json.Node? value; public FunctionError? error; public uint generation; public size_t encoded_bytes;
    public Update (Json.Node? value, FunctionError? error, uint generation, size_t encoded_bytes) {
      this.value = value; this.error = error; this.generation = generation; this.encoded_bytes = encoded_bytes;
    }
  }

  internal class LiveOwner : GLib.Object {
    private Client client;
    private Session session = new Session ();
    private WebsocketConnection? socket;
    private HashMap<uint, Subscription> active = new HashMap<uint, Subscription> ();
    private uint next_query_id = 1;
    private uint query_set_version = 0;
    // Each callback captures this number.  A late close/error from a retired
    // socket must never be allowed to change the replacement connection.
    private uint socket_generation = 0;
    private uint remote_query_set = 0;
    private uint remote_identity = 0;
    private string remote_timestamp = "AAAAAAAAAAA=";
    private uint connection_count = 0;
    private string last_close_reason = "InitialConnect";
    private string max_timestamp = "AAAAAAAAAAA=";
    private uint64 max_timestamp_number = 0;
    private bool saw_timestamp = false;
    private bool connecting = false;
    private bool closing = false;
    private uint reconnect_backoff_ms = 100;
    private uint reconnect_source = 0;
    private uint frame_timeout_source = 0;
    private const uint LIVE_FRAME_TIMEOUT_MS = 5000;

    internal LiveOwner (Client client) { this.client = client; }

    internal Subscription add (string path, Json.Node args) throws ClientError {
      if (next_query_id == uint.MAX) throw new ClientError.PROTOCOL ("query id space exhausted");
      var subscription = new Subscription (next_query_id++, path, args.copy ());
      active.set (subscription.query_id, subscription);
      ensure_connected ();
      if (socket != null && socket.state == WebsocketState.OPEN) send_modify ({ subscription }, {});
      return subscription;
    }

    internal void remove (Subscription subscription) {
      if (!subscription.active) return;
      // Invalidate before emitting an acknowledgement from the adapter.
      subscription.invalidate ();
      active.unset (subscription.query_id);
      if (socket != null && socket.state == WebsocketState.OPEN) send_modify ({}, { subscription.query_id });
      if (active.size == 0 && reconnect_source != 0) { Source.remove (reconnect_source); reconnect_source = 0; }
    }

    internal bool debug_disconnect () {
      if (socket == null) return false;
      last_close_reason = "debugDisconnect";
      // retire_and_reconnect invalidates callbacks and schedules the next
      // connection before this method returns, which is the adapter ACK barrier.
      retire_and_reconnect ("debugDisconnect");
      return true;
    }

    internal void close () {
      closing = true;
      if (reconnect_source != 0) { Source.remove (reconnect_source); reconnect_source = 0; }
      if (frame_timeout_source != 0) { Source.remove (frame_timeout_source); frame_timeout_source = 0; }
      foreach (var subscription in active.values) subscription.invalidate ();
      active.clear ();
      if (socket != null) socket.close (1000, "client closed");
      socket = null;
      session.abort ();
    }

    private string websocket_url () throws ClientError {
      if (client.url.has_prefix ("https://")) return "wss://" + client.url.substring (8) + "/api/sync";
      if (client.url.has_prefix ("http://")) return "ws://" + client.url.substring (7) + "/api/sync";
      throw new ClientError.PROTOCOL ("Convex deployment URL must use http or https");
    }

    private void ensure_connected () {
      if (closing || connecting || socket != null || active.size == 0) return;
      open_socket.begin ();
    }

    private async void open_socket () {
      connecting = true;
      try {
        var message = new Message ("GET", websocket_url ());
        message.request_headers.append ("Convex-Client", "vala-0.1.0");
        if (client.auth_token != null) message.request_headers.append ("Authorization", "Bearer " + client.auth_token);
        var next = yield session.websocket_connect_async (message, null, null, Priority.DEFAULT, null);
        if (closing) { next.close (1000, "client closed"); return; }
        socket = next;
        uint generation = ++socket_generation;
        query_set_version = 0;
        remote_query_set = 0; remote_identity = 0; remote_timestamp = "AAAAAAAAAAA=";
        reconnect_backoff_ms = 100;
        socket.set_max_incoming_payload_size (2 * 1024 * 1024);
        arm_frame_timeout (generation);
        socket.message.connect ((type, payload) => {
          if (socket == next && socket_generation == generation) on_message (type, payload);
        });
        socket.error.connect ((error) => {
          if (socket == next && socket_generation == generation) transport_failure (error.message);
        });
        socket.closed.connect (() => {
          if (socket == next && socket_generation == generation) transport_failure ("socket closed");
        });
        string observed_timestamp = saw_timestamp ? ",\"maxObservedTimestamp\":" + json_string (max_timestamp) : "";
        send_text ("{\"type\":\"Connect\",\"sessionId\":" + json_string (Uuid.string_random ()) +
                   ",\"connectionCount\":" + connection_count.to_string () + ",\"lastCloseReason\":" +
                   json_string (last_close_reason) + observed_timestamp + ",\"clientTs\":0}");
        var all = new ArrayList<Subscription> ();
        foreach (var sub in active.values) {
          if (connection_count > 0) sub.prepare_rehydration ();
          all.add (sub);
        }
        if (all.size > 0) {
          Subscription[] subscriptions = new Subscription[all.size];
          for (int i = 0; i < all.size; i++) subscriptions[i] = all.get (i);
          send_modify (subscriptions, {});
        }
      } catch (Error error) {
        transport_failure (error.message);
      } finally { connecting = false; }
    }

    private void send_text (string text) {
      if (socket == null || socket.state != WebsocketState.OPEN) return;
      socket.send_text (text);
    }

    private void send_modify (Subscription[] adds, uint[] removes) {
      if (socket == null || socket.state != WebsocketState.OPEN) return;
      var parts = new ArrayList<string> ();
      foreach (var sub in adds) parts.add ("{\"type\":\"Add\",\"queryId\":" + sub.query_id.to_string () +
                                           ",\"udfPath\":" + json_string (sub.path) + ",\"args\":[" + node_text (sub.args) + "]}");
      foreach (var id in removes) parts.add ("{\"type\":\"Remove\",\"queryId\":" + id.to_string () + "}");
      if (parts.size == 0) return;
      var next = query_set_version + 1;
      string joined = "";
      foreach (var part in parts) joined += (joined.length == 0 ? "" : ",") + part;
      send_text ("{\"type\":\"ModifyQuerySet\",\"baseVersion\":" + query_set_version.to_string () +
                 ",\"newVersion\":" + next.to_string () + ",\"modifications\":[" + joined + "]}");
      query_set_version = next;
    }

    private void retire_and_reconnect (string reason) {
      if (socket == null && !connecting) return;
      var retired = socket;
      socket = null; connecting = false; query_set_version = 0;
      if (frame_timeout_source != 0) { Source.remove (frame_timeout_source); frame_timeout_source = 0; }
      socket_generation++;
      remote_query_set = 0; remote_identity = 0; remote_timestamp = "AAAAAAAAAAA=";
      connection_count++; last_close_reason = reason;
      if (retired != null && retired.state == WebsocketState.OPEN) retired.close (4000, reason);
      if (closing || active.size == 0 || reconnect_source != 0) return;
      uint delay = reconnect_backoff_ms;
      reconnect_backoff_ms = uint.min (reconnect_backoff_ms * 2, 15000);
      reconnect_source = Timeout.add (delay, () => { reconnect_source = 0; ensure_connected (); return false; });
    }

    private void on_message (int type, Bytes payload) {
      if (socket != null) arm_frame_timeout (socket_generation);
      if (type != WebsocketDataType.TEXT) { protocol_failure ("binary Live frame"); return; }
      unowned uint8[] data = payload.get_data ();
      try { handle_transition (parse_json ((string) data)); }
      catch (Error error) { protocol_failure (error.message); }
    }

    private void handle_transition (Json.Node node) throws Error {
      if (node.get_node_type () != NodeType.OBJECT) throw new ClientError.PROTOCOL ("Live frame is not an object");
      var root = node.get_object ();
      var type = root.get_string_member ("type");
      if (type == "Ping" || type == "MutationResponse" || type == "ActionResponse") return;
      if (type != "Transition") throw new ClientError.PROTOCOL ("unexpected Live message " + type);
      var start = root.get_object_member ("startVersion");
      if (uint32_member (start, "querySet") != remote_query_set ||
          uint32_member (start, "identity") != remote_identity ||
          start.get_string_member ("ts") != remote_timestamp) throw new ClientError.PROTOCOL ("Transition start version mismatch");
      var pending = new ArrayList<UpdatePublication> ();
      var modifications = root.get_array_member ("modifications");
      for (uint i = 0; i < modifications.get_length (); i++) {
        var modification = modifications.get_object_element (i);
        uint id = uint32_member (modification, "queryId");
        var sub = active.get (id); if (sub == null) continue;
        var kind = modification.get_string_member ("type");
        if (kind == "QueryUpdated") pending.add (new UpdatePublication (sub, modification.get_member ("value").copy (), null));
        else if (kind == "QueryFailed") {
          Json.Node? data = modification.has_member ("errorData") ? modification.get_member ("errorData").copy () : null;
          pending.add (new UpdatePublication (sub, null, new FunctionError ("FunctionError", modification.get_string_member ("errorMessage"), data, logs_from (modification))));
        } else if (kind != "QueryRemoved") throw new ClientError.PROTOCOL ("unknown Transition modification " + kind);
      }
      var end = root.get_object_member ("endVersion");
      var end_timestamp = end.get_string_member ("ts");
      uint64 end_number = timestamp_value (end_timestamp);
      if (end_number < max_timestamp_number) throw new ClientError.PROTOCOL ("timestamp moved backwards");
      max_timestamp = end_timestamp; max_timestamp_number = end_number;
      saw_timestamp = true;
      remote_timestamp = end_timestamp; remote_query_set = uint32_member (end, "querySet"); remote_identity = uint32_member (end, "identity");
      // All state is committed before any callback can observe the transition.
      foreach (var update in pending) update.subscription.publish (update.value, update.error);
    }

    private void protocol_failure (string message) {
      foreach (var sub in active.values) sub.publish (null, new FunctionError ("ProtocolError", message));
      retire_and_reconnect (message);
    }

    // libsoup only emits a completed WebSocket message. If a peer stalls in a
    // partial frame, abandon that connection instead of retaining parser state
    // indefinitely or treating the next connection as its continuation.
    private void arm_frame_timeout (uint generation) {
      if (frame_timeout_source != 0) Source.remove (frame_timeout_source);
      frame_timeout_source = Timeout.add (LIVE_FRAME_TIMEOUT_MS, () => {
        frame_timeout_source = 0;
        if (!closing && socket != null && socket_generation == generation) {
          transport_failure ("Live frame timed out");
        }
        return false;
      });
    }

    private void transport_failure (string message) {
      foreach (var sub in active.values) sub.publish (null, new FunctionError ("TransportError", message));
      retire_and_reconnect (message);
    }
  }

  internal class UpdatePublication : GLib.Object {
    public Subscription subscription; public Json.Node? value; public FunctionError? error;
    public UpdatePublication (Subscription subscription, Json.Node? value, FunctionError? error) { this.subscription = subscription; this.value = value; this.error = error; }
  }

  public class Client : GLib.Object {
    internal string url;
    private string? token;
    private Session session = new Session ();
    private LiveOwner? live;
    private bool closed = false;
    public FunctionError? last_function_error { get; private set; }
    internal string? auth_token { get { return token; } }
    public Client (string url) throws ClientError {
      if (!url.has_prefix ("http://") && !url.has_prefix ("https://")) throw new ClientError.PROTOCOL ("Convex deployment URL must use http or https");
      this.url = url.has_suffix ("/") ? url.substring (0, url.length - 1) : url;
      session.timeout = 15;
    }
    public void set_auth (string token) throws ClientError { if (closed) throw new ClientError.CLOSED ("client is closed"); this.token = token.length == 0 ? null : token; }
    public Result query (string path, Json.Node args) throws Error { return call ("query", path, args); }
    public Result mutation (string path, Json.Node args) throws Error { return call ("mutation", path, args); }
    public Result action (string path, Json.Node args) throws Error { return call ("action", path, args); }
    public Subscription subscribe (string path, Json.Node args) throws ClientError {
      if (closed) throw new ClientError.CLOSED ("client is closed");
      if (path.length == 0 || args.get_node_type () != NodeType.OBJECT) throw new ClientError.PROTOCOL ("Live query needs a path and JSON object args");
      if (live == null) live = new LiveOwner (this);
      return live.add (path, args);
    }
    public void unsubscribe (Subscription subscription) { if (live != null) live.remove (subscription); }
    public bool debug_disconnect_for_adapter () { return live != null && live.debug_disconnect (); }
    public void close () { if (closed) return; closed = true; if (live != null) live.close (); session.abort (); }
    private Result call (string operation, string path, Json.Node args) throws Error {
      last_function_error = null;
      if (closed) throw new ClientError.CLOSED ("client is closed");
      if (path.length == 0 || args.get_node_type () != NodeType.OBJECT) throw new ClientError.PROTOCOL ("Convex arguments must be a JSON object");
      var body = "{\"path\":" + json_string (path) + ",\"args\":" + node_text (args) + ",\"format\":\"json\"}";
      var message = new Message ("POST", url + "/api/" + operation);
      message.request_headers.append ("Accept", "application/json"); message.request_headers.append ("Convex-Client", "vala-0.1.0");
      if (token != null) message.request_headers.append ("Authorization", "Bearer " + token);
      message.set_request_body_from_bytes ("application/json", new Bytes (body.data));
      Bytes response = session.send_and_read (message, null);
      if (response.get_size () > 2 * 1024 * 1024) throw new ClientError.TRANSPORT ("HTTP response exceeds 2 MiB");
      unowned uint8[] data = response.get_data (); var decoded = parse_json ((string) data);
      if (decoded.get_node_type () != NodeType.OBJECT) throw new ClientError.PROTOCOL ("HTTP response is not an object");
      var object = decoded.get_object (); var logs = logs_from (object); var status = object.get_string_member ("status");
      if (status == "success") { if (!object.has_member ("value")) throw new ClientError.PROTOCOL ("success response omitted value"); return new Result (object.get_member ("value").copy (), logs); }
      if (status == "error") {
        Json.Node? data_node = object.has_member ("errorData") ? object.get_member ("errorData").copy () : null;
        last_function_error = new FunctionError ("FunctionError", object.get_string_member ("errorMessage"), data_node, logs);
        throw new ClientError.FUNCTION (last_function_error.message);
      }
      throw new ClientError.PROTOCOL ("unknown Convex HTTP status");
    }
  }
}
