-- buffer_test.vhdl - unit coverage for convex_buffer.vhdl's decimal,
-- base64, hex and comparison helpers, checked against well-known test
-- vectors rather than only round-tripping the client's own encoder
-- against its own decoder.
use work.convex_buffer.all;

entity buffer_test is
end entity buffer_test;

architecture behav of buffer_test is
begin
  process is
    variable buf : byte_array(0 to 255);
    variable len : natural;
    variable v : integer;
    variable ok : boolean;
    variable src : byte_array(0 to 2);
  begin
    len := 0;
    buf_put_int(buf, len, 0);
    assert buf_eq_str(buf, 0, len, "0") report "int0 failed" severity failure;

    len := 0;
    buf_put_int(buf, len, 42);
    assert buf_eq_str(buf, 0, len, "42") report "int42 failed" severity failure;

    len := 0;
    buf_put_int(buf, len, -7);
    assert buf_eq_str(buf, 0, len, "-7") report "int-7 failed" severity failure;

    len := 0;
    buf_parse_uint(buf, 0, 0, v, ok); -- reuse buf; irrelevant contents, l=0
    assert not ok report "parse empty should fail" severity failure;

    len := 0;
    buf_put_str(buf, len, "12345");
    buf_parse_uint(buf, 0, len, v, ok);
    assert ok and v = 12345 report "parse 12345 failed" severity failure;

    -- base64("foo") = "Zm9v" (well-known test vector)
    src(0) := character'pos('f');
    src(1) := character'pos('o');
    src(2) := character'pos('o');
    len := 0;
    buf_put_base64(buf, len, src, 0, 3);
    assert buf_eq_str(buf, 0, len, "Zm9v") report "base64 foo failed" severity failure;

    -- hex
    len := 0;
    buf_put_hex(buf, len, src, 0, 3);
    assert buf_eq_str(buf, 0, len, "666f6f") report "hex foo failed" severity failure;

    -- case-insensitive compare
    len := 0;
    buf_put_str(buf, len, "Content-Length");
    assert buf_eq_str_ci(buf, 0, len, "content-length") report "ci compare failed" severity failure;

    report "PASS buffer_test";
    wait;
  end process;
end architecture behav;
