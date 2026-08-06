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

  internal string required_string_member (Json.Object object, string field) throws ClientError {
    if (!object.has_member (field)) throw new ClientError.PROTOCOL ("missing " + field);
    var node = object.get_member (field);
    if (node.get_node_type () != NodeType.VALUE || node.get_value_type () != typeof (string)) {
      throw new ClientError.PROTOCOL (field + " is not a string");
    }
    return object.get_string_member (field);
  }

  internal Json.Object required_object_member (Json.Object object, string field) throws ClientError {
    if (!object.has_member (field) || object.get_member (field).get_node_type () != NodeType.OBJECT) {
      throw new ClientError.PROTOCOL (field + " is not an object");
    }
    return object.get_object_member (field);
  }

  internal Json.Array required_array_member (Json.Object object, string field) throws ClientError {
    if (!object.has_member (field) || object.get_member (field).get_node_type () != NodeType.ARRAY) {
      throw new ClientError.PROTOCOL (field + " is not an array");
    }
    return object.get_array_member (field);
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

  internal string[] logs_from (Json.Object? object) throws ClientError {
    if (object == null || !object.has_member ("logLines")) return {};
    var array = required_array_member (object, "logLines");
    var logs = new ArrayList<string> ();
    for (uint i = 0; i < array.get_length (); i++) {
      var element = array.get_element (i);
      if (element.get_node_type () != NodeType.VALUE || element.get_value_type () != typeof (string)) {
        throw new ClientError.PROTOCOL ("logLines contains a non-string value");
      }
      logs.add (array.get_string_element (i));
    }
    string[] answer = new string[logs.size];
    for (int i = 0; i < logs.size; i++) answer[i] = logs.get (i);
    return answer;
  }

  internal uint64 timestamp_value (string encoded) throws ClientError {
    uint8[] bytes = Base64.decode (encoded);
    if (bytes.length != 8 || Base64.encode (bytes) != encoded) {
      throw new ClientError.PROTOCOL ("timestamp is not a canonical uint64");
    }
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
    private const size_t DELIVERY_RUNTIME_OVERHEAD = 256;
    private uint relay_generation = 1;
    private uint delivery_source = 0;
    private size_t pending_bytes = 0;
    private uint reserved_updates = 0;
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

    internal size_t pending_count () { return reserved_updates; }
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
      reserved_updates = 0;
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
          reserved_updates = 0;
          return false;
        }
        var next = queue.poll ();
        if (before_delivery_for_test != null) before_delivery_for_test (this);
        // This reservation remains charged while the consumer runs. A
        // callback may block on output, replace itself, or revoke the relay;
        // releasing it before that point would hide in-flight memory.
        if (next.generation == relay_generation && active) {
          updated (next.value, next.error);
          if (active && generation == relay_generation && pending_bytes >= next.encoded_bytes) {
            pending_bytes -= next.encoded_bytes;
            if (reserved_updates > 0) reserved_updates--;
          }
        }
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
      size_t encoded_bytes = delivery_encoded_bytes (value, error);
      while ((reserved_updates >= MAX_PENDING_UPDATES || encoded_bytes > MAX_PENDING_BYTES - pending_bytes) && !queue.is_empty) {
        var discarded = queue.poll ();
        pending_bytes -= discarded.encoded_bytes;
        reserved_updates--;
      }
      if (encoded_bytes > MAX_PENDING_BYTES) {
        while (!queue.is_empty) queue.poll ();
        var bounded = new FunctionError ("ProtocolError", "Live update exceeds the bounded delivery byte budget");
        encoded_bytes = delivery_encoded_bytes (null, bounded);
        if (encoded_bytes > MAX_PENDING_BYTES - pending_bytes || reserved_updates >= MAX_PENDING_UPDATES) return;
        value = null;
        error = bounded;
      }
      // An already-running callback cannot be evicted. Drop this later update
      // if its count or byte reservation cannot fit until that callback
      // returns; never make in-flight memory disappear from the budget.
      if (reserved_updates >= MAX_PENDING_UPDATES || encoded_bytes > MAX_PENDING_BYTES - pending_bytes) return;
      last_signature = signature;
      queue.offer (new Update (value, error, relay_generation, encoded_bytes));
      reserved_updates++;
      pending_bytes += encoded_bytes;
      schedule_delivery ();
    }

    private size_t delivery_encoded_bytes (Json.Node? value, FunctionError? error) {
      // The fixed allowance covers the complete adapter envelope, a maximum
      // subscription ID, queue nodes, signal arguments, and allocator slack.
      size_t bytes = DELIVERY_RUNTIME_OVERHEAD;
      if (value != null) bytes += node_text (value).length;
      if (error != null) {
        bytes += json_string (error.name).length + json_string (error.message).length;
        if (error.data != null) bytes += node_text (error.data).length;
        foreach (var log in error.logs) bytes += json_string (log).length + 1;
      }
      return bytes;
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
    private WebSocketTransport? socket;
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

    internal LiveOwner (Client client) { this.client = client; }

    internal Subscription add (string path, Json.Node args) throws ClientError {
      if (next_query_id == uint.MAX) throw new ClientError.PROTOCOL ("query id space exhausted");
      var subscription = new Subscription (next_query_id++, path, args.copy ());
      active.set (subscription.query_id, subscription);
      ensure_connected ();
      if (socket != null && socket.is_open) send_modify ({ subscription }, {});
      return subscription;
    }

    internal void remove (Subscription subscription) {
      if (!subscription.active) return;
      // Invalidate before emitting an acknowledgement from the adapter.
      subscription.invalidate ();
      active.unset (subscription.query_id);
      if (socket != null && socket.is_open) send_modify ({}, { subscription.query_id });
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
      foreach (var subscription in active.values) subscription.invalidate ();
      active.clear ();
      if (socket != null) socket.graceful_close (1000, "client closed");
      socket = null;
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
      WebSocketTransport? next = null;
      try {
        next = new WebSocketTransport ();
        yield next.connect (websocket_url (), client.auth_token);
        if (closing) { next.graceful_close (1000, "client closed"); return; }
        socket = next;
        uint generation = ++socket_generation;
        query_set_version = 0;
        remote_query_set = 0; remote_identity = 0; remote_timestamp = "AAAAAAAAAAA=";
        reconnect_backoff_ms = 100;
        next.text_message.connect ((text) => {
          if (socket == next && socket_generation == generation) on_message (text);
        });
        next.transport_failed.connect ((message) => {
          if (socket == next && socket_generation == generation) transport_failure (message);
        });
        next.protocol_failed.connect ((message) => {
          if (socket == next && socket_generation == generation) protocol_failure (message);
        });
        next.peer_closed.connect ((reason) => {
          if (socket == next && socket_generation == generation) transport_failure (reason);
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
        next.start ();
      } catch (Error error) {
        if (next != null) next.abort ();
        if (error is ClientError.PROTOCOL) protocol_failure (error.message);
        else transport_failure (error.message);
      } finally { connecting = false; }
    }

    private void send_text (string text) {
      if (socket == null || !socket.is_open) return;
      socket.send_text (text);
    }

    private void send_modify (Subscription[] adds, uint[] removes) {
      if (socket == null || !socket.is_open) return;
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
      socket_generation++;
      remote_query_set = 0; remote_identity = 0; remote_timestamp = "AAAAAAAAAAA=";
      connection_count++; last_close_reason = reason;
      if (retired != null) retired.abort ();
      if (closing || active.size == 0 || reconnect_source != 0) return;
      uint delay = reconnect_backoff_ms;
      reconnect_backoff_ms = uint.min (reconnect_backoff_ms * 2, 15000);
      reconnect_source = Timeout.add (delay, () => { reconnect_source = 0; ensure_connected (); return false; });
    }

    private void on_message (string text) {
      try { handle_transition (parse_json (text)); }
      catch (Error error) { protocol_failure (error.message); }
    }

    private void handle_transition (Json.Node node) throws Error {
      if (node.get_node_type () != NodeType.OBJECT) throw new ClientError.PROTOCOL ("Live frame is not an object");
      var root = node.get_object ();
      var type = required_string_member (root, "type");
      if (type == "Ping" || type == "MutationResponse" || type == "ActionResponse") return;
      if (type != "Transition") throw new ClientError.PROTOCOL ("unexpected Live message " + type);
      var start = required_object_member (root, "startVersion");
      if (uint32_member (start, "querySet") != remote_query_set ||
          uint32_member (start, "identity") != remote_identity ||
          required_string_member (start, "ts") != remote_timestamp) throw new ClientError.PROTOCOL ("Transition start version mismatch");
      var pending = new ArrayList<UpdatePublication> ();
      var modifications = required_array_member (root, "modifications");
      for (uint i = 0; i < modifications.get_length (); i++) {
        var modification_node = modifications.get_element (i);
        if (modification_node.get_node_type () != NodeType.OBJECT) {
          throw new ClientError.PROTOCOL ("Transition modification is not an object");
        }
        var modification = modification_node.get_object ();
        uint id = uint32_member (modification, "queryId");
        var kind = required_string_member (modification, "type");
        if (kind != "QueryUpdated" && kind != "QueryFailed" && kind != "QueryRemoved") {
          throw new ClientError.PROTOCOL ("unknown Transition modification " + kind);
        }
        if (kind == "QueryUpdated" && !modification.has_member ("value")) {
          throw new ClientError.PROTOCOL ("QueryUpdated omitted value");
        }
        if (kind == "QueryFailed") {
          required_string_member (modification, "errorMessage");
          logs_from (modification);
        }
        var sub = active.get (id); if (sub == null) continue;
        if (kind == "QueryUpdated") {
          pending.add (new UpdatePublication (sub, modification.get_member ("value").copy (), null));
        }
        else if (kind == "QueryFailed") {
          Json.Node? data = modification.has_member ("errorData") ? modification.get_member ("errorData").copy () : null;
          pending.add (new UpdatePublication (sub, null, new FunctionError ("FunctionError", required_string_member (modification, "errorMessage"), data, logs_from (modification))));
        }
      }
      var end = required_object_member (root, "endVersion");
      var end_timestamp = required_string_member (end, "ts");
      uint64 end_number = timestamp_value (end_timestamp);
      if (end_number < max_timestamp_number) throw new ClientError.PROTOCOL ("timestamp moved backwards");
      uint end_query_set = uint32_member (end, "querySet");
      if (end_query_set < remote_query_set || end_query_set > query_set_version) {
        throw new ClientError.PROTOCOL ("Transition end query-set version is outside the requested range");
      }
      max_timestamp = end_timestamp; max_timestamp_number = end_number;
      saw_timestamp = true;
      remote_timestamp = end_timestamp; remote_query_set = end_query_set; remote_identity = uint32_member (end, "identity");
      // All state is committed before any callback can observe the transition.
      foreach (var update in pending) update.subscription.publish (update.value, update.error);
    }

    private void protocol_failure (string message) {
      foreach (var sub in active.values) sub.publish (null, new FunctionError ("ProtocolError", message));
      retire_and_reconnect (message);
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

  /* An inactivity timeout is not an absolute operation deadline: a peer can
  * otherwise drip one byte at a time forever. This guard owns a monotonic
  * deadline and cancels one blocking GIO operation from a helper thread. */
  internal class OperationDeadline : GLib.Object {
    private Mutex state_lock;
    private bool stopped = false;
    private bool expired = false;
    private int64 deadline;
    private Cancellable cancellable;
    private Thread<bool>? worker;

    internal OperationDeadline (Cancellable cancellable, uint timeout_ms) {
      this.cancellable = cancellable;
      deadline = get_monotonic_time () + ((int64) timeout_ms * TimeSpan.MILLISECOND);
      worker = new Thread<bool> ("vala-operation-deadline", () => {
        for (;;) {
          bool should_cancel = false;
          int64 remaining = 0;
          lock (state_lock) {
            if (stopped) return true;
            remaining = deadline - get_monotonic_time ();
            if (remaining <= 0) {
              expired = true;
              should_cancel = true;
            }
          }
          if (should_cancel) {
            cancellable.cancel ();
            return true;
          }
          // Wake frequently enough to make stop() bounded without resetting
          // the one absolute deadline after each successful byte.
          Thread.usleep ((ulong) int64.min (remaining, 10 * TimeSpan.MILLISECOND));
        }
      });
    }

    internal bool stop () {
      lock (state_lock) {
        stopped = true;
      }
      var active = worker;
      worker = null;
      if (active != null) active.join ();
      lock (state_lock) { return expired; }
    }
  }

  public class Client : GLib.Object {
    private const size_t MAX_HTTP_RESPONSE_BYTES = 2 * 1024 * 1024;
    internal static uint http_timeout_seconds_for_test = 15;
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
      session.timeout = http_timeout_seconds_for_test;
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
      // Soup's convenient send_and_read() materializes the entire peer body
      // before returning. Read in fixed chunks so the 2 MiB limit bounds
      // ingestion, including chunked and intentionally slow responses.
      var cancellation = new Cancellable ();
      var deadline = new OperationDeadline (cancellation, http_timeout_seconds_for_test * 1000);
      InputStream? stream = null;
      var response = new ByteArray ();
      uint8[] chunk = new uint8[8192];
      try {
        stream = session.send (message, cancellation);
        // HTTP status is transport truth. Never allow a success-shaped Convex
        // JSON body on a non-2xx response to become a successful result.
        if (message.status_code < 200 || message.status_code >= 300) {
          throw new ClientError.TRANSPORT ("HTTP status " + message.status_code.to_string ());
        }
        for (;;) {
          ssize_t received = stream.read (chunk, cancellation);
          if (received == 0) break;
          if ((size_t) received > MAX_HTTP_RESPONSE_BYTES - response.len) {
            throw new ClientError.TRANSPORT ("HTTP response exceeds 2 MiB");
          }
          response.append (chunk[0 : (int) received]);
        }
        if (deadline.stop ()) throw new ClientError.TRANSPORT ("HTTP request exceeded its absolute deadline");
      } catch (ClientError error) {
        throw error;
      } catch (Error error) {
        if (deadline.stop ()) throw new ClientError.TRANSPORT ("HTTP request exceeded its absolute deadline");
        throw new ClientError.TRANSPORT (error.message);
      } finally {
        deadline.stop ();
        if (stream != null) {
          try { stream.close (cancellation); } catch (Error error) {}
        }
      }
      uint8[] terminated = new uint8[response.len + 1];
      for (int index = 0; index < response.len; index++) terminated[index] = response.data[index];
      Json.Node decoded;
      try {
        decoded = parse_json ((string) terminated);
      } catch (Error error) {
        throw new ClientError.PROTOCOL ("malformed Convex HTTP response: " + error.message);
      }
      if (decoded.get_node_type () != NodeType.OBJECT) throw new ClientError.PROTOCOL ("HTTP response is not an object");
      var object = decoded.get_object (); var logs = logs_from (object); var status = required_string_member (object, "status");
      if (status == "success") { if (!object.has_member ("value")) throw new ClientError.PROTOCOL ("success response omitted value"); return new Result (object.get_member ("value").copy (), logs); }
      if (status == "error") {
        Json.Node? data_node = object.has_member ("errorData") ? object.get_member ("errorData").copy () : null;
        last_function_error = new FunctionError ("FunctionError", required_string_member (object, "errorMessage"), data_node, logs);
        throw new ClientError.FUNCTION (last_function_error.message);
      }
      throw new ClientError.PROTOCOL ("unknown Convex HTTP status");
    }
  }
}
