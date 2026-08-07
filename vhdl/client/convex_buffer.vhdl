-- convex_buffer.vhdl - byte buffers, base64, hex and decimal helpers.
--
-- VHDL has no heap and no dynamically growing array, so every buffer in
-- this client is a fixed-capacity byte_array variable declared by its
-- caller, paired with a `natural` length that tracks how much of it is
-- in use -- the same discipline this project's ALGOL 60 client uses for
-- the same reason. Unlike ALGOL 60, VHDL arrays carry their own bounds
-- ('length, 'range) and support slicing, so a helper here takes the
-- buffer itself as an unconstrained `byte_array` parameter rather than a
-- separate capacity argument.
package convex_buffer is

  subtype byte_t is integer range 0 to 255;
  type byte_array is array (natural range <>) of byte_t;

  -- Appends one byte if the buffer still has room; silently drops it
  -- otherwise (every caller in this client sizes buffers generously
  -- for the protocol text it builds and checks length where it matters,
  -- matching this project's other native clients' bounded-buffer style).
  procedure buf_put_byte(buf : inout byte_array; len : inout natural; b : in byte_t);

  -- Appends every character of s, encoded as its ASCII/Latin-1 code
  -- point. Used only for protocol text this client itself writes
  -- (HTTP verbs, header names, JSON punctuation): never for a value
  -- that could contain a multi-byte UTF-8 character, which goes
  -- through buf_put_utf8 in convex_json.vhdl instead.
  procedure buf_put_str(buf : inout byte_array; len : inout natural; s : in string);

  -- Appends the decimal ASCII representation of n, including a leading
  -- '-' for a negative value.
  procedure buf_put_int(buf : inout byte_array; len : inout natural; n : in integer);

  -- True when buf(off to off + s'length - 1) is byte-for-byte equal to
  -- s's character codes.
  function buf_eq_str(buf : byte_array; off, l : natural; s : string) return boolean;

  -- Case-insensitive ASCII compare, for HTTP header names.
  function buf_eq_str_ci(buf : byte_array; off, l : natural; s : string) return boolean;

  -- Copies src(srcoff to srcoff + srclen - 1) onto the end of dst.
  procedure buf_put_slice(
    dst : inout byte_array; dstlen : inout natural;
    src : in byte_array; srcoff, srclen : in natural
  );

  -- Parses the decimal integer at buf(off to off + l - 1). ok is false
  -- for an empty range, a non-digit character, or overflow past the
  -- range of integer.
  procedure buf_parse_uint(buf : byte_array; off, l : natural; value : out integer; ok : out boolean);

  -- Base64 (RFC 4648, standard alphabet, '=' padding), used only for
  -- the WebSocket handshake's Sec-WebSocket-Key.
  procedure buf_put_base64(
    dst : inout byte_array; dstlen : inout natural;
    src : in byte_array; srcoff, srclen : in natural
  );

  -- Lowercase hex, used for the Live idempotency key (runId).
  procedure buf_put_hex(
    dst : inout byte_array; dstlen : inout natural;
    src : in byte_array; srcoff, srclen : in natural
  );

end package convex_buffer;

package body convex_buffer is

  procedure buf_put_byte(buf : inout byte_array; len : inout natural; b : in byte_t) is
  begin
    if len <= buf'high then
      buf(buf'low + len) := b;
      len := len + 1;
    end if;
  end procedure buf_put_byte;

  procedure buf_put_str(buf : inout byte_array; len : inout natural; s : in string) is
  begin
    for i in s'range loop
      buf_put_byte(buf, len, character'pos(s(i)));
    end loop;
  end procedure buf_put_str;

  procedure buf_put_int(buf : inout byte_array; len : inout natural; n : in integer) is
    variable digits_buf : byte_array(0 to 15);
    variable dcount : natural := 0;
    variable mag : integer;
  begin
    if n = 0 then
      buf_put_byte(buf, len, character'pos('0'));
      return;
    end if;
    if n < 0 then
      buf_put_byte(buf, len, character'pos('-'));
    end if;
    -- integer'low cannot be negated safely, but no Convex protocol
    -- value this client formats ever approaches it; a plain library
    -- ("+" cannot represent it either) is only sound to negate here for
    -- values that were originally non-negative and then negated above.
    if n = integer'low then
      buf_put_str(buf, len, "2147483648");
      return;
    end if;
    if n < 0 then
      mag := -n;
    else
      mag := n;
    end if;
    while mag > 0 loop
      digits_buf(dcount) := mag mod 10;
      mag := mag / 10;
      dcount := dcount + 1;
    end loop;
    for i in dcount - 1 downto 0 loop
      buf_put_byte(buf, len, character'pos('0') + digits_buf(i));
    end loop;
  end procedure buf_put_int;

  function buf_eq_str(buf : byte_array; off, l : natural; s : string) return boolean is
  begin
    if l /= s'length then
      return false;
    end if;
    for i in 0 to l - 1 loop
      if buf(buf'low + off + i) /= character'pos(s(s'low + i)) then
        return false;
      end if;
    end loop;
    return true;
  end function buf_eq_str;

  function to_lower_code(c : byte_t) return byte_t is
  begin
    if c >= character'pos('A') and c <= character'pos('Z') then
      return c + (character'pos('a') - character'pos('A'));
    end if;
    return c;
  end function to_lower_code;

  function buf_eq_str_ci(buf : byte_array; off, l : natural; s : string) return boolean is
  begin
    if l /= s'length then
      return false;
    end if;
    for i in 0 to l - 1 loop
      if to_lower_code(buf(buf'low + off + i)) /=
         to_lower_code(character'pos(s(s'low + i))) then
        return false;
      end if;
    end loop;
    return true;
  end function buf_eq_str_ci;

  procedure buf_put_slice(
    dst : inout byte_array; dstlen : inout natural;
    src : in byte_array; srcoff, srclen : in natural
  ) is
  begin
    for i in 0 to srclen - 1 loop
      buf_put_byte(dst, dstlen, src(src'low + srcoff + i));
    end loop;
  end procedure buf_put_slice;

  procedure buf_parse_uint(buf : byte_array; off, l : natural; value : out integer; ok : out boolean) is
    variable acc : integer := 0;
    variable d : integer;
  begin
    if l = 0 then
      value := 0;
      ok := false;
      return;
    end if;
    for i in 0 to l - 1 loop
      d := buf(buf'low + off + i) - character'pos('0');
      if d < 0 or d > 9 then
        value := 0;
        ok := false;
        return;
      end if;
      if acc > (integer'high - d) / 10 then
        value := 0;
        ok := false;
        return;
      end if;
      acc := acc * 10 + d;
    end loop;
    value := acc;
    ok := true;
  end procedure buf_parse_uint;

  procedure buf_put_base64(
    dst : inout byte_array; dstlen : inout natural;
    src : in byte_array; srcoff, srclen : in natural
  ) is
    constant alphabet : string := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    variable i : natural := 0;
    variable b0, b1, b2 : integer;
    variable n : integer;
  begin
    while i + 3 <= srclen loop
      b0 := src(src'low + srcoff + i);
      b1 := src(src'low + srcoff + i + 1);
      b2 := src(src'low + srcoff + i + 2);
      n := b0 * 65536 + b1 * 256 + b2;
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 262144) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 4096) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 64) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos(alphabet(n mod 64 + 1)));
      i := i + 3;
    end loop;
    if srclen - i = 1 then
      b0 := src(src'low + srcoff + i);
      n := b0 * 65536;
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 262144) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 4096) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos('='));
      buf_put_byte(dst, dstlen, character'pos('='));
    elsif srclen - i = 2 then
      b0 := src(src'low + srcoff + i);
      b1 := src(src'low + srcoff + i + 1);
      n := b0 * 65536 + b1 * 256;
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 262144) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 4096) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos(alphabet((n / 64) mod 64 + 1)));
      buf_put_byte(dst, dstlen, character'pos('='));
    end if;
  end procedure buf_put_base64;

  procedure buf_put_hex(
    dst : inout byte_array; dstlen : inout natural;
    src : in byte_array; srcoff, srclen : in natural
  ) is
    constant digits_hex : string := "0123456789abcdef";
    variable v : integer;
  begin
    for i in 0 to srclen - 1 loop
      v := src(src'low + srcoff + i);
      buf_put_byte(dst, dstlen, character'pos(digits_hex(v / 16 + 1)));
      buf_put_byte(dst, dstlen, character'pos(digits_hex(v mod 16 + 1)));
    end loop;
  end procedure buf_put_hex;

end package body convex_buffer;
