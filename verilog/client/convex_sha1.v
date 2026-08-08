// convex_sha1.v - a pure-Verilog SHA-1 (FIPS 180-4), just capable enough
// to compute the Sec-WebSocket-Accept value RFC 6455 SS4.2.2 defines:
// base64(SHA-1(Sec-WebSocket-Key + the fixed magic GUID)). This
// toolchain has no crypto library binding at all (native.c deliberately
// stays limited to sockets/TLS/entropy/stdio - see its own file header),
// so this hash lives in the client the same way convex_buffer.v's JSON
// codec does: as ordinary Verilog operating on byte arrays, never a
// foreign call.
//
// Every accumulator below (the padded message, the 80-word schedule,
// the five running hash words) is a `reg`/`byte` array declared LOCAL to
// the `compute` task, not module-level scratch state, and that is a
// deliberate departure from convex_http.v's module-level-scratch
// discipline for string accumulation, not an oversight: the Icarus
// 11.0 bug that discipline works around (vthread.cc:212) is specific to
// a self-referential `string` concatenation (`x = {x, ...}`) inside an
// automatic task; convex_buffer.v's own `tok_as_int` already proves a
// task-local fixed-size numeric array accumulated with ordinary indexed
// assignment (`digits_buf[i] = ...`) works fine in this same toolchain.
// Every multi-byte value here is built with `{...}` concatenation of
// plain `byte`/`reg` locals (never a `string[index]` select, the OTHER
// documented Icarus bug) or with a part-select on a sized `reg`, never
// on a plain `integer` - both proactively avoided per the workarounds
// already paid for in convex_http.v.
`timescale 1ns / 1ps

module convex_sha1 #(
  parameter MAXLEN = 256
);

  byte data [0:MAXLEN-1];
  integer len;
  reg overflow;

  // The 20-byte digest, set by compute() below.
  reg [7:0] digest [0:19];

  initial begin
    len = 0;
    overflow = 1'b0;
  end

  task automatic reset;
    begin
      len = 0;
      overflow = 1'b0;
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
    return len;
  endfunction

  function automatic byte get_digest_byte(input integer idx);
    return digest[idx];
  endfunction

  function automatic [31:0] rotl32(input [31:0] x, input integer n);
    rotl32 = (x << n) | (x >> (32 - n));
  endfunction

  // Runs FIPS 180-4 SHA-1 over data[0..len-1] (padded per the standard)
  // and writes the 20-byte result into digest[0..19].
  task automatic compute;
    byte msg [0:MAXLEN+71];
    integer padded_len;
    integer nblocks;
    integer blk, i, t;
    reg [31:0] w [0:79];
    reg [31:0] a, b, c, d, e, f, k, temp;
    reg [31:0] h0, h1, h2, h3, h4;
    longint bitlen;
    byte b0, b1, b2, b3;
    begin
      for (i = 0; i < len; i = i + 1) msg[i] = data[i];
      msg[len] = 8'h80;
      padded_len = len + 1;
      while ((padded_len % 64) != 56) begin
        msg[padded_len] = 8'h00;
        padded_len = padded_len + 1;
      end
      bitlen = len;
      bitlen = bitlen * 8;
      for (i = 7; i >= 0; i = i - 1) begin
        msg[padded_len] = bitlen[(i*8) +: 8];
        padded_len = padded_len + 1;
      end
      nblocks = padded_len / 64;

      h0 = 32'h67452301;
      h1 = 32'hEFCDAB89;
      h2 = 32'h98BADCFE;
      h3 = 32'h10325476;
      h4 = 32'hC3D2E1F0;

      for (blk = 0; blk < nblocks; blk = blk + 1) begin
        for (t = 0; t < 16; t = t + 1) begin
          b0 = msg[blk*64 + t*4 + 0];
          b1 = msg[blk*64 + t*4 + 1];
          b2 = msg[blk*64 + t*4 + 2];
          b3 = msg[blk*64 + t*4 + 3];
          w[t] = {b0, b1, b2, b3};
        end
        for (t = 16; t < 80; t = t + 1) begin
          w[t] = rotl32(w[t-3] ^ w[t-8] ^ w[t-14] ^ w[t-16], 1);
        end

        a = h0; b = h1; c = h2; d = h3; e = h4;

        for (t = 0; t < 80; t = t + 1) begin
          if (t < 20) begin
            f = (b & c) | ((~b) & d);
            k = 32'h5A827999;
          end else if (t < 40) begin
            f = b ^ c ^ d;
            k = 32'h6ED9EBA1;
          end else if (t < 60) begin
            f = (b & c) | (b & d) | (c & d);
            k = 32'h8F1BBCDC;
          end else begin
            f = b ^ c ^ d;
            k = 32'hCA62C1D6;
          end
          temp = rotl32(a, 5) + f + e + k + w[t];
          e = d;
          d = c;
          c = rotl32(b, 30);
          b = a;
          a = temp;
        end

        h0 = h0 + a;
        h1 = h1 + b;
        h2 = h2 + c;
        h3 = h3 + d;
        h4 = h4 + e;
      end

      digest[0]  = h0[31:24]; digest[1]  = h0[23:16]; digest[2]  = h0[15:8]; digest[3]  = h0[7:0];
      digest[4]  = h1[31:24]; digest[5]  = h1[23:16]; digest[6]  = h1[15:8]; digest[7]  = h1[7:0];
      digest[8]  = h2[31:24]; digest[9]  = h2[23:16]; digest[10] = h2[15:8]; digest[11] = h2[7:0];
      digest[12] = h3[31:24]; digest[13] = h3[23:16]; digest[14] = h3[15:8]; digest[15] = h3[7:0];
      digest[16] = h4[31:24]; digest[17] = h4[23:16]; digest[18] = h4[15:8]; digest[19] = h4[7:0];
    end
  endtask

endmodule
