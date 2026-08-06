using GLib;
using Gee;

namespace Convex {
  /*
   * This is deliberately a small RFC6455 transport rather than a Convex
   * protocol implementation. LiveOwner remains the only owner of Convex
   * query-set state; this object owns one GIO stream and its incremental frame
   * parser on the same GLib main context.
   */
  internal class WebSocketTransport : GLib.Object {
    private const size_t MAX_HEADER_BYTES = 16 * 1024;
    private const size_t MAX_PAYLOAD_BYTES = 2 * 1024 * 1024;
    private const size_t MAX_QUEUED_WRITE_BYTES = 4 * 1024 * 1024;
    private const uint MAX_QUEUED_WRITES = 32;
    private const uint CONNECT_TIMEOUT_MS = 15000;
    private const uint FRAME_TIMEOUT_MS = 5000;
    private const uint WRITE_TIMEOUT_MS = 5000;
    private const uint CLOSE_TIMEOUT_MS = 1000;

    private IOStream? stream;
    private InputStream? input;
    private OutputStream? output;
    private InputStream? entropy;
    private Cancellable lifetime = new Cancellable ();
    private ByteArray incoming = new ByteArray ();
    private ByteArray fragmented_message = new ByteArray ();
    private ArrayQueue<OutgoingFrame> outgoing = new ArrayQueue<OutgoingFrame> ();
    private uint8 fragmented_opcode = 0;
    private bool open_state = false;
    private bool started = false;
    private bool writing = false;
    private bool closing_state = false;
    private bool failed_state = false;
    private uint frame_timeout_source = 0;
    private uint write_timeout_source = 0;
    private uint close_timeout_source = 0;
    private size_t reserved_write_bytes = 0;
    private uint reserved_write_count = 0;

    internal signal void text_message (string text);
    internal signal void transport_failed (string message);
    internal signal void protocol_failed (string message);
    internal signal void peer_closed (string reason);

    internal bool is_open { get { return open_state && !failed_state && !closing_state; } }

    internal async void connect (string url, string? auth_token) throws Error {
      Uri uri;
      try {
        uri = Uri.parse (url, UriFlags.NONE);
      } catch (UriError error) {
        throw new ClientError.PROTOCOL ("invalid WebSocket URL: " + error.message);
      }
      var scheme = uri.get_scheme ().down ();
      var host = uri.get_host ();
      if ((scheme != "ws" && scheme != "wss") || host == null || host.length == 0 ||
          uri.get_userinfo () != null || uri.get_fragment () != null) {
        throw new ClientError.PROTOCOL ("invalid WebSocket URL");
      }
      bool secure = scheme == "wss";
      int parsed_port = uri.get_port ();
      uint16 port = (uint16) (parsed_port >= 0 ? parsed_port : (secure ? 443 : 80));
      string connect_host = host.contains (":") ? "[" + host + "]" : host;
      string host_header = connect_host;
      if (parsed_port >= 0 && parsed_port != (secure ? 443 : 80)) host_header += ":" + parsed_port.to_string ();
      string target = uri.get_path ();
      if (target.length == 0) target = "/";
      if (uri.get_query () != null) target += "?" + uri.get_query ();

      entropy = File.new_for_path ("/dev/urandom").read (lifetime);
      var socket_client = new SocketClient ();
      // Keep the socket's idle timeout at GIO's zero default. The cancellable
      // below bounds connect and upgrade, while frame, write, and close each
      // have their own absolute deadlines after real work starts.
      // GSocketClient wraps the connected socket in GTlsClientConnection when
      // this is true, including hostname and CA validation before it returns.
      socket_client.tls = secure;
      uint connect_timeout = Timeout.add (CONNECT_TIMEOUT_MS, () => {
        lifetime.cancel ();
        return false;
      });
      try {
        stream = yield socket_client.connect_to_host_async (connect_host, port, lifetime);
        input = stream.input_stream;
        output = stream.output_stream;
        uint8[] nonce = random_bytes (16);
        string key = Base64.encode (nonce);
        string request = "GET " + target + " HTTP/1.1\r\nHost: " + host_header +
                         "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key +
                         "\r\nSec-WebSocket-Version: 13\r\nConvex-Client: vala-0.1.0\r\n";
        if (auth_token != null) {
          if (auth_token.contains ("\r") || auth_token.contains ("\n")) {
            throw new ClientError.PROTOCOL ("authentication token contains an invalid header character");
          }
          request += "Authorization: Bearer " + auth_token + "\r\n";
        }
        request += "\r\n";
        size_t written = 0;
        yield output.write_all_async (request.data, Priority.DEFAULT, lifetime, out written);
        if (written != request.length) throw new IOError.FAILED ("short WebSocket handshake write");
        yield read_and_validate_handshake (key);
        open_state = true;
      } finally {
        if (connect_timeout != 0) Source.remove (connect_timeout);
      }
    }

    internal void start () {
      if (started || !open_state || failed_state) return;
      started = true;
      if (incoming.len > 0) {
        arm_frame_timeout ();
        try {
          process_frames ();
        } catch (Error error) {
          fail_protocol (error.message);
          return;
        }
      }
      if (!failed_state) read_loop.begin ();
    }

    internal void send_text (string text) {
      if (!is_open) return;
      if (!text.validate ()) {
        fail_protocol ("outgoing Live message is not UTF-8");
        return;
      }
      enqueue_frame (0x1, text.data, false);
    }

    internal void graceful_close (uint16 code, string reason) {
      if (failed_state || !open_state) {
        abort ();
        return;
      }
      if (!valid_close_code (code) || !reason.validate () || reason.length > 123) {
        abort ();
        return;
      }
      closing_state = true;
      clear_outgoing ();
      var payload = new ByteArray ();
      payload.append ({ (uint8) ((code >> 8) & 0xff), (uint8) (code & 0xff) });
      if (reason.length > 0) payload.append (reason.data);
      enqueue_frame (0x8, payload.data, true, null);
      arm_close_timeout ();
    }

    internal void abort () {
      if (failed_state) return;
      failed_state = true;
      shutdown_stream ();
    }

    private async void read_and_validate_handshake (string expected_key) throws Error {
      uint8[] chunk = new uint8[2048];
      int boundary = -1;
      while (boundary < 0) {
        ssize_t received = yield input.read_async (chunk, Priority.DEFAULT, lifetime);
        if (received == 0) throw new IOError.CLOSED ("peer closed during WebSocket handshake");
        incoming.append (chunk[0 : (int) received]);
        boundary = header_boundary (incoming);
        if (boundary < 0 && incoming.len > MAX_HEADER_BYTES) {
          throw new ClientError.PROTOCOL ("WebSocket handshake headers exceed 16 KiB");
        }
      }
      if ((size_t) boundary > MAX_HEADER_BYTES) {
        throw new ClientError.PROTOCOL ("WebSocket handshake headers exceed 16 KiB");
      }
      uint8[] header_bytes = new uint8[boundary + 1];
      for (int index = 0; index < boundary; index++) header_bytes[index] = incoming.data[index];
      string header_text = (string) header_bytes;
      incoming.remove_range (0, (uint) boundary + 4);
      validate_handshake (header_text, websocket_accept (expected_key));
    }

    private int header_boundary (ByteArray bytes) {
      if (bytes.len < 4) return -1;
      for (uint index = 0; index + 3 < bytes.len; index++) {
        if (bytes.data[index] == '\r' && bytes.data[index + 1] == '\n' &&
            bytes.data[index + 2] == '\r' && bytes.data[index + 3] == '\n') return (int) index;
      }
      return -1;
    }

    private void validate_handshake (string response, string expected_accept) throws ClientError {
      string[] lines = response.split ("\r\n");
      if (lines.length == 0 || !lines[0].has_prefix ("HTTP/1.1 ")) {
        throw new ClientError.PROTOCOL ("invalid WebSocket HTTP status line");
      }
      string[] status_parts = lines[0].split (" ");
      if (status_parts.length < 2 || status_parts[1] != "101") {
        throw new ClientError.TRANSPORT ("WebSocket upgrade HTTP status is not 101");
      }
      bool saw_upgrade = false;
      bool saw_connection = false;
      int accept_count = 0;
      string? accept = null;
      for (int index = 1; index < lines.length; index++) {
        string line = lines[index];
        int separator = line.index_of (":");
        if (separator <= 0) throw new ClientError.PROTOCOL ("malformed WebSocket response header");
        string name = line.substring (0, separator).strip ().down ();
        string value = line.substring (separator + 1).strip ();
        if (name == "upgrade") saw_upgrade = has_token (value, "websocket");
        else if (name == "connection") saw_connection = has_token (value, "upgrade");
        else if (name == "sec-websocket-accept") { accept_count++; accept = value; }
        else if (name == "sec-websocket-extensions" || name == "sec-websocket-protocol") {
          throw new ClientError.PROTOCOL ("server selected an unrequested WebSocket extension or protocol");
        }
      }
      if (!saw_upgrade || !saw_connection || accept_count != 1 || accept != expected_accept) {
        throw new ClientError.PROTOCOL ("invalid WebSocket upgrade response");
      }
    }

    private bool has_token (string value, string expected) {
      foreach (var token in value.split (",")) if (token.strip ().down () == expected) return true;
      return false;
    }

    private string websocket_accept (string key) {
      var checksum = new Checksum (ChecksumType.SHA1);
      string source = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
      checksum.update (source.data, source.length);
      uint8[] digest = new uint8[20];
      size_t length = digest.length;
      checksum.get_digest (digest, ref length);
      return Base64.encode (digest);
    }

    private uint8[] random_bytes (int length) throws Error {
      uint8[] bytes = new uint8[length];
      size_t received = 0;
      if (entropy == null || !entropy.read_all (bytes, out received, lifetime) || received != bytes.length) {
        throw new IOError.FAILED ("could not read WebSocket entropy");
      }
      return bytes;
    }

    private async void read_loop () {
      uint8[] chunk = new uint8[8192];
      try {
        while (!failed_state && open_state) {
          ssize_t received = yield input.read_async (chunk, Priority.DEFAULT, lifetime);
          if (received == 0) throw new IOError.CLOSED ("Live peer closed the transport");
          if (incoming.len == 0) arm_frame_timeout ();
          incoming.append (chunk[0 : (int) received]);
          process_frames ();
        }
      } catch (Error error) {
        if (!failed_state) {
          // Once the upgrade is complete, malformed RFC6455 bytes are still
          // protocol failures. Keep them distinct from socket and TLS errors
          // so the adapter can serialize the right structured error.
          if (error is ClientError.PROTOCOL) fail_protocol (error.message);
          else fail_transport (error.message);
        }
      }
    }

    private void process_frames () throws Error {
      while (!failed_state) {
        if (incoming.len < 2) return;
        uint8 first = incoming.data[0];
        uint8 second = incoming.data[1];
        if ((first & 0x70) != 0) throw new ClientError.PROTOCOL ("Live frame used unsupported RSV bits");
        bool fin = (first & 0x80) != 0;
        uint8 opcode = first & 0x0f;
        bool control = (opcode & 0x08) != 0;
        if ((second & 0x80) != 0) throw new ClientError.PROTOCOL ("server Live frame was masked");
        uint64 payload_length = second & 0x7f;
        uint header_length = 2;
        if (payload_length == 126) {
          if (incoming.len < 4) return;
          payload_length = ((uint64) incoming.data[2] << 8) | incoming.data[3];
          header_length = 4;
          if (payload_length < 126) throw new ClientError.PROTOCOL ("non-canonical Live frame length");
        } else if (payload_length == 127) {
          if (incoming.len < 10) return;
          if ((incoming.data[2] & 0x80) != 0) throw new ClientError.PROTOCOL ("invalid 64-bit Live frame length");
          payload_length = 0;
          for (int index = 2; index < 10; index++) payload_length = (payload_length << 8) | incoming.data[index];
          header_length = 10;
          if (payload_length <= uint16.MAX) throw new ClientError.PROTOCOL ("non-canonical Live frame length");
        }
        if (control && (!fin || payload_length > 125)) throw new ClientError.PROTOCOL ("invalid Live control frame");
        if (payload_length > MAX_PAYLOAD_BYTES) throw new ClientError.PROTOCOL ("Live frame exceeds 2 MiB");
        if ((uint64) incoming.len < (uint64) header_length + payload_length) return;
        uint8[] payload = new uint8[(int) payload_length];
        for (int index = 0; index < payload.length; index++) payload[index] = incoming.data[header_length + index];
        incoming.remove_range (0, header_length + (uint) payload_length);
        clear_frame_timeout ();
        handle_frame (fin, opcode, payload);
        if (failed_state) return;
        if (incoming.len > 0) arm_frame_timeout ();
      }
    }

    private void handle_frame (bool fin, uint8 opcode, uint8[] payload) throws Error {
      if (opcode == 0x0) {
        if (fragmented_opcode == 0) throw new ClientError.PROTOCOL ("unexpected Live continuation frame");
        append_fragment (payload);
        if (fin) {
          uint8 complete_opcode = fragmented_opcode;
          fragmented_opcode = 0;
          uint8[] complete = new uint8[fragmented_message.len];
          for (int index = 0; index < complete.length; index++) complete[index] = fragmented_message.data[index];
          fragmented_message.set_size (0);
          deliver_data (complete_opcode, complete);
        }
      } else if (opcode == 0x1 || opcode == 0x2) {
        if (fragmented_opcode != 0) throw new ClientError.PROTOCOL ("new Live data frame interrupted a fragmented message");
        if (fin) deliver_data (opcode, payload);
        else {
          fragmented_opcode = opcode;
          fragmented_message.set_size (0);
          append_fragment (payload);
        }
      } else if (opcode == 0x8) {
        handle_close_frame (payload);
      } else if (opcode == 0x9) {
        enqueue_frame (0xa, payload, false);
      } else if (opcode == 0xa) {
        // Pong is useful liveness traffic but does not alter parser deadlines.
      } else {
        throw new ClientError.PROTOCOL ("unknown Live frame opcode");
      }
    }

    private void append_fragment (uint8[] payload) throws ClientError {
      if ((size_t) payload.length > MAX_PAYLOAD_BYTES - fragmented_message.len) {
        throw new ClientError.PROTOCOL ("fragmented Live message exceeds 2 MiB");
      }
      fragmented_message.append (payload);
    }

    private void deliver_data (uint8 opcode, uint8[] payload) throws ClientError {
      if (opcode != 0x1) throw new ClientError.PROTOCOL ("binary Live message is unsupported");
      uint8[] terminated = new uint8[payload.length + 1];
      for (int index = 0; index < payload.length; index++) terminated[index] = payload[index];
      string text = (string) terminated;
      if (!text.validate ((ssize_t) payload.length)) throw new ClientError.PROTOCOL ("Live text message is not valid UTF-8");
      text_message (text);
    }

    private void handle_close_frame (uint8[] payload) throws ClientError {
      if (payload.length == 1) throw new ClientError.PROTOCOL ("invalid Live close payload");
      uint16 code = 1000;
      string reason = "peer closed";
      if (payload.length >= 2) {
        code = (uint16) (((uint16) payload[0] << 8) | payload[1]);
        if (!valid_close_code (code)) throw new ClientError.PROTOCOL ("invalid Live close code");
        uint8[] reason_bytes = new uint8[payload.length - 2];
        for (int index = 2; index < payload.length; index++) reason_bytes[index - 2] = payload[index];
        uint8[] terminated = new uint8[reason_bytes.length + 1];
        for (int index = 0; index < reason_bytes.length; index++) terminated[index] = reason_bytes[index];
        reason = (string) terminated;
        if (!reason.validate ((ssize_t) reason_bytes.length)) throw new ClientError.PROTOCOL ("Live close reason is not valid UTF-8");
      }
      closing_state = true;
      clear_outgoing ();
      string close_reason = "WebSocket close " + code.to_string () + (reason.length > 0 ? ": " + reason : "");
      enqueue_frame (0x8, payload.length == 0 ? new uint8[0] : payload, true, close_reason);
      arm_close_timeout ();
    }

    private bool valid_close_code (uint16 code) {
      if (code < 1000 || code >= 5000) return false;
      if (code == 1004 || code == 1005 || code == 1006 || code == 1015) return false;
      return code < 1016 || code >= 3000;
    }

    private void enqueue_frame (uint8 opcode, uint8[] payload, bool close_after, string? peer_close_reason = null) {
      if (failed_state || !open_state || (closing_state && opcode != 0x8 && opcode != 0xa)) return;
      try {
        var encoded = encode_client_frame (opcode, payload);
        if (reserved_write_count >= MAX_QUEUED_WRITES ||
            encoded.length > MAX_QUEUED_WRITE_BYTES - reserved_write_bytes) {
          fail_transport ("Live write queue exceeded its bounded budget");
          return;
        }
        outgoing.offer (new OutgoingFrame (encoded, close_after, peer_close_reason));
        reserved_write_count++;
        reserved_write_bytes += encoded.length;
        if (!writing) drain_writes.begin ();
      } catch (Error error) {
        fail_transport (error.message);
      }
    }

    private uint8[] encode_client_frame (uint8 opcode, uint8[] payload) throws Error {
      if (payload.length > MAX_PAYLOAD_BYTES) throw new ClientError.PROTOCOL ("outgoing Live frame exceeds 2 MiB");
      var frame = new ByteArray ();
      frame.append ({ (uint8) (0x80 | opcode) });
      if (payload.length < 126) {
        frame.append ({ (uint8) (0x80 | payload.length) });
      } else if (payload.length <= uint16.MAX) {
        frame.append ({ 0xfe, (uint8) ((payload.length >> 8) & 0xff), (uint8) (payload.length & 0xff) });
      } else {
        frame.append ({ 0xff });
        uint64 length = payload.length;
        uint8[] extended = new uint8[8];
        for (int index = 7; index >= 0; index--) { extended[index] = (uint8) (length & 0xff); length >>= 8; }
        frame.append (extended);
      }
      uint8[] mask = random_bytes (4);
      frame.append (mask);
      uint8[] masked = new uint8[payload.length];
      for (int index = 0; index < payload.length; index++) masked[index] = payload[index] ^ mask[index % 4];
      frame.append (masked);
      uint8[] answer = new uint8[frame.len];
      for (int index = 0; index < answer.length; index++) answer[index] = frame.data[index];
      return answer;
    }

    private async void drain_writes () {
      if (writing || failed_state) return;
      writing = true;
      try {
        while (!outgoing.is_empty && !failed_state) {
          var next = outgoing.poll ();
          arm_write_timeout ();
          size_t written = 0;
          yield output.write_all_async (next.bytes, Priority.DEFAULT, lifetime, out written);
          clear_write_timeout ();
          if (written != next.bytes.length) throw new IOError.FAILED ("short Live frame write");
          if (reserved_write_count > 0) reserved_write_count--;
          if (reserved_write_bytes >= next.bytes.length) reserved_write_bytes -= next.bytes.length;
          if (next.close_after) {
            string? reason = next.peer_close_reason;
            shutdown_stream ();
            if (reason != null) peer_closed (reason);
            break;
          }
        }
      } catch (Error error) {
        clear_write_timeout ();
        if (!failed_state) fail_transport (error.message);
      }
      writing = false;
    }

    private void clear_outgoing () {
      outgoing.clear ();
      reserved_write_count = 0;
      reserved_write_bytes = 0;
    }

    private void arm_frame_timeout () {
      if (frame_timeout_source != 0 || incoming.len == 0 || failed_state) return;
      frame_timeout_source = Timeout.add (FRAME_TIMEOUT_MS, () => {
        frame_timeout_source = 0;
        fail_transport ("Live frame timed out");
        return false;
      });
    }

    private void clear_frame_timeout () {
      if (frame_timeout_source != 0) Source.remove (frame_timeout_source);
      frame_timeout_source = 0;
    }

    private void arm_write_timeout () {
      clear_write_timeout ();
      write_timeout_source = Timeout.add (WRITE_TIMEOUT_MS, () => {
        write_timeout_source = 0;
        fail_transport ("Live frame write timed out");
        return false;
      });
    }

    private void clear_write_timeout () {
      if (write_timeout_source != 0) Source.remove (write_timeout_source);
      write_timeout_source = 0;
    }

    private void arm_close_timeout () {
      if (close_timeout_source != 0) return;
      close_timeout_source = Timeout.add (CLOSE_TIMEOUT_MS, () => {
        close_timeout_source = 0;
        fail_transport ("Live close handshake timed out");
        return false;
      });
    }

    private void fail_transport (string message) {
      if (failed_state) return;
      failed_state = true;
      shutdown_stream ();
      transport_failed (message);
    }

    private void fail_protocol (string message) {
      if (failed_state) return;
      failed_state = true;
      shutdown_stream ();
      protocol_failed (message);
    }

    private void shutdown_stream () {
      open_state = false;
      clear_frame_timeout ();
      clear_write_timeout ();
      if (close_timeout_source != 0) Source.remove (close_timeout_source);
      close_timeout_source = 0;
      clear_outgoing ();
      lifetime.cancel ();
      if (stream != null) stream.close_async.begin (Priority.DEFAULT, null);
      stream = null;
      input = null;
      output = null;
      entropy = null;
    }
  }

  internal class OutgoingFrame : GLib.Object {
    internal uint8[] bytes;
    internal bool close_after;
    internal string? peer_close_reason;

    internal OutgoingFrame (uint8[] bytes, bool close_after, string? peer_close_reason) {
      this.bytes = bytes;
      this.close_after = close_after;
      this.peer_close_reason = peer_close_reason;
    }
  }
}
