module: convex

// -------------------------------------------------------------------------
// JSON encoding and decoding.
//
// A JSON value is represented in Dylan as one of:
//   - $json-null                 (the unique <json-null> instance)
//   - #t / #f                    (JSON true / false)
//   - <integer>                  (a JSON number with no fractional part
//                                 and no exponent, in Dylan bignum range)
//   - <double-float>              (any other JSON number)
//   - <byte-string>               (a JSON string, decoded to UTF-8 bytes
//                                 stored one Dylan character per byte --
//                                 see the UTF-8 note below)
//   - <simple-object-vector>      (a JSON array)
//   - <string-table>              (a JSON object, keyed by member name)
//
// This client treats <byte-string> contents as a UTF-8 byte sequence
// rather than decoding to Unicode code points internally: Dylan's
// <byte-string> element type <byte-character> is exactly one byte, which
// is what every consumer here actually needs (HTTP framing, WebSocket
// payloads, and comparison against expected ASCII protocol text all work
// directly on bytes). \uXXXX escapes are decoded to their UTF-8 byte
// encoding on the way in, and non-ASCII bytes are emitted verbatim
// (already valid UTF-8 in, valid UTF-8 out) rather than re-escaped on the
// way out, matching ordinary JSON library behavior.
// -------------------------------------------------------------------------

define class <json-null> (<object>) end class;
define constant $json-null = make(<json-null>);

define function json-null? (v :: <object>) => (well? :: <boolean>)
  instance?(v, <json-null>)
end function;

// ---- encoding ----

define function json-escape-string (s :: <byte-string>) => (out :: <byte-string>)
  let parts = make(<stretchy-vector>);
  add!(parts, "\"");
  for (ch in s)
    let code = as(<integer>, ch);
    select (code)
      34 => add!(parts, "\\\"");
      92 => add!(parts, "\\\\");
      10 => add!(parts, "\\n");
      13 => add!(parts, "\\r");
      9  => add!(parts, "\\t");
      otherwise =>
        if (code < 32)
          add!(parts, format-to-string("\\u%04x", code));
        else
          add!(parts, make(<byte-string>, size: 1, fill: ch));
        end if;
    end select;
  end for;
  add!(parts, "\"");
  apply(concatenate, "", as(<list>, parts))
end function;

define function json-encode (v :: <object>) => (out :: <byte-string>)
  if (json-null?(v))
    "null"
  elseif (v == #t)
    "true"
  elseif (v == #f)
    "false"
  elseif (instance?(v, <integer>))
    integer-to-string(v)
  elseif (instance?(v, <float>))
    json-encode-float(v)
  elseif (instance?(v, <byte-string>))
    json-escape-string(v)
  elseif (instance?(v, <string-table>))
    json-encode-object(v)
  elseif (instance?(v, <sequence>))
    json-encode-array(v)
  else
    error("json-encode: unsupported value");
  end if
end function;

define function json-encode-float (v :: <float>) => (out :: <byte-string>)
  // Convex's public JSON format has no reliable way to distinguish an
  // integral float from an integer, so an integral double is emitted
  // with an explicit ".0" the way the reference clients' fixtures expect
  // (e.g. a count of 1.0 rather than 1) whenever the source value truly
  // is a float rather than an integer.
  let whole = truncate(v);
  if (as(<double-float>, whole) = v & abs(v) < 1.0e15)
    concatenate(integer-to-string(whole), ".0")
  else
    // A hand-rolled fixed-point formatter for the rare genuinely
    // fractional value: Dylan's format library has no %f directive, and
    // this client never needs IEEE round-trip precision, only a decimal
    // rendering a JSON reader will parse back to the same double within
    // ordinary tolerance.
    let negative? = v < 0.0d0;
    let magnitude = abs(v);
    let int-part = truncate(magnitude);
    let frac = magnitude - as(<double-float>, int-part);
    let scaled = truncate(frac * 1000000.0d0 + 0.5d0);
    concatenate(if (negative?) "-" else "" end if,
                integer-to-string(int-part), ".",
                pad-left-zeros(integer-to-string(scaled), 6))
  end if
end function;

define function pad-left-zeros (s :: <byte-string>, width :: <integer>) => (out :: <byte-string>)
  if (s.size >= width)
    s
  else
    concatenate(make(<byte-string>, size: width - s.size, fill: '0'), s)
  end if
end function;

define function json-encode-array (v :: <sequence>) => (out :: <byte-string>)
  let parts = make(<stretchy-vector>);
  add!(parts, "[");
  let first? = #t;
  for (item in v)
    if (~first?) add!(parts, ",") end if;
    first? := #f;
    add!(parts, json-encode(item));
  end for;
  add!(parts, "]");
  apply(concatenate, "", as(<list>, parts))
end function;

// Objects are encoded in the order their keys were inserted (a
// <string-table> here is always built through json-object-set!, backed by
// a parallel key-order list) so a hand-built request body's field order
// matches what a human reading the README would expect.
define function json-encode-object (v :: <string-table>) => (out :: <byte-string>)
  let parts = make(<stretchy-vector>);
  add!(parts, "{");
  let first? = #t;
  for (key in json-object-keys(v))
    if (~first?) add!(parts, ",") end if;
    first? := #f;
    add!(parts, json-escape-string(key));
    add!(parts, ":");
    add!(parts, json-encode(v[key]));
  end for;
  add!(parts, "}");
  apply(concatenate, "", as(<list>, parts))
end function;

// -- ordered object helpers --
//
// <string-table> alone has no defined iteration order, so every JSON
// object this client builds or parses carries its key order alongside it
// in a parallel table keyed by the same object, avoiding a bespoke
// wrapper class for something this small.
define variable *object-key-order* = make(<table>);

// A private, unforgeable sentinel: element(..., default: $absent) always
// returns this exact object when a key is missing, and nothing else ever
// produces or compares equal to it, so identity comparison is a safe
// "was this key present" test without a separate key-exists? primitive
// (which lives in the collection-extensions library this client does not
// otherwise need).
define class <absent-marker> (<object>) end class;
define constant $absent = make(<absent-marker>);

define function make-json-object () => (obj :: <string-table>)
  let obj = make(<string-table>);
  element(*object-key-order*, obj) := make(<stretchy-vector>);
  obj
end function;

define function json-object-keys (obj :: <string-table>) => (keys :: <sequence>)
  let order = element(*object-key-order*, obj, default: $absent);
  if (order == $absent) #[] else order end if
end function;

define function json-object-set! (obj :: <string-table>, key :: <byte-string>, value :: <object>) => ()
  if (element(obj, key, default: $absent) == $absent)
    add!(element(*object-key-order*, obj), key);
  end if;
  element(obj, key) := value;
end function;

define function json-object-ref
    (obj :: <object>, key :: <byte-string>, #key default = #f)
 => (value :: <object>)
  if (instance?(obj, <string-table>))
    let v = element(obj, key, default: $absent);
    if (v == $absent) default else v end if
  else
    default
  end if
end function;

define function json-object-has-key? (obj :: <object>, key :: <byte-string>) => (well? :: <boolean>)
  instance?(obj, <string-table>) & element(obj, key, default: $absent) ~== $absent
end function;

// ---- decoding ----

define class <json-parse-error> (<error>) end class;

// A tiny cursor over a <byte-string>: pos is the next unread index.
define class <json-cursor> (<object>)
  slot jc-text :: <byte-string>, required-init-keyword: text:;
  slot jc-pos :: <integer> = 0;
end class <json-cursor>;

define function jc-peek (c :: <json-cursor>) => (ch :: false-or(<byte-character>))
  if (c.jc-pos < c.jc-text.size) c.jc-text[c.jc-pos] else #f end if
end function;

define function jc-advance (c :: <json-cursor>) => ()
  c.jc-pos := c.jc-pos + 1;
end function;

define function jc-skip-whitespace (c :: <json-cursor>) => ()
  block (done)
    while (#t)
      let ch = jc-peek(c);
      if (ch & member?(ch, #(' ', '\t', '\n', '\r')))
        jc-advance(c);
      else
        done();
      end if;
    end while;
  end block;
end function;

define function jc-expect (c :: <json-cursor>, ch :: <byte-character>) => ()
  if (jc-peek(c) ~= ch)
    signal(make(<json-parse-error>));
  end if;
  jc-advance(c);
end function;

define function jc-literal? (c :: <json-cursor>, text :: <byte-string>) => (well? :: <boolean>)
  let n = text.size;
  if (c.jc-pos + n <= c.jc-text.size &
      copy-sequence(c.jc-text, start: c.jc-pos, end: c.jc-pos + n) = text)
    c.jc-pos := c.jc-pos + n;
    #t
  else
    #f
  end if
end function;

// Encodes a Unicode code point as UTF-8 bytes appended (as Dylan
// characters, one per byte) onto the given stretchy string buffer -- used
// only for \uXXXX escapes, since every other JSON string byte is already
// valid UTF-8 and is copied through unchanged.
define function append-utf8! (buf :: <stretchy-vector>, code-point :: <integer>) => ()
  if (code-point < #x80)
    add!(buf, as(<byte-character>, code-point));
  elseif (code-point < #x800)
    add!(buf, as(<byte-character>, logior(#xC0, ash(code-point, -6))));
    add!(buf, as(<byte-character>, logior(#x80, logand(code-point, #x3F))));
  elseif (code-point < #x10000)
    add!(buf, as(<byte-character>, logior(#xE0, ash(code-point, -12))));
    add!(buf, as(<byte-character>, logior(#x80, logand(ash(code-point, -6), #x3F))));
    add!(buf, as(<byte-character>, logior(#x80, logand(code-point, #x3F))));
  else
    add!(buf, as(<byte-character>, logior(#xF0, ash(code-point, -18))));
    add!(buf, as(<byte-character>, logior(#x80, logand(ash(code-point, -12), #x3F))));
    add!(buf, as(<byte-character>, logior(#x80, logand(ash(code-point, -6), #x3F))));
    add!(buf, as(<byte-character>, logior(#x80, logand(code-point, #x3F))));
  end if;
end function;

define function hex-digit-value (ch :: <byte-character>) => (v :: <integer>)
  let code = as(<integer>, ch);
  select (code)
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57 => code - 48;
    65, 66, 67, 68, 69, 70 => code - 65 + 10;
    97, 98, 99, 100, 101, 102 => code - 97 + 10;
    otherwise => signal(make(<json-parse-error>));
  end select
end function;

define function jc-parse-hex4 (c :: <json-cursor>) => (v :: <integer>)
  let v = 0;
  for (i from 0 below 4)
    let ch = jc-peek(c) | signal(make(<json-parse-error>));
    v := v * 16 + hex-digit-value(ch);
    jc-advance(c);
  end for;
  v
end function;

define function jc-parse-string (c :: <json-cursor>) => (s :: <byte-string>)
  jc-expect(c, '"');
  let buf = make(<stretchy-vector>);
  block (done)
    while (#t)
      let ch = jc-peek(c) | signal(make(<json-parse-error>));
      if (ch = '"')
        jc-advance(c);
        done();
      elseif (ch = '\\')
        jc-advance(c);
        let esc = jc-peek(c) | signal(make(<json-parse-error>));
        jc-advance(c);
        select (esc)
          '"' => add!(buf, '"');
          '\\' => add!(buf, '\\');
          '/' => add!(buf, '/');
          'n' => add!(buf, '\n');
          't' => add!(buf, '\t');
          'r' => add!(buf, '\r');
          'b' => add!(buf, as(<byte-character>, 8));
          'f' => add!(buf, as(<byte-character>, 12));
          'u' =>
            let code-point = jc-parse-hex4(c);
            // A high surrogate is only meaningful paired with a
            // following low surrogate; recombine to the real code point
            // before UTF-8 encoding rather than emitting lone surrogates.
            if (code-point >= #xD800 & code-point <= #xDBFF &
                c.jc-pos + 1 < c.jc-text.size & c.jc-text[c.jc-pos] = '\\' &
                c.jc-text[c.jc-pos + 1] = 'u')
              jc-advance(c); jc-advance(c);
              let low = jc-parse-hex4(c);
              let combined = #x10000 + ash(code-point - #xD800, 10) + (low - #xDC00);
              append-utf8!(buf, combined);
            else
              append-utf8!(buf, code-point);
            end if;
          otherwise => signal(make(<json-parse-error>));
        end select;
      else
        add!(buf, ch);
        jc-advance(c);
      end if;
    end while;
  end block;
  let result = make(<byte-string>, size: buf.size);
  for (i from 0 below buf.size)
    result[i] := buf[i];
  end for;
  result
end function;

define function json-digit? (ch :: <byte-character>) => (well? :: <boolean>)
  ch >= '0' & ch <= '9'
end function;

// Dylan's base libraries only convert strings to integers out of the box
// (string-to-integer, in common-dylan); a JSON float is parsed here by
// hand from its three possible parts (sign, integer.fraction, exponent)
// combined with ordinary float arithmetic, which is exact enough for
// every value this protocol actually carries (Convex's own "json" format
// is explicitly not lossless for extreme magnitudes; see convex-json's
// header comment).
define function parse-json-float (text :: <byte-string>) => (v :: <double-float>)
  let i = 0;
  let n = text.size;
  let negative? = #f;
  if (i < n & text[i] = '-')
    negative? := #t;
    i := i + 1;
  end if;
  let int-part = 0;
  while (i < n & json-digit?(text[i]))
    int-part := int-part * 10 + (as(<integer>, text[i]) - as(<integer>, '0'));
    i := i + 1;
  end while;
  let frac-value = as(<double-float>, 0);
  let frac-scale = as(<double-float>, 1);
  if (i < n & text[i] = '.')
    i := i + 1;
    while (i < n & json-digit?(text[i]))
      frac-scale := frac-scale / 10.0d0;
      frac-value := frac-value + (as(<integer>, text[i]) - as(<integer>, '0')) * frac-scale;
      i := i + 1;
    end while;
  end if;
  let mantissa = as(<double-float>, int-part) + frac-value;
  let exponent = 0;
  let exponent-negative? = #f;
  if (i < n & (text[i] = 'e' | text[i] = 'E'))
    i := i + 1;
    if (i < n & (text[i] = '+' | text[i] = '-'))
      exponent-negative? := text[i] = '-';
      i := i + 1;
    end if;
    while (i < n & json-digit?(text[i]))
      exponent := exponent * 10 + (as(<integer>, text[i]) - as(<integer>, '0'));
      i := i + 1;
    end while;
  end if;
  let scaled =
    if (exponent = 0)
      mantissa
    elseif (exponent-negative?)
      mantissa / (10.0d0 ^ exponent)
    else
      mantissa * (10.0d0 ^ exponent)
    end if;
  if (negative?) -scaled else scaled end if
end function;

define function jc-parse-number (c :: <json-cursor>) => (n :: <object>)
  let start = c.jc-pos;
  let is-float? = #f;
  if (jc-peek(c) = '-') jc-advance(c) end if;
  while (jc-peek(c) & json-digit?(jc-peek(c)))
    jc-advance(c);
  end while;
  if (jc-peek(c) = '.')
    is-float? := #t;
    jc-advance(c);
    while (jc-peek(c) & json-digit?(jc-peek(c)))
      jc-advance(c);
    end while;
  end if;
  if (jc-peek(c) = 'e' | jc-peek(c) = 'E')
    is-float? := #t;
    jc-advance(c);
    if (jc-peek(c) = '+' | jc-peek(c) = '-') jc-advance(c) end if;
    while (jc-peek(c) & json-digit?(jc-peek(c)))
      jc-advance(c);
    end while;
  end if;
  let text = copy-sequence(c.jc-text, start: start, end: c.jc-pos);
  if (is-float?)
    parse-json-float(text)
  else
    string-to-integer(text)
  end if
end function;

define function jc-parse-value (c :: <json-cursor>) => (v :: <object>)
  jc-skip-whitespace(c);
  let ch = jc-peek(c) | signal(make(<json-parse-error>));
  select (ch)
    '"' => jc-parse-string(c);
    '{' => jc-parse-object(c);
    '[' => jc-parse-array(c);
    't' => if (jc-literal?(c, "true")) #t else signal(make(<json-parse-error>)) end if;
    'f' => if (jc-literal?(c, "false")) #f else signal(make(<json-parse-error>)) end if;
    'n' => if (jc-literal?(c, "null")) $json-null else signal(make(<json-parse-error>)) end if;
    otherwise =>
      if (ch = '-' | json-digit?(ch))
        jc-parse-number(c)
      else
        signal(make(<json-parse-error>));
      end if;
  end select
end function;

define function jc-parse-object (c :: <json-cursor>) => (obj :: <string-table>)
  jc-expect(c, '{');
  let obj = make-json-object();
  jc-skip-whitespace(c);
  if (jc-peek(c) = '}')
    jc-advance(c);
  else
    block (done)
      while (#t)
        jc-skip-whitespace(c);
        let key = jc-parse-string(c);
        jc-skip-whitespace(c);
        jc-expect(c, ':');
        let value = jc-parse-value(c);
        json-object-set!(obj, key, value);
        jc-skip-whitespace(c);
        let ch = jc-peek(c) | signal(make(<json-parse-error>));
        if (ch = ',')
          jc-advance(c);
        elseif (ch = '}')
          jc-advance(c);
          done();
        else
          signal(make(<json-parse-error>));
        end if;
      end while;
    end block;
  end if;
  obj
end function;

define function jc-parse-array (c :: <json-cursor>) => (v :: <simple-object-vector>)
  jc-expect(c, '[');
  let items = make(<stretchy-vector>);
  jc-skip-whitespace(c);
  if (jc-peek(c) = ']')
    jc-advance(c);
  else
    block (done)
      while (#t)
        add!(items, jc-parse-value(c));
        jc-skip-whitespace(c);
        let ch = jc-peek(c) | signal(make(<json-parse-error>));
        if (ch = ',')
          jc-advance(c);
        elseif (ch = ']')
          jc-advance(c);
          done();
        else
          signal(make(<json-parse-error>));
        end if;
      end while;
    end block;
  end if;
  as(<simple-object-vector>, items)
end function;

// Parses exactly one JSON value from the whole of text (trailing
// whitespace tolerated, trailing garbage is not), returning #f as the
// second value on any malformed input rather than signalling out to the
// caller -- every caller here is on a protocol boundary (HTTP body,
// adapter command line, sync message) that must turn a parse failure into
// a structured protocol error, never an uncaught condition.
define function json-parse (text :: <byte-string>) => (value :: <object>, ok? :: <boolean>)
  block ()
    let c = make(<json-cursor>, text: text);
    let v = jc-parse-value(c);
    jc-skip-whitespace(c);
    if (c.jc-pos = text.size)
      values(v, #t)
    else
      values(#f, #f)
    end if;
  exception (<json-parse-error>)
    values(#f, #f)
  exception (<error>)
    values(#f, #f)
  end block
end function;
