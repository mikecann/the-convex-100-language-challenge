' Implementation of the shared byte, text, time, and failure primitives.

#include once "core.bi"

' The C runtime supplies only memory movement, formatting, and clock services.
' Every Convex-specific behaviour above these calls is written in FreeBASIC.
declare function c_memcpy cdecl alias "memcpy" ( _
  byval destination as any ptr, _
  byval source as any ptr, _
  byval length as uinteger) as any ptr
declare function c_snprintf cdecl alias "snprintf" ( _
  byval buffer as zstring ptr, _
  byval limit as uinteger, _
  byval format as zstring ptr, ...) as long
declare function c_strtod cdecl alias "strtod" ( _
  byval text as zstring ptr, _
  byval tail as zstring ptr ptr) as double

const CLOCK_MONOTONIC = 1

type TimeSpecT
  tv_sec as longint
  tv_nsec as longint
end type

declare function sys_clock_gettime cdecl alias "clock_gettime" ( _
  byval clock as long, _
  byval value as TimeSpecT ptr) as long
declare function sys_nanosleep cdecl alias "nanosleep" ( _
  byval requested as TimeSpecT ptr, _
  byval remaining as TimeSpecT ptr) as long

' OpenSSL is the pinned TLS provider, so its CSPRNG is already loaded when the
' client needs unpredictable WebSocket masking keys and session identifiers.
' #inclib records libcrypto as a link dependency of this object file itself,
' so any command that links core.bas pulls it in -- unlike net.bas, core.bas
' is linked on its own by the style-check gate, without net.bas's own
' #inclib "crypto" alongside it.
#inclib "crypto"
declare function RAND_bytes cdecl alias "RAND_bytes" ( _
  byval buffer as ubyte ptr, _
  byval length as long) as long

const NANOS_PER_MILLI as longint = 1000000
const MILLIS_PER_SECOND as longint = 1000

' Nothing in this module has mutable global state. FreeBASIC only runs the
' top-level code of the main module, so a library module must compute its
' tables rather than assign them at load time.

sub FaultClear(byref fault as ConvexFault)
  fault.kind = FAULT_NONE
  fault.message = ""
  fault.hasData = false
  fault.dataJson = ""
end sub

sub FaultSet( _
    byref fault as ConvexFault, _
    byref kind as string, _
    byref message as string)
  fault.kind = kind
  fault.message = message
  fault.hasData = false
  fault.dataJson = ""
end sub

sub StrBuf.Reserve(byval extra as uinteger)
  dim as uinteger needed = this.count + extra
  if needed <= culng(len(this.store)) then
    exit sub
  end if
  dim as uinteger grown = culng(len(this.store))
  if grown < 64 then
    grown = 64
  end if
  while grown < needed
    grown = grown * 2
  wend
  this.store += space(cint(grown) - len(this.store))
end sub

sub StrBuf.AppendByte(byval octet as ubyte)
  this.Reserve(1)
  this.store[this.count] = octet
  this.count += 1
end sub

sub StrBuf.Append(byref chunk as string)
  dim as uinteger length = culng(len(chunk))
  if length = 0 then
    exit sub
  end if
  this.Reserve(length)
  c_memcpy(@this.store[this.count], strptr(chunk), length)
  this.count += length
end sub

sub StrBuf.AppendRaw(byval source as ubyte ptr, byval length as uinteger)
  if source = 0 orelse length = 0 then
    exit sub
  end if
  this.Reserve(length)
  c_memcpy(@this.store[this.count], source, length)
  this.count += length
end sub

sub StrBuf.Clear()
  this.count = 0
  this.store = ""
end sub

' Consume a decoded prefix without reallocating the whole buffer on every
' WebSocket frame; the residue keeps partially received frames intact.
sub StrBuf.DropFront(byval length as uinteger)
  if length >= this.count then
    this.count = 0
    exit sub
  end if
  c_memcpy(@this.store[0], @this.store[length], this.count - length)
  this.count -= length
end sub

function StrBuf.Take() as string
  if this.count = 0 then
    return ""
  end if
  return left(this.store, cint(this.count))
end function

function StrBuf.Slice(byval offset as uinteger, byval length as uinteger) as string
  if offset >= this.count orelse length = 0 then
    return ""
  end if
  dim as uinteger available = this.count - offset
  if length > available then
    length = available
  end if
  return mid(this.store, cint(offset) + 1, cint(length))
end function

function MonotonicMs() as longint
  dim as TimeSpecT now
  if sys_clock_gettime(CLOCK_MONOTONIC, @now) <> 0 then
    return 0
  end if
  return now.tv_sec * MILLIS_PER_SECOND + now.tv_nsec \ NANOS_PER_MILLI
end function

sub SleepMs(byval milliseconds as long)
  if milliseconds <= 0 then
    exit sub
  end if
  dim as TimeSpecT requested
  requested.tv_sec = cast(longint, milliseconds) \ MILLIS_PER_SECOND
  requested.tv_nsec = (cast(longint, milliseconds) mod MILLIS_PER_SECOND) * NANOS_PER_MILLI
  dim as TimeSpecT remaining
  ' A signal must not shorten a bounded wait, so resume with the remainder.
  while sys_nanosleep(@requested, @remaining) <> 0
    if remaining.tv_sec = 0 andalso remaining.tv_nsec = 0 then
      exit while
    end if
    requested = remaining
    remaining.tv_sec = 0
    remaining.tv_nsec = 0
  wend
end sub

function RandomBytes(byval length as long) as string
  if length <= 0 then
    return ""
  end if
  dim as string raw = space(length)
  if RAND_bytes(cast(ubyte ptr, strptr(raw)), length) <> 1 then
    return ""
  end if
  return raw
end function

function RandomHex(byval length as long) as string
  dim as string raw = RandomBytes(length)
  if len(raw) = 0 then
    return ""
  end if
  return ToHex(raw)
end function

' Convex identifies a sync session by an opaque string. A version 4 UUID keeps
' the wire shape familiar without depending on a UUID library.
function SessionId() as string
  dim as string raw = RandomBytes(16)
  if len(raw) <> 16 then
    return ""
  end if
  raw[6] = (raw[6] and &h0f) or &h40
  raw[8] = (raw[8] and &h3f) or &h80
  dim as string digits = ToHex(raw)
  return mid(digits, 1, 8) & "-" & mid(digits, 9, 4) & "-" & mid(digits, 13, 4) & _
    "-" & mid(digits, 17, 4) & "-" & mid(digits, 21, 12)
end function

function HexDigit(byval nibble as long) as ubyte
  nibble = nibble and &h0f
  if nibble < 10 then
    return asc("0") + nibble
  end if
  return asc("a") + (nibble - 10)
end function

function ToHex(byref raw as string) as string
  dim as string result = space(len(raw) * 2)
  for index as integer = 0 to len(raw) - 1
    result[index * 2] = HexDigit(raw[index] shr 4)
    result[index * 2 + 1] = HexDigit(raw[index] and &h0f)
  next
  return result
end function

private function Base64Char(byval value as long) as ubyte
  select case value
    case 0 to 25
      return asc("A") + value
    case 26 to 51
      return asc("a") + (value - 26)
    case 52 to 61
      return asc("0") + (value - 52)
    case 62
      return asc("+")
  end select
  return asc("/")
end function

function Base64Encode(byref raw as string) as string
  dim as StrBuf encoded
  dim as integer total = len(raw)
  dim as integer index = 0
  while index < total
    dim as ulong group = cast(ulong, raw[index]) shl 16
    dim as integer available = 1
    if index + 1 < total then
      group or= cast(ulong, raw[index + 1]) shl 8
      available += 1
    end if
    if index + 2 < total then
      group or= cast(ulong, raw[index + 2])
      available += 1
    end if
    encoded.AppendByte(Base64Char((group shr 18) and &h3f))
    encoded.AppendByte(Base64Char((group shr 12) and &h3f))
    if available >= 2 then
      encoded.AppendByte(Base64Char((group shr 6) and &h3f))
    else
      encoded.AppendByte(asc("="))
    end if
    if available >= 3 then
      encoded.AppendByte(Base64Char(group and &h3f))
    else
      encoded.AppendByte(asc("="))
    end if
    index += 3
  wend
  return encoded.Take()
end function

private function Base64Index(byval octet as ubyte) as long
  select case octet
    case asc("A") to asc("Z")
      return octet - asc("A")
    case asc("a") to asc("z")
      return octet - asc("a") + 26
    case asc("0") to asc("9")
      return octet - asc("0") + 52
    case asc("+")
      return 62
    case asc("/")
      return 63
  end select
  return -1
end function

' Strict base64: canonical padding only, no whitespace, and no unused trailing
' bits. Convex timestamps arrive base64 encoded and a lenient decoder would let
' two different spellings claim the same sync position.
function Base64Decode(byref encoded as string, byref decoded as string) as boolean
  decoded = ""
  dim as integer total = len(encoded)
  if total = 0 then
    return true
  end if
  if (total mod 4) <> 0 then
    return false
  end if
  dim as StrBuf sink
  dim as integer index = 0
  while index < total
    dim as integer padding = 0
    dim as ulong group = 0
    for slot as integer = 0 to 3
      dim as ubyte octet = encoded[index + slot]
      if octet = asc("=") then
        ' Padding is legal only in the final quantum's last two slots.
        if index + 4 <> total orelse slot < 2 then
          return false
        end if
        padding += 1
        group = group shl 6
      else
        if padding > 0 then
          return false
        end if
        dim as long value = Base64Index(octet)
        if value < 0 then
          return false
        end if
        group = (group shl 6) or cast(ulong, value)
      end if
    next
    if padding = 1 then
      if (group and &hff) <> 0 then
        return false
      end if
      sink.AppendByte((group shr 16) and &hff)
      sink.AppendByte((group shr 8) and &hff)
    elseif padding = 2 then
      if (group and &hffff) <> 0 then
        return false
      end if
      sink.AppendByte((group shr 16) and &hff)
    else
      sink.AppendByte((group shr 16) and &hff)
      sink.AppendByte((group shr 8) and &hff)
      sink.AppendByte(group and &hff)
    end if
    index += 4
  wend
  decoded = sink.Take()
  return true
end function

private function RotateLeft32(byval value as ulong, byval bits as long) as ulong
  return ((value shl bits) or (value shr (32 - bits))) and &hffffffffull
end function

' RFC 3174 SHA-1. The WebSocket opening handshake needs it to verify
' Sec-WebSocket-Accept, and implementing it here keeps the handshake check
' inside the target language rather than delegating it.
function Sha1(byref message as string) as string
  dim as ulong h0 = &h67452301ul
  dim as ulong h1 = &hEFCDAB89ul
  dim as ulong h2 = &h98BADCFEul
  dim as ulong h3 = &h10325476ul
  dim as ulong h4 = &hC3D2E1F0ul

  dim as ulongint bitLength = cast(ulongint, len(message)) * 8
  dim as StrBuf padded
  padded.Append(message)
  padded.AppendByte(&h80)
  while ((padded.count + 8) mod 64) <> 0
    padded.AppendByte(0)
  wend
  for shift as integer = 7 to 0 step -1
    padded.AppendByte((bitLength shr (shift * 8)) and &hff)
  next

  dim as ulong words(0 to 79)
  dim as uinteger blockStart = 0
  while blockStart < padded.count
    for index as integer = 0 to 15
      dim as uinteger wordBase = blockStart + index * 4
      words(index) = (cast(ulong, padded.store[wordBase]) shl 24) or _
        (cast(ulong, padded.store[wordBase + 1]) shl 16) or _
        (cast(ulong, padded.store[wordBase + 2]) shl 8) or _
        cast(ulong, padded.store[wordBase + 3])
    next
    for index as integer = 16 to 79
      words(index) = RotateLeft32( _
        words(index - 3) xor words(index - 8) xor words(index - 14) xor words(index - 16), 1)
    next

    dim as ulong a = h0, b = h1, c = h2, d = h3, e = h4
    for index as integer = 0 to 79
      dim as ulong f, k
      select case index \ 20
        case 0
          f = (b and c) or ((not b) and d)
          k = &h5A827999ul
        case 1
          f = b xor c xor d
          k = &h6ED9EBA1ul
        case 2
          f = (b and c) or (b and d) or (c and d)
          k = &h8F1BBCDCul
        case else
          f = b xor c xor d
          k = &hCA62C1D6ul
      end select
      dim as ulong temp = (RotateLeft32(a, 5) + f + e + k + words(index)) and &hffffffffull
      e = d
      d = c
      c = RotateLeft32(b, 30)
      b = a
      a = temp
    next
    h0 = (h0 + a) and &hffffffffull
    h1 = (h1 + b) and &hffffffffull
    h2 = (h2 + c) and &hffffffffull
    h3 = (h3 + d) and &hffffffffull
    h4 = (h4 + e) and &hffffffffull
    blockStart += 64
  wend

  dim as string digest = space(20)
  dim as ulong state(0 to 4)
  state(0) = h0
  state(1) = h1
  state(2) = h2
  state(3) = h3
  state(4) = h4
  for index as integer = 0 to 4
    digest[index * 4] = (state(index) shr 24) and &hff
    digest[index * 4 + 1] = (state(index) shr 16) and &hff
    digest[index * 4 + 2] = (state(index) shr 8) and &hff
    digest[index * 4 + 3] = state(index) and &hff
  next
  return digest
end function

' Reject overlong forms, surrogates, and out-of-range code points. A Live
' message that is not well-formed UTF-8 is a protocol failure, not a value.
function IsValidUtf8(byref text as string) as boolean
  dim as integer index = 0
  dim as integer total = len(text)
  while index < total
    dim as ubyte lead = text[index]
    dim as integer extra
    dim as ulong codePoint
    if lead < &h80 then
      index += 1
      continue while
    elseif (lead and &he0) = &hc0 then
      extra = 1
      codePoint = lead and &h1f
    elseif (lead and &hf0) = &he0 then
      extra = 2
      codePoint = lead and &h0f
    elseif (lead and &hf8) = &hf0 then
      extra = 3
      codePoint = lead and &h07
    else
      return false
    end if
    if index + extra >= total then
      return false
    end if
    for offset as integer = 1 to extra
      dim as ubyte continuation = text[index + offset]
      if (continuation and &hc0) <> &h80 then
        return false
      end if
      codePoint = (codePoint shl 6) or (continuation and &h3f)
    next
    select case extra
      case 1
        if codePoint < &h80 then
          return false
        end if
      case 2
        if codePoint < &h800 then
          return false
        end if
        if codePoint >= &hd800 andalso codePoint <= &hdfff then
          return false
        end if
      case 3
        if codePoint < &h10000 orelse codePoint > &h10ffff then
          return false
        end if
    end select
    index += extra + 1
  wend
  return true
end function

function AsciiLower(byref text as string) as string
  dim as string result = text
  for index as integer = 0 to len(result) - 1
    if result[index] >= asc("A") andalso result[index] <= asc("Z") then
      result[index] += 32
    end if
  next
  return result
end function

function AsciiTrim(byref text as string) as string
  dim as integer first = 0
  dim as integer last = len(text) - 1
  while first <= last andalso (text[first] = 32 orelse text[first] = 9)
    first += 1
  wend
  while last >= first andalso (text[last] = 32 orelse text[last] = 9)
    last -= 1
  wend
  if first > last then
    return ""
  end if
  return mid(text, first + 1, last - first + 1)
end function

' Content-Length and chunk sizes must not be accepted from a lenient parse.
' Reject empty text, non-digits, and anything that would overflow.
function DecimalToUlong(byref text as string, byref parsed as ulongint) as boolean
  parsed = 0
  if len(text) = 0 orelse len(text) > 20 then
    return false
  end if
  for index as integer = 0 to len(text) - 1
    dim as ubyte octet = text[index]
    if octet < asc("0") orelse octet > asc("9") then
      return false
    end if
    dim as ulongint digit = octet - asc("0")
    dim as ulongint limit = not cast(ulongint, 0)
    if parsed > (limit - digit) \ 10 then
      return false
    end if
    parsed = parsed * 10 + digit
  next
  return true
end function

function FormatInteger(byval value as longint) as string
  dim as zstring * 32 buffer
  c_snprintf(@buffer, 32, "%lld", value)
  return buffer
end function

' Emit the shortest decimal spelling that reads back as the same double so a
' round-tripped Convex value is byte-comparable without losing precision.
function FormatDouble(byval value as double, byref rendered as string) as boolean
  rendered = ""
  ' Non-finite doubles have no JSON spelling; refuse instead of emitting a
  ' token the peer would reject.
  if value <> value then
    return false
  end if
  if value > 1.7976931348623157e308 orelse value < -1.7976931348623157e308 then
    return false
  end if
  dim as zstring * 64 buffer
  for precision as long = 15 to 17
    c_snprintf(@buffer, 64, "%." & FormatInteger(precision) & "g", value)
    dim as string candidate = buffer
    dim as double restored
    if ParseDouble(candidate, restored) andalso restored = value then
      rendered = candidate
      exit for
    end if
  next
  if len(rendered) = 0 then
    return false
  end if
  ' A JSON number never carries an exponent without digits or a bare integer
  ' marker, so normalise the C spellings that JSON forbids.
  if instr(rendered, "inf") > 0 orelse instr(rendered, "nan") > 0 then
    rendered = ""
    return false
  end if
  return true
end function

function ParseDouble(byref text as string, byref parsed as double) as boolean
  parsed = 0
  if len(text) = 0 then
    return false
  end if
  dim as zstring ptr tail
  dim as zstring * 512 buffer
  if len(text) >= 512 then
    return false
  end if
  buffer = text
  parsed = c_strtod(@buffer, @tail)
  ' strtod must have consumed the entire token; a partial parse means the
  ' caller handed us something that is not a JSON number.
  return tail = cast(zstring ptr, @buffer) + len(text)
end function
