// An RFC 6455 client written in Pike.
//
// This fragment is textually included by convex.pike. It sits between the byte
// channel and the Convex sync state machine and owns exactly one connection:
// the upgrade request, the 101 validation, masking, fragment reassembly,
// control frames, and a bounded retirement path. Because it only ever talks to
// a Channel, every rule below is provable with in-process fixtures.
#ifndef CONVEX_WEBSOCKET_PIKE
#define CONVEX_WEBSOCKET_PIKE

constant WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
constant MAX_WS_HANDSHAKE_BYTES = 32 * 1024;
constant MAX_WS_FRAME_BYTES = 1024 * 1024;
constant MAX_WS_MESSAGE_BYTES = 2 * 1024 * 1024;
// A frame that has started arriving must finish within this window. The parser
// never rewinds to a guessed boundary, so the only safe alternative to waiting
// is abandoning the whole connection.
constant PARTIAL_FRAME_TIMEOUT_MS = 15000;
constant CLOSE_HANDSHAKE_TIMEOUT_MS = 1000;

constant WS_CONTINUATION = 0x0;
constant WS_TEXT = 0x1;
constant WS_BINARY = 0x2;
constant WS_CLOSE = 0x8;
constant WS_PING = 0x9;
constant WS_PONG = 0xa;

string websocket_accept_for(string key)
{
  return MIME.encode_base64(Crypto.SHA1.hash(key + WEBSOCKET_GUID), 1);
}

// RFC 6455 requires every client frame to be masked with a fresh key. The
// per-byte loop is deliberate: it is exact for every payload length and the
// frames this client sends are small control messages.
string apply_mask(string payload, string mask)
{
  if (!sizeof(payload))
    return "";
  array(int) bytes = (array(int))payload;
  array(int) key = (array(int))mask;
  for (int index = 0; index < sizeof(bytes); index++)
    bytes[index] = bytes[index] ^ key[index & 3];
  return (string)bytes;
}

string encode_frame(int opcode, string payload, string mask)
{
  int length = sizeof(payload);
  string header = sprintf("%c", 0x80 | opcode);
  if (length < 126)
    header += sprintf("%c", 0x80 | length);
  else if (length < 65536)
    header += sprintf("%c%2c", 0x80 | 126, length);
  else
    header += sprintf("%c%8c", 0x80 | 127, length);
  return header + mask + apply_mask(payload, mask);
}

// A UUID the pinned sync profile accepts as a session identifier. Version and
// variant bits are set so the value is a well-formed random UUID rather than 16
// arbitrary bytes formatted to look like one.
string random_session_id()
{
  array(int) bytes = (array(int))random_string(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  string hex = String.string2hex((string)bytes);
  return hex[..7] + "-" + hex[8..11] + "-" + hex[12..15] + "-" + hex[16..19] +
         "-" + hex[20..];
}

class WebSocketConnection
{
  Channel channel;
  mapping target;
  string client_version;

  function(void:void) opened_handler;
  function(string:void) message_handler;
  function(string:void) closed_handler;

  // "handshake" -> "open" -> "closing" -> "closed"
  string state = "handshake";
  string handshake_key = "";
  string buffer = "";
  string fragments = "";
  int fragment_opcode = -1;
  int partial_since;
  int close_deadline;
  string close_reason = "";
  int announced;

  protected void create(Channel connection_channel, mapping connection_target,
                        string version,
                        function(void:void) on_open,
                        function(string:void) on_message,
                        function(string:void) on_close)
  {
    channel = connection_channel;
    target = connection_target;
    client_version = version;
    opened_handler = on_open;
    message_handler = on_message;
    closed_handler = on_close;
    channel->set_handlers(receive, channel_closed);
    handshake_key = MIME.encode_base64(random_string(16), 1);
    if (!channel->write(handshake_request()))
      retire("WebSocket upgrade request could not be written");
  }

  string handshake_request()
  {
    array(string) lines = ({
      sprintf("GET %s HTTP/1.1", target->path),
      "Host: " + target->authority,
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: " + handshake_key,
      "Sec-WebSocket-Version: 13",
      "Convex-Client: " + client_version,
    });
    return lines * "\r\n" + "\r\n\r\n";
  }

  void channel_closed(string reason)
  {
    retire(sizeof(reason) ? reason : "WebSocket transport closed");
  }

  // The single entry point for inbound bytes. Any rule violation retires this
  // connection with a reason instead of throwing into the Pike backend, which
  // would discard it; the owner above turns that reason into a structured error
  // and a reconnect.
  void receive(string data)
  {
    if (state == "closed")
      return;
    buffer += data;
    mixed failed = catch {
      if (state == "handshake")
        step_handshake();
      if (state == "open" || state == "closing")
        step_frames();
    };
    if (failed) {
      retire(as_convex_error(failed, "live")->message);
      return;
    }
    note_partial_progress();
  }

  void note_partial_progress()
  {
    if (state == "closed")
      return;
    int incomplete = sizeof(buffer) || fragment_opcode >= 0;
    if (incomplete && !partial_since)
      partial_since = now_ms();
    else if (!incomplete)
      partial_since = 0;
  }

  void step_handshake()
  {
    int end = search(buffer, "\r\n\r\n");
    if (end < 0) {
      if (sizeof(buffer) > MAX_WS_HANDSHAKE_BYTES)
        throw(protocol_error("WebSocket upgrade headers exceed their budget",
                             "live"));
      return;
    }
    string head = buffer[..end - 1];
    buffer = buffer[end + 4..];

    array(string) lines = head / "\r\n";
    if (!has_prefix(lines[0], "HTTP/1.1 101 ") &&
        !has_prefix(lines[0], "HTTP/1.0 101 "))
      throw(protocol_error("WebSocket upgrade was not answered with 101",
                           "live"));

    mapping(string:string) headers = ([]);
    foreach (lines[1..], string line) {
      if (!sizeof(line))
        continue;
      int colon = search(line, ":");
      if (colon < 1)
        throw(protocol_error("WebSocket upgrade sent a malformed header",
                             "live"));
      headers[lower_case(trim_ascii(line[..colon - 1]))] =
        trim_ascii(line[colon + 1..]);
    }
    if (lower_case(headers->upgrade || "") != "websocket")
      throw(protocol_error("WebSocket upgrade omitted the websocket token",
                           "live"));
    if (search(lower_case(headers->connection || ""), "upgrade") < 0)
      throw(protocol_error("WebSocket upgrade omitted the upgrade connection",
                           "live"));
    // The accept value proves the peer processed this exact key rather than
    // replaying a cached 101 from an unrelated handshake.
    if ((headers["sec-websocket-accept"] || "") !=
        websocket_accept_for(handshake_key))
      throw(protocol_error("WebSocket accept value did not match the key",
                           "live"));
    if (headers["sec-websocket-extensions"])
      throw(protocol_error("this client negotiated no WebSocket extensions",
                           "live"));

    state = "open";
    if (opened_handler)
      opened_handler();
  }

  void step_frames()
  {
    while (state != "closed") {
      if (sizeof(buffer) < 2)
        return;
      int first = buffer[0];
      int second = buffer[1];
      int fin = (first & 0x80) != 0;
      int opcode = first & 0x0f;
      if (first & 0x70)
        throw(protocol_error("WebSocket frame set a reserved bit", "live"));
      if (second & 0x80)
        throw(protocol_error("a server frame must not be masked", "live"));

      int length = second & 0x7f;
      int offset = 2;
      if (length == 126) {
        if (sizeof(buffer) < 4)
          return;
        sscanf(buffer[2..3], "%2c", length);
        offset = 4;
      } else if (length == 127) {
        if (sizeof(buffer) < 10)
          return;
        sscanf(buffer[2..9], "%8c", length);
        offset = 10;
      }
      if (length < 0 || length > MAX_WS_FRAME_BYTES)
        throw(protocol_error("WebSocket frame exceeds its byte budget",
                             "live"));
      if (opcode >= 8 && (!fin || length > 125))
        throw(protocol_error("WebSocket control frame is malformed", "live"));
      if (sizeof(buffer) < offset + length)
        return;

      string payload = buffer[offset..offset + length - 1];
      buffer = buffer[offset + length..];
      handle_frame(fin, opcode, payload);
    }
  }

  void handle_frame(int fin, int opcode, string payload)
  {
    if (opcode == WS_CLOSE) {
      string reason = "peer closed the WebSocket";
      if (sizeof(payload) >= 2) {
        int code;
        sscanf(payload[..1], "%2c", code);
        reason = sprintf("peer closed the WebSocket with code %d", code);
      }
      // Answer the close so a cooperative peer can finish, then retire without
      // waiting for it to act on the reply.
      if (state == "open")
        write_frame(WS_CLOSE, payload);
      retire(reason);
      return;
    }
    if (opcode == WS_PING) {
      write_frame(WS_PONG, payload);
      return;
    }
    if (opcode == WS_PONG)
      return;

    if (opcode == WS_CONTINUATION) {
      if (fragment_opcode < 0)
        throw(protocol_error("unexpected WebSocket continuation frame",
                             "live"));
      if (sizeof(fragments) + sizeof(payload) > MAX_WS_MESSAGE_BYTES)
        throw(protocol_error("WebSocket message exceeds its byte budget",
                             "live"));
      fragments += payload;
      if (!fin)
        return;
      opcode = fragment_opcode;
      payload = fragments;
      fragments = "";
      fragment_opcode = -1;
    } else if (opcode == WS_TEXT || opcode == WS_BINARY) {
      if (fragment_opcode >= 0)
        throw(protocol_error("WebSocket data frame interleaved with a fragment",
                             "live"));
      if (!fin) {
        if (sizeof(payload) > MAX_WS_MESSAGE_BYTES)
          throw(protocol_error("WebSocket message exceeds its byte budget",
                               "live"));
        fragment_opcode = opcode;
        fragments = payload;
        return;
      }
    } else {
      throw(protocol_error(sprintf("unsupported WebSocket opcode %d", opcode),
                           "live"));
    }

    if (opcode != WS_TEXT)
      throw(protocol_error("Convex Live sends text frames only", "live"));
    // Deliver the raw UTF-8 bytes. The sync layer decodes them, so an invalid
    // encoding is classified there next to the rest of the message validation.
    if (state == "open" && message_handler)
      message_handler(payload);
  }

  void write_frame(int opcode, string payload)
  {
    if (state == "closed")
      return;
    if (!channel->write(encode_frame(opcode, payload, random_string(4))))
      retire("WebSocket frame could not be written");
  }

  void send_text(string payload)
  {
    if (state != "open")
      throw(transport_error("WebSocket is not open", "live"));
    write_frame(WS_TEXT, payload);
  }

  // Begin a courteous close, but bound it. The peer may be idle, flooding, or
  // stalled mid-frame; none of those may delay retirement past the deadline.
  void begin_close(int code, string reason)
  {
    if (state == "closed" || state == "closing")
      return;
    // RFC 6455 leaves 123 bytes for the reason. Keep the wire form short and
    // printable so a long transport message cannot block the close frame.
    string trimmed = reason;
    if (sizeof(trimmed) > 100)
      trimmed = trimmed[..99];
    if (state == "open")
      write_frame(WS_CLOSE, sprintf("%2c", code) + trimmed);
    state = "closing";
    close_reason = reason;
    close_deadline = now_ms() + CLOSE_HANDSHAKE_TIMEOUT_MS;
  }

  // Called from the owner's poll. Returns 1 when it retired the connection.
  int enforce_deadlines(int now)
  {
    if (state == "closed")
      return 0;
    if (state == "closing" && now >= close_deadline) {
      retire(sizeof(close_reason) ? close_reason : "close handshake timed out");
      return 1;
    }
    if (partial_since && now - partial_since >= PARTIAL_FRAME_TIMEOUT_MS) {
      retire("WebSocket frame stalled partway through");
      return 1;
    }
    return 0;
  }

  void abort(string reason)
  {
    retire(reason);
  }

  void retire(string reason)
  {
    if (state == "closed")
      return;
    state = "closed";
    buffer = "";
    fragments = "";
    fragment_opcode = -1;
    partial_since = 0;
    channel->set_handlers(0, 0);
    channel->hard_close(reason);
    if (!announced) {
      announced = 1;
      if (closed_handler)
        closed_handler(reason);
    }
  }

  int is_open()
  {
    return state == "open";
  }

  int is_closed()
  {
    return state == "closed";
  }
}

#endif
