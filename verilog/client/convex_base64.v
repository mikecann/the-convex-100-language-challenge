// convex_base64.v - base64 (RFC 4648 section 4, standard alphabet, '='
// padding), encode and decode. Encode builds the Sec-WebSocket-Key
// nonce's text form and the expected Sec-WebSocket-Accept value to
// compare, byte-for-byte, against what the server actually sent (see
// convex_websocket.v). Decode exists for convex_sync.v: the sync
// protocol's `maxObservedTimestamp` is a base64-encoded 8-byte
// little-endian value this client must compare in magnitude, which
// needs the raw bytes back, not just the text. Every 6-bit group below
// comes from a bit-select on a `reg [23:0]`/`reg[5:0]` built by
// concatenating plain `byte`/`reg` locals, never from arithmetic
// shifting of a `byte` value directly - `byte` is SIGNED in
// SystemVerilog, and a raw random byte or hash-digest byte with its top
// bit set (any byte >= 0x80) would sign-extend under `<<`/`>>` and
// corrupt the group. Concatenation and bit-select both operate on the
// plain bit pattern regardless of signedness, so this file uses only
// those two operations to move bits around.
`timescale 1ns / 1ps

module convex_base64 #(
  parameter MAXLEN = 64
);

  byte data [0:MAXLEN-1];
  integer len;
  reg overflow;

  convex_buffer #(.MAXLEN(((MAXLEN + 2) / 3) * 4 + 4)) out ();

  initial begin
    len = 0;
    overflow = 1'b0;
  end

  task automatic reset;
    begin
      len = 0;
      overflow = 1'b0;
      out.reset;
    end
  endtask

  task automatic put_byte(input byte b);
    begin
      if (len < MAXLEN) begin
        data[len] = b;
        len = len + 1;
      end else begin
        overflow = 1'b1;
      end
    end
  endtask

  function automatic integer length;
    return out.length();
  endfunction

  function automatic byte get_byte(input integer idx);
    return out.get_byte(idx);
  endfunction

  function automatic byte alphabet_char(input [5:0] v);
    begin
      if (v < 26) alphabet_char = "A" + v;
      else if (v < 52) alphabet_char = "a" + (v - 26);
      else if (v < 62) alphabet_char = "0" + (v - 52);
      else if (v == 62) alphabet_char = "+";
      else alphabet_char = "/";
    end
  endfunction

  // Encodes data[0..len-1] into `out`, a convex_buffer instance a caller
  // reads with out.get_byte/out.length (or this module's own
  // length()/get_byte() convenience wrappers above).
  task automatic encode;
    integer i;
    byte b0, b1, b2;
    reg [23:0] group;
    begin
      out.reset;
      i = 0;
      while (i < len) begin
        b0 = data[i];
        b1 = (i + 1 < len) ? data[i+1] : 8'h00;
        b2 = (i + 2 < len) ? data[i+2] : 8'h00;
        group = {b0, b1, b2};
        out.put_byte(alphabet_char(group[23:18]));
        out.put_byte(alphabet_char(group[17:12]));
        if (i + 1 < len) out.put_byte(alphabet_char(group[11:6]));
        else out.put_byte("=");
        if (i + 2 < len) out.put_byte(alphabet_char(group[5:0]));
        else out.put_byte("=");
        i = i + 3;
      end
    end
  endtask

  // Inverse of alphabet_char: a sextet 0-63 for an alphabet character,
  // or -1 for '=' (padding) or anything else. decode below only ever
  // calls this on a character it has already special-cased '=' out of,
  // so -1 here means genuinely malformed input; decode does not reject
  // that (this client only ever decodes a value it, or a trusted test
  // fixture, produced with encode above - see convex_sync.v), it simply
  // is not guaranteed to reproduce the original bytes.
  function automatic integer alphabet_value(input byte c);
    begin
      if (c >= "A" && c <= "Z") alphabet_value = c - "A";
      else if (c >= "a" && c <= "z") alphabet_value = c - "a" + 26;
      else if (c >= "0" && c <= "9") alphabet_value = c - "0" + 52;
      else if (c == "+") alphabet_value = 62;
      else if (c == "/") alphabet_value = 63;
      else alphabet_value = -1;
    end
  endfunction

  // Decodes data[0..len-1] (base64 text, a multiple of 4 bytes - every
  // string this client decodes came from its own encode above or a
  // real server, both always padded to a multiple of 4) into `out`'s
  // raw bytes. Each sextet is copied into a `reg [5:0]` local before
  // concatenation, sidestepping the same signed-`byte`-in-arithmetic
  // hazard encode's own header comment describes - alphabet_value
  // returns a plain `integer`, and this client never bit-selects an
  // `integer` directly (see convex_websocket.v's read_frame for the
  // same rule): every value is copied into a sized `reg` first.
  task automatic decode;
    integer i;
    byte c0, c1, c2, c3;
    integer iv0, iv1, iv2, iv3;
    reg [5:0] s0, s1, s2, s3;
    reg [23:0] group;
    begin
      out.reset;
      i = 0;
      while (i + 4 <= len) begin
        c0 = data[i]; c1 = data[i+1]; c2 = data[i+2]; c3 = data[i+3];
        iv0 = alphabet_value(c0);
        iv1 = alphabet_value(c1);
        iv2 = (c2 == "=") ? 0 : alphabet_value(c2);
        iv3 = (c3 == "=") ? 0 : alphabet_value(c3);
        s0 = iv0; s1 = iv1; s2 = iv2; s3 = iv3;
        group = {s0, s1, s2, s3};
        out.put_byte(group[23:16]);
        if (c2 != "=") out.put_byte(group[15:8]);
        if (c3 != "=") out.put_byte(group[7:0]);
        i = i + 4;
      end
    end
  endtask

endmodule
