// tcp_smoke.v - gate proof (a): a real TCP connection driven from
// Verilog through the VPI boundary in client/native.c.
//
// This is test infrastructure for the toolchain gate, not part of the
// public client. It connects to a one-shot fixture TCP server (see
// verilog/Dockerfile's tcpfix.c, started before this program runs),
// writes a known request one byte at a time through
// transport.xport_call(CMD_WRITE_BYTE, ...), flushes it with a real
// write(2) via CMD_WRITE_FLUSH, then reads the fixture's canned reply
// back one byte at a time through CMD_READ_BYTE and checks it matches
// exactly. Every byte crosses the clocked req/ack bus in
// convex_transport.v; nothing here calls $cx_dispatch directly.

`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"

module tcp_smoke;

  convex_transport transport ();

  reg signed [31:0] result;
  integer i;
  integer handle;
  integer failed;

  // The exact bytes tcpfix.c expects to read before it replies, and the
  // exact bytes it replies with. Kept identical to the Dockerfile stage
  // that starts tcpfix so a change to one without the other fails loudly
  // instead of silently passing against a stale fixture.
  reg [7:0] request  [0:12];
  reg [7:0] expected [0:20];

  initial begin
    request[0]  = "P";
    request[1]  = "I";
    request[2]  = "N";
    request[3]  = "G";
    request[4]  = " ";
    request[5]  = "v";
    request[6]  = "e";
    request[7]  = "r";
    request[8]  = "i";
    request[9]  = "l";
    request[10] = "o";
    request[11] = "g";
    request[12] = "\n";

    expected[0]  = "P";
    expected[1]  = "O";
    expected[2]  = "N";
    expected[3]  = "G";
    expected[4]  = " ";
    expected[5]  = "f";
    expected[6]  = "i";
    expected[7]  = "x";
    expected[8]  = "t";
    expected[9]  = "u";
    expected[10] = "r";
    expected[11] = "e";
    expected[12] = "\n";

    failed = 0;

    // Point native.c's host accumulator at the fixture's loopback address.
    transport.xport_call(`CMD_HOST_RESET, 0, 0, result);
    transport.xport_call(`CMD_HOST_PUSH, "1", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, "2", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, "7", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, ".", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, "0", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, ".", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, "0", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, ".", 0, result);
    transport.xport_call(`CMD_HOST_PUSH, "1", 0, result);

    // Plain TCP: a0=port, a1=0 (use_tls=0).
    transport.xport_call(`CMD_CONNECT, 44201, 0, result);
    handle = result;
    if (handle < 0) begin
      $display("FAIL tcp_smoke: connect returned %0d", handle);
      $finish;
    end

    for (i = 0; i <= 12; i = i + 1) begin
      transport.xport_call(`CMD_WRITE_BYTE, handle, request[i], result);
      if (result < 0) begin
        $display("FAIL tcp_smoke: write_byte %0d returned %0d", i, result);
        failed = 1;
      end
    end
    transport.xport_call(`CMD_WRITE_FLUSH, handle, 0, result);
    if (result != 13) begin
      $display("FAIL tcp_smoke: write_flush sent %0d bytes, expected 13", result);
      failed = 1;
    end

    for (i = 0; i <= 12; i = i + 1) begin
      transport.xport_call(`CMD_READ_BYTE, handle, 5000, result);
      if (result != expected[i]) begin
        $display("FAIL tcp_smoke: byte %0d was %0d, expected %0d", i, result, expected[i]);
        failed = 1;
      end
    end

    transport.xport_call(`CMD_CLOSE, handle, 0, result);

    if (failed == 0) begin
      $display("PASS tcp_smoke");
    end else begin
      $display("FAIL tcp_smoke");
    end
    $finish;
  end

endmodule
