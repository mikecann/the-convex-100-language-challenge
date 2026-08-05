using GLib;
using Json;
using Convex;

/* The adapter is deliberately separate from the educational client API. */
class Adapter : GLib.Object {
  private Client? client;
  private HashTable<string, Subscription> subscriptions = new HashTable<string, Subscription> (str_hash, str_equal);
  private OutputStream? tcp_output;
  private MainLoop loop;
  private bool closed = false;

  public Adapter (MainLoop loop) { this.loop = loop; }

  private void emit (string event) {
    try {
      if (tcp_output != null) {
        size_t written;
        tcp_output.write_all ((event + "\n").data, out written, null);
      } else {
        stdout.printf ("%s\n", event);
        stdout.flush ();
      }
    } catch (Error error) { stderr.printf ("adapter output failed: %s\n", error.message); }
  }

  private void error (string id, string name, string message, Json.Node? data = null, string? subscription_id = null) {
    var body = "{\"name\":" + Convex.json_string (name) + ",\"message\":" + Convex.json_string (message);
    if (data != null) body += ",\"data\":" + Convex.node_text (data);
    body += "}";
    if (subscription_id != null) emit ("{\"type\":\"subscription\",\"subscriptionId\":" + Convex.json_string (subscription_id) + ",\"error\":" + body + "}");
    else if (id.length > 0) emit ("{\"id\":" + Convex.json_string (id) + ",\"type\":\"error\",\"error\":" + body + "}");
    else emit ("{\"type\":\"error\",\"error\":" + body + "}");
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
    if (failure != null) { error ("", failure.name, failure.message, failure.data, subscription_id); return; }
    if (value != null) emit ("{\"type\":\"subscription\",\"subscriptionId\":" + Convex.json_string (subscription_id) + ",\"value\":" + Convex.node_text (value) + "}");
  }

  public void handle (string line) {
    Json.Node command;
    try { command = Convex.parse_json (line); }
    catch (Error parse_error) { error ("", "ProtocolError", "malformed adapter command"); return; }
    if (command.get_node_type () != NodeType.OBJECT) { error ("", "ProtocolError", "malformed adapter command"); return; }
    var object = command.get_object ();
    var id = object.has_member ("id") ? object.get_string_member ("id") : "";
    var op = object.has_member ("op") ? object.get_string_member ("op") : "";
    try {
      if (op == "hello") {
        if (!object.has_member ("protocolVersion") || object.get_int_member ("protocolVersion") != 1) throw new ClientError.PROTOCOL ("unsupported adapter protocol version");
        emit ("{\"protocolVersion\":1,\"id\":" + Convex.json_string (id) + ",\"type\":\"ready\",\"language\":\"vala\",\"implementation\":\"native-vala-libsoup3\",\"runtime\":" + Convex.json_string (Environment.get_variable ("VALA_RUNTIME") ?? "glib") + "}");
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
        subscription.updated.connect ((value, failure) => { on_subscription (subscription_id, value, failure); });
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
      if (client != null && client.last_function_error != null) {
        var failure = client.last_function_error;
        error (id, failure.name, failure.message, failure.data);
      } else {
        error (id, "ProtocolError", command_error.message);
      }
    }
  }

  public bool on_stdin (IOChannel channel, IOCondition condition) {
    if ((condition & IOCondition.IN) == 0) return !closed;
    string? line; size_t length; size_t terminal;
    try {
      if (channel.read_line (out line, out length, out terminal) == IOStatus.NORMAL && line != null) handle (line);
    } catch (Error error) { stderr.printf ("adapter input failed: %s\n", error.message); return false; }
    return !closed;
  }

  public async void read_tcp (SocketConnection connection) {
    tcp_output = connection.output_stream;
    var input = new DataInputStream (connection.input_stream);
    try {
      while (!closed) {
        size_t length = 0;
        string? line = yield input.read_line_utf8_async (Priority.DEFAULT, null, out length);
        if (line == null) break;
        handle (line);
      }
    } catch (Error error) { stderr.printf ("adapter TCP input failed: %s\n", error.message); }
    if (!closed) loop.quit ();
  }
}

int main (string[] args) {
  var loop = new MainLoop ();
  var adapter = new Adapter (loop);
  var listen = Environment.get_variable ("ADAPTER_LISTEN");
  if (listen == null || listen.length == 0) {
    var channel = new IOChannel.unix_new (0);
    channel.add_watch (IOCondition.IN | IOCondition.HUP, adapter.on_stdin);
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
  return 0;
}
