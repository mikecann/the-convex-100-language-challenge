// sha1_test.v - a language-local unit suite for client/convex_sha1.v and
// client/convex_base64.v, run with no transport and no network (no
// -mnative needed, matching client/tests/json_test.v's role for
// convex_buffer.v's JSON codec).
//
// Two independent known-answer vectors are checked: the standard SHA-1
// test vector for "abc", and RFC 6455's OWN worked example from
// section 1.3 - the exact Sec-WebSocket-Key "dGhlIHNhbXBsZSBub25jZQ=="
// must produce the exact Sec-WebSocket-Accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
// once concatenated with the magic GUID, hashed and base64-encoded. That
// second vector proves convex_sha1.v and convex_base64.v are correct
// TOGETHER, in exactly the composition convex_websocket.v's handshake
// uses them in, independent of any live network round trip.

`timescale 1ns / 1ps

module sha1_test;

  convex_sha1   #(.MAXLEN(128)) sha1 ();
  convex_base64 #(.MAXLEN(32))  b64 ();

  integer failed;
  integer i;
  string s;
  byte expected [0:19];
  bit mismatch;

  // "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" as a byte-indexable array, since a
  // `string[index]` select works fine as a comparison operand (only a
  // `{...}` concatenation RHS is the documented Icarus 11.0 trap - see
  // convex_http.v's header comment).
  string rfc_key;
  string rfc_expected_accept;
  string rfc_guid;

  task automatic check_sha1_abc;
    begin
      sha1.reset;
      s = "abc";
      for (i = 0; i < s.len(); i = i + 1) sha1.put_byte(s[i]);
      sha1.compute;
      // Known answer: SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89
      expected[0]='ha9; expected[1]='h99; expected[2]='h3e; expected[3]='h36;
      expected[4]='h47; expected[5]='h06; expected[6]='h81; expected[7]='h6a;
      expected[8]='hba; expected[9]='h3e; expected[10]='h25; expected[11]='h71;
      expected[12]='h78; expected[13]='h50; expected[14]='hc2; expected[15]='h6c;
      expected[16]='h9c; expected[17]='hd0; expected[18]='hd8; expected[19]='h9d;
      mismatch = 1'b0;
      for (i = 0; i < 20; i = i + 1) begin
        if (sha1.get_digest_byte(i) != expected[i]) mismatch = 1'b1;
      end
      if (mismatch) begin
        $display("FAIL sha1_test: SHA1(\"abc\") did not match the known digest");
        failed = 1;
      end else begin
        $display("sha1_test: SHA1(\"abc\") OK");
      end
    end
  endtask

  task automatic check_rfc6455_accept;
    bit match;
    begin
      sha1.reset;
      for (i = 0; i < rfc_key.len(); i = i + 1) sha1.put_byte(rfc_key[i]);
      for (i = 0; i < rfc_guid.len(); i = i + 1) sha1.put_byte(rfc_guid[i]);
      sha1.compute;

      b64.reset;
      for (i = 0; i < 20; i = i + 1) b64.put_byte(sha1.get_digest_byte(i));
      b64.encode;

      match = (b64.length() == rfc_expected_accept.len());
      if (match) begin
        for (i = 0; i < b64.length(); i = i + 1) begin
          if (b64.get_byte(i) != rfc_expected_accept[i]) match = 1'b0;
        end
      end
      if (!match) begin
        $display("FAIL sha1_test: RFC 6455 SS1.3 worked example did not reproduce s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
        failed = 1;
      end else begin
        $display("sha1_test: RFC 6455 SS1.3 Sec-WebSocket-Accept worked example OK");
      end
    end
  endtask

  initial begin
    failed = 0;
    rfc_key = "dGhlIHNhbXBsZSBub25jZQ==";
    rfc_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    rfc_expected_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

    check_sha1_abc;
    check_rfc6455_accept;

    if (failed == 0) begin
      $display("PASS sha1_test");
    end else begin
      $display("FAIL sha1_test");
    end
    $finish;
  end

endmodule
