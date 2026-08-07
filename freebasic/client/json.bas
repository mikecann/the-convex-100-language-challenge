' Strict JSON tree, parser, and serializer implementation.

#include once "json.bi"

' Parser state travels in one record so recursion stays reentrant and the
' bounds are enforced in exactly one place.
type JsonParser
  text as string
  position as uinteger
  total as uinteger
  depth as long
  nodes as long
  reason as string
end type

declare function ParseValue(byref parser as JsonParser) as JsonValue ptr

function JsonNew(byval kind as long) as JsonValue ptr
  dim as JsonValue ptr node = new JsonValue
  if node = 0 then
    return 0
  end if
  node->kind = kind
  node->boolValue = false
  node->isInteger = false
  node->intValue = 0
  node->dblValue = 0
  node->children = 0
  node->count = 0
  node->capacity = 0
  return node
end function

sub JsonFree(byval node as JsonValue ptr)
  if node = 0 then
    exit sub
  end if
  if node->children <> 0 then
    for index as integer = 0 to cast(integer, node->count) - 1
      JsonFree(node->children[index])
    next
    deallocate(node->children)
    node->children = 0
  end if
  delete node
end sub

function JsonNewBool(byval value as boolean) as JsonValue ptr
  dim as JsonValue ptr node = JsonNew(JSON_BOOL)
  if node <> 0 then
    node->boolValue = value
  end if
  return node
end function

function JsonNewInteger(byval value as longint) as JsonValue ptr
  dim as JsonValue ptr node = JsonNew(JSON_NUMBER)
  if node <> 0 then
    node->isInteger = true
    node->intValue = value
    node->dblValue = value
  end if
  return node
end function

function JsonNewDouble(byval value as double) as JsonValue ptr
  dim as JsonValue ptr node = JsonNew(JSON_NUMBER)
  if node <> 0 then
    node->isInteger = false
    node->dblValue = value
  end if
  return node
end function

function JsonNewString(byref value as string) as JsonValue ptr
  dim as JsonValue ptr node = JsonNew(JSON_STRING)
  if node <> 0 then
    node->text = value
  end if
  return node
end function

private sub JsonGrow(byval parent as JsonValue ptr)
  if parent->count < parent->capacity then
    exit sub
  end if
  dim as uinteger grown = parent->capacity
  if grown = 0 then
    grown = 4
  else
    grown = grown * 2
  end if
  parent->children = reallocate(parent->children, grown * sizeof(any ptr))
  parent->capacity = grown
end sub

sub JsonAppend(byval parent as JsonValue ptr, byval child as JsonValue ptr)
  if parent = 0 orelse child = 0 then
    exit sub
  end if
  JsonGrow(parent)
  parent->children[parent->count] = child
  parent->count += 1
end sub

' Replacing an existing key keeps object semantics single valued, which matters
' because a duplicated key in a Convex envelope would otherwise be ambiguous.
sub JsonSet( _
    byval parent as JsonValue ptr, _
    byref memberKey as string, _
    byval child as JsonValue ptr)
  if parent = 0 orelse child = 0 then
    exit sub
  end if
  child->memberKey = memberKey
  for index as integer = 0 to cast(integer, parent->count) - 1
    if parent->children[index]->memberKey = memberKey then
      JsonFree(parent->children[index])
      parent->children[index] = child
      exit sub
    end if
  next
  JsonAppend(parent, child)
end sub

function JsonMember( _
    byval node as JsonValue ptr, _
    byref memberKey as string) as JsonValue ptr
  if node = 0 orelse node->kind <> JSON_OBJECT then
    return 0
  end if
  for index as integer = 0 to cast(integer, node->count) - 1
    if node->children[index]->memberKey = memberKey then
      return node->children[index]
    end if
  next
  return 0
end function

function JsonAt(byval node as JsonValue ptr, byval index as uinteger) as JsonValue ptr
  if node = 0 orelse index >= node->count then
    return 0
  end if
  return node->children[index]
end function

function JsonClone(byval node as JsonValue ptr) as JsonValue ptr
  if node = 0 then
    return 0
  end if
  dim as JsonValue ptr copy = JsonNew(node->kind)
  if copy = 0 then
    return 0
  end if
  copy->boolValue = node->boolValue
  copy->isInteger = node->isInteger
  copy->intValue = node->intValue
  copy->dblValue = node->dblValue
  copy->text = node->text
  copy->memberKey = node->memberKey
  for index as integer = 0 to cast(integer, node->count) - 1
    JsonAppend(copy, JsonClone(node->children[index]))
  next
  return copy
end function

' Object comparison ignores member order because Convex does not promise a
' stable key order, and an ordering difference is not a value change.
function JsonEqual( _
    byval first as JsonValue ptr, _
    byval second as JsonValue ptr) as boolean
  if first = 0 orelse second = 0 then
    return first = second
  end if
  if first->kind <> second->kind then
    return false
  end if
  select case first->kind
    case JSON_NULL
      return true
    case JSON_BOOL
      return first->boolValue = second->boolValue
    case JSON_NUMBER
      if first->isInteger andalso second->isInteger then
        return first->intValue = second->intValue
      end if
      return first->dblValue = second->dblValue
    case JSON_STRING
      return first->text = second->text
    case JSON_ARRAY
      if first->count <> second->count then
        return false
      end if
      for index as integer = 0 to cast(integer, first->count) - 1
        if not JsonEqual(first->children[index], second->children[index]) then
          return false
        end if
      next
      return true
    case JSON_OBJECT
      if first->count <> second->count then
        return false
      end if
      for index as integer = 0 to cast(integer, first->count) - 1
        dim as JsonValue ptr mate = _
          JsonMember(second, first->children[index]->memberKey)
        if mate = 0 orelse not JsonEqual(first->children[index], mate) then
          return false
        end if
      next
      return true
  end select
  return false
end function

private function ParserPeek(byref parser as JsonParser) as long
  if parser.position >= parser.total then
    return -1
  end if
  return parser.text[parser.position]
end function

private sub SkipWhitespace(byref parser as JsonParser)
  while parser.position < parser.total
    dim as ubyte octet = parser.text[parser.position]
    if octet <> 32 andalso octet <> 9 andalso octet <> 10 andalso octet <> 13 then
      exit while
    end if
    parser.position += 1
  wend
end sub

private sub ParserFail(byref parser as JsonParser, byref reason as string)
  if len(parser.reason) = 0 then
    parser.reason = reason
  end if
end sub

' Encode one code point as UTF-8. Escaped input is the only place the parser
' produces multi-byte sequences itself, so it must not emit surrogates.
private sub AppendCodePoint(byref sink as StrBuf, byval codePoint as ulong)
  if codePoint < &h80 then
    sink.AppendByte(codePoint)
  elseif codePoint < &h800 then
    sink.AppendByte(&hc0 or (codePoint shr 6))
    sink.AppendByte(&h80 or (codePoint and &h3f))
  elseif codePoint < &h10000 then
    sink.AppendByte(&he0 or (codePoint shr 12))
    sink.AppendByte(&h80 or ((codePoint shr 6) and &h3f))
    sink.AppendByte(&h80 or (codePoint and &h3f))
  else
    sink.AppendByte(&hf0 or (codePoint shr 18))
    sink.AppendByte(&h80 or ((codePoint shr 12) and &h3f))
    sink.AppendByte(&h80 or ((codePoint shr 6) and &h3f))
    sink.AppendByte(&h80 or (codePoint and &h3f))
  end if
end sub

private function ReadHex4(byref parser as JsonParser, byref value as ulong) as boolean
  value = 0
  if parser.position + 4 > parser.total then
    return false
  end if
  for offset as long = 0 to 3
    dim as ubyte octet = parser.text[parser.position + offset]
    dim as ulong digit
    select case octet
      case asc("0") to asc("9")
        digit = octet - asc("0")
      case asc("a") to asc("f")
        digit = octet - asc("a") + 10
      case asc("A") to asc("F")
        digit = octet - asc("A") + 10
      case else
        return false
    end select
    value = (value shl 4) or digit
  next
  parser.position += 4
  return true
end function

private function ParseStringBody(byref parser as JsonParser, byref value as string) as boolean
  dim as StrBuf sink
  ' The opening quote has already been consumed by the caller.
  do
    if parser.position >= parser.total then
      ParserFail(parser, "unterminated JSON string")
      return false
    end if
    dim as ubyte octet = parser.text[parser.position]
    if octet = asc("""") then
      parser.position += 1
      value = sink.Take()
      return true
    end if
    if octet < &h20 then
      ParserFail(parser, "unescaped control character in JSON string")
      return false
    end if
    if octet <> asc("\") then
      sink.AppendByte(octet)
      parser.position += 1
      continue do
    end if
    parser.position += 1
    if parser.position >= parser.total then
      ParserFail(parser, "truncated JSON escape")
      return false
    end if
    dim as ubyte escaped = parser.text[parser.position]
    parser.position += 1
    select case escaped
      case asc("""")
        sink.AppendByte(asc(""""))
      case asc("\")
        sink.AppendByte(asc("\"))
      case asc("/")
        sink.AppendByte(asc("/"))
      case asc("b")
        sink.AppendByte(8)
      case asc("f")
        sink.AppendByte(12)
      case asc("n")
        sink.AppendByte(10)
      case asc("r")
        sink.AppendByte(13)
      case asc("t")
        sink.AppendByte(9)
      case asc("u")
        dim as ulong codePoint
        if not ReadHex4(parser, codePoint) then
          ParserFail(parser, "invalid JSON unicode escape")
          return false
        end if
        if codePoint >= &hd800 andalso codePoint <= &hdbff then
          ' A high surrogate must be followed by its low surrogate; a lone
          ' half would produce invalid UTF-8 on the way back out.
          if parser.position + 1 >= parser.total orelse _
             parser.text[parser.position] <> asc("\") orelse _
             parser.text[parser.position + 1] <> asc("u") then
            ParserFail(parser, "unpaired JSON high surrogate")
            return false
          end if
          parser.position += 2
          dim as ulong low
          if not ReadHex4(parser, low) then
            ParserFail(parser, "invalid JSON unicode escape")
            return false
          end if
          if low < &hdc00 orelse low > &hdfff then
            ParserFail(parser, "unpaired JSON high surrogate")
            return false
          end if
          codePoint = &h10000 + ((codePoint - &hd800) shl 10) + (low - &hdc00)
        elseif codePoint >= &hdc00 andalso codePoint <= &hdfff then
          ParserFail(parser, "unpaired JSON low surrogate")
          return false
        end if
        AppendCodePoint(sink, codePoint)
      case else
        ParserFail(parser, "unknown JSON escape")
        return false
    end select
  loop
  return false
end function

private function ParseNumber(byref parser as JsonParser) as JsonValue ptr
  dim as uinteger start = parser.position
  dim as boolean isDouble = false
  if ParserPeek(parser) = asc("-") then
    parser.position += 1
  end if
  dim as uinteger digitsStart = parser.position
  while parser.position < parser.total andalso _
        parser.text[parser.position] >= asc("0") andalso _
        parser.text[parser.position] <= asc("9")
    parser.position += 1
  wend
  if parser.position = digitsStart then
    ParserFail(parser, "JSON number is missing digits")
    return 0
  end if
  ' JSON forbids leading zeros such as 01 and -0123.
  if parser.position - digitsStart > 1 andalso parser.text[digitsStart] = asc("0") then
    ParserFail(parser, "JSON number has a leading zero")
    return 0
  end if
  if ParserPeek(parser) = asc(".") then
    isDouble = true
    parser.position += 1
    dim as uinteger fractionStart = parser.position
    while parser.position < parser.total andalso _
          parser.text[parser.position] >= asc("0") andalso _
          parser.text[parser.position] <= asc("9")
      parser.position += 1
    wend
    if parser.position = fractionStart then
      ParserFail(parser, "JSON number is missing fraction digits")
      return 0
    end if
  end if
  dim as long marker = ParserPeek(parser)
  if marker = asc("e") orelse marker = asc("E") then
    isDouble = true
    parser.position += 1
    marker = ParserPeek(parser)
    if marker = asc("+") orelse marker = asc("-") then
      parser.position += 1
    end if
    dim as uinteger exponentStart = parser.position
    while parser.position < parser.total andalso _
          parser.text[parser.position] >= asc("0") andalso _
          parser.text[parser.position] <= asc("9")
      parser.position += 1
    wend
    if parser.position = exponentStart then
      ParserFail(parser, "JSON number is missing exponent digits")
      return 0
    end if
  end if

  dim as string token = mid(parser.text, cint(start) + 1, cint(parser.position - start))
  if not isDouble then
    ' Keep an exact integer spelling when it fits, so identifiers and counters
    ' survive a round trip unchanged.
    dim as boolean negative = (token[0] = asc("-"))
    dim as string digits = token
    if negative then
      digits = mid(token, 2)
    end if
    dim as ulongint magnitude
    if DecimalToUlong(digits, magnitude) then
      if negative andalso magnitude = 9223372036854775808ull then
        ' The most negative 64-bit integer has no positive counterpart, so it
        ' cannot be produced by negating a longint.
        return JsonNewInteger(-9223372036854775807ll - 1)
      end if
      if magnitude <= 9223372036854775807ull then
        dim as longint value = cast(longint, magnitude)
        if negative then
          value = -value
        end if
        return JsonNewInteger(value)
      end if
    end if
  end if
  dim as double parsed
  if not ParseDouble(token, parsed) then
    ParserFail(parser, "JSON number could not be decoded")
    return 0
  end if
  ' JSON has no spelling for infinity, so a token that overflows a double is a
  ' malformed document rather than a very large value.
  if parsed <> parsed orelse parsed > 1.7976931348623157e308 orelse _
     parsed < -1.7976931348623157e308 then
    ParserFail(parser, "JSON number is out of range")
    return 0
  end if
  return JsonNewDouble(parsed)
end function

private function ParseLiteral( _
    byref parser as JsonParser, _
    byref word as string) as boolean
  if parser.position + culng(len(word)) > parser.total then
    return false
  end if
  return mid(parser.text, cint(parser.position) + 1, len(word)) = word
end function

function ParseValue(byref parser as JsonParser) as JsonValue ptr
  ' Locals are hoisted so the object and array arms cannot collide on a name,
  ' and so the recursive descent reads as one flat dispatch.
  dim as JsonValue ptr node
  dim as JsonValue ptr child
  dim as string memberKey
  dim as string value
  dim as long separator
  parser.nodes += 1
  if parser.nodes > JSON_MAX_NODES then
    ParserFail(parser, "JSON document has too many values")
    return 0
  end if
  if parser.depth > JSON_MAX_DEPTH then
    ParserFail(parser, "JSON document is nested too deeply")
    return 0
  end if
  SkipWhitespace(parser)
  dim as long lead = ParserPeek(parser)
  select case lead
    case -1
      ParserFail(parser, "JSON document ended early")
      return 0
    case asc("{")
      parser.position += 1
      parser.depth += 1
      node = JsonNew(JSON_OBJECT)
      SkipWhitespace(parser)
      if ParserPeek(parser) = asc("}") then
        parser.position += 1
        parser.depth -= 1
        return node
      end if
      do
        SkipWhitespace(parser)
        if ParserPeek(parser) <> asc("""") then
          ParserFail(parser, "JSON object key must be a string")
          JsonFree(node)
          return 0
        end if
        parser.position += 1
        if not ParseStringBody(parser, memberKey) then
          JsonFree(node)
          return 0
        end if
        SkipWhitespace(parser)
        if ParserPeek(parser) <> asc(":") then
          ParserFail(parser, "JSON object member is missing a colon")
          JsonFree(node)
          return 0
        end if
        parser.position += 1
        child = ParseValue(parser)
        if child = 0 then
          JsonFree(node)
          return 0
        end if
        if JsonMember(node, memberKey) <> 0 then
          ParserFail(parser, "JSON object has a duplicate key")
          JsonFree(child)
          JsonFree(node)
          return 0
        end if
        child->memberKey = memberKey
        JsonAppend(node, child)
        SkipWhitespace(parser)
        separator = ParserPeek(parser)
        if separator = asc(",") then
          parser.position += 1
          continue do
        end if
        if separator = asc("}") then
          parser.position += 1
          parser.depth -= 1
          return node
        end if
        ParserFail(parser, "JSON object is missing a comma or brace")
        JsonFree(node)
        return 0
      loop
    case asc("[")
      parser.position += 1
      parser.depth += 1
      node = JsonNew(JSON_ARRAY)
      SkipWhitespace(parser)
      if ParserPeek(parser) = asc("]") then
        parser.position += 1
        parser.depth -= 1
        return node
      end if
      do
        child = ParseValue(parser)
        if child = 0 then
          JsonFree(node)
          return 0
        end if
        JsonAppend(node, child)
        SkipWhitespace(parser)
        separator = ParserPeek(parser)
        if separator = asc(",") then
          parser.position += 1
          continue do
        end if
        if separator = asc("]") then
          parser.position += 1
          parser.depth -= 1
          return node
        end if
        ParserFail(parser, "JSON array is missing a comma or bracket")
        JsonFree(node)
        return 0
      loop
    case asc("""")
      parser.position += 1
      if not ParseStringBody(parser, value) then
        return 0
      end if
      return JsonNewString(value)
    case asc("t")
      if not ParseLiteral(parser, "true") then
        ParserFail(parser, "unknown JSON literal")
        return 0
      end if
      parser.position += 4
      return JsonNewBool(true)
    case asc("f")
      if not ParseLiteral(parser, "false") then
        ParserFail(parser, "unknown JSON literal")
        return 0
      end if
      parser.position += 5
      return JsonNewBool(false)
    case asc("n")
      if not ParseLiteral(parser, "null") then
        ParserFail(parser, "unknown JSON literal")
        return 0
      end if
      parser.position += 4
      return JsonNew(JSON_NULL)
    case else
      if lead = asc("-") orelse (lead >= asc("0") andalso lead <= asc("9")) then
        return ParseNumber(parser)
      end if
      ParserFail(parser, "unexpected JSON character")
      return 0
  end select
end function

function JsonParse( _
    byref text as string, _
    byref reason as string) as JsonValue ptr
  reason = ""
  if not IsValidUtf8(text) then
    reason = "JSON document is not valid UTF-8"
    return 0
  end if
  dim as JsonParser parser
  parser.text = text
  parser.position = 0
  parser.total = culng(len(text))
  parser.depth = 0
  parser.nodes = 0
  dim as JsonValue ptr node = ParseValue(parser)
  if node = 0 then
    reason = parser.reason
    if len(reason) = 0 then
      reason = "invalid JSON document"
    end if
    return 0
  end if
  SkipWhitespace(parser)
  if parser.position <> parser.total then
    JsonFree(node)
    reason = "JSON document has trailing content"
    return 0
  end if
  return node
end function

private sub RenderString(byref text as string, byref sink as StrBuf)
  sink.AppendByte(asc(""""))
  for index as integer = 0 to len(text) - 1
    dim as ubyte octet = text[index]
    select case octet
      case asc("""")
        sink.Append("\""")
      case asc("\")
        sink.Append("\\")
      case 8
        sink.Append("\b")
      case 12
        sink.Append("\f")
      case 10
        sink.Append("\n")
      case 13
        sink.Append("\r")
      case 9
        sink.Append("\t")
      case else
        if octet < &h20 then
          sink.Append("\u00")
          sink.AppendByte(HexDigit(octet shr 4))
          sink.AppendByte(HexDigit(octet and &h0f))
        else
          ' Everything else, including multi-byte UTF-8, is emitted verbatim.
          sink.AppendByte(octet)
        end if
    end select
  next
  sink.AppendByte(asc(""""))
end sub

sub JsonRenderInto(byval node as JsonValue ptr, byref sink as StrBuf)
  if node = 0 then
    sink.Append("null")
    exit sub
  end if
  select case node->kind
    case JSON_NULL
      sink.Append("null")
    case JSON_BOOL
      if node->boolValue then
        sink.Append("true")
      else
        sink.Append("false")
      end if
    case JSON_NUMBER
      if node->isInteger then
        sink.Append(FormatInteger(node->intValue))
      else
        dim as string rendered
        if FormatDouble(node->dblValue, rendered) then
          sink.Append(rendered)
        else
          ' A non-finite double has no JSON spelling. Null is the only legal
          ' placeholder, and the encoder never produces one from parsed input.
          sink.Append("null")
        end if
      end if
    case JSON_STRING
      RenderString(node->text, sink)
    case JSON_ARRAY
      sink.AppendByte(asc("["))
      for index as integer = 0 to cast(integer, node->count) - 1
        if index > 0 then
          sink.AppendByte(asc(","))
        end if
        JsonRenderInto(node->children[index], sink)
      next
      sink.AppendByte(asc("]"))
    case JSON_OBJECT
      sink.AppendByte(asc("{"))
      for index as integer = 0 to cast(integer, node->count) - 1
        if index > 0 then
          sink.AppendByte(asc(","))
        end if
        RenderString(node->children[index]->memberKey, sink)
        sink.AppendByte(asc(":"))
        JsonRenderInto(node->children[index], sink)
      next
      sink.AppendByte(asc("}"))
  end select
end sub

function JsonRender(byval node as JsonValue ptr) as string
  dim as StrBuf sink
  JsonRenderInto(node, sink)
  return sink.Take()
end function

function JsonIsObject(byval node as JsonValue ptr) as boolean
  return node <> 0 andalso node->kind = JSON_OBJECT
end function

function JsonStringField( _
    byval node as JsonValue ptr, _
    byref memberKey as string, _
    byref value as string) as boolean
  dim as JsonValue ptr member = JsonMember(node, memberKey)
  if member = 0 orelse member->kind <> JSON_STRING then
    return false
  end if
  value = member->text
  return true
end function

function JsonUnsignedField( _
    byval node as JsonValue ptr, _
    byref memberKey as string, _
    byref value as ulongint) as boolean
  dim as JsonValue ptr member = JsonMember(node, memberKey)
  if member = 0 orelse member->kind <> JSON_NUMBER then
    return false
  end if
  if not member->isInteger orelse member->intValue < 0 then
    return false
  end if
  value = cast(ulongint, member->intValue)
  return true
end function

' Convex may encode a whole number as 1 or 1.0. Accept both spellings while
' rejecting fractions, non-finite doubles, and values outside 64-bit range.
function JsonWholeNumber(byval node as JsonValue ptr, byref value as longint) as boolean
  value = 0
  if node = 0 orelse node->kind <> JSON_NUMBER then
    return false
  end if
  if node->isInteger then
    value = node->intValue
    return true
  end if
  dim as double number = node->dblValue
  if number <> number then
    return false
  end if
  if number < -9223372036854775808.0 orelse number >= 9223372036854775808.0 then
    return false
  end if
  dim as longint truncated = cast(longint, number)
  if cast(double, truncated) <> number then
    return false
  end if
  value = truncated
  return true
end function
