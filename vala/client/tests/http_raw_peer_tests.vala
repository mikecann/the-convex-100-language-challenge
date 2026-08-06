using GLib;
using Gee;
using Json;
using Convex;

internal enum RawHttpMode {
  STATUS_503_SUCCESS,
  FIXED_OVERSIZED,
  CHUNKED_OVERSIZED,
  SLOW_STREAM,
  DRIP_STREAM,
  MALFORMED_JSON,
  ROOT_ARRAY,
  MISSING_STATUS,
  STATUS_NUMBER,
  LOGS_NOT_ARRAY,
  ERROR_MISSING_MESSAGE,
  FUNCTION_ERROR,
  SUCCESS
}

/* A real HTTP/1.1 peer keeps status, framing, and deadline tests independent
 * from libsoup's server-side behavior. Every response closes its connection so
 * the fixture can deterministically associate one mode with one client call. */
internal class RawHttpPeer : GLib.Object {
  private SocketListener listener = new SocketListener ();
  private Thread<bool>? worker;
  private Mutex state_lock;
  private bool stopping = false;
  private uint delayed_responses_finished = 0;
  private string? failure;
  private RawHttpMode[] modes;

  internal uint16 port { get; private set; }
  internal string? failure_message { get { lock (state_lock) { return failure; } } }

  internal bool wait_for_delayed_responses (uint expected, int64 timeout_us) {
    int64 deadline = get_monotonic_time () + timeout_us;
    while (get_monotonic_time () < deadline) {
      lock (state_lock) {
        if (delayed_responses_finished >= expected) return true;
        if (failure != null) return false;
      }
      Thread.usleep (1000);
    }
    return false;
  }

  internal RawHttpPeer (RawHttpMode[] modes) throws Error {
    this.modes = modes;
    port = listener.add_any_inet_port (null);
  }

  internal void start () {
    worker = new Thread<bool> ("vala-http-raw-peer", () => {
      try {
        foreach (var mode in modes) {
          if (is_stopping ()) break;
          serve_one (mode);
        }
      } catch (Error error) {
        if (!is_stopping ()) set_failure (error.message);
      }
      return true;
    });
  }

  internal void stop () {
    lock (state_lock) { stopping = true; }
    listener.close ();
    if (worker != null) worker.join ();
    if (failure_message != null) {
      stderr.printf ("raw HTTP peer failure: %s\n", failure_message);
      assert_not_reached ();
    }
  }

  private bool is_stopping () {
    lock (state_lock) { return stopping; }
  }

  private void set_failure (string message) {
    lock (state_lock) { if (failure == null) failure = message; }
  }

  private void serve_one (RawHttpMode mode) throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = new DataInputStream (connection.input_stream);
    read_request (input);
    try {
      write_response (connection.output_stream, mode);
    } catch (Error error) {
      // The expected bounded-ingestion and deadline cases close while this
      // peer is still producing bytes. That reset is evidence, not a fixture
      // failure, and the next call must still be accepted.
      if (mode != RawHttpMode.FIXED_OVERSIZED && mode != RawHttpMode.CHUNKED_OVERSIZED &&
          mode != RawHttpMode.SLOW_STREAM && mode != RawHttpMode.DRIP_STREAM) throw error;
    }
    if (mode == RawHttpMode.SLOW_STREAM || mode == RawHttpMode.DRIP_STREAM) {
      lock (state_lock) { delayed_responses_finished++; }
    }
    try { connection.close (null); } catch (Error error) {}
  }

  private void read_request (DataInputStream input) throws Error {
    size_t length = 0;
    string? request = input.read_line_utf8 (out length, null);
    if (request == null || !request.has_prefix ("POST /api/")) throw new IOError.INVALID_DATA ("unexpected HTTP request line");
    size_t content_length = 0;
    for (;;) {
      string? line = input.read_line_utf8 (out length, null);
      if (line == null) throw new IOError.CLOSED ("short HTTP request headers");
      string stripped = line.strip ();
      if (stripped.length == 0) break;
      int separator = stripped.index_of (":");
      if (separator <= 0) throw new IOError.INVALID_DATA ("malformed HTTP request header");
      if (stripped.substring (0, separator).down () == "content-length") {
        content_length = (size_t) uint64.parse (stripped.substring (separator + 1).strip ());
      }
    }
    if (content_length > 2 * 1024 * 1024) throw new IOError.INVALID_DATA ("unexpectedly large HTTP request");
    uint8[] body = new uint8[content_length];
    size_t received = 0;
    if (content_length > 0 && (!input.read_all (body, out received, null) || received != content_length)) {
      throw new IOError.CLOSED ("short HTTP request body");
    }
  }

  private void write_response (OutputStream output, RawHttpMode mode) throws Error {
    if (mode == RawHttpMode.STATUS_503_SUCCESS) {
      write_fixed (output, "HTTP/1.1 503 Service Unavailable", "{\"status\":\"success\",\"value\":7,\"logLines\":[]}");
    } else if (mode == RawHttpMode.FIXED_OVERSIZED) {
      write_all (output, ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                          ((2 * 1024 * 1024) + 1).to_string () + "\r\nConnection: close\r\n\r\n").data);
      write_repeated (output, (2 * 1024 * 1024) + 1);
    } else if (mode == RawHttpMode.CHUNKED_OVERSIZED) {
      write_all (output, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".data);
      uint8[] chunk = repeated_bytes (64 * 1024);
      for (int index = 0; index < 33; index++) {
        write_all (output, "10000\r\n".data);
        write_all (output, chunk);
        write_all (output, "\r\n".data);
      }
      write_all (output, "0\r\n\r\n".data);
    } else if (mode == RawHttpMode.SLOW_STREAM) {
      string body = "{\"status\":\"success\",\"value\":7,\"logLines\":[]}";
      write_all (output, ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.length.to_string () +
                          "\r\nConnection: close\r\n\r\n" + body.substring (0, 1)).data);
      Thread.usleep (2 * 1000 * 1000);
      write_all (output, body.substring (1).data);
    } else if (mode == RawHttpMode.DRIP_STREAM) {
      string body = "{\"status\":\"success\",\"value\":7,\"logLines\":[]}";
      write_all (output, ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.length.to_string () +
                          "\r\nConnection: close\r\n\r\n").data);
      // Every byte arrives well inside libsoup's inactivity timeout, but the
      // complete operation still exceeds the client's one-second absolute
      // deadline. This catches deadline resets on each successful read.
      for (int index = 0; index < body.length; index++) {
        write_all (output, body.substring (index, 1).data);
        Thread.usleep (100 * 1000);
      }
    } else if (mode == RawHttpMode.MALFORMED_JSON) {
      write_fixed (output, "HTTP/1.1 200 OK", "{");
    } else if (mode == RawHttpMode.ROOT_ARRAY) {
      write_fixed (output, "HTTP/1.1 200 OK", "[]");
    } else if (mode == RawHttpMode.MISSING_STATUS) {
      write_fixed (output, "HTTP/1.1 200 OK", "{\"value\":7,\"logLines\":[]}");
    } else if (mode == RawHttpMode.STATUS_NUMBER) {
      write_fixed (output, "HTTP/1.1 200 OK", "{\"status\":7,\"value\":7,\"logLines\":[]}");
    } else if (mode == RawHttpMode.LOGS_NOT_ARRAY) {
      write_fixed (output, "HTTP/1.1 200 OK", "{\"status\":\"success\",\"value\":7,\"logLines\":{}}");
    } else if (mode == RawHttpMode.ERROR_MISSING_MESSAGE) {
      write_fixed (output, "HTTP/1.1 200 OK", "{\"status\":\"error\",\"logLines\":[]}");
    } else if (mode == RawHttpMode.FUNCTION_ERROR) {
      write_fixed (output, "HTTP/1.1 200 OK", "{\"status\":\"error\",\"errorMessage\":\"fixture function failure\",\"logLines\":[\"fixture\"]}");
    } else {
      write_fixed (output, "HTTP/1.1 200 OK", "{\"status\":\"success\",\"value\":7,\"logLines\":[]}");
    }
  }

  private void write_fixed (OutputStream output, string status, string body) throws Error {
    string response = status + "\r\nContent-Type: application/json\r\nContent-Length: " + body.length.to_string () +
                      "\r\nConnection: close\r\n\r\n" + body;
    write_all (output, response.data);
  }

  private uint8[] repeated_bytes (int length) {
    uint8[] bytes = new uint8[length];
    for (int index = 0; index < length; index++) bytes[index] = 'x';
    return bytes;
  }

  private void write_repeated (OutputStream output, int length) throws Error {
    uint8[] chunk = repeated_bytes (64 * 1024);
    int remaining = length;
    while (remaining > 0) {
      int count = int.min (remaining, chunk.length);
      write_all (output, chunk[0 : count]);
      remaining -= count;
    }
  }

  private void write_all (OutputStream output, uint8[] bytes) throws Error {
    size_t written = 0;
    output.write_all (bytes, out written, null);
    if (written != bytes.length) throw new IOError.FAILED ("short raw HTTP write");
  }
}

#if ADAPTER_HTTP_TEST
#else
#if HTTP_STANDALONE_PEER
int main (string[] args) {
  try {
    RawHttpMode[] modes = {
      RawHttpMode.STATUS_503_SUCCESS,
      RawHttpMode.FIXED_OVERSIZED,
      RawHttpMode.CHUNKED_OVERSIZED,
      RawHttpMode.SLOW_STREAM,
      RawHttpMode.DRIP_STREAM,
      RawHttpMode.MALFORMED_JSON,
      RawHttpMode.ROOT_ARRAY,
      RawHttpMode.MISSING_STATUS,
      RawHttpMode.STATUS_NUMBER,
      RawHttpMode.LOGS_NOT_ARRAY,
      RawHttpMode.ERROR_MISSING_MESSAGE,
      RawHttpMode.FUNCTION_ERROR,
      RawHttpMode.SUCCESS
    };
    var peer = new RawHttpPeer (modes);
    peer.start ();
    stdout.printf ("%u\n", peer.port);
    stdout.flush ();
    Thread.usleep (20 * 1000 * 1000);
    peer.stop ();
    return 0;
  } catch (Error error) {
    stderr.printf ("standalone raw HTTP peer failed: %s\n", error.message);
    return 1;
  }
}
#else
private static Json.Node http_args () {
  var node = new Json.Node (NodeType.OBJECT);
  node.set_object (new Json.Object ());
  return node;
}

private static void require_http_failure (Client client, bool transport) {
  bool rejected = false;
  try {
    client.query ("demo:state", http_args ());
  } catch (Error error) {
    rejected = transport ? error is ClientError.TRANSPORT : !(error is ClientError.TRANSPORT);
  }
  assert (rejected);
}

private static void status_and_bounded_stream_failures_recover () {
  RawHttpMode[] modes = {
    RawHttpMode.STATUS_503_SUCCESS,
    RawHttpMode.SUCCESS,
    RawHttpMode.FIXED_OVERSIZED,
    RawHttpMode.SUCCESS,
    RawHttpMode.CHUNKED_OVERSIZED,
    RawHttpMode.SUCCESS,
    RawHttpMode.SLOW_STREAM,
    RawHttpMode.SUCCESS,
    RawHttpMode.DRIP_STREAM,
    RawHttpMode.SUCCESS
  };
  try {
    Client.http_timeout_seconds_for_test = 1;
    var peer = new RawHttpPeer (modes);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    for (int index = 0; index < 5; index++) {
      require_http_failure (client, true);
      if (index >= 3) assert (peer.wait_for_delayed_responses ((uint) index - 2, 3 * 1000 * 1000));
      assert (client.query ("demo:state", http_args ()).value.get_int () == 7);
    }
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw HTTP bounded test failed: %s\n", error.message);
    assert_not_reached ();
  } finally {
    Client.http_timeout_seconds_for_test = 15;
  }
}

private static void malformed_shapes_recover () {
  RawHttpMode[] modes = {
    RawHttpMode.MALFORMED_JSON,
    RawHttpMode.ROOT_ARRAY,
    RawHttpMode.MISSING_STATUS,
    RawHttpMode.STATUS_NUMBER,
    RawHttpMode.LOGS_NOT_ARRAY,
    RawHttpMode.ERROR_MISSING_MESSAGE,
    RawHttpMode.SUCCESS
  };
  try {
    var peer = new RawHttpPeer (modes);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    for (int index = 0; index < modes.length - 1; index++) require_http_failure (client, false);
    assert (client.query ("demo:state", http_args ()).value.get_int () == 7);
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw HTTP shape test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

int main (string[] args) {
  Test.init (ref args);
  Test.add_func ("/convex/http/raw-peer/status-bounds-deadline-recovery", status_and_bounded_stream_failures_recover);
  Test.add_func ("/convex/http/raw-peer/malformed-shape-recovery", malformed_shapes_recover);
  return Test.run ();
}
#endif
#endif
