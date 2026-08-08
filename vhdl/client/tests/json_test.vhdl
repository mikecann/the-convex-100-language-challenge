-- json_test.vhdl - unit coverage for convex_json.vhdl, including the
-- integral-decimal-number regression AGENTS.md requires: "0.0" and "1.0"
-- must decode as the integers 0 and 1, while a genuinely fractional,
-- quoted, or overflowing number must be rejected rather than silently
-- truncated or coerced.
use work.convex_buffer.all;
use work.convex_json.all;

entity json_test is
end entity json_test;

architecture behav of json_test is
begin
  process is
    variable buf : byte_array(0 to 511);
    variable len : natural;
    variable toks : json_tok_array(0 to 63);
    variable ntoks : natural;
    variable ok : boolean;
    variable t, obj, arr, v : integer;
    variable found : boolean;
    variable ival : integer;
    variable outbuf : byte_array(0 to 127);
    variable outlen : natural;
  begin
    -- === encoding ===
    -- Built with character'val throughout, so the intended quote,
    -- backslash and newline bytes never depend on VHDL's own string-quote
    -- doubling rule. Input: hello "world" then a real newline byte.
    -- Expected JSON: "hello \"world\"\n" (the newline escaped as \n).
    len := 0;
    json_put_string(buf, len,
      "hello " & character'val(34) & "world" & character'val(34) & character'val(10));
    assert buf_eq_str(buf, 0, len,
      character'val(34) & "hello " & character'val(92) & character'val(34) &
      "world" & character'val(92) & character'val(34) &
      character'val(92) & character'val(110) & character'val(34))
      report "json_put_string escaping failed" severity failure;

    len := 0;
    json_put_int(buf, len, -42);
    assert buf_eq_str(buf, 0, len, "-42") report "json_put_int failed" severity failure;

    len := 0;
    json_put_bool(buf, len, true);
    assert buf_eq_str(buf, 0, len, "true") report "json_put_bool true failed" severity failure;
    len := 0;
    json_put_bool(buf, len, false);
    assert buf_eq_str(buf, 0, len, "false") report "json_put_bool false failed" severity failure;
    len := 0;
    json_put_null(buf, len);
    assert buf_eq_str(buf, 0, len, "null") report "json_put_null failed" severity failure;

    -- A hand-assembled object, matching how this client actually builds a
    -- request envelope: no generic value tree, just direct writes.
    len := 0;
    buf_put_byte(buf, len, character'pos('{'));
    json_put_string(buf, len, "path");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_string(buf, len, "demo:state");
    buf_put_byte(buf, len, character'pos(','));
    json_put_string(buf, len, "args");
    buf_put_byte(buf, len, character'pos(':'));
    buf_put_byte(buf, len, character'pos('{'));
    json_put_string(buf, len, "room");
    buf_put_byte(buf, len, character'pos(':'));
    json_put_string(buf, len, "r1");
    buf_put_byte(buf, len, character'pos('}'));
    buf_put_byte(buf, len, character'pos('}'));
    assert buf_eq_str(buf, 0, len, "{""path"":""demo:state"",""args"":{""room"":""r1""}}")
      report "hand-assembled envelope did not match" severity failure;

    -- === decoding: a realistic Convex query response ===
    len := 0;
    buf_put_str(buf, len, "{""status"":""success"",""value"":{""count"":0.0,");
    buf_put_str(buf, len, """room"":""r1"",""tags"":[1,2,3],""ok"":true,");
    buf_put_str(buf, len, """extra"":null},""logLines"":[]}");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse of realistic response failed" severity failure;

    json_object_get(buf, toks, ntoks, toks'low, "status", t, found);
    assert found and json_tok_eq_str(buf, toks, t, "success")
      report "status lookup failed" severity failure;

    json_object_get(buf, toks, ntoks, toks'low, "value", obj, found);
    assert found report "value lookup failed" severity failure;

    json_object_get(buf, toks, ntoks, obj, "count", t, found);
    assert found report "count lookup failed" severity failure;
    json_tok_as_int(buf, toks, t, ival, ok);
    assert ok and ival = 0 report "count 0.0 did not decode as integer 0" severity failure;

    json_object_get(buf, toks, ntoks, obj, "room", t, found);
    assert found and json_tok_eq_str(buf, toks, t, "r1") report "room lookup failed" severity failure;
    outlen := 0;
    json_tok_get_str(buf, toks, t, outbuf, outlen);
    assert buf_eq_str(outbuf, 0, outlen, "r1") report "room get_str failed" severity failure;

    json_object_get(buf, toks, ntoks, obj, "tags", arr, found);
    assert found and json_child_count(toks, ntoks, arr) = 3
      report "tags array should have 3 elements" severity failure;
    v := json_array_nth(toks, ntoks, arr, 1);
    json_tok_as_int(buf, toks, v, ival, ok);
    assert ok and ival = 2 report "tags[1] should be 2" severity failure;

    json_object_get(buf, toks, ntoks, obj, "ok", t, found);
    assert found and toks(t).kind = JSON_BOOL and toks(t).bool_value
      report "ok field should decode as boolean true" severity failure;

    json_object_get(buf, toks, ntoks, obj, "extra", t, found);
    assert found and toks(t).kind = JSON_NULL report "extra field should decode as null" severity failure;

    json_object_get(buf, toks, ntoks, obj, "missing", t, found);
    assert not found report "missing field should not be found" severity failure;

    -- === the integral-decimal-number regression ===
    len := 0;
    buf_put_str(buf, len, "0.0");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse 0.0 failed" severity failure;
    json_tok_as_int(buf, toks, toks'low, ival, ok);
    assert ok and ival = 0 report "0.0 should decode as integral 0" severity failure;

    len := 0;
    buf_put_str(buf, len, "1.0");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse 1.0 failed" severity failure;
    json_tok_as_int(buf, toks, toks'low, ival, ok);
    assert ok and ival = 1 report "1.0 should decode as integral 1" severity failure;

    len := 0;
    buf_put_str(buf, len, "1e2");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse 1e2 failed" severity failure;
    json_tok_as_int(buf, toks, toks'low, ival, ok);
    assert ok and ival = 100 report "1e2 should decode as integral 100" severity failure;

    len := 0;
    buf_put_str(buf, len, "1.5");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse 1.5 failed" severity failure; -- still a valid JSON document
    json_tok_as_int(buf, toks, toks'low, ival, ok);
    assert not ok report "1.5 is fractional and must be rejected as an integer" severity failure;

    len := 0;
    buf_put_str(buf, len, """5""");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse quoted 5 failed" severity failure;
    json_tok_as_int(buf, toks, toks'low, ival, ok);
    assert not ok report "a quoted number must be rejected, not coerced" severity failure;

    len := 0;
    buf_put_str(buf, len, "99999999999999999999");
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse of an overflowing literal should still succeed" severity failure;
    json_tok_as_int(buf, toks, toks'low, ival, ok);
    assert not ok report "an overflowing integer must be rejected" severity failure;

    len := 0;
    buf_put_str(buf, len, "NaN");
    json_parse(buf, len, toks, ntoks, ok);
    assert not ok report "NaN is not valid JSON and must fail to parse at all" severity failure;

    -- === malformed input ===
    len := 0;
    buf_put_str(buf, len, "{");
    json_parse(buf, len, toks, ntoks, ok);
    assert not ok report "unterminated object should fail to parse" severity failure;

    len := 0;
    buf_put_str(buf, len, "{""a"":}");
    json_parse(buf, len, toks, ntoks, ok);
    assert not ok report "missing value should fail to parse" severity failure;

    len := 0;
    buf_put_str(buf, len, "01");
    json_parse(buf, len, toks, ntoks, ok);
    assert not ok report "a leading zero followed by more digits should fail to parse" severity failure;

    len := 0;
    buf_put_str(buf, len, "true false");
    json_parse(buf, len, toks, ntoks, ok);
    assert not ok report "trailing content after a value should fail to parse" severity failure;

    -- === unicode string decoding ===
    len := 0;
    buf_put_byte(buf, len, character'pos('"'));
    buf_put_str(buf, len, "caf" & character'val(195) & character'val(169)); -- raw UTF-8 "café"
    buf_put_str(buf, len, "!"); -- an escaped '!'
    buf_put_byte(buf, len, character'pos('"'));
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse of a UTF-8 string failed" severity failure;
    outlen := 0;
    json_tok_get_str(buf, toks, toks'low, outbuf, outlen);
    assert buf_eq_str(outbuf, 0, outlen,
      "caf" & character'val(195) & character'val(169) & "!")
      report "UTF-8 passthrough plus \u escape decode failed" severity failure;

    -- A literal é escape (backslash is not special in a VHDL string
    -- literal, so the text below is exactly those six source characters),
    -- which must decode to U+00E9 "e with acute" = UTF-8 C3 A9.
    len := 0;
    buf_put_byte(buf, len, character'pos('"'));
    -- The six ASCII bytes backslash, u, 0, 0, e, 9 -- spelled with
    -- character'val so nothing here depends on how this source file
    -- itself is encoded.
    buf_put_byte(buf, len, 92);
    buf_put_byte(buf, len, character'pos('u'));
    buf_put_byte(buf, len, character'pos('0'));
    buf_put_byte(buf, len, character'pos('0'));
    buf_put_byte(buf, len, character'pos('e'));
    buf_put_byte(buf, len, character'pos('9'));
    buf_put_byte(buf, len, character'pos('"'));
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse of a \u escape failed" severity failure;
    outlen := 0;
    json_tok_get_str(buf, toks, toks'low, outbuf, outlen);
    assert buf_eq_str(outbuf, 0, outlen, character'val(195) & character'val(169))
      report "é should decode to UTF-8 C3 A9" severity failure;

    -- A literal 👋 surrogate pair, U+1F44B (a waving-hand
    -- emoji), which must combine into one 4-byte UTF-8 sequence, not two
    -- independent 3-byte encodings of each surrogate half.
    len := 0;
    buf_put_byte(buf, len, character'pos('"'));
    -- 👋 spelled the same explicit way.
    buf_put_byte(buf, len, 92);
    buf_put_byte(buf, len, character'pos('u'));
    buf_put_byte(buf, len, character'pos('d'));
    buf_put_byte(buf, len, character'pos('8'));
    buf_put_byte(buf, len, character'pos('3'));
    buf_put_byte(buf, len, character'pos('d'));
    buf_put_byte(buf, len, 92);
    buf_put_byte(buf, len, character'pos('u'));
    buf_put_byte(buf, len, character'pos('d'));
    buf_put_byte(buf, len, character'pos('c'));
    buf_put_byte(buf, len, character'pos('4'));
    buf_put_byte(buf, len, character'pos('b'));
    buf_put_byte(buf, len, character'pos('"'));
    json_parse(buf, len, toks, ntoks, ok);
    assert ok report "parse of a surrogate pair escape failed" severity failure;
    outlen := 0;
    json_tok_get_str(buf, toks, toks'low, outbuf, outlen);
    assert outlen = 4 and outbuf(0) = 240 and outbuf(1) = 159 and outbuf(2) = 145 and outbuf(3) = 139
      report "surrogate pair should combine into one 4-byte UTF-8 sequence" severity failure;

    report "PASS json_test";
    wait;
  end process;
end architecture behav;
