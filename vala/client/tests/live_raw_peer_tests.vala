using GLib;
using Json;
using Convex;

/*
 * This deliberately speaks RFC6455 over a plain TCP socket instead of using
 * server library. The production client uses the same GIO stream path under
 * test here: masked client frames, incremental control/data parsing,
 * fragmentation, close, and reconnect.
 */

private delegate bool RawCondition ();

private static void spin_until (RawCondition condition, int64 timeout_us, string description) {
  int64 deadline = get_monotonic_time () + timeout_us;
  while (!condition ()) {
    while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
    if (get_monotonic_time () >= deadline) {
      stderr.printf ("raw peer timeout: %s\n", description);
      assert_not_reached ();
    }
    Thread.usleep (1000);
  }
  while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
}

private static Json.Node raw_object (string room) {
  var object = new Json.Object ();
  object.set_string_member ("room", room);
  var node = new Json.Node (NodeType.OBJECT);
  node.set_object (object);
  return node;
}

private static string raw_timestamp (uint64 value) {
  uint8[] bytes = new uint8[8];
  for (int index = 0; index < 8; index++) {
    bytes[index] = (uint8) (value & 0xff);
    value >>= 8;
  }
  return Base64.encode (bytes);
}

private static string raw_transition (uint start_query_set, uint end_query_set, uint64 start, uint64 end, uint query_id, string modification) {
  return "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":" + start_query_set.to_string () +
         ",\"identity\":0,\"ts\":" + Convex.json_string (raw_timestamp (start)) + "},\"endVersion\":{\"querySet\":" +
         end_query_set.to_string () + ",\"identity\":0,\"ts\":" + Convex.json_string (raw_timestamp (end)) +
         "},\"modifications\":[" + modification + "]}";
}

private static string raw_update (uint query_id, uint count, string? label = null) {
  string value = "{\"count\":" + count.to_string ();
  if (label != null) value += ",\"label\":" + Convex.json_string (label);
  value += "}";
  return "{\"type\":\"QueryUpdated\",\"queryId\":" + query_id.to_string () + ",\"value\":" + value + ",\"logLines\":[]}";
}

private static string raw_failure (uint query_id) {
  return "{\"type\":\"QueryFailed\",\"queryId\":" + query_id.to_string () +
         ",\"errorMessage\":\"fixture failure\",\"errorData\":{\"code\":\"FIXTURE\"},\"logLines\":[\"fixture\"]}";
}

private static void raw_write_all (OutputStream output, uint8[] bytes) throws Error {
  size_t written = 0;
  output.write_all (bytes, out written, null);
  assert (written == bytes.length);
}

private static bool raw_read_all (InputStream input, uint8[] bytes) throws Error {
  size_t read = 0;
  return input.read_all (bytes, out read, null) && read == bytes.length;
}

private static uint8[] raw_be16 (uint64 value) {
  uint8[] bytes = new uint8[2];
  bytes[0] = (uint8) ((value >> 8) & 0xff);
  bytes[1] = (uint8) (value & 0xff);
  return bytes;
}

private static uint8[] raw_be64 (uint64 value) {
  uint8[] bytes = new uint8[8];
  for (int index = 7; index >= 0; index--) {
    bytes[index] = (uint8) (value & 0xff);
    value >>= 8;
  }
  return bytes;
}

private class RawFrame : GLib.Object {
  public bool fin;
  public uint8 opcode;
  public uint8[] payload;
  public RawFrame (bool fin, uint8 opcode, uint8[] payload) {
    this.fin = fin;
    this.opcode = opcode;
    this.payload = payload;
  }
}

private static uint8[] raw_frame_bytes (bool fin, uint8 opcode, uint8[] payload) {
  assert ((opcode & 0x08) == 0 || (fin && payload.length <= 125));
  var frame = new ByteArray ();
  if (payload.length < 126) {
    frame.append ({ (uint8) ((fin ? 0x80 : 0) | opcode), (uint8) payload.length });
  } else if (payload.length <= uint16.MAX) {
    uint8[] header = new uint8[4];
    header[0] = (uint8) ((fin ? 0x80 : 0) | opcode);
    header[1] = 126;
    uint8[] length = raw_be16 (payload.length);
    header[2] = length[0]; header[3] = length[1];
    frame.append (header);
  } else {
    uint8[] header = new uint8[10];
    header[0] = (uint8) ((fin ? 0x80 : 0) | opcode);
    header[1] = 127;
    uint8[] length = raw_be64 (payload.length);
    for (int index = 0; index < length.length; index++) header[index + 2] = length[index];
    frame.append (header);
  }
  if (payload.length > 0) frame.append (payload);
  uint8[] answer = new uint8[frame.len];
  for (int index = 0; index < answer.length; index++) answer[index] = frame.data[index];
  return answer;
}

private static void raw_write_frame (OutputStream output, bool fin, uint8 opcode, uint8[] payload) throws Error {
  raw_write_all (output, raw_frame_bytes (fin, opcode, payload));
}

private static void raw_write_text (OutputStream output, string text) throws Error {
  raw_write_frame (output, true, 0x1, text.data);
}

private static void raw_write_partial_text_header (OutputStream output, size_t length) throws Error {
  if (length < 126) {
    raw_write_all (output, { 0x81, (uint8) length });
  } else if (length <= uint16.MAX) {
    uint8[] header = new uint8[4];
    header[0] = 0x81; header[1] = 126;
    uint8[] encoded = raw_be16 (length);
    header[2] = encoded[0]; header[3] = encoded[1];
    raw_write_all (output, header);
  } else {
    throw new IOError.INVALID_DATA ("fixture partial frame is unexpectedly large");
  }
}

private static RawFrame raw_read_client_frame (InputStream input) throws Error {
  uint8[] header = new uint8[2];
  if (!raw_read_all (input, header)) throw new IOError.CLOSED ("peer closed before frame header");
  bool fin = (header[0] & 0x80) != 0;
  if ((header[0] & 0x70) != 0) throw new IOError.INVALID_DATA ("client used RSV bits");
  uint8 opcode = header[0] & 0x0f;
  if ((header[1] & 0x80) == 0) throw new IOError.INVALID_DATA ("client WebSocket frame is not masked");
  uint64 length = header[1] & 0x7f;
  if (length == 126) {
    uint8[] extended = new uint8[2];
    if (!raw_read_all (input, extended)) throw new IOError.CLOSED ("short extended frame length");
    length = ((uint64) extended[0] << 8) | extended[1];
  } else if (length == 127) {
    uint8[] extended = new uint8[8];
    if (!raw_read_all (input, extended)) throw new IOError.CLOSED ("short extended frame length");
    length = 0;
    for (int index = 0; index < 8; index++) length = (length << 8) | extended[index];
  }
  if (length > 2 * 1024 * 1024) throw new IOError.INVALID_DATA ("client frame is too large");
  if ((opcode & 0x08) != 0 && (!fin || length > 125)) throw new IOError.INVALID_DATA ("invalid control frame");
  uint8[] mask = new uint8[4];
  if (!raw_read_all (input, mask)) throw new IOError.CLOSED ("short masking key");
  uint8[] payload = new uint8[(int) length];
  if (length > 0 && !raw_read_all (input, payload)) throw new IOError.CLOSED ("short frame payload");
  for (int index = 0; index < payload.length; index++) payload[index] ^= mask[index % 4];
  return new RawFrame (fin, opcode, payload);
}

private static string raw_text (uint8[] bytes) {
  // Allocate a terminator instead of depending on an inbound network buffer
  // being NUL-terminated before passing it through JSON-GLib.
  uint8[] terminated = new uint8[bytes.length + 1];
  for (int index = 0; index < bytes.length; index++) terminated[index] = bytes[index];
  return (string) terminated;
}

private static Json.Object raw_read_client_json (InputStream input, OutputStream output) throws Error {
  for (;;) {
    var frame = raw_read_client_frame (input);
    if (frame.opcode == 0x9) {
      raw_write_frame (output, true, 0xa, frame.payload);
      continue;
    }
    if (frame.opcode == 0xa) continue;
    if (frame.opcode == 0x8) throw new IOError.CLOSED ("client closed before JSON command");
    if (frame.opcode != 0x1 || !frame.fin) throw new IOError.INVALID_DATA ("client JSON command was fragmented or non-text");
    var node = Convex.parse_json (raw_text (frame.payload));
    if (node.get_node_type () != NodeType.OBJECT) throw new IOError.INVALID_DATA ("client command is not an object");
    return node.get_object ();
  }
}

private static string raw_accept (string key) throws Error {
  uint8[] decoded = Base64.decode (key);
  if (decoded.length != 16) throw new IOError.INVALID_DATA ("invalid Sec-WebSocket-Key");
  var checksum = new Checksum (ChecksumType.SHA1);
  string source = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  checksum.update (source.data, source.length);
  uint8[] digest = new uint8[20];
  size_t digest_length = digest.length;
  checksum.get_digest (digest, ref digest_length);
  assert (digest_length == digest.length);
  return Base64.encode (digest);
}

private class RawPeer : GLib.Object {
  private SocketListener listener = new SocketListener ();
  private Thread<bool>? worker;
  private Mutex state_lock;
  private Cond state_changed;
  private bool stopping = false;
  private string? failure;
  private uint received_connections = 0;
  private uint received_adds = 0;
  private bool peer_closed = false;
  private int64 peer_closed_at = 0;
  private int mode;
  private uint64 timestamp = 0;
  private string? replay_args;
  private uint replay_query_id = uint.MAX;
  private bool initial_delivery_completed = false;

  public uint16 port { get; private set; }
  public uint connections { get { lock (state_lock) { return received_connections; } } }
  public uint adds { get { lock (state_lock) { return received_adds; } } }
  public bool closed_by_client { get { lock (state_lock) { return peer_closed; } } }
  public int64 closed_elapsed_us { get { lock (state_lock) { return peer_closed_at; } } }
  public string? failure_message { get { lock (state_lock) { return failure; } } }

  public void release_after_initial_delivery () {
    lock (state_lock) {
      initial_delivery_completed = true;
      state_changed.broadcast ();
    }
  }

  public RawPeer (int mode) throws Error {
    this.mode = mode;
    port = listener.add_any_inet_port (null);
  }

  public void start () {
    worker = new Thread<bool> ("vala-raw-peer", () => {
      try { serve (); } catch (Error error) { fail (error.message); }
      return true;
    });
  }

  public void stop () {
    lock (state_lock) { stopping = true; }
    listener.close ();
    if (worker != null) worker.join ();
    lock (state_lock) {
      if (failure != null) {
        stderr.printf ("raw peer failure: %s\n", failure);
        assert_not_reached ();
      }
    }
  }

  private void fail (string message) {
    lock (state_lock) {
      if (failure == null) failure = message;
      state_changed.broadcast ();
    }
  }

  private bool should_stop () {
    lock (state_lock) { return stopping; }
  }

  private void observe_connection () {
    lock (state_lock) { received_connections++; state_changed.broadcast (); }
  }

  private void observe_add () {
    lock (state_lock) { received_adds++; state_changed.broadcast (); }
  }

  private void observe_close (int64 started) {
    lock (state_lock) { peer_closed = true; peer_closed_at = get_monotonic_time () - started; state_changed.broadcast (); }
  }

  private void wait_for_initial_delivery () throws Error {
    int64 deadline = get_monotonic_time () + 5 * 1000 * 1000;
    for (;;) {
      lock (state_lock) {
        if (initial_delivery_completed) return;
        if (stopping) throw new IOError.CLOSED ("fixture stopped before initial delivery barrier");
      }
      if (get_monotonic_time () >= deadline) throw new IOError.TIMED_OUT ("initial delivery barrier timed out");
      Thread.usleep (1000);
    }
  }

  private DataInputStream handshake (SocketConnection connection, int failure_kind = 0) throws Error {
    var input = new DataInputStream (connection.input_stream);
    size_t line_length = 0;
    string? request = input.read_line_utf8 (out line_length, null);
    if (request == null || request.strip () != "GET /api/sync HTTP/1.1") {
      throw new IOError.INVALID_DATA ("unexpected WebSocket request: " + (request ?? "<eof>"));
    }
    string? key = null;
    bool saw_upgrade = false;
    bool saw_connection = false;
    bool saw_version = false;
    for (;;) {
      string? line = input.read_line_utf8 (out line_length, null);
      if (line == null) throw new IOError.CLOSED ("short WebSocket request");
      string header_line = line.strip ();
      if (header_line.length == 0) break;
      int separator = header_line.index_of (":");
      if (separator <= 0) throw new IOError.INVALID_DATA ("malformed WebSocket header");
      string name = header_line.substring (0, separator).down ();
      string value = header_line.substring (separator + 1).strip ();
      if (name == "sec-websocket-key") key = value;
      if (name == "upgrade" && value.down () == "websocket") saw_upgrade = true;
      if (name == "connection" && value.down ().contains ("upgrade")) saw_connection = true;
      if (name == "sec-websocket-version" && value == "13") saw_version = true;
    }
    if (key == null || !saw_upgrade || !saw_connection || !saw_version) throw new IOError.INVALID_DATA ("invalid WebSocket upgrade headers");
    string status = failure_kind == 1 ? "HTTP/1.1 503 Service Unavailable" : "HTTP/1.1 101 Switching Protocols";
    string response = status + "\r\n";
    if (failure_kind != 2) response += "Upgrade: websocket\r\n";
    if (failure_kind != 3) response += "Connection: keep-alive, Upgrade\r\n";
    response += "Sec-WebSocket-Accept: " + (failure_kind == 4 ? "wrong" : raw_accept (key)) + "\r\n\r\n";
    raw_write_all (connection.output_stream, response.data);
    // Keep using this buffered reader. Switching back to the raw socket can
    // lose a client frame prefetched with the HTTP upgrade headers.
    return input;
  }

  private uint accept_add (InputStream input, OutputStream output, uint expected_count, string expected_reason, bool expect_timestamp = true) throws Error {
    var connect = raw_read_client_json (input, output);
    if (connect.get_string_member ("type") != "Connect" || Convex.uint32_member (connect, "connectionCount") != expected_count) {
      throw new IOError.INVALID_DATA ("wrong Connect metadata");
    }
    if (expected_reason.length > 0 && connect.get_string_member ("lastCloseReason") != expected_reason) {
      throw new IOError.INVALID_DATA ("wrong reconnect close reason");
    }
    if (expected_count == 0 || !expect_timestamp) {
      if (connect.has_member ("maxObservedTimestamp")) throw new IOError.INVALID_DATA ("Connect carried an unobserved timestamp");
    } else if (!connect.has_member ("maxObservedTimestamp") || connect.get_string_member ("maxObservedTimestamp") != raw_timestamp (timestamp)) {
      throw new IOError.INVALID_DATA ("reconnect lost the numeric maximum timestamp");
    }
    var modify = raw_read_client_json (input, output);
    if (modify.get_string_member ("type") != "ModifyQuerySet" || Convex.uint32_member (modify, "baseVersion") != 0) {
      throw new IOError.INVALID_DATA ("wrong Add envelope");
    }
    var modifications = modify.get_array_member ("modifications");
    if (modifications.get_length () != 1) throw new IOError.INVALID_DATA ("expected one Add");
    var add = modifications.get_object_element (0);
    if (add.get_string_member ("type") != "Add" || add.get_string_member ("udfPath") != "demo:state") throw new IOError.INVALID_DATA ("wrong Add");
    string encoded_args = Convex.node_text (add.get_member ("args"));
    // A failed upgrade increments connectionCount without ever sending an
    // Add. Establish replay identity from the first successful connection,
    // rather than assuming that connectionCount must still be zero.
    if (replay_args == null) replay_args = encoded_args;
    else if (replay_args != encoded_args) throw new IOError.INVALID_DATA ("reconnect changed Add arguments");
    uint query_id = Convex.uint32_member (add, "queryId");
    if (replay_query_id == uint.MAX) replay_query_id = query_id;
    else if (replay_query_id != query_id) throw new IOError.INVALID_DATA ("reconnect changed Add query id");
    observe_add ();
    return query_id;
  }

  private void send_initial_fragmented (SocketConnection connection, InputStream input, uint query_id) throws Error {
    string message = raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 0, "café"));
    uint8[] bytes = message.data;
    int split = -1;
    for (int index = 0; index + 1 < bytes.length; index++) {
      if (bytes[index] == 0xc3 && bytes[index + 1] == 0xa9) { split = index + 1; break; }
    }
    if (split <= 0) throw new IOError.INVALID_DATA ("fixture UTF-8 split missing");
    uint8[] first = new uint8[split];
    uint8[] second = new uint8[bytes.length - split];
    for (int index = 0; index < split; index++) first[index] = bytes[index];
    for (int index = split; index < bytes.length; index++) second[index - split] = bytes[index];
    raw_write_frame (connection.output_stream, false, 0x1, first);
    raw_write_frame (connection.output_stream, true, 0x9, "probe".data);
    // The client must answer the control frame while retaining the fragmented
    // UTF-8 text message; only then may the continuation complete it.
    for (;;) {
      var reply = raw_read_client_frame (input);
      if (reply.opcode == 0xa) {
        if (raw_text (reply.payload) != "probe") throw new IOError.INVALID_DATA ("wrong Pong payload");
        break;
      }
      if (reply.opcode == 0x8) throw new IOError.CLOSED ("client closed before Pong");
    }
    raw_write_frame (connection.output_stream, true, 0x0, second);
  }

  private void wait_for_close (InputStream input, OutputStream output, int64 started) {
    try {
      for (;;) {
        var frame = raw_read_client_frame (input);
        if (frame.opcode == 0x8) {
          raw_write_frame (output, true, 0x8, frame.payload);
          observe_close (started);
          return;
        }
      }
    } catch (Error error) {
      observe_close (started);
    }
  }

  private void serve () throws Error {
    if (mode == 0) serve_reconnects ();
    else if (mode == 1) serve_partial_timeout ();
    else if (mode == 5) serve_same_id_replacement ();
    else if (mode == 6) serve_adapter_stress ();
    else if (mode == 7) serve_protocol_recovery ();
    else if (mode == 8) serve_idle_then_update (false);
    else if (mode == 9) serve_idle_then_update (true);
    else if (mode == 10) serve_handshake_validation ();
    else if (mode == 11) serve_close_with_buffered_transition ();
    else serve_stalled_close ();
  }

  private void serve_reconnects () throws Error {
    for (uint connection_number = 0; connection_number < 6 && !should_stop (); connection_number++) {
      GLib.Object? source;
      var connection = listener.accept (out source, null);
      var input = handshake (connection);
      observe_connection ();
      uint query_id = accept_add (input, connection.output_stream, connection_number, connection_number == 0 ? "InitialConnect" : "debugDisconnect");
      if (connection_number == 0) {
        send_initial_fragmented (connection, input, query_id);
        // QueryFailed must not strand the subscription.  The next update on
        // this same connection is the recovery assertion in the test.
        raw_write_text (connection.output_stream, raw_transition (1, 1, timestamp, ++timestamp, query_id, raw_failure (query_id)));
        raw_write_text (connection.output_stream, raw_transition (1, 1, timestamp, ++timestamp, query_id, raw_update (query_id, 1)));
      } else {
        // The first reconnect message repeats the last delivered count. The
        // client must suppress exactly this rehydration, not later values.
        raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, connection_number)));
        Thread.usleep (150 * 1000);
        raw_write_text (connection.output_stream, raw_transition (1, 1, timestamp, ++timestamp, query_id, raw_update (query_id, connection_number + 1)));
      }
      wait_for_close (input, connection.output_stream, get_monotonic_time ());
    }
  }

  private void serve_partial_timeout () throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 0)));
    // The test releases this only from the delivered-value callback. That
    // proves the parser drained the prior frame before the later header/prefix
    // begins a genuinely new absolute frame deadline.
    wait_for_initial_delivery ();
    string partial = raw_transition (1, 1, timestamp, timestamp + 1, query_id, raw_update (query_id, 99));
    uint8[] bytes = partial.data;
    // Declare a complete text message but stop inside it. A timeout must
    // abandon this TCP connection, not continue parsing on a reconnect.
    raw_write_partial_text_header (connection.output_stream, bytes.length);
    uint8[] prefix = new uint8[8];
    for (int index = 0; index < prefix.length; index++) prefix[index] = bytes[index];
    raw_write_all (connection.output_stream, prefix);
    wait_for_close (input, connection.output_stream, get_monotonic_time ());
    if (should_stop ()) return;
    var recovery_connection = listener.accept (out source, null);
    var recovery_input = handshake (recovery_connection);
    observe_connection ();
    uint recovery_query_id = accept_add (recovery_input, recovery_connection.output_stream, 1, "Live frame timed out");
    raw_write_text (recovery_connection.output_stream, raw_transition (0, 1, 0, ++timestamp, recovery_query_id, raw_update (recovery_query_id, 2)));
    wait_for_close (recovery_input, recovery_connection.output_stream, get_monotonic_time ());
  }

  private void serve_close_with_buffered_transition () throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 0)));
    wait_for_initial_delivery ();

    var close_builder = new ByteArray ();
    close_builder.append ({ 0x03, 0xe8 });
    close_builder.append ("fixture close".data);
    uint8[] close_payload = new uint8[close_builder.len];
    for (int index = 0; index < close_payload.length; index++) close_payload[index] = close_builder.data[index];
    string stale = raw_transition (1, 1, timestamp, timestamp + 1, query_id, raw_update (query_id, 99));
    var combined = new ByteArray ();
    combined.append (raw_frame_bytes (true, 0x8, close_payload));
    combined.append (raw_frame_bytes (true, 0x1, stale.data));
    // One kernel write makes the Close and stale Transition available in the
    // same parser buffer. The client must stop at Close, not publish count 99.
    uint8[] wire = new uint8[combined.len];
    for (int index = 0; index < wire.length; index++) wire[index] = combined.data[index];
    raw_write_all (connection.output_stream, wire);
    wait_for_close (input, connection.output_stream, get_monotonic_time ());
    if (should_stop ()) return;

    var recovery_connection = listener.accept (out source, null);
    var recovery_input = handshake (recovery_connection);
    observe_connection ();
    uint recovery_query_id = accept_add (recovery_input, recovery_connection.output_stream, 1, "WebSocket close 1000: fixture close");
    raw_write_text (recovery_connection.output_stream, raw_transition (0, 1, 0, ++timestamp, recovery_query_id, raw_update (recovery_query_id, 2)));
    wait_for_close (recovery_input, recovery_connection.output_stream, get_monotonic_time ());
  }

  private void serve_stalled_close () throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    int64 started = get_monotonic_time ();
    if (mode == 3) {
      string partial = raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 0));
      raw_write_partial_text_header (connection.output_stream, partial.length);
      raw_write_all (connection.output_stream, partial.data[0 : 4]);
    } else if (mode == 4) {
      try {
        for (uint count = 0; count < 64; count++) {
          raw_write_text (connection.output_stream, raw_transition (count == 0 ? 0 : 1, 1, count == 0 ? 0 : timestamp, ++timestamp, query_id, raw_update (query_id, count)));
        }
      } catch (Error error) {
        // A bounded client close may retire the socket while this deliberately
        // noisy peer is still writing. That reset is the expected close proof.
        observe_close (started);
        return;
      }
    }
    wait_for_close (input, connection.output_stream, started);
  }

  private void serve_same_id_replacement () throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint old_query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, old_query_id, raw_update (old_query_id, 10)));
    var remove = raw_read_client_json (input, connection.output_stream);
    if (remove.get_string_member ("type") != "ModifyQuerySet" || Convex.uint32_member (remove, "baseVersion") != 1 || Convex.uint32_member (remove, "newVersion") != 2 ||
        remove.get_array_member ("modifications").get_object_element (0).get_string_member ("type") != "Remove") {
      throw new IOError.INVALID_DATA ("replacement did not remove the old query first");
    }
    var add = raw_read_client_json (input, connection.output_stream);
    if (add.get_string_member ("type") != "ModifyQuerySet" || Convex.uint32_member (add, "baseVersion") != 2 || Convex.uint32_member (add, "newVersion") != 3) {
      throw new IOError.INVALID_DATA ("replacement did not add after Remove");
    }
    var new_add = add.get_array_member ("modifications").get_object_element (0);
    if (new_add.get_string_member ("type") != "Add") throw new IOError.INVALID_DATA ("replacement Add missing");
    observe_add ();
    uint new_query_id = Convex.uint32_member (new_add, "queryId");
    raw_write_text (connection.output_stream, raw_transition (1, 3, timestamp, ++timestamp, new_query_id, raw_update (new_query_id, 20)));
    wait_for_close (input, connection.output_stream, get_monotonic_time ());
  }

  private void serve_adapter_stress () throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    var text = new StringBuilder ();
    for (int index = 0; index < 1536 * 1024; index++) text.append_c ('x');
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 0, text.str)));
    // Pace each near-maximum update just enough for the adapter to begin its
    // corresponding controller write. A blast would be collapsed by the
    // deliberately bounded client queue before it could exercise backpressure.
    Thread.usleep (25 * 1000);
    for (uint count = 1; count < 64; count++) {
      raw_write_text (connection.output_stream, raw_transition (1, 1, timestamp, ++timestamp, query_id, raw_update (query_id, count, text.str)));
      Thread.usleep (25 * 1000);
    }
    // The caller deliberately stops reading adapter stdout. Keep the peer
    // alive briefly so the real final adapter is measured while writes stall.
    Thread.usleep (8 * 1000 * 1000);
  }

  private void serve_protocol_recovery () throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 0)));
    raw_write_text (connection.output_stream, "{not-json");
    wait_for_close (input, connection.output_stream, get_monotonic_time ());
    if (should_stop ()) return;
    var recovery_connection = listener.accept (out source, null);
    var recovery_input = handshake (recovery_connection);
    observe_connection ();
    uint recovery_query_id = accept_add (recovery_input, recovery_connection.output_stream, 1, "");
    raw_write_text (recovery_connection.output_stream, raw_transition (0, 1, 0, ++timestamp, recovery_query_id, raw_update (recovery_query_id, 2)));
    wait_for_close (recovery_input, recovery_connection.output_stream, get_monotonic_time ());
  }

  private void serve_idle_then_update (bool control_traffic) throws Error {
    GLib.Object? source;
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    uint query_id = accept_add (input, connection.output_stream, 0, "InitialConnect");
    for (int second = 0; second < 6; second++) {
      Thread.usleep (1100 * 1000);
      if (!control_traffic) continue;
      string probe = "idle-" + second.to_string ();
      raw_write_frame (connection.output_stream, true, 0x9, probe.data);
      var pong = raw_read_client_frame (input);
      if (pong.opcode != 0xa || raw_text (pong.payload) != probe) {
        throw new IOError.INVALID_DATA ("idle control traffic did not receive matching Pong");
      }
    }
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 7)));
    wait_for_close (input, connection.output_stream, get_monotonic_time ());
  }

  private void serve_handshake_validation () throws Error {
    GLib.Object? source;
    for (int failure_kind = 1; failure_kind <= 4; failure_kind++) {
      var rejected = listener.accept (out source, null);
      var rejected_input = handshake (rejected, failure_kind);
      observe_connection ();
      uint8[] byte = new uint8[1];
      try { rejected_input.read (byte, null); } catch (Error error) {}
    }
    var connection = listener.accept (out source, null);
    var input = handshake (connection);
    observe_connection ();
    // Four failed upgrades increment connectionCount, but none observed a
    // server transition, so Connect must still omit maxObservedTimestamp.
    uint query_id = accept_add (input, connection.output_stream, 4, "invalid WebSocket upgrade response", false);
    raw_write_text (connection.output_stream, raw_transition (0, 1, 0, ++timestamp, query_id, raw_update (query_id, 11)));
    wait_for_close (input, connection.output_stream, get_monotonic_time ());
  }
}

#if ADAPTER_TEST
#else
#if ADAPTER_STRESS_PEER
#else
// The adapter fixture needs RawPeer, not these standalone test entrypoints.
// Keeping them out of that translation unit also avoids an amd64 GCC/QEMU
// compiler crash without reducing either raw-peer or adapter coverage.
private static void raw_reconnect_fragment_and_recovery () {
  try {
    var peer = new RawPeer (0);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    var subscription = client.subscribe ("demo:state", raw_object ("raw-peer"));
    var values = new Gee.ArrayList<int> ();
    int failures = 0;
    subscription.updated.connect ((value, failure) => {
      if (failure != null) { failures++; return; }
      if (value != null) values.add ((int) value.get_object ().get_int_member ("count"));
    });
    spin_until (() => values.size >= 1 && failures >= 1 || peer.failure_message != null, 5 * 1000 * 1000, "fragmented initial value and QueryFailed");
    if (peer.failure_message != null) {
      stderr.printf ("raw reconnect fixture failed: %s\n", peer.failure_message);
      assert_not_reached ();
    }
    spin_until (() => values.size >= 2, 5 * 1000 * 1000, "QueryFailed recovery");
    assert (values.get (0) == 0);
    assert (values.get (1) == 1);
    assert (failures == 1);
    for (int index = 0; index < 5; index++) {
      assert (client.debug_disconnect_for_adapter ());
      spin_until (() => peer.connections >= (uint) index + 2, 5 * 1000 * 1000, "debug reconnect");
      int delivered_before = values.size;
      Thread.usleep (250 * 1000);
      while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
      // The peer's unchanged snapshot is held for 150 ms before its external
      // value. The only new callback in this cycle is the changed value.
      spin_until (() => values.size == delivered_before + 1, 5 * 1000 * 1000, "changed reconnect value");
    }
    assert (peer.connections == 6);
    assert (peer.adds == 6);
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw reconnect test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

private static void raw_partial_frame_times_out_and_abandons_connection () {
  try {
    var peer = new RawPeer (1);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    var subscription = client.subscribe ("demo:state", raw_object ("partial-timeout"));
    bool initial = false;
    bool transport_error = false;
    bool recovered = false;
    bool false_partial_value = false;
    subscription.updated.connect ((value, failure) => {
      if (failure != null && failure.name == "TransportError") transport_error = true;
      if (value != null && value.get_object ().get_int_member ("count") == 0) {
        initial = true;
        peer.release_after_initial_delivery ();
      }
      if (value != null && value.get_object ().get_int_member ("count") == 2) recovered = true;
      if (value != null && value.get_object ().get_int_member ("count") == 99) false_partial_value = true;
    });
    spin_until (() => initial, 5 * 1000 * 1000, "partial initial value");
    spin_until (() => transport_error && peer.closed_by_client, 8 * 1000 * 1000, "partial frame timeout and close");
    assert (peer.closed_elapsed_us >= 4 * 1000 * 1000);
    assert (peer.closed_elapsed_us <= 7 * 1000 * 1000);
    spin_until (() => recovered && peer.connections == 2 && peer.adds == 2, 5 * 1000 * 1000, "recovery after abandoned partial frame");
    assert (!false_partial_value);
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw partial timeout test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

private static void raw_close_discards_buffered_transition_and_recovers () {
  try {
    var peer = new RawPeer (11);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    var subscription = client.subscribe ("demo:state", raw_object ("close-buffer"));
    bool initial = false;
    bool transport_error = false;
    bool stale = false;
    bool recovered = false;
    subscription.updated.connect ((value, failure) => {
      if (failure != null && failure.name == "TransportError") transport_error = true;
      if (value == null) return;
      int64 count = value.get_object ().get_int_member ("count");
      if (count == 0) {
        initial = true;
        peer.release_after_initial_delivery ();
      } else if (count == 99) stale = true;
      else if (count == 2) recovered = true;
    });
    spin_until (() => initial, 5 * 1000 * 1000, "close fixture initial value");
    spin_until (() => transport_error && peer.connections == 2 && peer.adds == 2, 5 * 1000 * 1000, "Close retirement and Add replay");
    spin_until (() => recovered, 5 * 1000 * 1000, "fresh value after Close reconnect");
    assert (!stale);
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw buffered Close test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

private static void raw_protocol_error_recovers_on_a_new_connection () {
  try {
    var peer = new RawPeer (7);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    var subscription = client.subscribe ("demo:state", raw_object ("protocol-recovery"));
    bool initial = false;
    bool protocol_error = false;
    bool recovered = false;
    subscription.updated.connect ((value, failure) => {
      if (failure != null && failure.name == "ProtocolError") protocol_error = true;
      if (value != null && value.get_object ().get_int_member ("count") == 0) initial = true;
      if (value != null && value.get_object ().get_int_member ("count") == 2) recovered = true;
    });
    spin_until (() => initial && protocol_error, 5 * 1000 * 1000, "structured protocol error");
    spin_until (() => recovered && peer.connections == 2, 5 * 1000 * 1000, "protocol recovery");
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw protocol recovery test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

private static void raw_close_stays_bounded_with_idle_flood_and_half_frame () {
  for (int mode = 2; mode <= 4; mode++) {
    try {
      var peer = new RawPeer (mode);
      peer.start ();
      var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
      client.subscribe ("demo:state", raw_object ("close-bound"));
      spin_until (() => peer.adds == 1, 5 * 1000 * 1000, "fixture Add");
      int64 started = get_monotonic_time ();
      client.close ();
      assert (get_monotonic_time () - started < 2 * 1000 * 1000);
      spin_until (() => peer.closed_by_client, 2 * 1000 * 1000, "bounded fixture close");
      assert (peer.closed_elapsed_us < 2 * 1000 * 1000);
      peer.stop ();
    } catch (Error error) {
      stderr.printf ("raw bounded close test failed: %s\n", error.message);
      assert_not_reached ();
    }
  }
}

private static void raw_idle_and_control_traffic_do_not_start_frame_deadline () {
  for (int mode = 8; mode <= 9; mode++) {
    try {
      var peer = new RawPeer (mode);
      peer.start ();
      var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
      var subscription = client.subscribe ("demo:state", raw_object (mode == 8 ? "idle" : "control"));
      bool delivered = false;
      int failures = 0;
      subscription.updated.connect ((value, failure) => {
        if (failure != null) failures++;
        if (value != null && value.get_object ().get_int_member ("count") == 7) delivered = true;
      });
      int64 started = get_monotonic_time ();
      spin_until (() => delivered || peer.failure_message != null, 10 * 1000 * 1000, "idle Live update after frame deadline window");
      assert (get_monotonic_time () - started > 5 * 1000 * 1000);
      assert (peer.failure_message == null);
      assert (failures == 0);
      assert (peer.connections == 1);
      client.close ();
      peer.stop ();
    } catch (Error error) {
      stderr.printf ("raw idle deadline test failed: %s\n", error.message);
      assert_not_reached ();
    }
  }
}

private static void raw_upgrade_validation_rejects_then_recovers () {
  try {
    var peer = new RawPeer (10);
    peer.start ();
    var client = new Client ("http://127.0.0.1:" + peer.port.to_string ());
    var subscription = client.subscribe ("demo:state", raw_object ("handshake-validation"));
    int transport_failures = 0;
    int protocol_failures = 0;
    bool recovered = false;
    subscription.updated.connect ((value, failure) => {
      if (failure != null && failure.name == "TransportError") transport_failures++;
      if (failure != null && failure.name == "ProtocolError") protocol_failures++;
      if (value != null && value.get_object ().get_int_member ("count") == 11) recovered = true;
    });
    spin_until (() => recovered || peer.failure_message != null, 10 * 1000 * 1000, "strict WebSocket upgrade recovery");
    if (peer.failure_message != null) stderr.printf ("strict upgrade peer failure: %s\n", peer.failure_message);
    assert (peer.failure_message == null);
    assert (peer.connections == 5);
    assert (transport_failures == 1);
    assert (protocol_failures == 3);
    client.close ();
    peer.stop ();
  } catch (Error error) {
    stderr.printf ("raw WebSocket upgrade test failed: %s\n", error.message);
    assert_not_reached ();
  }
}

#endif
#endif

#if ADAPTER_STRESS_PEER
int main (string[] args) {
  try {
    var peer = new RawPeer (6);
    peer.start ();
    stdout.printf ("%u\n", peer.port);
    stdout.flush ();
    Thread.usleep (10 * 1000 * 1000);
    peer.stop ();
    return 0;
  } catch (Error error) {
    stderr.printf ("adapter stress peer failed: %s\n", error.message);
    return 1;
  }
}
#else
#if ADAPTER_TEST
#else
int main (string[] args) {
  Test.init (ref args);
  Test.add_func ("/convex/live/raw-peer/reconnect-fragment-recovery", raw_reconnect_fragment_and_recovery);
  Test.add_func ("/convex/live/raw-peer/partial-frame-timeout", raw_partial_frame_times_out_and_abandons_connection);
  Test.add_func ("/convex/live/raw-peer/close-discards-buffered-transition", raw_close_discards_buffered_transition_and_recovers);
  Test.add_func ("/convex/live/raw-peer/protocol-recovery", raw_protocol_error_recovers_on_a_new_connection);
  Test.add_func ("/convex/live/raw-peer/bounded-close", raw_close_stays_bounded_with_idle_flood_and_half_frame);
  Test.add_func ("/convex/live/raw-peer/idle-and-control-deadline", raw_idle_and_control_traffic_do_not_start_frame_deadline);
  Test.add_func ("/convex/live/raw-peer/strict-upgrade-recovery", raw_upgrade_validation_rejects_then_recovers);
  return Test.run ();
}
#endif
#endif
