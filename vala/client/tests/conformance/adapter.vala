using GLib;
using Json;
using Convex;

/* The adapter is deliberately separate from the educational client API. */
class Adapter : GLib.Object {
  private Client? client;
  private HashTable<string, Subscription> subscriptions = new HashTable<string, Subscription> (str_hash, str_equal);
  private OutputStream protocol_output = new UnixOutputStream (1, false);
  private MainLoop loop;
  private bool closed = false;
  private bool failed = false;
  private size_t output_in_flight_bytes = 0;
  private uint output_in_flight_events = 0;
  private const size_t MAX_OUTPUT_BYTES = 8 * 1024 * 1024;
  private const uint MAX_OUTPUT_EVENTS = 64;
  private const size_t OUTPUT_RUNTIME_OVERHEAD = 256;
  private const size_t MAX_COMMAND_BYTES = 2 * 1024 * 1024;
  // The project targets Linux/amd64. Keep the controller socket's kernel
  // buffering much smaller than one maximum event so a stopped reader reaches
  // the userspace absolute-deadline path instead of being hidden by autotune.
  private const int LINUX_SOL_SOCKET = 1;
  private const int LINUX_SO_SNDBUF = 7;
  private const int CONTROLLER_SEND_BUFFER_BYTES = 64 * 1024;
  // Language-local tests attach here to assert the exact NDJSON event that is
  // written. This never changes adapter stdout or the production client API.
  internal signal void emitted_for_test (string event);

  public Adapter (MainLoop loop) { this.loop = loop; }

  internal uint output_in_flight_count_for_test () { return output_in_flight_events; }
  internal size_t output_in_flight_bytes_for_test () { return output_in_flight_bytes; }
  internal bool failed_for_process () { return failed; }
  internal void set_output_for_test (OutputStream output) { protocol_output = output; }

  private uint output_deadline_ms () {
    var configured = Environment.get_variable ("ADAPTER_OUTPUT_DEADLINE_MS");
    if (configured == null || configured.length == 0) return 1000;
    uint64 parsed;
    if (!uint64.try_parse (configured, out parsed) || parsed == 0 || parsed > 60000) return 1000;
    return (uint) parsed;
  }

  private void stop_with_failure (string message) {
    failed = true;
    closed = true;
    stderr.printf ("adapter failed: %s\n", message);
    if (client != null) client.close ();
    loop.quit ();
  }

  private void emit (string event) {
    size_t wire_bytes = event.length + 1;
    size_t encoded_bytes = wire_bytes + OUTPUT_RUNTIME_OVERHEAD;
    if (wire_bytes > 2 * 1024 * 1024) { stop_with_failure ("adapter event exceeds 2 MiB"); return; }
    if (output_in_flight_events >= MAX_OUTPUT_EVENTS || output_in_flight_bytes + encoded_bytes > MAX_OUTPUT_BYTES) {
      stop_with_failure ("adapter output budget exhausted");
      return;
    }
    output_in_flight_events++;
    output_in_flight_bytes += encoded_bytes;
    emitted_for_test (event);
    try {
      string line = event + "\n";
      write_with_deadline (line);
    } catch (Error error) {
      stop_with_failure ("adapter output failed: " + error.message);
    }
    output_in_flight_events--;
    output_in_flight_bytes -= encoded_bytes;
  }

  private void write_with_deadline (string line) throws Error {
    var pollable = protocol_output as PollableOutputStream;
    if (pollable == null || !pollable.can_poll ()) {
      // Docker's build smoke redirects stdout to a regular file, which GLib
      // reports as non-pollable even though it cannot apply controller
      // backpressure. Production pipes and TCP sockets take the bounded path
      // below; retain ordinary file redirection as a useful adapter mode.
      size_t written;
      protocol_output.write_all (line.data, out written, null);
      if (written != line.length) throw new IOError.FAILED ("short adapter output write");
      return;
    }
    int64 deadline = get_monotonic_time () + ((int64) output_deadline_ms () * TimeSpan.MILLISECOND);
    size_t offset = 0;
    while (offset < line.length) {
      int64 remaining = deadline - get_monotonic_time ();
      if (remaining <= 0) throw new IOError.TIMED_OUT ("adapter output exceeded its absolute deadline");
      try {
        ssize_t written = pollable.write_nonblocking (line.data[(int) offset: line.length], null);
        if (written <= 0) throw new IOError.FAILED ("short adapter output write");
        offset += (size_t) written;
      } catch (IOError error) {
        if (!(error is IOError.WOULD_BLOCK)) throw error;
        // Poll in short bounded intervals. GLib's synchronous write_all()
        // cannot reliably be interrupted from another thread on every socket
        // backend, while this path never enters a blocking write at all.
        Thread.usleep ((ulong) int64.min (remaining, TimeSpan.MILLISECOND));
      }
    }
  }

  private void error (string id, string name, string message, Json.Node? data = null, string? subscription_id = null, string[] logs = {}) {
    var body = "{\"name\":" + Convex.json_string (name) + ",\"message\":" + Convex.json_string (message);
    if (data != null) body += ",\"data\":" + Convex.node_text (data);
    body += "}";
    var logs_field = logs.length > 0 ? ",\"logs\":" + logs_json (logs) : "";
    if (subscription_id != null) emit ("{\"type\":\"subscription\",\"subscriptionId\":" + Convex.json_string (subscription_id) + ",\"error\":" + body + logs_field + "}");
    else if (id.length > 0) emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"error\",\"error\":" + body + logs_field + "}");
    else emit ("{\"type\":\"error\",\"error\":" + body + logs_field + "}");
  }

  private string logs_json (string[] logs) {
    string[] encoded = new string[logs.length];
    for (int i = 0; i < logs.length; i++) encoded[i] = Convex.json_string (logs[i]);
    return "[" + string.joinv (",", encoded) + "]";
  }

  private Client get_client () throws Error {
    if (client != null) return client;
    var url = Environment.get_variable ("CONVEX_URL");
    if (url == null || url.length == 0) throw new ClientError.PROTOCOL ("CONVEX_URL is required");
    client = new Client (url);
    var token = Environment.get_variable ("CONVEX_AUTH_TOKEN");
    if (token != null && token.length > 0) client.set_auth (token);
    return client;
  }

  private void on_subscription (string subscription_id, Json.Node? value, FunctionError? failure) {
    if (!subscriptions.contains (subscription_id)) return;
    if (failure != null) { error ("", failure.name, failure.message, failure.data, subscription_id, failure.logs); return; }
    if (value != null) emit ("{\"type\":\"subscription\",\"subscriptionId\":" + Convex.json_string (subscription_id) + ",\"value\":" + Convex.node_text (value) + "}");
  }

  public void handle (string line) {
    Json.Node command;
    // parse_json also rejects a command with no JSON value at all and one
    // whose parsed tree would exceed the bounded retained budget. Those carry
    // a specific reason; a syntax error stays the generic malformed report.
    try {
      command = Convex.parse_json (line, "adapter command");
    } catch (Error parse_error) {
      // Vala's error-code `is` expression is valid as a condition, but this
      // compiler version cannot parse it directly as a ternary condition.
      string reason = "malformed adapter command";
      if (parse_error is ClientError.PROTOCOL) reason = parse_error.message;
      error ("", "ProtocolError", reason);
      return;
    }
    if (command.get_node_type () != NodeType.OBJECT) { error ("", "ProtocolError", "malformed adapter command"); return; }
    var object = command.get_object ();
    var id = "";
    try {
      validate_envelope (object);
      id = object.get_string_member ("id");
      var op = object.get_string_member ("op");
      if (op == "hello") {
        if (!object.has_member ("protocolVersion") || Convex.uint32_member (object, "protocolVersion") != 1) throw new ClientError.PROTOCOL ("unsupported adapter protocol version");
        emit ("{\"protocolVersion\":1,\"id\":" + Convex.json_string (id) + ",\"type\":\"ready\",\"language\":\"vala\",\"implementation\":\"native-vala-glib-gio-libsoup3\",\"runtime\":" + Convex.json_string (Environment.get_variable ("VALA_RUNTIME") ?? "glib") + "}");
      } else if (op == "query" || op == "mutation" || op == "action") {
        if (!object.has_member ("path") || !object.has_member ("args")) throw new ClientError.PROTOCOL ("call requires path and args");
        var service = get_client (); Result result;
        if (op == "query") result = service.query (object.get_string_member ("path"), object.get_member ("args"));
        else if (op == "mutation") result = service.mutation (object.get_string_member ("path"), object.get_member ("args"));
        else result = service.action (object.get_string_member ("path"), object.get_member ("args"));
        emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"result\",\"value\":" + Convex.node_text (result.value) + ",\"logs\":" + logs_json (result.logs) + "}");
      } else if (op == "setAuth") {
        get_client ().set_auth (object.has_member ("token") ? object.get_string_member ("token") : "");
        emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"ack\"}");
      } else if (op == "subscribe") {
        if (!object.has_member ("subscriptionId") || !object.has_member ("path") || !object.has_member ("args")) throw new ClientError.PROTOCOL ("subscribe requires subscriptionId, path, and args");
        var subscription_id = object.get_string_member ("subscriptionId");
        var prior = subscriptions.lookup (subscription_id);
        if (prior != null) get_client ().unsubscribe (prior);
        var subscription = get_client ().subscribe (object.get_string_member ("path"), object.get_member ("args"));
        subscriptions.insert (subscription_id, subscription);
        subscription.updated.connect ((value, failure) => {
          // A same-ID replacement must not let the retired relay publish into
          // the new subscription after its acknowledgement barrier.
          if (subscriptions.lookup (subscription_id) == subscription) {
            on_subscription (subscription_id, value, failure);
          }
        });
        emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"ack\"}");
      } else if (op == "unsubscribe") {
        var subscription_id = object.has_member ("subscriptionId") ? object.get_string_member ("subscriptionId") : "";
        var subscription = subscriptions.lookup (subscription_id);
        if (subscription != null) { subscriptions.remove (subscription_id); get_client ().unsubscribe (subscription); }
        emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"ack\"}");
      } else if (op == "debugDisconnect") {
        if (client == null || !client.debug_disconnect_for_adapter ()) throw new ClientError.PROTOCOL ("Live WebSocket is not connected");
        emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"ack\"}");
      } else if (op == "close") {
        closed = true; subscriptions.remove_all (); if (client != null) client.close ();
        emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"closed\"}");
        loop.quit ();
      } else throw new ClientError.PROTOCOL ("unknown adapter operation");
    } catch (Error command_error) {
      if (command_error is ClientError.FUNCTION && client != null && client.last_function_error != null) {
        var failure = client.last_function_error;
        error (id, failure.name, failure.message, failure.data, null, failure.logs);
      } else {
        string name = (command_error is ClientError.TRANSPORT || command_error is ClientError.CLOSED) ? "TransportError" : "ProtocolError";
        error (id, name, command_error.message);
      }
    }
  }

  // The harness relies on a strict protocol. Rejecting unknown fields makes
  // client-side typos visible instead of silently treating them as success.
  private string required_string (Json.Object object, string field, long minimum = 0, long maximum = -1) throws ClientError {
    if (!object.has_member (field) || object.get_member (field).get_value_type () != typeof (string)) {
      throw new ClientError.PROTOCOL (field + " must be a string");
    }
    var value = object.get_string_member (field);
    // JSON Schema's maxLength counts Unicode code points, not encoded UTF-8
    // bytes. This accepts 128 astral characters and rejects the 129th.
    long characters = value.char_count ();
    if (characters < minimum || (maximum >= 0 && characters > maximum)) {
      throw new ClientError.PROTOCOL (field + " has invalid length");
    }
    return value;
  }

  private void validate_envelope (Json.Object object) throws ClientError {
    var id = required_string (object, "id", 1, 128);
    var op = required_string (object, "op", 1);
    string[] permitted;
    if (op == "hello") permitted = { "id", "op", "protocolVersion" };
    else if (op == "query" || op == "mutation" || op == "action") permitted = { "id", "op", "path", "args" };
    else if (op == "setAuth") permitted = { "id", "op", "token" };
    else if (op == "subscribe") permitted = { "id", "op", "subscriptionId", "path", "args" };
    else if (op == "unsubscribe") permitted = { "id", "op", "subscriptionId" };
    else if (op == "debugDisconnect" || op == "close") permitted = { "id", "op" };
    else throw new ClientError.PROTOCOL ("unknown adapter operation");

    foreach (unowned string member in object.get_members ()) {
      bool allowed = false;
      foreach (var name in permitted) if (member == name) { allowed = true; break; }
      if (!allowed) throw new ClientError.PROTOCOL ("unknown adapter field " + member);
    }

    if (op == "hello") {
      if (!object.has_member ("protocolVersion") || Convex.uint32_member (object, "protocolVersion") != 1) {
        throw new ClientError.PROTOCOL ("unsupported adapter protocol version");
      }
    } else if (op == "query" || op == "mutation" || op == "action") {
      if (required_string (object, "path", 3).length < 3 || !object.has_member ("args") ||
          object.get_member ("args").get_node_type () != NodeType.OBJECT) {
        throw new ClientError.PROTOCOL ("call needs a path and object args");
      }
    } else if (op == "setAuth") {
      required_string (object, "token");
    } else if (op == "subscribe") {
      required_string (object, "subscriptionId", 1, 128);
      required_string (object, "path", 1);
      if (!object.has_member ("args") || object.get_member ("args").get_node_type () != NodeType.OBJECT) {
        throw new ClientError.PROTOCOL ("subscribe needs object args");
      }
    } else if (op == "unsubscribe") {
      required_string (object, "subscriptionId", 1, 128);
    }
  }

  private bool append_command_bytes (ByteArray command, uint8[] bytes) {
    if ((size_t) bytes.length > MAX_COMMAND_BYTES - command.len) {
      // Reject at the first chunk containing byte 2 MiB + 1. The fixed read
      // buffer is the only allocation beyond the bounded command itself.
      error ("", "ProtocolError", "adapter command exceeds 2 MiB");
      command.set_size (0);
      return false;
    }
    if (bytes.length > 0) command.append (bytes);
    return true;
  }

  private void handle_command_bytes (ByteArray command) {
    int length = (int) command.len;
    if (length > 0 && command.data[length - 1] == '\r') length--;
    uint8[] terminated = new uint8[length + 1];
    for (int index = 0; index < length; index++) terminated[index] = command.data[index];
    handle ((string) terminated);
  }

  // stdin and TCP deliberately share this parser so neither transport can
  // allocate an unbounded line before applying the NDJSON command limit.
  internal async void read_commands (InputStream input) {
    uint8[] chunk = new uint8[8192];
    var command = new ByteArray ();
    bool discarding_oversized = false;
    try {
      while (!closed) {
        ssize_t received = yield input.read_async (chunk, Priority.DEFAULT, null);
        if (received == 0) {
          if (!discarding_oversized && command.len > 0) handle_command_bytes (command);
          break;
        }
        int segment_start = 0;
        for (int index = 0; index < received; index++) {
          if (chunk[index] != '\n') continue;
          if (!discarding_oversized &&
              append_command_bytes (command, chunk[segment_start : index])) {
            handle_command_bytes (command);
          }
          command.set_size (0);
          discarding_oversized = false;
          segment_start = index + 1;
          if (closed) break;
        }
        if (closed) break;
        if (segment_start < received && !discarding_oversized &&
            !append_command_bytes (command, chunk[segment_start: (int) received])) {
          discarding_oversized = true;
        }
      }
    } catch (Error input_error) {
      stderr.printf ("adapter input failed: %s\n", input_error.message);
    }
    if (!closed) loop.quit ();
  }

  public async void read_tcp (SocketConnection connection) {
    try {
      connection.socket.set_option (LINUX_SOL_SOCKET, LINUX_SO_SNDBUF, CONTROLLER_SEND_BUFFER_BYTES);
    } catch (Error error) {
      stop_with_failure ("could not bound controller send buffer: " + error.message);
      return;
    }
    protocol_output = connection.output_stream;
    yield read_commands (connection.input_stream);
  }
}

#if ADAPTER_TEST
#else
int main (string[] args) {
  var loop = new MainLoop ();
  var adapter = new Adapter (loop);
  var listen = Environment.get_variable ("ADAPTER_LISTEN");
  if (listen == null || listen.length == 0) {
    adapter.read_commands.begin (new UnixInputStream (0, false));
  } else {
    var parts = listen.split (":");
    if (parts.length != 2) { stderr.printf ("invalid ADAPTER_LISTEN\n"); return 1; }
    try {
      var service = new SocketService ();
      var address = new InetSocketAddress (new InetAddress.from_string (parts[0]), (uint16) int.parse (parts[1]));
      SocketAddress effective_address;
      service.add_address (address, SocketType.STREAM, SocketProtocol.TCP, null, out effective_address);
      bool accepted = false;
      service.incoming.connect ((connection, source) => { if (accepted) return false; accepted = true; adapter.read_tcp.begin (connection); return true; });
      service.start ();
    } catch (Error error) { stderr.printf ("adapter listen failed: %s\n", error.message); return 1; }
  }
  loop.run ();
  return adapter.failed_for_process () ? 1 : 0;
}
#endif
