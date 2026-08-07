// A strict JSON codec written for Convex rather than a general purpose one.
//
// Two Convex specific requirements shape it.
//
// Convex sends integral values in whatever decimal form the backend produced.
// A count of one can arrive as `1`, `1.0`, or `1e0`. Routing every number
// through a 64 bit float would make `9007199254740993` decode to a different
// integer and `1e400` decode to infinity, so `JsonNumber` keeps the exact
// source lexeme and converts on demand. `integral()` then accepts any
// mathematically integral value in range and rejects fractional, non-finite,
// and overflowing ones.
//
// The conformance suite also echoes decimals and multi-byte text through
// the backend and compares them for equality, so the codec must reproduce the
// original number lexeme and pass UTF-8 through without escaping it.

primitive JsonLimits
  """
  Bounds that make a hostile or accidental payload fail closed instead of
  exhausting memory. Nesting depth is checked while parsing and while
  encoding, because a value can be built by the caller as well as parsed.
  """
  fun max_depth(): USize => 64

type JsonValue is (None | Bool | JsonNumber | String | JsonArray | JsonObject)

class val JsonNumber
  """
  A JSON number held as its exact lexeme.
  """

  let text: String

  new val create(text': String) ? =>
    if not JsonNumberText.valid(text') then error end
    text = text'

  new val from_i64(value: I64) =>
    text = value.string()

  fun same_text(other: JsonNumber): Bool => text == other.text

  fun integral(): I64 ? =>
    """
    Convert to an exact 64 bit integer.

    Fractional values, values outside the signed 64 bit range, and any lexeme
    that is not a JSON number are errors. `0.0`, `1e2`, and `-100e-2` are not.
    """
    (let negative: Bool, let digits: String, let exponent: I64) =
      JsonNumberText.parts(text)?

    // Shift the digit string by the decimal exponent instead of multiplying,
    // so no intermediate value can overflow or lose precision.
    var shifted: String iso = String(digits.size() + 24)
    if exponent >= 0 then
      shifted.append(digits)
      var added: I64 = 0
      while added < exponent do
        shifted.push('0')
        // A value this long cannot fit in 64 bits, so stop rather than
        // building an unbounded string for an absurd exponent.
        if shifted.size() > 40 then error end
        added = added + 1
      end
    else
      let drop = (-exponent).usize()
      if drop > digits.size() then
        // More fractional places than digits means the value is below one and
        // can only be integral if every digit is zero.
        var index: USize = 0
        while index < digits.size() do
          if digits(index)? != '0' then error end
          index = index + 1
        end
        shifted.push('0')
      else
        let keep = digits.size() - drop
        var index: USize = keep
        while index < digits.size() do
          if digits(index)? != '0' then error end
          index = index + 1
        end
        index = 0
        while index < keep do
          shifted.push(digits(index)?)
          index = index + 1
        end
      end
    end
    let magnitude: String = consume shifted

    var accumulated: U64 = 0
    var position: USize = 0
    while position < magnitude.size() do
      let digit = magnitude(position)? - '0'
      if accumulated > 1844674407370955161 then error end
      accumulated = accumulated * 10
      if accumulated > (U64.max_value() - digit.u64()) then error end
      accumulated = accumulated + digit.u64()
      position = position + 1
    end

    if negative then
      if accumulated > 9223372036854775808 then error end
      if accumulated == 9223372036854775808 then
        I64.min_value()
      else
        -(accumulated.i64())
      end
    else
      if accumulated > 9223372036854775807 then error end
      accumulated.i64()
    end

primitive JsonNumberText
  """
  Lexeme level analysis of a JSON number, kept separate from `JsonNumber` so
  the validating constructor can use it before any instance exists.
  """

  fun valid(text': String): Bool =>
    try
      JsonNumberText.parts(text')?
      true
    else
      false
    end

  fun parts(text': String): (Bool, String, I64) ? =>
    """
    Split a JSON number lexeme into sign, significant digits with the decimal
    point removed, and the resulting power of ten. Strictly rejects the forms
    JSON does not allow, such as a leading `+`, a leading zero, `.5`, and `1.`.
    """
    if text'.size() == 0 then error end
    var index: USize = 0
    let negative = text'(0)? == '-'
    if negative then index = 1 end
    if index >= text'.size() then error end

    var digits: String iso = String(text'.size())
    let first = text'(index)?
    if first == '0' then
      digits.push('0')
      index = index + 1
    elseif (first >= '1') and (first <= '9') then
      while index < text'.size() do
        let byte = text'(index)?
        if (byte < '0') or (byte > '9') then break end
        digits.push(byte)
        index = index + 1
      end
    else
      error
    end

    var exponent: I64 = 0
    if (index < text'.size()) and (text'(index)? == '.') then
      index = index + 1
      var fraction_digits: USize = 0
      while index < text'.size() do
        let byte = text'(index)?
        if (byte < '0') or (byte > '9') then break end
        digits.push(byte)
        fraction_digits = fraction_digits + 1
        index = index + 1
      end
      if fraction_digits == 0 then error end
      exponent = exponent - fraction_digits.i64()
    end

    if index < text'.size() then
      let marker = text'(index)?
      if (marker != 'e') and (marker != 'E') then error end
      index = index + 1
      if index >= text'.size() then error end
      var exponent_negative = false
      let sign = text'(index)?
      if (sign == '+') or (sign == '-') then
        exponent_negative = sign == '-'
        index = index + 1
      end
      var exponent_digits: USize = 0
      var magnitude: I64 = 0
      while index < text'.size() do
        let byte = text'(index)?
        if (byte < '0') or (byte > '9') then error end
        // Clamp rather than overflow. Anything this large is out of range for
        // `integral()` anyway, and the clamp keeps the sign meaningful.
        if magnitude < 100000 then
          magnitude = (magnitude * 10) + (byte - '0').i64()
        end
        exponent_digits = exponent_digits + 1
        index = index + 1
      end
      if exponent_digits == 0 then error end
      let signed = if exponent_negative then -magnitude else magnitude end
      exponent = exponent + signed
    end

    if index != text'.size() then error end
    (negative, consume digits, exponent)

class val JsonArray
  let items: Array[JsonValue] val

  new val create(items': Array[JsonValue] val) =>
    items = items'

  fun size(): USize => items.size()

  fun apply(index: USize): JsonValue ? => items(index)?

class val JsonObject
  """
  Members are kept in an ordered list rather than a hash map so encoding is
  deterministic. Convex payloads are small, and a stable byte-for-byte
  encoding is what lets the Live layer compare a rehydrated value against the
  one it last delivered.
  """

  let entries: Array[(String, JsonValue)] val

  new val create(entries': Array[(String, JsonValue)] val) =>
    entries = entries'

  fun size(): USize => entries.size()

  fun contains(name: String): Bool =>
    for entry in entries.values() do
      if entry._1 == name then return true end
    end
    false

  fun apply(name: String): JsonValue ? =>
    for entry in entries.values() do
      if entry._1 == name then return entry._2 end
    end
    error

  fun get_or_none(name: String): JsonValue =>
    try apply(name)? else None end

  fun string_field(name: String): String ? =>
    match apply(name)?
    | let value: String => value
    else
      error
    end

  fun object_field(name: String): JsonObject ? =>
    match apply(name)?
    | let value: JsonObject => value
    else
      error
    end

  fun array_field(name: String): JsonArray ? =>
    match apply(name)?
    | let value: JsonArray => value
    else
      error
    end

  fun u32_field(name: String): U32 ? =>
    match apply(name)?
    | let value: JsonNumber =>
      let integer = value.integral()?
      if (integer < 0) or (integer > 4294967295) then error end
      integer.u32()
    else
      error
    end

  fun string_list(name: String): Array[String] val ? =>
    """
    Convex log lines. An absent field is an empty list, but a present field
    that is not an array of strings is a protocol error rather than a silent
    empty list.
    """
    if not contains(name) then return recover val Array[String] end end
    match apply(name)?
    | None => recover val Array[String] end
    | let value: JsonArray =>
      var out: Array[String] iso = Array[String](value.size())
      var index: USize = 0
      while index < value.size() do
        match value(index)?
        | let line: String => out.push(line)
        else
          error
        end
        index = index + 1
      end
      consume out
    else
      error
    end

primitive JsonOf
  """
  Small constructors for the object shapes this client sends. Convex function
  arguments are always a named object, so these cover every call site here.
  """

  fun empty(): JsonObject =>
    JsonObject(recover val Array[(String, JsonValue)] end)

  fun obj(pairs: Array[(String, JsonValue)] val): JsonObject =>
    JsonObject(pairs)

  fun obj1(name1: String, value1: JsonValue): JsonObject =>
    JsonObject(recover val
      let out = Array[(String, JsonValue)](1)
      out.push((name1, value1))
      out
    end)

  fun obj2(name1: String, value1: JsonValue, name2: String, value2: JsonValue)
    : JsonObject
  =>
    JsonObject(recover val
      let out = Array[(String, JsonValue)](2)
      out.push((name1, value1))
      out.push((name2, value2))
      out
    end)

  fun obj3(
    name1: String,
    value1: JsonValue,
    name2: String,
    value2: JsonValue,
    name3: String,
    value3: JsonValue)
    : JsonObject
  =>
    JsonObject(recover val
      let out = Array[(String, JsonValue)](3)
      out.push((name1, value1))
      out.push((name2, value2))
      out.push((name3, value3))
      out
    end)

  fun array(items: Array[JsonValue] val): JsonArray =>
    JsonArray(items)

  fun array1(item1: JsonValue): JsonArray =>
    JsonArray(recover val
      let out = Array[JsonValue](1)
      out.push(item1)
      out
    end)

  fun number(value: I64): JsonNumber =>
    JsonNumber.from_i64(value)

primitive JsonEncode
  """
  Encode a value back to compact JSON. Non-ASCII bytes are emitted unchanged so
  a round-tripped string is byte identical to the one Convex sent.
  """

  fun apply(value: JsonValue): String ? =>
    recover val
      let out = String(128)
      JsonEncode.write(out, value, 0)?
      out
    end

  fun write(out: String ref, value: JsonValue, depth: USize) ? =>
    if depth > JsonLimits.max_depth() then error end
    match value
    | None => out.append("null")
    | let flag: Bool => out.append(if flag then "true" else "false" end)
    | let number: JsonNumber => out.append(number.text)
    | let text: String => JsonEncode.write_string(out, text)
    | let items: JsonArray =>
      out.push('[')
      var index: USize = 0
      while index < items.size() do
        if index > 0 then out.push(',') end
        JsonEncode.write(out, items(index)?, depth + 1)?
        index = index + 1
      end
      out.push(']')
    | let fields: JsonObject =>
      out.push('{')
      var index: USize = 0
      while index < fields.entries.size() do
        if index > 0 then out.push(',') end
        let entry = fields.entries(index)?
        JsonEncode.write_string(out, entry._1)
        out.push(':')
        JsonEncode.write(out, entry._2, depth + 1)?
        index = index + 1
      end
      out.push('}')
    end

  fun write_string(out: String ref, text: String) =>
    out.push('"')
    var index: USize = 0
    while index < text.size() do
      let byte = try text(index)? else 0 end
      if byte == '"' then
        out.append("\\\"")
      elseif byte == '\\' then
        out.append("\\\\")
      elseif byte == 0x08 then
        out.append("\\b")
      elseif byte == 0x09 then
        out.append("\\t")
      elseif byte == 0x0a then
        out.append("\\n")
      elseif byte == 0x0c then
        out.append("\\f")
      elseif byte == 0x0d then
        out.append("\\r")
      elseif byte < 0x20 then
        out.append("\\u00")
        out.push(Hex.digit(byte >> 4))
        out.push(Hex.digit(byte and 0x0f))
      else
        out.push(byte)
      end
      index = index + 1
    end
    out.push('"')

primitive JsonDecode
  """
  Parse a complete JSON document. Trailing content, comments, `NaN`, and other
  extensions are rejected: a Convex response that is not exactly one JSON value
  is a protocol failure, not something to guess at.
  """

  fun apply(text: String): JsonValue ? =>
    if not Utf8.valid_string(text) then error end
    let reader = _JsonReader(text)
    reader.parse()?

  fun parse_object(text: String): JsonObject ? =>
    match JsonDecode(text)?
    | let value: JsonObject => value
    else
      error
    end

class ref _JsonReader
  let _text: String
  var _position: USize = 0

  new ref create(text: String) =>
    _text = text

  fun ref parse(): JsonValue ? =>
    _skip_space()
    let value = _value(0)?
    _skip_space()
    if _position != _text.size() then error end
    value

  fun ref _skip_space() =>
    while _position < _text.size() do
      let byte = try _text(_position)? else return end
      if (byte == 0x20) or (byte == 0x09) or (byte == 0x0a) or (byte == 0x0d)
      then
        _position = _position + 1
      else
        return
      end
    end

  fun ref _value(depth: USize): JsonValue ? =>
    if depth > JsonLimits.max_depth() then error end
    _skip_space()
    let byte = _text(_position)?
    if byte == '{' then
      _object(depth)?
    elseif byte == '[' then
      _array(depth)?
    elseif byte == '"' then
      _string()?
    elseif byte == 't' then
      _literal("true")?
      true
    elseif byte == 'f' then
      _literal("false")?
      false
    elseif byte == 'n' then
      _literal("null")?
      None
    elseif (byte == '-') or ((byte >= '0') and (byte <= '9')) then
      _number()?
    else
      error
    end

  fun ref _literal(word: String) ? =>
    var index: USize = 0
    while index < word.size() do
      if _text(_position + index)? != word(index)? then error end
      index = index + 1
    end
    _position = _position + word.size()

  fun ref _object(depth: USize): JsonObject ? =>
    _position = _position + 1
    var entries: Array[(String, JsonValue)] iso =
      Array[(String, JsonValue)](8)
    _skip_space()
    if _text(_position)? == '}' then
      _position = _position + 1
    else
      while true do
        _skip_space()
        let name = _string()?
        _skip_space()
        if _text(_position)? != ':' then error end
        _position = _position + 1
        let value = _value(depth + 1)?
        entries.push((name, value))
        _skip_space()
        let byte = _text(_position)?
        if byte == ',' then
          _position = _position + 1
        elseif byte == '}' then
          _position = _position + 1
          break
        else
          error
        end
      end
    end
    JsonObject(consume entries)

  fun ref _array(depth: USize): JsonArray ? =>
    _position = _position + 1
    var items: Array[JsonValue] iso = Array[JsonValue](8)
    _skip_space()
    if _text(_position)? == ']' then
      _position = _position + 1
    else
      while true do
        items.push(_value(depth + 1)?)
        _skip_space()
        let byte = _text(_position)?
        if byte == ',' then
          _position = _position + 1
        elseif byte == ']' then
          _position = _position + 1
          break
        else
          error
        end
      end
    end
    JsonArray(consume items)

  fun ref _string(): String ? =>
    if _text(_position)? != '"' then error end
    _position = _position + 1
    var out: String iso = String(16)
    while true do
      let byte = _text(_position)?
      if byte == '"' then
        _position = _position + 1
        break
      elseif byte == '\\' then
        _position = _position + 1
        let escape = _text(_position)?
        _position = _position + 1
        if escape == '"' then
          out.push('"')
        elseif escape == '\\' then
          out.push('\\')
        elseif escape == '/' then
          out.push('/')
        elseif escape == 'b' then
          out.push(0x08)
        elseif escape == 'f' then
          out.push(0x0c)
        elseif escape == 'n' then
          out.push(0x0a)
        elseif escape == 'r' then
          out.push(0x0d)
        elseif escape == 't' then
          out.push(0x09)
        elseif escape == 'u' then
          let first = _hex4()?
          if (first >= 0xd800) and (first <= 0xdbff) then
            // A high surrogate is only meaningful when its low half follows.
            if _text(_position)? != '\\' then error end
            if _text(_position + 1)? != 'u' then error end
            _position = _position + 2
            let second = _hex4()?
            if (second < 0xdc00) or (second > 0xdfff) then error end
            let combined =
              0x10000 + (((first - 0xd800) << 10) or (second - 0xdc00))
            for point_byte in Utf8.write_point(combined).values() do
              out.push(point_byte)
            end
          elseif (first >= 0xdc00) and (first <= 0xdfff) then
            error
          else
            for point_byte in Utf8.write_point(first).values() do
              out.push(point_byte)
            end
          end
        else
          error
        end
      elseif byte < 0x20 then
        // Raw control characters are not legal inside a JSON string.
        error
      else
        out.push(byte)
        _position = _position + 1
      end
    end
    consume out

  fun ref _hex4(): U32 ? =>
    var value: U32 = 0
    var index: USize = 0
    while index < 4 do
      let byte = _text(_position + index)?
      let digit =
        if (byte >= '0') and (byte <= '9') then
          (byte - '0').u32()
        elseif (byte >= 'a') and (byte <= 'f') then
          ((byte - 'a') + 10).u32()
        elseif (byte >= 'A') and (byte <= 'F') then
          ((byte - 'A') + 10).u32()
        else
          error
        end
      value = (value << 4) or digit
      index = index + 1
    end
    _position = _position + 4
    value

  fun ref _number(): JsonNumber ? =>
    let start = _position
    if _text(_position)? == '-' then _position = _position + 1 end
    while _position < _text.size() do
      let byte = _text(_position)?
      if ((byte >= '0') and (byte <= '9')) or (byte == '.') or (byte == 'e') or
        (byte == 'E') or (byte == '+') or (byte == '-')
      then
        _position = _position + 1
      else
        break
      end
    end
    var lexeme: String iso = String(_position - start)
    var index: USize = start
    while index < _position do
      lexeme.push(_text(index)?)
      index = index + 1
    end
    // `create` re-validates the lexeme, so a shape such as `1.` or `01` that
    // the scan above would happily consume still fails here.
    JsonNumber(consume lexeme)?
