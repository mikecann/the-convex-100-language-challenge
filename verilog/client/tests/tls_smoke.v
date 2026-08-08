// tls_smoke.v - gate proof (b): a real TLS handshake, with certificate
// AND hostname verification, to the approved test deployment
// usable-reindeer-44.convex.cloud:443, driven from Verilog through the
// same VPI boundary tcp_smoke.v exercises for plain TCP.
//
// This is test infrastructure for the toolchain gate, not part of the
// public client. native.c's handle_connect (client/native.c) only
// returns a non-negative handle for a TLS connection once
// SSL_connect succeeds AND SSL_get_verify_result reports X509_V_OK
// against the exact hostname pushed below (SSL_set1_host) - so a
// non-negative handle here already is the certificate+hostname proof.
// This test goes one step further and also sends a real HTTP/1.1
// request over that handshake and checks a real response comes back,
// so the proof is not just "the handshake bit was set" but "application
// bytes travel through it".

`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"

module tls_smoke;

  convex_transport transport ();

  reg signed [31:0] result;
  integer i;
  integer handle;
  integer failed;

  reg [8*128-1:0] host;
  integer host_len;
  reg [8*160-1:0] request;
  integer request_len;
  reg [7:0] status_prefix [0:7];

  initial begin
    failed  = 0;
    host    = "usable-reindeer-44.convex.cloud";
    host_len = 31;

    request = {"GET / HTTP/1.1\r\nHost: usable-reindeer-44.convex.cloud\r\nConnection: close\r\n\r\n"};
    request_len = 76;

    // Placeholder bytes, overwritten by the real response read below; the
    // initial values only matter if that read loop is skipped entirely.
    status_prefix[0] = "H";
    status_prefix[1] = "T";
    status_prefix[2] = "T";
    status_prefix[3] = "P";
    status_prefix[4] = "/";
    status_prefix[5] = "1";
    status_prefix[6] = ".";
    status_prefix[7] = "0";

    transport.xport_call(`CMD_HOST_RESET, 0, 0, result);
    for (i = 0; i < host_len; i = i + 1) begin
      transport.xport_call(`CMD_HOST_PUSH, host[8*(host_len-1-i) +: 8], 0, result);
    end

    // a0=port 443, a1=1 (use_tls=1): native.c performs SSL_connect with
    // SNI + SSL_set1_host both set to the pushed hostname, and only
    // returns a handle >= 0 when SSL_get_verify_result == X509_V_OK.
    transport.xport_call(`CMD_CONNECT, 443, 1, result);
    handle = result;
    if (handle < 0) begin
      $display("FAIL tls_smoke: TLS connect returned %0d (see stderr for native.c's OpenSSL error)", handle);
      $finish;
    end
    $display("tls_smoke: TLS handshake verified (cert + hostname), handle=%0d", handle);

    for (i = 0; i < request_len; i = i + 1) begin
      transport.xport_call(`CMD_WRITE_BYTE, handle, request[8*(request_len-1-i) +: 8], result);
      if (result < 0) begin
        $display("FAIL tls_smoke: write_byte %0d returned %0d", i, result);
        failed = 1;
      end
    end
    transport.xport_call(`CMD_WRITE_FLUSH, handle, 0, result);
    if (result != request_len) begin
      $display("FAIL tls_smoke: write_flush sent %0d bytes, expected %0d", result, request_len);
      failed = 1;
    end

    // Read back the first 8 bytes of the response and confirm it is a
    // real HTTP status line ("HTTP/1." + a digit), proving application
    // data actually flows over the verified handshake.
    for (i = 0; i < 8; i = i + 1) begin
      transport.xport_call(`CMD_READ_BYTE, handle, 10000, result);
      if (result < 0) begin
        $display("FAIL tls_smoke: read_byte %0d returned %0d", i, result);
        failed = 1;
      end else begin
        status_prefix[i] = result[7:0];
      end
    end

    if (!(status_prefix[0] == "H" && status_prefix[1] == "T" && status_prefix[2] == "T" &&
          status_prefix[3] == "P" && status_prefix[4] == "/" && status_prefix[5] == "1" &&
          status_prefix[6] == ".")) begin
      $display("FAIL tls_smoke: response did not start with an HTTP/1.x status line: %s",
                {status_prefix[0], status_prefix[1], status_prefix[2], status_prefix[3],
                 status_prefix[4], status_prefix[5], status_prefix[6], status_prefix[7]});
      failed = 1;
    end else begin
      $display("tls_smoke: received real HTTP response over the verified TLS channel");
    end

    transport.xport_call(`CMD_CLOSE, handle, 0, result);

    if (failed == 0) begin
      $display("PASS tls_smoke");
    end else begin
      $display("FAIL tls_smoke");
    end
    $finish;
  end

endmodule
