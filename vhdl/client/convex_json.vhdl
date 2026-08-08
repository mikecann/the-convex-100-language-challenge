-- convex_json.vhdl - a small hand-written JSON encoder and decoder.
--
-- VHDL has no heap, no dynamically growing array and no tagged union, so a
-- parsed document is not a tree of pointers: it is a flat, bounded array of
-- tokens (the same non-recursive-storage discipline jsmn, the well-known
-- embedded-systems JSON tokenizer, uses in C for the same reason). Each
-- token records only a kind and a byte span into the caller's own input
-- buffer, plus a parent index; nothing is copied or allocated during
-- parsing. Decoding a string's escapes, or a number's exact value, happens
-- lazily in the accessor functions below, only for the specific token a
-- caller actually asks about.
--
-- The parser itself is an ordinary recursive-descent parser -- GHDL
-- supports recursive subprograms (see the empirical proof this client's
-- checkpoint history records), so json_parse, parse_value, parse_object and
-- parse_array call each other directly rather than threading an explicit
-- stack through by hand.
--
-- Encoding is the mirror of convex_buffer.vhdl's own style: bounded
-- procedures that append directly into a caller's byte buffer. There is no
-- generic "value" type to build first, because every JSON document this
-- client sends has a shape it already knows -- the request envelope, or one
-- /api/sync message -- so writing it directly is simpler and needs no
-- allocation at all.
use work.convex_buffer.all;

package convex_json is

  type json_kind_t is (JSON_UNDEFINED, JSON_NULL, JSON_BOOL, JSON_NUMBER, JSON_STRING, JSON_ARRAY, JSON_OBJECT);

  -- start/stop bound a token's raw content in the input buffer: for a
  -- STRING, the bytes between (not including) the quotes, still escaped;
  -- for a NUMBER, its full text; for OBJECT/ARRAY, the whole `{...}` or
  -- `[...]` span. bool_value is only meaningful when kind = JSON_BOOL.
  -- value_tok is only meaningful when kind = JSON_STRING and this token is
  -- an object member's key: it points at the token holding that member's
  -- value, so a caller never needs to scan past a key to find it.
  type json_tok_t is record
    kind       : json_kind_t;
    start      : natural;
    stop       : natural;
    parent     : integer;
    bool_value : boolean;
    value_tok  : integer;
  end record json_tok_t;

  type json_tok_array is array (natural range <>) of json_tok_t;

  constant JSON_NO_TOK : integer := -1;

  -- Parses one JSON document from buf(buf'low to buf'low + buflen - 1) into
  -- toks, starting at toks'low. ok is false for malformed input, trailing
  -- non-whitespace content after the value, or more tokens than toks has
  -- room for.
  procedure json_parse(
    buf    : in byte_array;
    buflen : in natural;
    toks   : inout json_tok_array;
    ntoks  : out natural;
    ok     : out boolean
  );

  -- Looks up a member of an OBJECT token by key. found is false when
  -- obj_tok is not an OBJECT token or has no member with that key.
  procedure json_object_get(
    buf     : in byte_array;
    toks    : in json_tok_array;
    ntoks   : in natural;
    obj_tok : in integer;
    key     : in string;
    val_tok : out integer;
    found   : out boolean
  );

  -- The number of direct members of an OBJECT token, or elements of an
  -- ARRAY token; 0 for anything else.
  function json_child_count(toks : json_tok_array; ntoks : natural; container_tok : integer) return natural;

  -- The token index of the 0-based nth direct element of an ARRAY token, or
  -- JSON_NO_TOK if container_tok is not an array or n is out of range.
  function json_array_nth(toks : json_tok_array; ntoks : natural; arr_tok : integer; n : natural) return integer;

  -- True when tok is a STRING token whose decoded text equals s exactly.
  -- Every JSON escape sequence in the token is resolved for the comparison,
  -- including \uXXXX; s is always compared as plain ASCII (every key name
  -- and literal this client compares against is ASCII), so any escape or
  -- raw byte that decodes above U+007F simply cannot match and short-
  -- circuits the comparison rather than needing full UTF-8 re-encoding
  -- here.
  function json_tok_eq_str(buf : byte_array; toks : json_tok_array; tok : integer; s : string) return boolean;

  -- Copies a STRING token's decoded text -- with every escape resolved and
  -- every raw input byte otherwise passed through unchanged -- onto the end
  -- of dst. Silently stops at dst's capacity, matching convex_buffer.vhdl's
  -- own bounded-buffer convention: every caller in this client sizes its
  -- buffers generously for the protocol text it decodes.
  procedure json_tok_get_str(
    buf    : in byte_array;
    toks   : in json_tok_array;
    tok    : in integer;
    dst    : inout byte_array;
    dstlen : inout natural
  );

  -- Interprets a NUMBER token as an integer. ok is false unless tok is a
  -- NUMBER token (never a STRING, even a quoted digit sequence: "quoted"
  -- values are always rejected) whose text is mathematically integral --
  -- "0.0", "1.0" and "1e2" all qualify, exactly like a bare "0", "1" or
  -- "100" -- and whose value fits in VHDL's `integer`. A fractional value
  -- such as "1.5", and a value that would overflow, are both rejected.
  -- JSON has no literal for a non-finite number, so one can only ever
  -- appear as a bareword the parser already refused to tokenize as a
  -- NUMBER in the first place.
  procedure json_tok_as_int(
    buf   : in byte_array;
    toks  : in json_tok_array;
    tok   : in integer;
    value : out integer;
    ok    : out boolean
  );

  -- === encoding: appends directly into a caller's byte buffer ===

  procedure json_put_string(buf : inout byte_array; len : inout natural; s : in string);

  -- The byte-buffer equivalent of json_put_string, for a string this
  -- client already holds as a byte slice (typically one just decoded with
  -- json_tok_get_str) rather than a VHDL string literal.
  procedure json_put_string_bytes(
    dst    : inout byte_array;
    dstlen : inout natural;
    src    : in byte_array;
    srcoff : in natural;
    srclen : in natural
  );

  procedure json_put_int(buf : inout byte_array; len : inout natural; n : in integer);
  procedure json_put_bool(buf : inout byte_array; len : inout natural; b : in boolean);
  procedure json_put_null(buf : inout byte_array; len : inout natural);

end package convex_json;

package body convex_json is

  -- Forward declarations: json_parse's value/object/array/string/number
  -- helpers call each other directly (an object's value can itself be an
  -- object; an array's element can itself be an array), so each needs to
  -- be visible to the others before its own body is given.
  procedure parse_value(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_object(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_array(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_string(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_number(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_true(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_false(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );
  procedure parse_null(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  );

  procedure skip_ws(buf : in byte_array; buflen : in natural; pos : inout natural) is
  begin
    while pos < buflen and
          (buf(pos) = 32 or buf(pos) = 9 or buf(pos) = 10 or buf(pos) = 13) loop
      pos := pos + 1;
    end loop;
  end procedure skip_ws;

  -- 0..15 for an ASCII hex digit, -1 otherwise.
  function hex_digit_value(b : byte_t) return integer is
  begin
    if b >= character'pos('0') and b <= character'pos('9') then
      return b - character'pos('0');
    elsif b >= character'pos('a') and b <= character'pos('f') then
      return b - character'pos('a') + 10;
    elsif b >= character'pos('A') and b <= character'pos('F') then
      return b - character'pos('A') + 10;
    end if;
    return -1;
  end function hex_digit_value;

  procedure alloc_tok(
    toks   : inout json_tok_array;
    ntoks  : inout natural;
    kind   : in json_kind_t;
    tstart : in natural;
    tstop  : in natural;
    parent : in integer;
    idx    : out integer;
    ok     : out boolean
  ) is
  begin
    if ntoks >= toks'length then
      idx := JSON_NO_TOK;
      ok := false;
      return;
    end if;
    idx := toks'low + ntoks;
    toks(idx) := (
      kind => kind, start => tstart, stop => tstop, parent => parent,
      bool_value => false, value_tok => JSON_NO_TOK
    );
    ntoks := ntoks + 1;
    ok := true;
  end procedure alloc_tok;

  procedure parse_value(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable c : byte_t;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    skip_ws(buf, buflen, pos);
    if pos >= buflen then
      return;
    end if;
    c := buf(pos);
    if c = character'pos('{') then
      parse_object(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    elsif c = character'pos('[') then
      parse_array(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    elsif c = character'pos('"') then
      parse_string(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    elsif c = character'pos('t') then
      parse_true(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    elsif c = character'pos('f') then
      parse_false(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    elsif c = character'pos('n') then
      parse_null(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    elsif c = character'pos('-') or (c >= character'pos('0') and c <= character'pos('9')) then
      parse_number(buf, buflen, pos, toks, ntoks, parent, out_tok, ok);
    end if;
  end procedure parse_value;

  procedure parse_object(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable obj_tok, key_tok, val_tok : integer;
    variable c : byte_t;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    alloc_tok(toks, ntoks, JSON_OBJECT, pos, pos, parent, obj_tok, step_ok);
    if not step_ok then
      return;
    end if;
    pos := pos + 1; -- consume '{'
    skip_ws(buf, buflen, pos);
    if pos < buflen and buf(pos) = character'pos('}') then
      pos := pos + 1;
      toks(obj_tok).stop := pos;
      out_tok := obj_tok;
      ok := true;
      return;
    end if;
    loop
      skip_ws(buf, buflen, pos);
      if pos >= buflen or buf(pos) /= character'pos('"') then
        return;
      end if;
      parse_string(buf, buflen, pos, toks, ntoks, obj_tok, key_tok, step_ok);
      if not step_ok then
        return;
      end if;
      skip_ws(buf, buflen, pos);
      if pos >= buflen or buf(pos) /= character'pos(':') then
        return;
      end if;
      pos := pos + 1; -- consume ':'
      parse_value(buf, buflen, pos, toks, ntoks, key_tok, val_tok, step_ok);
      if not step_ok then
        return;
      end if;
      toks(key_tok).value_tok := val_tok;
      skip_ws(buf, buflen, pos);
      if pos >= buflen then
        return;
      end if;
      c := buf(pos);
      if c = character'pos(',') then
        pos := pos + 1;
      elsif c = character'pos('}') then
        pos := pos + 1;
        exit;
      else
        return;
      end if;
    end loop;
    toks(obj_tok).stop := pos;
    out_tok := obj_tok;
    ok := true;
  end procedure parse_object;

  procedure parse_array(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable arr_tok, el_tok : integer;
    variable c : byte_t;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    alloc_tok(toks, ntoks, JSON_ARRAY, pos, pos, parent, arr_tok, step_ok);
    if not step_ok then
      return;
    end if;
    pos := pos + 1; -- consume '['
    skip_ws(buf, buflen, pos);
    if pos < buflen and buf(pos) = character'pos(']') then
      pos := pos + 1;
      toks(arr_tok).stop := pos;
      out_tok := arr_tok;
      ok := true;
      return;
    end if;
    loop
      parse_value(buf, buflen, pos, toks, ntoks, arr_tok, el_tok, step_ok);
      if not step_ok then
        return;
      end if;
      skip_ws(buf, buflen, pos);
      if pos >= buflen then
        return;
      end if;
      c := buf(pos);
      if c = character'pos(',') then
        pos := pos + 1;
      elsif c = character'pos(']') then
        pos := pos + 1;
        exit;
      else
        return;
      end if;
    end loop;
    toks(arr_tok).stop := pos;
    out_tok := arr_tok;
    ok := true;
  end procedure parse_array;

  -- Validates and spans a JSON string starting at buf(pos) = '"', without
  -- decoding its escapes; json_tok_get_str and json_tok_eq_str do that
  -- lazily, only for a token a caller actually inspects.
  procedure parse_string(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable content_start : natural;
    variable c : byte_t;
    variable h : integer;
    variable str_tok : integer;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    pos := pos + 1; -- consume opening '"'
    content_start := pos;
    loop
      if pos >= buflen then
        return;
      end if;
      c := buf(pos);
      if c = character'pos('"') then
        exit;
      elsif c = character'pos('\') then
        pos := pos + 1;
        if pos >= buflen then
          return;
        end if;
        c := buf(pos);
        case c is
          when 34 | 92 | 47 | 98 | 102 | 110 | 114 | 116 => -- " \ / b f n r t
            pos := pos + 1;
          when 117 => -- u
            if pos + 4 >= buflen then
              return;
            end if;
            for i in 1 to 4 loop
              h := hex_digit_value(buf(pos + i));
              if h < 0 then
                return;
              end if;
            end loop;
            pos := pos + 5;
          when others =>
            return;
        end case;
      elsif c < 32 then
        return; -- raw control character is not allowed unescaped
      else
        pos := pos + 1;
      end if;
    end loop;
    alloc_tok(toks, ntoks, JSON_STRING, content_start, pos, parent, str_tok, step_ok);
    if not step_ok then
      return;
    end if;
    pos := pos + 1; -- consume closing '"'
    out_tok := str_tok;
    ok := true;
  end procedure parse_string;

  procedure parse_number(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable tstart : natural;
    variable num_tok : integer;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    tstart := pos;
    if pos < buflen and buf(pos) = character'pos('-') then
      pos := pos + 1;
    end if;
    if pos >= buflen or buf(pos) < character'pos('0') or buf(pos) > character'pos('9') then
      return;
    end if;
    if buf(pos) = character'pos('0') then
      pos := pos + 1; -- a leading zero is never followed by more int digits
    else
      while pos < buflen and buf(pos) >= character'pos('0') and buf(pos) <= character'pos('9') loop
        pos := pos + 1;
      end loop;
    end if;
    if pos < buflen and buf(pos) = character'pos('.') then
      pos := pos + 1;
      if pos >= buflen or buf(pos) < character'pos('0') or buf(pos) > character'pos('9') then
        return;
      end if;
      while pos < buflen and buf(pos) >= character'pos('0') and buf(pos) <= character'pos('9') loop
        pos := pos + 1;
      end loop;
    end if;
    if pos < buflen and (buf(pos) = character'pos('e') or buf(pos) = character'pos('E')) then
      pos := pos + 1;
      if pos < buflen and (buf(pos) = character'pos('+') or buf(pos) = character'pos('-')) then
        pos := pos + 1;
      end if;
      if pos >= buflen or buf(pos) < character'pos('0') or buf(pos) > character'pos('9') then
        return;
      end if;
      while pos < buflen and buf(pos) >= character'pos('0') and buf(pos) <= character'pos('9') loop
        pos := pos + 1;
      end loop;
    end if;
    alloc_tok(toks, ntoks, JSON_NUMBER, tstart, pos, parent, num_tok, step_ok);
    if not step_ok then
      return;
    end if;
    out_tok := num_tok;
    ok := true;
  end procedure parse_number;

  procedure parse_true(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable tstart : natural;
    variable btok : integer;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    tstart := pos;
    if pos + 4 > buflen then
      return;
    end if;
    if buf(pos) = character'pos('t') and buf(pos + 1) = character'pos('r') and
       buf(pos + 2) = character'pos('u') and buf(pos + 3) = character'pos('e') then
      pos := pos + 4;
      alloc_tok(toks, ntoks, JSON_BOOL, tstart, pos, parent, btok, step_ok);
      if not step_ok then
        return;
      end if;
      toks(btok).bool_value := true;
      out_tok := btok;
      ok := true;
    end if;
  end procedure parse_true;

  procedure parse_false(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable tstart : natural;
    variable btok : integer;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    tstart := pos;
    if pos + 5 > buflen then
      return;
    end if;
    if buf(pos) = character'pos('f') and buf(pos + 1) = character'pos('a') and
       buf(pos + 2) = character'pos('l') and buf(pos + 3) = character'pos('s') and
       buf(pos + 4) = character'pos('e') then
      pos := pos + 5;
      alloc_tok(toks, ntoks, JSON_BOOL, tstart, pos, parent, btok, step_ok);
      if not step_ok then
        return;
      end if;
      toks(btok).bool_value := false;
      out_tok := btok;
      ok := true;
    end if;
  end procedure parse_false;

  procedure parse_null(
    buf : in byte_array; buflen : in natural; pos : inout natural;
    toks : inout json_tok_array; ntoks : inout natural;
    parent : in integer; out_tok : out integer; ok : out boolean
  ) is
    variable tstart : natural;
    variable ntok : integer;
    variable step_ok : boolean;
  begin
    out_tok := JSON_NO_TOK;
    ok := false;
    tstart := pos;
    if pos + 4 > buflen then
      return;
    end if;
    if buf(pos) = character'pos('n') and buf(pos + 1) = character'pos('u') and
       buf(pos + 2) = character'pos('l') and buf(pos + 3) = character'pos('l') then
      pos := pos + 4;
      alloc_tok(toks, ntoks, JSON_NULL, tstart, pos, parent, ntok, step_ok);
      if not step_ok then
        return;
      end if;
      out_tok := ntok;
      ok := true;
    end if;
  end procedure parse_null;

  procedure json_parse(
    buf    : in byte_array;
    buflen : in natural;
    toks   : inout json_tok_array;
    ntoks  : out natural;
    ok     : out boolean
  ) is
    variable pos : natural := buf'low;
    variable root : integer;
    variable step_ok : boolean;
    variable local_ntoks : natural := 0;
  begin
    parse_value(buf, buf'low + buflen, pos, toks, local_ntoks, JSON_NO_TOK, root, step_ok);
    ntoks := local_ntoks;
    ok := false;
    if not step_ok then
      return;
    end if;
    skip_ws(buf, buf'low + buflen, pos);
    if pos /= buf'low + buflen then
      return; -- trailing non-whitespace content
    end if;
    ok := true;
  end procedure json_parse;

  procedure json_object_get(
    buf     : in byte_array;
    toks    : in json_tok_array;
    ntoks   : in natural;
    obj_tok : in integer;
    key     : in string;
    val_tok : out integer;
    found   : out boolean
  ) is
  begin
    found := false;
    val_tok := JSON_NO_TOK;
    if obj_tok = JSON_NO_TOK or ntoks = 0 then
      return;
    end if;
    if toks(obj_tok).kind /= JSON_OBJECT then
      return;
    end if;
    for i in toks'low to toks'low + ntoks - 1 loop
      if toks(i).parent = obj_tok and toks(i).kind = JSON_STRING then
        if json_tok_eq_str(buf, toks, i, key) then
          val_tok := toks(i).value_tok;
          found := true;
          return;
        end if;
      end if;
    end loop;
  end procedure json_object_get;

  function json_child_count(toks : json_tok_array; ntoks : natural; container_tok : integer) return natural is
    variable cnt : natural := 0;
  begin
    if container_tok = JSON_NO_TOK or ntoks = 0 then
      return 0;
    end if;
    if toks(container_tok).kind /= JSON_ARRAY and toks(container_tok).kind /= JSON_OBJECT then
      return 0;
    end if;
    for i in toks'low to toks'low + ntoks - 1 loop
      if toks(i).parent = container_tok then
        if toks(container_tok).kind = JSON_ARRAY or toks(i).kind = JSON_STRING then
          cnt := cnt + 1;
        end if;
      end if;
    end loop;
    return cnt;
  end function json_child_count;

  function json_array_nth(toks : json_tok_array; ntoks : natural; arr_tok : integer; n : natural) return integer is
    variable seen : natural := 0;
  begin
    if arr_tok = JSON_NO_TOK or ntoks = 0 then
      return JSON_NO_TOK;
    end if;
    if toks(arr_tok).kind /= JSON_ARRAY then
      return JSON_NO_TOK;
    end if;
    for i in toks'low to toks'low + ntoks - 1 loop
      if toks(i).parent = arr_tok then
        if seen = n then
          return i;
        end if;
        seen := seen + 1;
      end if;
    end loop;
    return JSON_NO_TOK;
  end function json_array_nth;

  function json_tok_eq_str(buf : byte_array; toks : json_tok_array; tok : integer; s : string) return boolean is
    variable p, stop : natural;
    variable si : integer;
    variable c : byte_t;
    variable cp : integer;
    variable h1, h2, h3, h4 : integer;
  begin
    if tok = JSON_NO_TOK or toks(tok).kind /= JSON_STRING then
      return false;
    end if;
    p := toks(tok).start;
    stop := toks(tok).stop;
    si := s'low;
    while p < stop loop
      c := buf(p);
      if c /= character'pos('\') then
        if c > 127 then
          return false; -- s is always ASCII; a raw non-ASCII byte can never match
        end if;
        cp := c;
        p := p + 1;
      else
        p := p + 1;
        if p >= stop then
          return false;
        end if;
        case buf(p) is
          when 34 => cp := 34; p := p + 1; -- "
          when 92 => cp := 92; p := p + 1; -- backslash
          when 47 => cp := 47; p := p + 1; -- /
          when 98 => cp := 8; p := p + 1;  -- b
          when 102 => cp := 12; p := p + 1; -- f
          when 110 => cp := 10; p := p + 1; -- n
          when 114 => cp := 13; p := p + 1; -- r
          when 116 => cp := 9; p := p + 1;  -- t
          when 117 => -- u: any \uXXXX decodes to a codepoint that is either
                       -- a literal ASCII value handled by the digits below,
                       -- or > 127 (including every surrogate half), and s
                       -- can only ever equal an ASCII byte, so the exact
                       -- surrogate-pair codepoint never needs computing here.
            if p + 4 >= stop then
              return false;
            end if;
            h1 := hex_digit_value(buf(p + 1));
            h2 := hex_digit_value(buf(p + 2));
            h3 := hex_digit_value(buf(p + 3));
            h4 := hex_digit_value(buf(p + 4));
            if h1 < 0 or h2 < 0 or h3 < 0 or h4 < 0 then
              return false;
            end if;
            cp := h1 * 4096 + h2 * 256 + h3 * 16 + h4;
            p := p + 5;
          when others =>
            return false;
        end case;
      end if;
      if cp > 127 then
        return false;
      end if;
      if si > s'high then
        return false; -- token has more content than s does
      end if;
      if character'pos(s(si)) /= cp then
        return false;
      end if;
      si := si + 1;
    end loop;
    return si = s'high + 1; -- every character of s was matched, none left over
  end function json_tok_eq_str;

  procedure json_tok_get_str(
    buf    : in byte_array;
    toks   : in json_tok_array;
    tok    : in integer;
    dst    : inout byte_array;
    dstlen : inout natural
  ) is
    variable p, stop : natural;
    variable c : byte_t;
    variable cp, high_surrogate, low_surrogate : integer;
    variable h1, h2, h3, h4 : integer;
  begin
    if tok = JSON_NO_TOK or toks(tok).kind /= JSON_STRING then
      return;
    end if;
    p := toks(tok).start;
    stop := toks(tok).stop;
    while p < stop loop
      c := buf(p);
      if c /= character'pos('\') then
        -- Raw input bytes -- including every continuation byte of a
        -- multi-byte UTF-8 character -- pass through unchanged, one byte at
        -- a time: reinterpreting one as a rune and re-encoding it would
        -- corrupt every non-ASCII character into mojibake.
        buf_put_byte(dst, dstlen, c);
        p := p + 1;
        next;
      end if;
      p := p + 1;
      if p >= stop then
        return;
      end if;
      case buf(p) is
        when 34 => cp := 34; p := p + 1;
        when 92 => cp := 92; p := p + 1;
        when 47 => cp := 47; p := p + 1;
        when 98 => cp := 8; p := p + 1;
        when 102 => cp := 12; p := p + 1;
        when 110 => cp := 10; p := p + 1;
        when 114 => cp := 13; p := p + 1;
        when 116 => cp := 9; p := p + 1;
        when 117 =>
          if p + 4 >= stop then
            return;
          end if;
          h1 := hex_digit_value(buf(p + 1));
          h2 := hex_digit_value(buf(p + 2));
          h3 := hex_digit_value(buf(p + 3));
          h4 := hex_digit_value(buf(p + 4));
          if h1 < 0 or h2 < 0 or h3 < 0 or h4 < 0 then
            return;
          end if;
          cp := h1 * 4096 + h2 * 256 + h3 * 16 + h4;
          p := p + 5;
          if cp >= 16#D800# and cp <= 16#DBFF# then
            -- A high surrogate must be followed by a \u low surrogate;
            -- combine the pair into the real astral codepoint rather than
            -- emitting either half as if it stood alone.
            high_surrogate := cp;
            if p + 5 >= stop or buf(p) /= character'pos('\') or buf(p + 1) /= character'pos('u') then
              return;
            end if;
            h1 := hex_digit_value(buf(p + 2));
            h2 := hex_digit_value(buf(p + 3));
            h3 := hex_digit_value(buf(p + 4));
            h4 := hex_digit_value(buf(p + 5));
            if h1 < 0 or h2 < 0 or h3 < 0 or h4 < 0 then
              return;
            end if;
            low_surrogate := h1 * 4096 + h2 * 256 + h3 * 16 + h4;
            if low_surrogate < 16#DC00# or low_surrogate > 16#DFFF# then
              return;
            end if;
            cp := 16#10000# + (high_surrogate - 16#D800#) * 1024 + (low_surrogate - 16#DC00#);
            p := p + 6;
          elsif cp >= 16#DC00# and cp <= 16#DFFF# then
            return; -- a lone low surrogate is not valid
          end if;
        when others =>
          return;
      end case;
      -- UTF-8 encode cp, 1 to 4 bytes depending on its magnitude.
      if cp <= 16#7F# then
        buf_put_byte(dst, dstlen, cp);
      elsif cp <= 16#7FF# then
        buf_put_byte(dst, dstlen, 16#C0# + cp / 64);
        buf_put_byte(dst, dstlen, 16#80# + cp mod 64);
      elsif cp <= 16#FFFF# then
        buf_put_byte(dst, dstlen, 16#E0# + cp / 4096);
        buf_put_byte(dst, dstlen, 16#80# + (cp / 64) mod 64);
        buf_put_byte(dst, dstlen, 16#80# + cp mod 64);
      else
        buf_put_byte(dst, dstlen, 16#F0# + cp / 262144);
        buf_put_byte(dst, dstlen, 16#80# + (cp / 4096) mod 64);
        buf_put_byte(dst, dstlen, 16#80# + (cp / 64) mod 64);
        buf_put_byte(dst, dstlen, 16#80# + cp mod 64);
      end if;
    end loop;
  end procedure json_tok_get_str;

  procedure json_tok_as_int(
    buf   : in byte_array;
    toks  : in json_tok_array;
    tok   : in integer;
    value : out integer;
    ok    : out boolean
  ) is
    variable p, stop : natural;
    variable neg : boolean := false;
    variable digits_buf : byte_array(0 to 39);
    variable ndigits : natural := 0;
    variable frac_digits : natural := 0;
    variable exp_val : integer := 0;
    variable exp_neg : boolean := false;
    variable shift : integer;
    variable acc : integer;
    variable overflow : boolean := false;
  begin
    value := 0;
    ok := false;
    if tok = JSON_NO_TOK then
      return;
    end if;
    if toks(tok).kind /= JSON_NUMBER then
      return; -- rejects a quoted string outright, even "5"
    end if;
    p := toks(tok).start;
    stop := toks(tok).stop;
    if p < stop and buf(p) = character'pos('-') then
      neg := true;
      p := p + 1;
    end if;
    while p < stop and buf(p) >= character'pos('0') and buf(p) <= character'pos('9') loop
      if ndigits <= digits_buf'high then
        digits_buf(ndigits) := buf(p) - character'pos('0');
        ndigits := ndigits + 1;
      else
        overflow := true;
      end if;
      p := p + 1;
    end loop;
    if p < stop and buf(p) = character'pos('.') then
      p := p + 1;
      while p < stop and buf(p) >= character'pos('0') and buf(p) <= character'pos('9') loop
        if ndigits <= digits_buf'high then
          digits_buf(ndigits) := buf(p) - character'pos('0');
          ndigits := ndigits + 1;
          frac_digits := frac_digits + 1;
        else
          overflow := true;
        end if;
        p := p + 1;
      end loop;
    end if;
    if p < stop and (buf(p) = character'pos('e') or buf(p) = character'pos('E')) then
      p := p + 1;
      if p < stop and (buf(p) = character'pos('+') or buf(p) = character'pos('-')) then
        exp_neg := (buf(p) = character'pos('-'));
        p := p + 1;
      end if;
      while p < stop and buf(p) >= character'pos('0') and buf(p) <= character'pos('9') loop
        if exp_val > (100000 - (buf(p) - character'pos('0'))) / 10 then
          overflow := true;
        else
          exp_val := exp_val * 10 + (buf(p) - character'pos('0'));
        end if;
        p := p + 1;
      end loop;
      if exp_neg then
        exp_val := -exp_val;
      end if;
    end if;
    if overflow or p /= stop or ndigits = 0 then
      return; -- malformed, empty, or too many digits to be worth reading
    end if;

    -- shift is how many decimal places the fractional/exponent part moves
    -- the value's true magnitude: negative means digits must actually
    -- cancel out (be zero) for the value to be an integer at all.
    shift := exp_val - frac_digits;
    if shift < 0 then
      if -shift > ndigits then
        return;
      end if;
      for i in ndigits + shift to ndigits - 1 loop
        if digits_buf(i) /= 0 then
          return; -- a nonzero digit remains below the decimal point
        end if;
      end loop;
      ndigits := ndigits + shift; -- drop the trailing zero digits
      shift := 0;
    end if;

    acc := 0;
    for i in 0 to ndigits - 1 loop
      if acc > (integer'high - digits_buf(i)) / 10 then
        return; -- overflow
      end if;
      acc := acc * 10 + digits_buf(i);
    end loop;
    for i in 1 to shift loop
      if acc > integer'high / 10 then
        return; -- overflow
      end if;
      acc := acc * 10;
    end loop;

    if neg then
      acc := -acc;
    end if;
    value := acc;
    ok := true;
  end procedure json_tok_as_int;

  procedure json_put_escaped_byte(buf : inout byte_array; len : inout natural; b : in byte_t) is
    constant hexd : string := "0123456789abcdef";
  begin
    case b is
      when 34 => buf_put_byte(buf, len, 92); buf_put_byte(buf, len, 34); -- \"
      when 92 => buf_put_byte(buf, len, 92); buf_put_byte(buf, len, 92); -- \\
      when 10 => buf_put_byte(buf, len, 92); buf_put_byte(buf, len, character'pos('n'));
      when 13 => buf_put_byte(buf, len, 92); buf_put_byte(buf, len, character'pos('r'));
      when 9 => buf_put_byte(buf, len, 92); buf_put_byte(buf, len, character'pos('t'));
      when others =>
        if b < 32 then
          buf_put_byte(buf, len, 92);
          buf_put_byte(buf, len, character'pos('u'));
          buf_put_byte(buf, len, character'pos('0'));
          buf_put_byte(buf, len, character'pos('0'));
          buf_put_byte(buf, len, character'pos(hexd(b / 16 + 1)));
          buf_put_byte(buf, len, character'pos(hexd(b mod 16 + 1)));
        else
          buf_put_byte(buf, len, b);
        end if;
    end case;
  end procedure json_put_escaped_byte;

  procedure json_put_string(buf : inout byte_array; len : inout natural; s : in string) is
  begin
    buf_put_byte(buf, len, character'pos('"'));
    for i in s'range loop
      json_put_escaped_byte(buf, len, character'pos(s(i)));
    end loop;
    buf_put_byte(buf, len, character'pos('"'));
  end procedure json_put_string;

  procedure json_put_string_bytes(
    dst    : inout byte_array;
    dstlen : inout natural;
    src    : in byte_array;
    srcoff : in natural;
    srclen : in natural
  ) is
  begin
    buf_put_byte(dst, dstlen, character'pos('"'));
    for i in 0 to srclen - 1 loop
      json_put_escaped_byte(dst, dstlen, src(src'low + srcoff + i));
    end loop;
    buf_put_byte(dst, dstlen, character'pos('"'));
  end procedure json_put_string_bytes;

  procedure json_put_int(buf : inout byte_array; len : inout natural; n : in integer) is
  begin
    buf_put_int(buf, len, n);
  end procedure json_put_int;

  procedure json_put_bool(buf : inout byte_array; len : inout natural; b : in boolean) is
  begin
    if b then
      buf_put_str(buf, len, "true");
    else
      buf_put_str(buf, len, "false");
    end if;
  end procedure json_put_bool;

  procedure json_put_null(buf : inout byte_array; len : inout natural) is
  begin
    buf_put_str(buf, len, "null");
  end procedure json_put_null;

end package body convex_json;
