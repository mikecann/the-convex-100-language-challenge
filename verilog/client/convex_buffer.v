// convex_buffer.v - a byte buffer with JSON encode/decode built in.
//
// Icarus Verilog (unlike GHDL's VHDL, see vhdl/client/convex_buffer.vhdl
// and vhdl/client/convex_json.vhdl, two separate packages that pass a
// caller's byte array by reference) does not support passing an unpacked
// array, a `ref` port, or even a dynamic `byte queue[$]`, into a task or
// function - each of those is either a flat "not supported" compile error
// or crashes the compiler outright (probed directly against this
// project's pinned iverilog 11.0 before this file was written). Every
// array here must therefore be MODULE state, reached only through a
// hierarchical name (`some_buffer.put_byte(...)`), never an argument -
// exactly the same restriction that makes native.c's foreign boundary
// byte-at-a-time. That restriction is also why JSON parsing lives in
// THIS module instead of a separate package the way VHDL splits it: a
// parser that reads someone else's buffer would need to take that buffer
// as an argument, which this toolchain cannot do. So a `convex_buffer`
// instance is both a byte buffer and, once `parse_json` has been called
// on it, a self-contained parsed JSON document over its own bytes - a
// "smart buffer" rather than a buffer plus a separate parser package.
//
// A second toolchain restriction shapes every task below: Icarus accepts
// a bare `return;` (no value) inside a FUNCTION only when every path
// still assigns the function's return value, and rejects it inside a
// TASK outright ("Cannot return from tasks"). Every task below therefore
// wraps its body in a named block (`begin : main ... end`) and uses
// `disable main;` for early exit - the standard pre-SystemVerilog
// Verilog idiom for "return" from a task, and the one this toolchain
// actually implements. A FUNCTION may not call a TASK at all (only
// another function), so any lookup that needs a byte-at-a-time decode
// (tok_eq_str) is itself a task, not a function - its callers store the
// result in a local variable before using it in a condition.
//
// Every instance of this module is one named buffer (a request body, a
// set of response headers, a response body, a WebSocket frame payload,
// scratch space for one JSON value) - the same "fixed set of purpose-
// built RAM blocks" a real circuit would use, not a dynamically-allocated
// object software would create per call.
`timescale 1ns / 1ps
`include "client/convex_chars.vh"

module convex_buffer #(
  parameter MAXLEN = 65536,
  parameter MAXTOK = 128
);

  // === raw byte storage ===============================================
  byte data [0:MAXLEN-1];
  integer len;
  // Set once a put_* call would have exceeded MAXLEN; every put_* becomes
  // a no-op after that rather than silently wrapping or corrupting data,
  // so a caller can check overflow once after building a whole message.
  reg overflow;

  initial begin
    len = 0;
    overflow = 1'b0;
  end

  task automatic reset;
    begin
      len = 0;
      overflow = 1'b0;
      ntoks = 0;
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

  task automatic put_str(input string s);
    integer i;
    begin
      for (i = 0; i < s.len(); i = i + 1) begin
        put_byte(s[i]);
      end
    end
  endtask

  // Decimal, handles negative values; matches JSON number syntax (no
  // leading zeros are ever produced since %0d never emits one).
  task automatic put_int(input integer n);
    begin
      put_str($sformatf("%0d", n));
    end
  endtask

  function automatic byte get_byte(input integer idx);
    return data[idx];
  endfunction

  function automatic integer length;
    return len;
  endfunction

  // === JSON encoding: appends directly into this buffer's own bytes ===

  task automatic json_put_escaped_byte(input byte b);
    begin
      case (b)
        8'h22: begin put_byte("\\"); put_byte("\""); end // "
        8'h5c: begin put_byte("\\"); put_byte("\\"); end // backslash
        8'h0a: begin put_byte("\\"); put_byte("n"); end
        8'h0d: begin put_byte("\\"); put_byte("r"); end
        8'h09: begin put_byte("\\"); put_byte("t"); end
        default: begin
          if (b < 8'h20) begin
            put_str($sformatf("\\u%04x", b));
          end else begin
            put_byte(b);
          end
        end
      endcase
    end
  endtask

  task automatic json_put_string(input string s);
    integer i;
    begin
      put_byte("\"");
      for (i = 0; i < s.len(); i = i + 1) begin
        json_put_escaped_byte(s[i]);
      end
      put_byte("\"");
    end
  endtask

  task automatic json_put_int(input integer n);
    begin
      put_int(n);
    end
  endtask

  task automatic json_put_bool(input bit b);
    begin
      if (b) put_str("true");
      else put_str("false");
    end
  endtask

  task automatic json_put_null;
    begin
      put_str("null");
    end
  endtask

  // === JSON parsing: tokenizes THIS buffer's own bytes (0 to len-1) ===
  //
  // A flat, bounded array of tokens rather than a tree of pointers -
  // VHDL's convex_json.vhdl uses the same non-recursive-storage
  // discipline (matching jsmn, the well-known embedded-systems JSON
  // tokenizer) for the same reason: no heap. Each token records only a
  // kind and a byte span into this buffer's own `data`, plus a parent
  // index; a STRING token's escapes are decoded lazily, only when a
  // caller actually reads that token's text.

  localparam KIND_UNDEFINED = 0;
  localparam KIND_NULL      = 1;
  localparam KIND_BOOL      = 2;
  localparam KIND_NUMBER    = 3;
  localparam KIND_STRING    = 4;
  localparam KIND_ARRAY     = 5;
  localparam KIND_OBJECT    = 6;

  integer tok_kind   [0:MAXTOK-1];
  integer tok_start  [0:MAXTOK-1];
  integer tok_stop   [0:MAXTOK-1];
  integer tok_parent [0:MAXTOK-1];
  reg     tok_bool   [0:MAXTOK-1];
  integer tok_value  [0:MAXTOK-1]; // meaningful only for a STRING key: its member's value token
  integer ntoks;
  // parse_json sets this; -1 (JSON_NO_TOK) when parsing failed.
  integer root_tok;
  reg     parse_ok;

  initial begin
    ntoks = 0;
    root_tok = -1;
    parse_ok = 1'b0;
  end

  function automatic bit is_digit(input byte b);
    return (b >= "0" && b <= "9");
  endfunction

  task automatic alloc_tok(
    input  integer kind,
    input  integer tstart,
    input  integer tstop,
    input  integer parent,
    output integer idx,
    output bit     ok
  );
    begin
      if (ntoks >= MAXTOK) begin
        idx = -1;
        ok = 1'b0;
      end else begin
        idx = ntoks;
        tok_kind[idx]   = kind;
        tok_start[idx]  = tstart;
        tok_stop[idx]   = tstop;
        tok_parent[idx] = parent;
        tok_bool[idx]   = 1'b0;
        tok_value[idx]  = -1;
        ntoks = ntoks + 1;
        ok = 1'b1;
      end
    end
  endtask

  integer parse_pos;

  task automatic skip_ws;
    begin
      while (parse_pos < len &&
             (data[parse_pos] == " " || data[parse_pos] == 8'h09 ||
              data[parse_pos] == 8'h0a || data[parse_pos] == 8'h0d)) begin
        parse_pos = parse_pos + 1;
      end
    end
  endtask

  // Forward-declared as automatic tasks so parse_value/parse_object/
  // parse_array can call each other (an object's value can itself be an
  // object; an array's element can itself be an array) - Icarus allows a
  // task to call one declared later in the same module.
  task automatic parse_value(input integer parent, output integer out_tok, output bit ok);
    byte c;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      skip_ws;
      if (parse_pos >= len) disable main;
      c = data[parse_pos];
      if (c == "{") parse_object(parent, out_tok, ok);
      else if (c == "[") parse_array(parent, out_tok, ok);
      else if (c == "\"") parse_string(parent, out_tok, ok);
      else if (c == "t") parse_true(parent, out_tok, ok);
      else if (c == "f") parse_false(parent, out_tok, ok);
      else if (c == "n") parse_null(parent, out_tok, ok);
      else if (c == "-" || is_digit(c)) parse_number(parent, out_tok, ok);
    end
  endtask

  task automatic parse_object(input integer parent, output integer out_tok, output bit ok);
    integer obj_tok, key_tok, val_tok;
    bit step_ok;
    byte c;
    bit looping;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      alloc_tok(KIND_OBJECT, parse_pos, parse_pos, parent, obj_tok, step_ok);
      if (!step_ok) disable main;
      parse_pos = parse_pos + 1; // consume '{'
      skip_ws;
      if (parse_pos < len && data[parse_pos] == "}") begin
        parse_pos = parse_pos + 1;
        tok_stop[obj_tok] = parse_pos;
        out_tok = obj_tok;
        ok = 1'b1;
        disable main;
      end
      looping = 1'b1;
      while (looping) begin
        skip_ws;
        if (parse_pos >= len || data[parse_pos] != "\"") disable main;
        parse_string(obj_tok, key_tok, step_ok);
        if (!step_ok) disable main;
        skip_ws;
        if (parse_pos >= len || data[parse_pos] != ":") disable main;
        parse_pos = parse_pos + 1;
        parse_value(key_tok, val_tok, step_ok);
        if (!step_ok) disable main;
        tok_value[key_tok] = val_tok;
        skip_ws;
        if (parse_pos >= len) disable main;
        c = data[parse_pos];
        if (c == ",") begin
          parse_pos = parse_pos + 1;
        end else if (c == "}") begin
          parse_pos = parse_pos + 1;
          tok_stop[obj_tok] = parse_pos;
          out_tok = obj_tok;
          ok = 1'b1;
          looping = 1'b0;
        end else begin
          disable main;
        end
      end
    end
  endtask

  task automatic parse_array(input integer parent, output integer out_tok, output bit ok);
    integer arr_tok, el_tok;
    bit step_ok;
    byte c;
    bit looping;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      alloc_tok(KIND_ARRAY, parse_pos, parse_pos, parent, arr_tok, step_ok);
      if (!step_ok) disable main;
      parse_pos = parse_pos + 1; // consume '['
      skip_ws;
      if (parse_pos < len && data[parse_pos] == "]") begin
        parse_pos = parse_pos + 1;
        tok_stop[arr_tok] = parse_pos;
        out_tok = arr_tok;
        ok = 1'b1;
        disable main;
      end
      looping = 1'b1;
      while (looping) begin
        parse_value(arr_tok, el_tok, step_ok);
        if (!step_ok) disable main;
        skip_ws;
        if (parse_pos >= len) disable main;
        c = data[parse_pos];
        if (c == ",") begin
          parse_pos = parse_pos + 1;
        end else if (c == "]") begin
          parse_pos = parse_pos + 1;
          tok_stop[arr_tok] = parse_pos;
          out_tok = arr_tok;
          ok = 1'b1;
          looping = 1'b0;
        end else begin
          disable main;
        end
      end
    end
  endtask

  // 0..15 for an ASCII hex digit, -1 otherwise.
  function automatic integer hex_digit_value(input byte b);
    begin
      if (b >= "0" && b <= "9") return b - "0";
      if (b >= "a" && b <= "f") return b - "a" + 10;
      if (b >= "A" && b <= "F") return b - "A" + 10;
      return -1;
    end
  endfunction

  // Validates and spans a JSON string starting at data[parse_pos] = '"',
  // without decoding its escapes; decode_str_start/next do that lazily,
  // only for a token a caller actually reads.
  task automatic parse_string(input integer parent, output integer out_tok, output bit ok);
    byte c;
    integer h;
    integer content_start;
    integer str_tok;
    bit step_ok;
    bit looping;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      parse_pos = parse_pos + 1; // consume opening '"'
      content_start = parse_pos;
      looping = 1'b1;
      while (looping) begin
        if (parse_pos >= len) disable main;
        c = data[parse_pos];
        if (c == "\"") begin
          parse_pos = parse_pos + 1;
          alloc_tok(KIND_STRING, content_start, parse_pos - 1, parent, str_tok, step_ok);
          if (!step_ok) disable main;
          out_tok = str_tok;
          ok = 1'b1;
          looping = 1'b0;
        end else if (c == "\\") begin
          parse_pos = parse_pos + 1;
          if (parse_pos >= len) disable main;
          c = data[parse_pos];
          case (c)
            "\"", "\\", "/", "b", "f", "n", "r", "t": parse_pos = parse_pos + 1;
            "u": begin
              if (parse_pos + 4 >= len) disable main;
              h = hex_digit_value(data[parse_pos + 1]);
              if (h < 0) disable main;
              h = hex_digit_value(data[parse_pos + 2]);
              if (h < 0) disable main;
              h = hex_digit_value(data[parse_pos + 3]);
              if (h < 0) disable main;
              h = hex_digit_value(data[parse_pos + 4]);
              if (h < 0) disable main;
              parse_pos = parse_pos + 5;
            end
            default: disable main;
          endcase
        end else if (c < 8'h20) begin
          disable main; // raw control character not allowed unescaped
        end else begin
          parse_pos = parse_pos + 1;
        end
      end
    end
  endtask

  task automatic parse_number(input integer parent, output integer out_tok, output bit ok);
    integer tstart;
    integer num_tok;
    bit step_ok;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      tstart = parse_pos;
      if (parse_pos < len && data[parse_pos] == "-") parse_pos = parse_pos + 1;
      if (parse_pos >= len || !is_digit(data[parse_pos])) disable main;
      if (data[parse_pos] == "0") begin
        parse_pos = parse_pos + 1; // leading zero is never followed by more int digits
      end else begin
        while (parse_pos < len && is_digit(data[parse_pos])) parse_pos = parse_pos + 1;
      end
      if (parse_pos < len && data[parse_pos] == ".") begin
        parse_pos = parse_pos + 1;
        if (parse_pos >= len || !is_digit(data[parse_pos])) disable main;
        while (parse_pos < len && is_digit(data[parse_pos])) parse_pos = parse_pos + 1;
      end
      if (parse_pos < len && (data[parse_pos] == "e" || data[parse_pos] == "E")) begin
        parse_pos = parse_pos + 1;
        if (parse_pos < len && (data[parse_pos] == "+" || data[parse_pos] == "-")) parse_pos = parse_pos + 1;
        if (parse_pos >= len || !is_digit(data[parse_pos])) disable main;
        while (parse_pos < len && is_digit(data[parse_pos])) parse_pos = parse_pos + 1;
      end
      alloc_tok(KIND_NUMBER, tstart, parse_pos, parent, num_tok, step_ok);
      if (!step_ok) disable main;
      out_tok = num_tok;
      ok = 1'b1;
    end
  endtask

  task automatic parse_true(input integer parent, output integer out_tok, output bit ok);
    integer tstart, btok;
    bit step_ok;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      tstart = parse_pos;
      if (parse_pos + 4 > len) disable main;
      if (data[parse_pos] == "t" && data[parse_pos+1] == "r" &&
          data[parse_pos+2] == "u" && data[parse_pos+3] == "e") begin
        parse_pos = parse_pos + 4;
        alloc_tok(KIND_BOOL, tstart, parse_pos, parent, btok, step_ok);
        if (!step_ok) disable main;
        tok_bool[btok] = 1'b1;
        out_tok = btok;
        ok = 1'b1;
      end
    end
  endtask

  task automatic parse_false(input integer parent, output integer out_tok, output bit ok);
    integer tstart, btok;
    bit step_ok;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      tstart = parse_pos;
      if (parse_pos + 5 > len) disable main;
      if (data[parse_pos] == "f" && data[parse_pos+1] == "a" && data[parse_pos+2] == "l" &&
          data[parse_pos+3] == "s" && data[parse_pos+4] == "e") begin
        parse_pos = parse_pos + 5;
        alloc_tok(KIND_BOOL, tstart, parse_pos, parent, btok, step_ok);
        if (!step_ok) disable main;
        tok_bool[btok] = 1'b0;
        out_tok = btok;
        ok = 1'b1;
      end
    end
  endtask

  task automatic parse_null(input integer parent, output integer out_tok, output bit ok);
    integer tstart, ntok_;
    bit step_ok;
    begin : main
      out_tok = -1;
      ok = 1'b0;
      tstart = parse_pos;
      if (parse_pos + 4 > len) disable main;
      if (data[parse_pos] == "n" && data[parse_pos+1] == "u" &&
          data[parse_pos+2] == "l" && data[parse_pos+3] == "l") begin
        parse_pos = parse_pos + 4;
        alloc_tok(KIND_NULL, tstart, parse_pos, parent, ntok_, step_ok);
        if (!step_ok) disable main;
        out_tok = ntok_;
        ok = 1'b1;
      end
    end
  endtask

  // Parses this buffer's own data[0 to len-1] as one JSON document. Sets
  // root_tok and parse_ok; a caller reads those (or the convenience
  // json_ok/json_root functions below) rather than being handed them
  // through output ports, so the same task signature works whether or
  // not a caller wants the failure reason.
  task automatic parse_json;
    integer root;
    bit step_ok;
    begin : main
      ntoks = 0;
      parse_pos = 0;
      parse_value(-1, root, step_ok);
      root_tok = root;
      parse_ok = 1'b0;
      if (!step_ok) disable main;
      skip_ws;
      if (parse_pos != len) disable main; // trailing non-whitespace content
      parse_ok = 1'b1;
    end
  endtask

  function automatic bit json_ok;
    return parse_ok;
  endfunction

  function automatic integer json_root;
    return root_tok;
  endfunction

  // === JSON accessors, all reading this buffer's own tok_* arrays =====

  task automatic json_object_get(
    input  integer obj_tok,
    input  string  key,
    output integer val_tok,
    output bit     found
  );
    integer i;
    bit eq;
    begin : main
      val_tok = -1;
      found = 1'b0;
      if (obj_tok < 0 || ntoks == 0) disable main;
      if (tok_kind[obj_tok] != KIND_OBJECT) disable main;
      for (i = 0; i < ntoks; i = i + 1) begin
        if (!found && tok_parent[i] == obj_tok && tok_kind[i] == KIND_STRING) begin
          tok_eq_str(i, key, eq);
          if (eq) begin
            val_tok = tok_value[i];
            found = 1'b1;
          end
        end
      end
    end
  endtask

  function automatic integer json_array_nth(input integer arr_tok, input integer n);
    integer i;
    integer seen;
    integer result;
    begin
      result = -1;
      seen = 0;
      if (arr_tok >= 0 && ntoks != 0 && tok_kind[arr_tok] == KIND_ARRAY) begin
        for (i = 0; i < ntoks; i = i + 1) begin
          if (result < 0 && tok_parent[i] == arr_tok) begin
            if (seen == n) result = i;
            seen = seen + 1;
          end
        end
      end
      return result;
    end
  endfunction

  function automatic integer json_child_count(input integer container_tok);
    integer i;
    integer cnt;
    begin
      cnt = 0;
      if (container_tok >= 0 && ntoks != 0 &&
          (tok_kind[container_tok] == KIND_ARRAY || tok_kind[container_tok] == KIND_OBJECT)) begin
        for (i = 0; i < ntoks; i = i + 1) begin
          if (tok_parent[i] == container_tok) begin
            if (tok_kind[container_tok] == KIND_ARRAY || tok_kind[i] == KIND_STRING) begin
              cnt = cnt + 1;
            end
          end
        end
      end
      return cnt;
    end
  endfunction

  function automatic integer json_kind(input integer tok);
    begin
      if (tok < 0) return KIND_UNDEFINED;
      return tok_kind[tok];
    end
  endfunction

  // Raw (un-escape-decoded) byte span of tok within THIS buffer's own
  // data, for a caller that needs to copy a token's exact source text
  // verbatim - e.g. convex_sync.v comparing two Live values byte-for-
  // byte for the rehydration-suppression rule, where re-encoding
  // through decode_str_next and back would risk normalizing away a
  // difference that should have suppressed (or not suppressed) an
  // event. Copy with `for (i = tok_span_start(t); i < tok_span_stop(t);
  // i = i + 1) dest.put_byte(get_byte(i));` - a plain function-argument
  // use, not a `{...}` concatenation, so none of convex_http.v's
  // string-concatenation workarounds apply to it.
  function automatic integer tok_span_start(input integer tok);
    return tok_start[tok];
  endfunction

  function automatic integer tok_span_stop(input integer tok);
    return tok_stop[tok];
  endfunction

  function automatic bit json_bool_value(input integer tok);
    return tok_bool[tok];
  endfunction

  // Decodes one escape (or literal ASCII byte) starting at p and returns
  // the resolved codepoint, advancing p past it. cp is set to -1 on a
  // malformed escape. Astral codepoints via a \uD800-\uDBFF + \uDC00-
  // \uDFFF surrogate pair are a known, documented limitation (see
  // README): this rejects a lone surrogate half rather than combining a
  // pair, so a BMP character always decodes correctly but an astral one
  // (emoji, some CJK extension characters) does not. Convex's own
  // protocol control text (paths, member names, status fields) never
  // contains one; a user data string that does would fail to decode.
  task automatic decode_one(inout integer p, input integer stop, output integer cp);
    byte c;
    integer h1, h2, h3, h4;
    begin : main
      cp = -1;
      if (p >= stop) disable main;
      c = data[p];
      if (c != "\\") begin
        cp = c;
        p = p + 1;
        disable main;
      end
      p = p + 1;
      if (p >= stop) disable main;
      c = data[p];
      case (c)
        "\"": begin cp = 34; p = p + 1; end
        "\\": begin cp = 92; p = p + 1; end
        "/":  begin cp = 47; p = p + 1; end
        "b":  begin cp = 8;  p = p + 1; end
        "f":  begin cp = 12; p = p + 1; end
        "n":  begin cp = 10; p = p + 1; end
        "r":  begin cp = 13; p = p + 1; end
        "t":  begin cp = 9;  p = p + 1; end
        "u": begin
          if (p + 4 >= stop) disable main;
          h1 = hex_digit_value(data[p+1]);
          h2 = hex_digit_value(data[p+2]);
          h3 = hex_digit_value(data[p+3]);
          h4 = hex_digit_value(data[p+4]);
          if (h1 < 0 || h2 < 0 || h3 < 0 || h4 < 0) disable main;
          cp = h1 * 4096 + h2 * 256 + h3 * 16 + h4;
          p = p + 5;
          if (cp >= 'hD800 && cp <= 'hDFFF) cp = -1; // surrogate half: see task comment
        end
        default: cp = -1;
      endcase
    end
  endtask

  // Streaming decode cursor over one STRING token: call decode_str_start
  // once, then decode_str_next repeatedly (each call returns one decoded
  // UTF-8 byte and done=0, or done=1 once the token is exhausted) so a
  // caller can copy the decoded text into ANY destination buffer with
  // `dest.put_byte(b)` in the same loop, without this module ever
  // needing to accept that destination as an argument.
  integer  ds_pos;
  integer  ds_stop;
  integer  ds_pending [0:3];
  integer  ds_pending_len;
  integer  ds_pending_pos;

  task automatic decode_str_start(input integer tok);
    begin
      ds_pos = tok_start[tok];
      ds_stop = tok_stop[tok];
      ds_pending_len = 0;
      ds_pending_pos = 0;
    end
  endtask

  task automatic decode_str_next(output byte b, output bit done);
    integer cp;
    begin : main
      done = 1'b0;
      b = 8'h00;
      if (ds_pending_pos < ds_pending_len) begin
        b = ds_pending[ds_pending_pos];
        ds_pending_pos = ds_pending_pos + 1;
        disable main;
      end
      if (ds_pos >= ds_stop) begin
        done = 1'b1;
        disable main;
      end
      // A raw input byte - including every continuation byte of a
      // multi-byte UTF-8 character - passes through unchanged, one byte
      // at a time: reinterpreting one as a codepoint and re-encoding it
      // would corrupt every non-ASCII character into mojibake (the same
      // rule VHDL's json_tok_get_str states explicitly). Only a `\`
      // escape represents an actual Unicode codepoint that needs UTF-8
      // encoding below.
      if (data[ds_pos] != `BACKSLASH) begin
        b = data[ds_pos];
        ds_pos = ds_pos + 1;
        disable main;
      end
      decode_one(ds_pos, ds_stop, cp);
      if (cp < 0) begin
        done = 1'b1; // malformed escape: stop decoding, same as VHDL's silent-stop-at-capacity policy
        disable main;
      end
      // UTF-8 encode cp into the pending queue, then emit its first byte.
      ds_pending_len = 0;
      if (cp <= 'h7F) begin
        ds_pending[ds_pending_len] = cp; ds_pending_len = ds_pending_len + 1;
      end else if (cp <= 'h7FF) begin
        ds_pending[ds_pending_len] = 'hC0 + cp / 64; ds_pending_len = ds_pending_len + 1;
        ds_pending[ds_pending_len] = 'h80 + cp % 64; ds_pending_len = ds_pending_len + 1;
      end else begin
        ds_pending[ds_pending_len] = 'hE0 + cp / 4096; ds_pending_len = ds_pending_len + 1;
        ds_pending[ds_pending_len] = 'h80 + (cp / 64) % 64; ds_pending_len = ds_pending_len + 1;
        ds_pending[ds_pending_len] = 'h80 + cp % 64; ds_pending_len = ds_pending_len + 1;
      end
      ds_pending_pos = 0;
      b = ds_pending[ds_pending_pos];
      ds_pending_pos = ds_pending_pos + 1;
    end
  endtask

  // True when tok is a STRING token whose decoded text equals s exactly.
  // s is always plain ASCII here (every key name and literal this client
  // compares against is ASCII), so any escape or raw byte that decodes
  // above U+007F simply cannot match. A task, not a function, because it
  // must call decode_one (a task) - see the file header.
  task automatic tok_eq_str(input integer tok, input string s, output bit eq);
    integer p, stop, cp;
    integer si;
    bit mismatch;
    begin : main
      eq = 1'b0;
      if (tok < 0 || tok_kind[tok] != KIND_STRING) disable main;
      p = tok_start[tok];
      stop = tok_stop[tok];
      si = 0;
      mismatch = 1'b0;
      while (p < stop && !mismatch) begin
        decode_one(p, stop, cp);
        if (cp < 0 || cp > 127) begin
          mismatch = 1'b1;
        end else if (si >= s.len()) begin
          mismatch = 1'b1;
        end else if (s[si] != cp) begin
          mismatch = 1'b1;
        end else begin
          si = si + 1;
        end
      end
      eq = (!mismatch && si == s.len());
    end
  endtask

  // Interprets tok as an integer per AGENTS.md's rule: a NUMBER token
  // (never a quoted string, even "5") whose text is mathematically
  // integral - "0.0", "1.0" and "1e2" all qualify, exactly like a bare
  // "0", "1" or "100" - and whose value fits in a 32-bit integer. A
  // fractional value such as "1.5" and an overflowing value are both
  // rejected.
  task automatic tok_as_int(input integer tok, output integer value, output bit ok);
    integer p, stop;
    bit neg;
    byte digits_buf [0:39];
    integer ndigits, frac_digits;
    integer exp_val;
    bit exp_neg;
    integer shift;
    longint acc;
    bit overflow_;
    integer i;
    begin : main
      value = 0;
      ok = 1'b0;
      if (tok < 0 || tok_kind[tok] != KIND_NUMBER) disable main;
      p = tok_start[tok];
      stop = tok_stop[tok];
      neg = 1'b0;
      if (p < stop && data[p] == "-") begin neg = 1'b1; p = p + 1; end
      ndigits = 0;
      frac_digits = 0;
      exp_val = 0;
      exp_neg = 1'b0;
      overflow_ = 1'b0;
      while (p < stop && is_digit(data[p])) begin
        if (ndigits <= 39) begin digits_buf[ndigits] = data[p] - "0"; ndigits = ndigits + 1; end
        else overflow_ = 1'b1;
        p = p + 1;
      end
      if (p < stop && data[p] == ".") begin
        p = p + 1;
        while (p < stop && is_digit(data[p])) begin
          if (ndigits <= 39) begin
            digits_buf[ndigits] = data[p] - "0";
            ndigits = ndigits + 1;
            frac_digits = frac_digits + 1;
          end else overflow_ = 1'b1;
          p = p + 1;
        end
      end
      if (p < stop && (data[p] == "e" || data[p] == "E")) begin
        p = p + 1;
        if (p < stop && (data[p] == "+" || data[p] == "-")) begin
          exp_neg = (data[p] == "-");
          p = p + 1;
        end
        while (p < stop && is_digit(data[p])) begin
          exp_val = exp_val * 10 + (data[p] - "0");
          p = p + 1;
        end
        if (exp_neg) exp_val = -exp_val;
      end
      if (overflow_ || p != stop || ndigits == 0) disable main;

      // shift is how many decimal places the fractional/exponent part
      // moves the value's true magnitude: negative means digits below
      // the decimal point must actually be zero for the value to be an
      // integer at all.
      shift = exp_val - frac_digits;
      if (shift < 0) begin
        if (-shift > ndigits) disable main;
        for (i = ndigits + shift; i < ndigits; i = i + 1) begin
          if (digits_buf[i] != 0) disable main; // nonzero digit below the decimal point
        end
        ndigits = ndigits + shift;
        shift = 0;
      end

      acc = 0;
      for (i = 0; i < ndigits; i = i + 1) begin
        acc = acc * 10 + digits_buf[i];
        if (acc > 64'h7FFFFFFF) disable main; // overflow, checked after each digit
      end
      for (i = 0; i < shift; i = i + 1) begin
        acc = acc * 10;
        if (acc > 64'h7FFFFFFF) disable main;
      end
      if (neg) acc = -acc;
      value = acc;
      ok = 1'b1;
    end
  endtask

endmodule
