// ws_smoke.v - gate proof: a real RFC 6455 WebSocket handshake against a
// fixture peer (verilog/Dockerfile's wsfix.c), then a genuine masked,
// fragmented, control-frame-interleaved message round trip and a clean
// close - proving client/convex_websocket.v's framing, masking,
// fragmentation reassembly, control-frame handling and one-shot (post-
// reassembly) UTF-8 validation all work end to end against a real TCP
// peer, not merely that they compile.
//
// wsfix.c plays "server": it answers the handshake with a correctly
// computed Sec-WebSocket-Accept, sends the test message as two TEXT
// fragments split in the middle of a 3-byte UTF-8 codepoint (U+20AC,
// the euro sign) so a per-fragment validator would wrongly reject the
// dangling first fragment, sends a PING between those two fragments
// (control frames may legally interleave a fragmented message per
// RFC 6455 SS5.4) and itself checks the client's PONG arrived masked
// and echoed the PING's exact payload, then sends a CLOSE and checks
// the client answered with its own masked CLOSE - see wsfix.c's own
// comments for the exact byte layout.

`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"

module ws_smoke;

  // OP_TEXT's value (1) is convex_websocket.v's own localparam; this
  // test compares against the literal, the same convention
  // client/tests/http_smoke.v uses for convex_buffer.v's KIND_OBJECT.
  localparam OP_TEXT = 1;

  convex_websocket #(.FRAME_CAP(4096), .MSG_CAP(4096)) ws ();

  bit ok;
  integer failed;
  integer i;
  reg [7:0] expected [0:10];
  reg [7:0] got;

  initial begin
    failed = 0;

    // "ok:" + E2 82 AC (U+20AC, euro sign, UTF-8) + ":done" - the exact
    // 12 bytes wsfix.c sends split across its two fragments.
    expected[0]="o";  expected[1]="k";  expected[2]=":";
    expected[3]=8'hE2; expected[4]=8'h82; expected[5]=8'hAC;
    expected[6]=":";  expected[7]="d";  expected[8]="o";
    expected[9]="n";  expected[10]="e";

    ws.connect("ws://127.0.0.1:44202", "/", ok);
    if (!ok) begin
      $display("FAIL ws_smoke: handshake failed (connect/upgrade, or Sec-WebSocket-Accept did not verify)");
      $finish;
    end
    $display("ws_smoke: handshake OK, Sec-WebSocket-Accept verified against a locally computed SHA-1+base64");

    ws.receive_message(ok);
    if (!ok) begin
      $display("FAIL ws_smoke: receive_message failed (fragmentation reassembly or interleaved control frame)");
      $finish;
    end

    if (ws.message_opcode() != OP_TEXT) begin
      $display("FAIL ws_smoke: reassembled message opcode was %0d, expected TEXT (1)", ws.message_opcode());
      failed = 1;
    end

    if (ws.msg.length() != 11) begin
      $display("FAIL ws_smoke: reassembled message was %0d bytes, expected 11", ws.msg.length());
      failed = 1;
    end else begin
      for (i = 0; i < 11; i = i + 1) begin
        got = ws.msg.get_byte(i);
        if (got != expected[i]) begin
          $display("FAIL ws_smoke: reassembled byte %0d was %0d, expected %0d", i, got, expected[i]);
          failed = 1;
        end
      end
    end

    if (!ws.message_utf8_ok()) begin
      $display("FAIL ws_smoke: message did not validate as UTF-8 (the split codepoint is well-formed once whole)");
      failed = 1;
    end else begin
      $display("ws_smoke: fragmentation reassembly OK (a split UTF-8 codepoint validated correctly once whole)");
    end

    // wsfix.c already asserted, on its own side, that the PONG this
    // client sent in response to its interleaved PING was masked and
    // echoed the exact PING payload (see its own stderr output,
    // captured separately by the Dockerfile stage) - receive_message
    // succeeding at all here is only possible if that round trip
    // actually completed, since read_frame blocks for it in-line.
    $display("ws_smoke: interleaved PING/PONG handled without disturbing fragmentation reassembly");

    // wsfix.c now sends a CLOSE; receive_message returns ok=0 with
    // close_received set for that case (a close is not a data message).
    ws.receive_message(ok);
    if (!ws.close_received) begin
      $display("FAIL ws_smoke: expected a CLOSE frame from the fixture, close_received was not set");
      failed = 1;
    end else begin
      $display("ws_smoke: received CLOSE, answered with our own masked CLOSE frame");
    end

    ws.close;

    if (failed == 0) begin
      $display("PASS ws_smoke");
    end else begin
      $display("FAIL ws_smoke");
    end
    $finish;
  end

endmodule
