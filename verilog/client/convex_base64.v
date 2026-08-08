// convex_base64.v - base64 (RFC 4648 section 4, standard alphabet, '='
// padding), ENCODE only: this client never needs to decode base64. The
// only use is building the Sec-WebSocket-Key nonce's text form and the
// expected Sec-WebSocket-Accept value to compare, byte-for-byte, against
// what the server actually sent (see convex_websocket.v). Every 6-bit
// group below comes from a bit-select on a `reg [23:0]` built by
// concatenating three plain `byte` locals, never from arithmetic
// shifting of a `byte` value directly - `byte` is SIGNED in
// SystemVerilog, and a raw random byte with its top bit set (any byte
// >= 0x80, routine for a hash digest or a masking key) would sign-extend
// under `<<`/`>>` and corrupt the group. Concatenation and bit-select
// both operate on the plain bit pattern regardless of signedness, so
// this file uses only those two operations to move bits around.
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

endmodule
