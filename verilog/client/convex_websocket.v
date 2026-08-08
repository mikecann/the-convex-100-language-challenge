// convex_websocket.v - RFC 6455 WebSocket framing on top of
// convex_http.v's connection/request machinery (the handshake IS an
// HTTP/1.1 request with an Upgrade header, so this module embeds one
// `convex_http` instance and reuses its request building, its
// status-line/header parsing, and its already-proven TCP/TLS
// connection - see hs.transport, reached hierarchically below exactly
// the way convex_http.v itself reaches its own req/resp_headers/
// resp_body sub-buffers) and convex_sha1.v/convex_base64.v (the
// Sec-WebSocket-Accept check).
//
// Everything below the handshake is raw frame bytes, not HTTP, so it is
// driven straight through `hs.transport.xport_call` with `hs.handle`,
// the same connection the handshake itself was read over - a WebSocket
// upgrade reuses one TCP/TLS connection for both halves, it does not
// open a second one.
`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"
`include "client/convex_chars.vh"

module convex_websocket #(
  parameter REQ_CAP    = 4096,
  parameter HEADER_CAP = 4096,
  parameter FRAME_CAP  = 65536,
  parameter MSG_CAP    = 1048576,
  parameter TIMEOUT_MS = 15000
);

  // Opcodes (RFC 6455 SS5.2). Redeclared here as this module's own
  // localparams rather than shared macros, the same "a localparam is
  // not meant to be a public constant, so a caller/test hardcodes the
  // literal with a comment" convention client/tests/http_smoke.v and
  // client/tests/json_test.v already use for convex_buffer.v's KIND_*
  // constants.
  localparam OP_CONTINUATION = 0;
  localparam OP_TEXT         = 1;
  localparam OP_BINARY       = 2;
  localparam OP_CLOSE        = 8;
  localparam OP_PING         = 9;
  localparam OP_PONG         = 10;

  convex_http   #(.REQ_CAP(REQ_CAP), .HEADER_CAP(HEADER_CAP), .BODY_CAP(64)) hs ();
  convex_sha1   #(.MAXLEN(256)) sha1 ();
  convex_base64 #(.MAXLEN(64))  b64 ();

  // Caller fills this before calling send_frame; send_frame masks and
  // writes it, then leaves it as-is (it does not reset its own input).
  convex_buffer #(.MAXLEN(FRAME_CAP)) send_payload ();
  // One raw frame's unmasked payload, refilled by every read_frame call.
  convex_buffer #(.MAXLEN(FRAME_CAP)) recv_frame ();
  // The fully reassembled message a caller reads after receive_message.
  convex_buffer #(.MAXLEN(MSG_CAP)) msg ();

  // === handshake-only scratch, module-level per the self-referential-
  // concatenation-loop rule (see convex_http.v's own header comment):
  // ws_key is built by looping `{ws_key_scratch, c}`, which must target
  // module state, not a task-local or output-port `string`, or Icarus
  // 11.0 aborts at run time (vthread.cc:212). =====================
  string ws_key_scratch;
  string ws_key;
  string ws_accept_header;
  string ws_guid;

  integer msg_opcode;
  bit     msg_utf8_ok;
  bit     close_received;
  reg [7:0] close_recv_code_bytes [0:1];
  integer close_recv_len;

  reg fin_reg;
  integer opcode_reg;
  bit masked_reg;

  // The native.c CMD_READ_BYTE result (see native.c's handle_read_byte:
  // -1 timeout, -2 clean close, -3 transport error) from the very first
  // byte read_frame attempted this call, captured before any header is
  // interpreted. convex_sync.v's poll loop reads this after a failed
  // read_frame/receive_message to tell "nothing arrived yet, the
  // connection is still fine" (-1, with zero bytes of this frame
  // consumed) apart from every other failure, which it treats as a
  // dead connection needing a reconnect - the same "timeout is
  // recoverable, everything else abandons the connection" rule
  // AGENTS.md's Live-acceptance section describes, applied at the one
  // point in a frame where recovering costs nothing because no partial
  // frame bytes have been consumed from the transport yet.
  integer last_read_error;

  // read_frame's own per-byte read deadline, separate from TIMEOUT_MS
  // (which stays the handshake's deadline, in hs.read_response above).
  // Defaults to TIMEOUT_MS but is independently adjustable via
  // set_frame_timeout_ms below - convex_sync.v's poll loop needs a much
  // shorter deadline than a one-off handshake ever would, without
  // changing read_frame's own signature (so every already-proven caller
  // - ws_smoke.v included - is unaffected and keeps TIMEOUT_MS's
  // default behavior unless it opts in).
  integer frame_timeout_ms;

  task automatic set_frame_timeout_ms(input integer t);
    begin
      frame_timeout_ms = t;
    end
  endtask

  initial begin
    ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    msg_opcode = -1;
    msg_utf8_ok = 1'b0;
    close_received = 1'b0;
    last_read_error = 0;
    frame_timeout_ms = TIMEOUT_MS;
  end

  function automatic integer message_opcode;
    return msg_opcode;
  endfunction

  function automatic bit message_utf8_ok;
    return msg_utf8_ok;
  endfunction

  // === UTF-8 validation, run exactly once by receive_message below, ===
  // over the FULLY reassembled `msg` buffer - never per fragment. Every
  // multi-byte form's leading byte, continuation-byte shape, overlong
  // encoding and (for 3-byte forms) UTF-16 surrogate range is checked;
  // `c`/`c2` are plain unsigned `reg [7:0]`, not `byte`, specifically so
  // a raw value >= 0x80 compares correctly instead of sign-extending.
  function automatic bit utf8_valid(input integer n);
    integer i;
    reg [7:0] c, c2;
    bit bad;
    begin
      i = 0;
      bad = 1'b0;
      while (i < n && !bad) begin
        c = msg.get_byte(i);
        if (c < 8'h80) begin
          i = i + 1;
        end else if ((c & 8'hE0) == 8'hC0) begin
          if (c < 8'hC2) begin
            bad = 1'b1; // overlong 2-byte form
          end else if (i + 1 >= n) begin
            bad = 1'b1;
          end else begin
            c2 = msg.get_byte(i+1);
            if ((c2 & 8'hC0) != 8'h80) bad = 1'b1;
            else i = i + 2;
          end
        end else if ((c & 8'hF0) == 8'hE0) begin
          if (i + 2 >= n) begin
            bad = 1'b1;
          end else begin
            c2 = msg.get_byte(i+1);
            if ((c2 & 8'hC0) != 8'h80) bad = 1'b1;
            else if (c == 8'hE0 && c2 < 8'hA0) bad = 1'b1;      // overlong 3-byte
            else if (c == 8'hED && c2 >= 8'hA0) bad = 1'b1;     // UTF-16 surrogate half
            else if ((msg.get_byte(i+2) & 8'hC0) != 8'h80) bad = 1'b1;
            else i = i + 3;
          end
        end else if ((c & 8'hF8) == 8'hF0) begin
          if (i + 3 >= n) begin
            bad = 1'b1;
          end else begin
            c2 = msg.get_byte(i+1);
            if (c > 8'hF4) bad = 1'b1;
            else if ((c2 & 8'hC0) != 8'h80) bad = 1'b1;
            else if (c == 8'hF0 && c2 < 8'h90) bad = 1'b1;      // overlong 4-byte
            else if (c == 8'hF4 && c2 >= 8'h90) bad = 1'b1;     // codepoint > U+10FFFF
            else if ((msg.get_byte(i+2) & 8'hC0) != 8'h80) bad = 1'b1;
            else if ((msg.get_byte(i+3) & 8'hC0) != 8'h80) bad = 1'b1;
            else i = i + 4;
          end
        end else begin
          bad = 1'b1;
        end
      end
      utf8_valid = !bad;
    end
  endfunction

  // === handshake ========================================================

  // Connects, performs the RFC 6455 Upgrade handshake against `path`,
  // and verifies Sec-WebSocket-Accept against a value this module
  // computes itself from the Sec-WebSocket-Key it sent - a server that
  // skipped hashing the key (or hashed the wrong one) is rejected here,
  // not merely trusted because a 101 status line arrived.
  task automatic connect(input string url, input string path, output bit ok);
    integer i, r;
    bit found, match;
    // Icarus 11.0 aborts at run time (vthread.cc:212, peek_str) when a
    // function call's result is concatenated inline
    // (`{ws_key_scratch, b64.get_byte(i)}`) - the same crash a raw
    // `string[index]` select hits at elaboration time inside a `{...}`.
    // Extracting the byte into this plain local first, exactly as
    // convex_http.v's header_value does for its own hv_scratch loop,
    // avoids it.
    byte kb;
    begin : main
      ok = 1'b0;

      hs.parse_endpoint(url, ok);
      if (!ok) disable main;

      hs.connect(ok);
      if (!ok) disable main;

      // A fresh 16-byte nonce (RFC 6455 SS4.1), base64-encoded, becomes
      // the Sec-WebSocket-Key text; the client picks this value, so
      // CMD_RANDOM_BYTE (native.c) only needs to be unpredictable
      // enough to defeat a caching proxy, per RFC 6455's own rationale.
      b64.reset;
      for (i = 0; i < 16; i = i + 1) begin
        hs.transport.xport_call(`CMD_RANDOM_BYTE, 0, 0, r);
        if (r < 0) disable main;
        b64.put_byte(r[7:0]);
      end
      b64.encode;
      ws_key_scratch = "";
      for (i = 0; i < b64.length(); i = i + 1) begin
        kb = b64.get_byte(i);
        ws_key_scratch = {ws_key_scratch, kb};
      end
      ws_key = ws_key_scratch;

      hs.write_request_line("GET", path);
      hs.write_header("Host", hs.ep_host);
      hs.write_header("Upgrade", "websocket");
      hs.write_header("Connection", "Upgrade");
      hs.write_header("Sec-WebSocket-Key", ws_key);
      hs.write_header("Sec-WebSocket-Version", "13");
      hs.end_headers;

      hs.send_request(ok);
      if (!ok) disable main;

      hs.read_response(TIMEOUT_MS, ok);
      if (!ok) disable main;

      if (hs.status() != 101) begin
        ok = 1'b0;
        disable main;
      end

      hs.header_value("Sec-WebSocket-Accept", ws_accept_header, found);
      if (!found) begin
        ok = 1'b0;
        disable main;
      end

      sha1.reset;
      for (i = 0; i < ws_key.len(); i = i + 1) sha1.put_byte(ws_key[i]);
      for (i = 0; i < ws_guid.len(); i = i + 1) sha1.put_byte(ws_guid[i]);
      sha1.compute;

      b64.reset;
      for (i = 0; i < 20; i = i + 1) b64.put_byte(sha1.get_digest_byte(i));
      b64.encode;

      match = (b64.length() == ws_accept_header.len());
      if (match) begin
        for (i = 0; i < b64.length(); i = i + 1) begin
          if (b64.get_byte(i) != ws_accept_header[i]) match = 1'b0;
        end
      end
      ok = match;
    end
  endtask

  // === frame I/O =========================================================
  //
  // recv_fin/recv_opcode/recv_masked describe the frame read_frame most
  // recently placed into `recv_frame`.
  function automatic bit recv_fin;
    return fin_reg;
  endfunction
  function automatic integer recv_opcode;
    return opcode_reg;
  endfunction

  // Reads exactly one frame from the peer into recv_frame. Fails (ok=0)
  // on a timeout, a transport error, an oversized payload, or a MASKED
  // frame from the server - RFC 6455 SS5.1 forbids a server from ever
  // masking, so that is a protocol violation, not something to tolerate.
  task automatic read_frame(output bit ok);
    integer r;
    reg [7:0] hb0, hb1;
    reg [15:0] ext16;
    reg [63:0] ext64;
    integer plen;
    integer i;
    begin : main
      ok = 1'b0;
      recv_frame.reset;

      hs.transport.xport_call(`CMD_READ_BYTE, hs.handle, frame_timeout_ms, r);
      last_read_error = r; // whatever it is, before any header is parsed
      if (r < 0) disable main;
      hb0 = r;
      hs.transport.xport_call(`CMD_READ_BYTE, hs.handle, frame_timeout_ms, r);
      if (r < 0) disable main;
      hb1 = r;

      fin_reg    = hb0[7];
      opcode_reg = hb0[3:0];
      masked_reg = hb1[7];
      if (masked_reg) disable main; // server MUST NOT mask (RFC 6455 SS5.1)

      if (hb1[6:0] == 7'd126) begin
        hs.transport.xport_call(`CMD_READ_BYTE, hs.handle, frame_timeout_ms, r);
        if (r < 0) disable main;
        ext16[15:8] = r;
        hs.transport.xport_call(`CMD_READ_BYTE, hs.handle, frame_timeout_ms, r);
        if (r < 0) disable main;
        ext16[7:0] = r;
        plen = ext16;
      end else if (hb1[6:0] == 7'd127) begin
        ext64 = 64'd0;
        for (i = 0; i < 8; i = i + 1) begin
          hs.transport.xport_call(`CMD_READ_BYTE, hs.handle, frame_timeout_ms, r);
          if (r < 0) disable main;
          ext64 = (ext64 << 8) | r;
        end
        if (ext64 > FRAME_CAP) disable main;
        plen = ext64;
      end else begin
        plen = hb1[6:0];
      end

      if (plen > FRAME_CAP) disable main;

      for (i = 0; i < plen; i = i + 1) begin
        hs.transport.xport_call(`CMD_READ_BYTE, hs.handle, frame_timeout_ms, r);
        if (r < 0) disable main;
        recv_frame.put_byte(r[7:0]);
      end
      if (recv_frame.overflow) disable main;

      ok = 1'b1;
    end
  endtask

  // Masks and sends send_payload's current bytes as one frame (RFC 6455
  // SS5.3: every client-to-server frame MUST be masked with a fresh,
  // unpredictable 32-bit key - generated here per frame, never reused).
  task automatic send_frame(input bit fin, input integer opcode, output bit ok);
    integer i, r, mb;
    reg [3:0] opcode4;
    reg [31:0] plen;
    reg [7:0] b0, b1;
    reg [7:0] mkey [0:3];
    reg [7:0] pb, xb;
    begin : main
      ok = 1'b0;
      opcode4 = opcode;
      plen = send_payload.length();
      if (plen > 32'd65535) disable main; // 64-bit length form not needed by this client

      b0 = {fin, 3'b000, opcode4};
      hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, b0, r);
      if (r < 0) disable main;

      if (plen < 32'd126) begin
        b1 = {1'b1, plen[6:0]};
        hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, b1, r);
        if (r < 0) disable main;
      end else begin
        b1 = {1'b1, 7'd126};
        hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, b1, r);
        if (r < 0) disable main;
        hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, plen[15:8], r);
        if (r < 0) disable main;
        hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, plen[7:0], r);
        if (r < 0) disable main;
      end

      for (i = 0; i < 4; i = i + 1) begin
        hs.transport.xport_call(`CMD_RANDOM_BYTE, 0, 0, mb);
        if (mb < 0) disable main;
        mkey[i] = mb[7:0];
        hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, mkey[i], r);
        if (r < 0) disable main;
      end

      for (i = 0; i < plen; i = i + 1) begin
        pb = send_payload.get_byte(i);
        xb = pb ^ mkey[i % 4];
        hs.transport.xport_call(`CMD_WRITE_BYTE, hs.handle, xb, r);
        if (r < 0) disable main;
      end

      hs.transport.xport_call(`CMD_WRITE_FLUSH, hs.handle, 0, r);
      ok = (r >= 0);
    end
  endtask

  // === message-level: fragmentation reassembly + control-frame ========
  // interleaving. A control frame (ping/pong/close) is never itself
  // fragmented and may legally arrive between the fragments of another
  // message (RFC 6455 SS5.4); this loop answers one immediately without
  // disturbing `msg`, whether or not a data message is mid-reassembly.
  task automatic receive_message(output bit ok);
    bit fok;
    bit looping, first;
    integer i;
    reg [7:0] pb;
    begin : main
      ok = 1'b0;
      msg.reset;
      msg_opcode = -1;
      msg_utf8_ok = 1'b0;
      first = 1'b1;
      looping = 1'b1;

      while (looping) begin
        read_frame(fok);
        if (!fok) disable main;

        if (opcode_reg == OP_PING) begin
          send_payload.reset;
          for (i = 0; i < recv_frame.length(); i = i + 1) begin
            pb = recv_frame.get_byte(i);
            send_payload.put_byte(pb);
          end
          send_frame(1'b1, OP_PONG, fok);
          if (!fok) disable main;

        end else if (opcode_reg == OP_PONG) begin
          // Unsolicited pong: accepted and ignored (RFC 6455 SS5.5.3).

        end else if (opcode_reg == OP_CLOSE) begin
          close_received = 1'b1;
          close_recv_len = recv_frame.length();
          if (close_recv_len >= 2) begin
            close_recv_code_bytes[0] = recv_frame.get_byte(0);
            close_recv_code_bytes[1] = recv_frame.get_byte(1);
          end
          // "the endpoint MUST send a Close frame in response"
          // (RFC 6455 SS5.5.1), echoing the peer's own status code when
          // it sent one so this does not invent disagreement about why
          // the connection is closing.
          send_payload.reset;
          if (close_recv_len >= 2) begin
            send_payload.put_byte(close_recv_code_bytes[0]);
            send_payload.put_byte(close_recv_code_bytes[1]);
          end else begin
            send_payload.put_byte(8'h03);
            send_payload.put_byte(8'hE8); // 1000, normal closure
          end
          send_frame(1'b1, OP_CLOSE, fok);
          ok = 1'b0; // a close is not a data message; caller checks close_received
          disable main;

        end else if (opcode_reg == OP_CONTINUATION) begin
          if (first) disable main; // continuation with nothing open: protocol error
          for (i = 0; i < recv_frame.length(); i = i + 1) begin
            pb = recv_frame.get_byte(i);
            msg.put_byte(pb);
          end
          if (msg.overflow) disable main;
          if (fin_reg) looping = 1'b0;

        end else begin
          // A new message's first frame (TEXT or BINARY).
          if (!first) disable main; // a second new message before the first finished
          first = 1'b0;
          msg_opcode = opcode_reg;
          for (i = 0; i < recv_frame.length(); i = i + 1) begin
            pb = recv_frame.get_byte(i);
            msg.put_byte(pb);
          end
          if (msg.overflow) disable main;
          if (fin_reg) looping = 1'b0;
        end
      end

      // Validated exactly once, over the fully reassembled message -
      // never per fragment - so a multi-byte codepoint legally split
      // across a fragment boundary is judged by its complete bytes.
      if (msg_opcode == OP_TEXT) msg_utf8_ok = utf8_valid(msg.length());
      else msg_utf8_ok = 1'b1; // binary: no UTF-8 requirement

      ok = 1'b1;
    end
  endtask

  // Client-initiated close: send a Close frame, then wait (bounded by
  // TIMEOUT_MS inside read_frame) for the peer's own Close frame.
  task automatic initiate_close(input integer code, output bit ok);
    reg [15:0] code16;
    bit fok;
    begin : main
      ok = 1'b0;
      code16 = code;
      send_payload.reset;
      send_payload.put_byte(code16[15:8]);
      send_payload.put_byte(code16[7:0]);
      send_frame(1'b1, OP_CLOSE, fok);
      if (!fok) disable main;
      read_frame(fok);
      ok = fok && (opcode_reg == OP_CLOSE);
    end
  endtask

  task automatic close;
    begin
      hs.close;
    end
  endtask

endmodule
