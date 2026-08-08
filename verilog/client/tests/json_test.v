// json_test.v - unit coverage for convex_buffer.v's JSON encode/decode,
// including the integral-decimal-number regression AGENTS.md requires:
// "0.0" and "1.0" must decode as the integers 0 and 1, while a genuinely
// fractional, quoted, or overflowing number must be rejected rather than
// silently truncated or coerced.
//
// Every JSON fixture below spells its `"` characters as the `DQUOTE`
// macro from convex_chars.vh, concatenated into the surrounding string
// literal, rather than `\"` - see that file's header comment for the
// Icarus `string`-literal bug this works around.
//
// This is test infrastructure, not part of the public client.

`timescale 1ns / 1ps
`include "client/convex_chars.vh"

module json_test;

  convex_buffer #(.MAXLEN(1024), .MAXTOK(64)) buf1 ();
  convex_buffer #(.MAXLEN(256))                outbuf ();

  integer failed;
  integer t, obj, arr, v;
  bit found, ok, eq;
  integer ival;

  task automatic check(input bit cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL json_test: %s", msg);
        failed = 1;
      end
    end
  endtask

  // Copies tok's decoded text into outbuf, resetting outbuf first.
  task automatic decode_into_outbuf(input integer tok);
    byte db;
    bit ddone;
    begin : main
      outbuf.reset;
      buf1.decode_str_start(tok);
      forever begin
        buf1.decode_str_next(db, ddone);
        if (ddone) disable main;
        outbuf.put_byte(db);
      end
    end
  endtask

  function automatic bit outbuf_eq(input string s);
    integer k;
    bit mismatch;
    begin
      mismatch = 1'b0;
      if (outbuf.length() != s.len()) mismatch = 1'b1;
      else begin
        for (k = 0; k < s.len(); k = k + 1) begin
          if (outbuf.get_byte(k) != s[k]) mismatch = 1'b1;
        end
      end
      outbuf_eq = !mismatch;
    end
  endfunction

  function automatic bit buf1_eq(input string s);
    integer k;
    bit mismatch;
    begin
      mismatch = 1'b0;
      if (buf1.length() != s.len()) mismatch = 1'b1;
      else begin
        for (k = 0; k < s.len(); k = k + 1) begin
          if (buf1.get_byte(k) != s[k]) mismatch = 1'b1;
        end
      end
      buf1_eq = !mismatch;
    end
  endfunction

  initial begin
    failed = 0;

    // === encoding ===
    // Input: hello "world" then a real newline byte.
    // Expected JSON: "hello \"world\"\n" (the newline escaped as \n).
    buf1.reset;
    buf1.json_put_string({"hello ", `DQUOTE, "world", `DQUOTE, `LF});
    check(buf1_eq({`DQUOTE, "hello ", `BACKSLASH, `DQUOTE, "world", `BACKSLASH, `DQUOTE,
                   `BACKSLASH, "n", `DQUOTE}),
          "json_put_string escaping failed");

    buf1.reset;
    buf1.json_put_int(-42);
    check(buf1_eq("-42"), "json_put_int failed");

    buf1.reset;
    buf1.json_put_bool(1'b1);
    check(buf1_eq("true"), "json_put_bool true failed");
    buf1.reset;
    buf1.json_put_bool(1'b0);
    check(buf1_eq("false"), "json_put_bool false failed");
    buf1.reset;
    buf1.json_put_null;
    check(buf1_eq("null"), "json_put_null failed");

    // A hand-assembled object, matching how this client actually builds a
    // request envelope: no generic value tree, just direct writes.
    buf1.reset;
    buf1.put_byte("{");
    buf1.json_put_string("path");
    buf1.put_byte(":");
    buf1.json_put_string("demo:state");
    buf1.put_byte(",");
    buf1.json_put_string("args");
    buf1.put_byte(":");
    buf1.put_byte("{");
    buf1.json_put_string("room");
    buf1.put_byte(":");
    buf1.json_put_string("r1");
    buf1.put_byte("}");
    buf1.put_byte("}");
    check(buf1_eq({"{", `DQUOTE, "path", `DQUOTE, ":", `DQUOTE, "demo:state", `DQUOTE, ",",
                   `DQUOTE, "args", `DQUOTE, ":{", `DQUOTE, "room", `DQUOTE, ":", `DQUOTE,
                   "r1", `DQUOTE, "}}"}),
          "hand-assembled envelope did not match");

    // === decoding: a realistic Convex query response ===
    buf1.reset;
    buf1.put_byte("{");
    buf1.json_put_string("status"); buf1.put_byte(":"); buf1.json_put_string("success");
    buf1.put_byte(",");
    buf1.json_put_string("value"); buf1.put_byte(":"); buf1.put_byte("{");
    buf1.json_put_string("count"); buf1.put_byte(":"); buf1.put_str("0.0");
    buf1.put_byte(",");
    buf1.json_put_string("room"); buf1.put_byte(":"); buf1.json_put_string("r1");
    buf1.put_byte(",");
    buf1.json_put_string("tags"); buf1.put_byte(":"); buf1.put_str("[1,2,3]");
    buf1.put_byte(",");
    buf1.json_put_string("ok"); buf1.put_byte(":"); buf1.json_put_bool(1'b1);
    buf1.put_byte(",");
    buf1.json_put_string("extra"); buf1.put_byte(":"); buf1.json_put_null;
    buf1.put_byte("}");
    buf1.put_byte(",");
    buf1.json_put_string("logLines"); buf1.put_byte(":"); buf1.put_str("[]");
    buf1.put_byte("}");
    buf1.parse_json;
    check(buf1.json_ok(), "parse of realistic response failed");

    buf1.json_object_get(buf1.json_root(), "status", t, found);
    buf1.tok_eq_str(t, "success", eq);
    check(found && eq, "status lookup failed");

    buf1.json_object_get(buf1.json_root(), "value", obj, found);
    check(found, "value lookup failed");

    buf1.json_object_get(obj, "count", t, found);
    check(found, "count lookup failed");
    buf1.tok_as_int(t, ival, ok);
    check(ok && ival == 0, "count 0.0 did not decode as integer 0");

    buf1.json_object_get(obj, "room", t, found);
    buf1.tok_eq_str(t, "r1", eq);
    check(found && eq, "room lookup failed");
    decode_into_outbuf(t);
    check(outbuf_eq("r1"), "room decode failed");

    buf1.json_object_get(obj, "tags", arr, found);
    check(found && buf1.json_child_count(arr) == 3, "tags array should have 3 elements");
    v = buf1.json_array_nth(arr, 1);
    buf1.tok_as_int(v, ival, ok);
    check(ok && ival == 2, "tags[1] should be 2");

    buf1.json_object_get(obj, "ok", t, found);
    check(found && buf1.json_kind(t) == 2 && buf1.json_bool_value(t) == 1'b1,
          "ok field should decode as boolean true");

    buf1.json_object_get(obj, "extra", t, found);
    check(found && buf1.json_kind(t) == 1, "extra field should decode as null");

    buf1.json_object_get(obj, "missing", t, found);
    check(!found, "missing field should not be found");

    // === the integral-decimal-number regression ===
    buf1.reset; buf1.put_str("0.0"); buf1.parse_json;
    check(buf1.json_ok(), "parse 0.0 failed");
    buf1.tok_as_int(buf1.json_root(), ival, ok);
    check(ok && ival == 0, "0.0 should decode as integral 0");

    buf1.reset; buf1.put_str("1.0"); buf1.parse_json;
    check(buf1.json_ok(), "parse 1.0 failed");
    buf1.tok_as_int(buf1.json_root(), ival, ok);
    check(ok && ival == 1, "1.0 should decode as integral 1");

    buf1.reset; buf1.put_str("1e2"); buf1.parse_json;
    check(buf1.json_ok(), "parse 1e2 failed");
    buf1.tok_as_int(buf1.json_root(), ival, ok);
    check(ok && ival == 100, "1e2 should decode as integral 100");

    buf1.reset; buf1.put_str("1.5"); buf1.parse_json;
    check(buf1.json_ok(), "parse 1.5 failed (still valid JSON)");
    buf1.tok_as_int(buf1.json_root(), ival, ok);
    check(!ok, "1.5 is fractional and must be rejected as an integer");

    buf1.reset; buf1.put_byte(`DQUOTE); buf1.put_byte("5"); buf1.put_byte(`DQUOTE); buf1.parse_json;
    check(buf1.json_ok(), "parse quoted 5 failed");
    buf1.tok_as_int(buf1.json_root(), ival, ok);
    check(!ok, "a quoted number must be rejected, not coerced");

    buf1.reset; buf1.put_str("99999999999999999999"); buf1.parse_json;
    check(buf1.json_ok(), "parse of an overflowing literal should still succeed");
    buf1.tok_as_int(buf1.json_root(), ival, ok);
    check(!ok, "an overflowing integer must be rejected");

    buf1.reset; buf1.put_str("NaN"); buf1.parse_json;
    check(!buf1.json_ok(), "NaN is not valid JSON and must fail to parse at all");

    // === malformed input ===
    buf1.reset; buf1.put_str("{"); buf1.parse_json;
    check(!buf1.json_ok(), "unterminated object should fail to parse");

    buf1.reset;
    buf1.put_byte("{"); buf1.put_byte(`DQUOTE); buf1.put_byte("a"); buf1.put_byte(`DQUOTE);
    buf1.put_byte(":"); buf1.put_byte("}");
    buf1.parse_json;
    check(!buf1.json_ok(), "missing value should fail to parse");

    buf1.reset; buf1.put_str("01"); buf1.parse_json;
    check(!buf1.json_ok(), "a leading zero followed by more digits should fail to parse");

    buf1.reset; buf1.put_str("true false"); buf1.parse_json;
    check(!buf1.json_ok(), "trailing content after a value should fail to parse");

    // === UTF-8 passthrough plus a \u escape ===
    buf1.reset;
    buf1.put_byte(`DQUOTE);
    buf1.put_str({"caf", 8'hC3, 8'hA9}); // raw UTF-8 "café"
    buf1.put_str("!");
    buf1.put_byte(`DQUOTE);
    buf1.parse_json;
    check(buf1.json_ok(), "parse of a UTF-8 string failed");
    decode_into_outbuf(buf1.json_root());
    check(outbuf.length() == 6 && outbuf.get_byte(0) == "c" && outbuf.get_byte(1) == "a" &&
          outbuf.get_byte(2) == "f" && outbuf.get_byte(3) == 8'hC3 && outbuf.get_byte(4) == 8'hA9 &&
          outbuf.get_byte(5) == "!",
          "UTF-8 passthrough plus u-escape decode failed");

    // A literal e-acute escape, which must decode to U+00E9 = UTF-8 C3 A9.
    buf1.reset;
    buf1.put_byte(`DQUOTE);
    buf1.put_str({`BACKSLASH, "u00e9"});
    buf1.put_byte(`DQUOTE);
    buf1.parse_json;
    check(buf1.json_ok(), "parse of a u-escape failed");
    decode_into_outbuf(buf1.json_root());
    check(outbuf.length() == 2 && outbuf.get_byte(0) == 8'hC3 && outbuf.get_byte(1) == 8'hA9,
          "u00e9 should decode to UTF-8 C3 A9");

    if (failed == 0) $display("PASS json_test");
    else $display("FAIL json_test");
    $finish;
  end

endmodule
