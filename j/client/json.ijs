NB. json.ijs -- a JSON reader and writer for the Convex client.
NB.
NB. J has no native map/record type, so a decoded value is a tagged boxed pair
NB. (tag;payload). This is a genuinely array-shaped decision, not a workaround:
NB. it lets every JSON value -- number, string, array, object -- share one
NB. uniform shape that the rest of the client can pattern match on with plain
NB. indexing instead of a family of per-type accessors.
NB.
NB.   tag 's' string : payload is the decoded byte string (raw bytes; a \uXXXX
NB.                    escape is converted to its UTF-8 bytes, everything else
NB.                    passes through untouched)
NB.   tag 'n' number : payload is the exact source literal, kept verbatim so a
NB.                    round trip never rewrites precision the way a float
NB.                    would (mirrors every other client in this repository)
NB.   tag 't'/'f'    : true / false, payload unused
NB.   tag 'z'        : null, payload unused
NB.   tag 'a' array  : payload is a boxed list of tagged values
NB.   tag 'o' object : payload is an n-by-2 boxed array of (key,value) rows,
NB.                    key is a raw byte string; order is preserved and
NB.                    duplicate keys are rejected while parsing
NB.
NB. Bytes, not code points: every string the client touches -- JSON source,
NB. decoded string payloads, HTTP bodies -- is a plain literal (one J character
NB. per byte). J's `a.` alphabet is exactly the 256 one-byte values, so this
NB. carries arbitrary UTF-8 content untouched without ever decoding it, the
NB. same discipline Awk's LC_ALL=C gives that client. The one place raw UTF-8
NB. bytes are actually decoded to code points is `\uXXXX` escape assembly
NB. (using J's own `u:` Unicode conversion) and Live text-frame validation.

NB. ---------------------------------------------------------------------------
NB. Tagged value constructors and accessors
NB. ---------------------------------------------------------------------------

jtag=: 3 : 0
  > 0 { y
)
jpay=: 3 : 0
  > 1 { y
)
NB. Box each side exactly once, then catenate the two resulting atoms into a
NB. plain 2-item list -- the same "box a cell, then ," shape used everywhere
NB. else in this file to build a pairs row or an array item. `;` (Link) is
NB. deliberately avoided here: it does not treat an already-boxed operand as
NB. one opaque cell the way `,` does, so linking a tag atom against a payload
NB. that is itself a multi-character string produced a lopsided pair.
jval=: 4 : 0
  (<x),(<y)
)
jstr=: 's'&jval
jnum=: 'n'&jval
jarr=: 'a'&jval
jobj=: 'o'&jval
jtrue=: (<'t'),(<'')
jfalse=: (<'f'),(<'')
jnull=: (<'z'),(<'')

NB. Object field lookup. _1 (rather than a boxed sentinel) means "absent" so
NB. callers can compare with a plain scalar instead of unboxing every result.
jfind=: 4 : 0
  if. -. 'o' -: jtag x do. _1 return. end.
  pairs=. jpay x
  if. 0 = # pairs do. _1 return. end.
  keys=. 0 {"1 pairs
  hit=. keys i. <y
  if. hit = # keys do. _1 return. end.
  1 { hit { pairs
)

jcount=: 3 : 0
  if. (jtag y) e. 'ao' do. # jpay y else. 0 end.
)

NB. ---------------------------------------------------------------------------
NB. Reader
NB.
NB. Parser state lives in script-local globals rather than being threaded
NB. through every recursive call. A JSON document is parsed start to finish by
NB. one owner and never interleaved with another parse, so this is simpler
NB. than passing and returning a position from every mutually recursive verb,
NB. and it mirrors how every other interpreted client in this repository
NB. structures its own hand-written recursive-descent reader.
NB. ---------------------------------------------------------------------------

JP_SRC=: ''
JP_POS=: 0
JP_LEN=: 0
JP_ERR=: ''
JP_DEPTH=: 0
JP_MAXDEPTH=: 128
JP_MAXBYTES=: 1048576

jp_ws=: a.{~9 10 13 32

NB. The current byte, or a NUL sentinel past the end of input. `*.`/`+.` do
NB. not short-circuit in J -- both sides are always evaluated -- so every
NB. lookahead in this reader goes through jp_peek instead of indexing
NB. JP_SRC directly, which would throw an index error the moment a boundary
NB. check and a character test were combined in one boolean expression.
jp_peek=: 3 : 0
  if. JP_POS < JP_LEN do. JP_SRC{~JP_POS return. end.
  0{a.
)

jp_atend=: 3 : 0
  JP_POS >: JP_LEN
)

jp_skip=: 3 : 0
  while. (jp_peek '') e. jp_ws do.
    JP_POS=: JP_POS + 1
  end.
  i. 0
)

NB. Parse `src`. Result is ok;payload: ok=1 gives the tagged value, ok=0 gives
NB. a plain error-message byte string.
cx_json_parse=: 3 : 0
  if. (# y) > JP_MAXBYTES do.
    0;'JSON input exceeds ',(": JP_MAXBYTES),' bytes' return.
  end.
  JP_SRC=: y
  JP_POS=: 0
  JP_LEN=: # y
  JP_ERR=: ''
  JP_DEPTH=: 0
  v=. jp_value ''
  if. -. JP_ERR -: '' do. 0;JP_ERR return. end.
  jp_skip ''
  if. JP_POS < JP_LEN do. 0;'trailing content after the JSON value' return. end.
  (<1),(<v)
)

jp_fail=: 3 : 0
  JP_ERR=: y
  jnull
)

jp_value=: 3 : 0
  jp_skip ''
  if. jp_atend '' do. jp_fail 'JSON value ended early' return. end.
  ch=. jp_peek ''
  if. ch = '{' do. jp_object '' return. end.
  if. ch = '[' do. jp_array '' return. end.
  if. ch = '"' do. jstr jp_string '' return. end.
  if. ch = 't' do. jp_literal ((<'true'),(<jtrue)) return. end.
  if. ch = 'f' do. jp_literal ((<'false'),(<jfalse)) return. end.
  if. ch = 'n' do. jp_literal ((<'null'),(<jnull)) return. end.
  if. (ch = '-') +. ch e. '0123456789' do. jp_number '' return. end.
  jp_fail 'unexpected JSON token'
)

jp_literal=: 3 : 0
  'word result'=. y
  n=. # word
  if. (JP_POS + n) > JP_LEN do. jp_fail 'unexpected JSON token' return. end.
  if. -. word -: n {. JP_POS }. JP_SRC do. jp_fail 'unexpected JSON token' return. end.
  JP_POS=: JP_POS + n
  result
)

jp_digit=: '0123456789' e.~ ]

jp_number=: 3 : 0
  start=. JP_POS
  if. '-' = jp_peek '' do. JP_POS=: JP_POS + 1 end.
  if. -. jp_digit jp_peek '' do.
    jp_fail 'invalid JSON number' return.
  end.
  if. '0' = jp_peek '' do.
    JP_POS=: JP_POS + 1
  else.
    while. jp_digit jp_peek '' do. JP_POS=: JP_POS + 1 end.
  end.
  if. '.' = jp_peek '' do.
    JP_POS=: JP_POS + 1
    if. -. jp_digit jp_peek '' do.
      jp_fail 'invalid JSON number' return.
    end.
    while. jp_digit jp_peek '' do. JP_POS=: JP_POS + 1 end.
  end.
  if. (jp_peek '') e. 'eE' do.
    JP_POS=: JP_POS + 1
    if. (jp_peek '') e. '+-' do. JP_POS=: JP_POS + 1 end.
    if. -. jp_digit jp_peek '' do.
      jp_fail 'invalid JSON number' return.
    end.
    while. jp_digit jp_peek '' do. JP_POS=: JP_POS + 1 end.
  end.
  jnum (JP_POS - start) {. start }. JP_SRC
)

jp_object=: 3 : 0
  JP_DEPTH=: JP_DEPTH + 1
  if. JP_DEPTH > JP_MAXDEPTH do. jp_fail 'JSON nesting exceeds ',(": JP_MAXDEPTH),' levels' return. end.
  JP_POS=: JP_POS + 1
  jp_skip ''
  pairs=. 0 2 $ a:
  if. '}' = jp_peek '' do.
    JP_POS=: JP_POS + 1
    JP_DEPTH=: JP_DEPTH - 1
    jobj pairs return.
  end.
  while. 1 do.
    jp_skip ''
    if. -. '"' = jp_peek '' do.
      jp_fail 'JSON object key must be a string' return.
    end.
    key=. jp_string ''
    if. -. JP_ERR -: '' do. jnull return. end.
    if. (# pairs) *. (<key) e. 0 {"1 pairs do.
      jp_fail 'JSON object has a duplicate key' return.
    end.
    jp_skip ''
    if. -. ':' = jp_peek '' do.
      jp_fail 'JSON object key is missing its colon' return.
    end.
    JP_POS=: JP_POS + 1
    child=. jp_value ''
    if. -. JP_ERR -: '' do. jnull return. end.
    pairs=. pairs , 1 2 $ (<key),(<child)
    jp_skip ''
    ch=. jp_peek ''
    if. ch = ',' do.
      JP_POS=: JP_POS + 1
    elseif. ch = '}' do.
      JP_POS=: JP_POS + 1
      JP_DEPTH=: JP_DEPTH - 1
      jobj pairs return.
    else.
      jp_fail 'JSON object is missing a comma or brace' return.
    end.
  end.
)

jp_array=: 3 : 0
  JP_DEPTH=: JP_DEPTH + 1
  if. JP_DEPTH > JP_MAXDEPTH do. jp_fail 'JSON nesting exceeds ',(": JP_MAXDEPTH),' levels' return. end.
  JP_POS=: JP_POS + 1
  jp_skip ''
  items=. 0 $ a:
  if. ']' = jp_peek '' do.
    JP_POS=: JP_POS + 1
    JP_DEPTH=: JP_DEPTH - 1
    jarr items return.
  end.
  while. 1 do.
    child=. jp_value ''
    if. -. JP_ERR -: '' do. jnull return. end.
    items=. items , < child
    jp_skip ''
    ch=. jp_peek ''
    if. ch = ',' do.
      JP_POS=: JP_POS + 1
    elseif. ch = ']' do.
      JP_POS=: JP_POS + 1
      JP_DEPTH=: JP_DEPTH - 1
      jarr items return.
    else.
      jp_fail 'JSON array is missing a comma or bracket' return.
    end.
  end.
)

NB. Decode one JSON string literal starting at the opening quote. Result is a
NB. raw byte string with every escape resolved, including \uXXXX surrogate
NB. pairs assembled into one code point and re-encoded as UTF-8 with J's own
NB. Unicode conversion (`8 u:`) rather than a hand-rolled encoder.
jp_string=: 3 : 0
  JP_POS=: JP_POS + 1
  out=. ''
  while. 1 do.
    if. JP_POS >: JP_LEN do. jp_fail 'JSON string is unterminated' return. end.
    ch=. JP_SRC{~JP_POS
    if. ch = '"' do.
      JP_POS=: JP_POS + 1
      out return.
    end.
    if. ch = '\' do.
      JP_POS=: JP_POS + 1
      if. JP_POS >: JP_LEN do. jp_fail 'JSON string is unterminated' return. end.
      esc=. JP_SRC{~JP_POS
      if. esc e. '"\/' do.
        out=. out , esc
        JP_POS=: JP_POS + 1
      elseif. esc = 'b' do. out=. out , 8{a. [ JP_POS=: JP_POS+1
      elseif. esc = 'f' do. out=. out , 12{a. [ JP_POS=: JP_POS+1
      elseif. esc = 'n' do. out=. out , LF [ JP_POS=: JP_POS+1
      elseif. esc = 'r' do. out=. out , CR [ JP_POS=: JP_POS+1
      elseif. esc = 't' do. out=. out , TAB [ JP_POS=: JP_POS+1
      elseif. esc = 'u' do.
        JP_POS=: JP_POS + 1
        code=. jp_hex4 ''
        if. -. JP_ERR -: '' do. jnull return. end.
        if. (code >: 56320) *. (code <: 57343) do.
          jp_fail 'JSON string has an unpaired low surrogate' return.
        end.
        if. (code >: 55296) *. (code <: 56319) do.
          if. -. '\u' -: 2 {. JP_POS }. JP_SRC do.
            jp_fail 'JSON string has an unpaired high surrogate' return.
          end.
          JP_POS=: JP_POS + 2
          low=. jp_hex4 ''
          if. -. JP_ERR -: '' do. jnull return. end.
          if. (low < 56320) +. (low > 57343) do.
            jp_fail 'JSON surrogate pair is malformed' return.
          end.
          code=. 65536 + (1024 * code - 55296) + (low - 56320)
        end.
        if. code = 0 do.
          jp_fail 'JSON strings containing U+0000 are unsupported' return.
        end.
        out=. out , 8 u: code
      else.
        jp_fail 'unsupported JSON escape' return.
      end.
    else.
      if. (a. i. ch) < 32 do. jp_fail 'JSON string has an unescaped control character' return. end.
      out=. out , ch
      JP_POS=: JP_POS + 1
    end.
  end.
)

jp_hexval=: 3 : 0
  if. y e. '0123456789' do. (a. i. y) - a. i. '0' return. end.
  if. y e. 'abcdef' do. 10 + (a. i. y) - a. i. 'a' return. end.
  if. y e. 'ABCDEF' do. 10 + (a. i. y) - a. i. 'A' return. end.
  _1
)

jp_hex4=: 3 : 0
  if. (JP_POS + 4) > JP_LEN do. jp_fail 'JSON \u escape is truncated' return. end.
  digits=. 4 {. JP_POS }. JP_SRC
  vals=. jp_hexval"0 digits
  if. 1 e. vals = _1 do. jp_fail 'JSON \u escape is not hexadecimal' return. end.
  JP_POS=: JP_POS + 4
  16 #. vals
)

NB. ---------------------------------------------------------------------------
NB. Writer
NB. ---------------------------------------------------------------------------

NB. Bytes that must never appear literally inside a JSON string: the quote,
NB. the backslash, and every C0 control character.
jw_needs_escape=: 3 : 0
  (y e. '"\') +. (a. i. y) < 32
)

jw_hexdigit=: '0123456789abcdef'&{

jw_hex2=: 3 : 0
  hi=. <. y % 16
  lo=. 16 | y
  (jw_hexdigit hi), jw_hexdigit lo
)

NB. Join a boxed list of already-encoded byte strings with commas and wrap the
NB. result in the given open/close bracket bytes. Used for both JSON arrays
NB. and objects, which differ only in what `parts` holds.
jw_bracket=: 4 : 0
  'open close'=. x
  if. 0 = # y do. open,close return. end.
  out=. > 0 { y
  for_part. }. y do.
    out=. out , ',' , > part
  end.
  open,out,close
)

jw_quote=: 3 : 0
  if. -. 1 e. jw_needs_escape y do. ('"',y,'"') return. end.
  out=. ,'"'
  for_ch. y do.
    code=. a. i. ch
    if. ch = '"' do. out=. out,'\"'
    elseif. ch = '\' do. out=. out,'\\'
    elseif. ch = LF do. out=. out,'\n'
    elseif. ch = CR do. out=. out,'\r'
    elseif. ch = TAB do. out=. out,'\t'
    elseif. code = 8 do. out=. out,'\b'
    elseif. code = 12 do. out=. out,'\f'
    elseif. code < 32 do.
      out=. out,'\u00',jw_hex2 code
    else.
      out=. out,ch
    end.
  end.
  out,'"'
)

cx_json_encode=: 3 : 0
  tag=. jtag y
  if. tag = 's' do. jw_quote jpay y return. end.
  if. tag = 'n' do. jpay y return. end.
  if. tag = 't' do. 'true' return. end.
  if. tag = 'f' do. 'false' return. end.
  if. tag = 'z' do. 'null' return. end.
  if. tag = 'a' do.
    items=. jpay y
    parts=. 0 $ a:
    for_item. items do. parts=. parts , < cx_json_encode > item end.
    ('[';']') jw_bracket parts return.
  end.
  if. tag = 'o' do.
    pairs=. jpay y
    parts=. 0 $ a:
    for_row. pairs do.
      parts=. parts , < (jw_quote > 0{row) , ':' , cx_json_encode > 1{row
    end.
    ('{';'}') jw_bracket parts return.
  end.
  'null'
)
