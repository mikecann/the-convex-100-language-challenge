' A strict RFC 8259 JSON tree, parser, and serializer written in FreeBASIC.
'
' Convex values arrive as JSON and every Convex envelope is validated against
' the shape below before the client treats it as data, so the parser refuses
' the lenient spellings (trailing commas, NaN, leading zeros, bare control
' characters) that would otherwise let a malformed response look successful.

#pragma once

#include once "core.bi"

const JSON_NULL = 0
const JSON_BOOL = 1
const JSON_NUMBER = 2
const JSON_STRING = 3
const JSON_ARRAY = 4
const JSON_OBJECT = 5

' Bounds are part of the contract, not tuning. A hostile or broken peer must
' not be able to make the client allocate without limit.
const JSON_MAX_DEPTH = 64
const JSON_MAX_NODES = 200000

type JsonValue
  kind as long
  boolValue as boolean
  ' Convex JSON numbers may be spelled 1 or 1.0. The integer spelling is kept
  ' so a round trip does not silently rewrite the wire form.
  isInteger as boolean
  intValue as longint
  dblValue as double
  text as string
  memberKey as string
  children as JsonValue ptr ptr
  count as uinteger
  capacity as uinteger
end type

declare function JsonNew(byval kind as long) as JsonValue ptr
declare sub JsonFree(byval node as JsonValue ptr)
declare function JsonNewBool(byval value as boolean) as JsonValue ptr
declare function JsonNewInteger(byval value as longint) as JsonValue ptr
declare function JsonNewDouble(byval value as double) as JsonValue ptr
declare function JsonNewString(byref value as string) as JsonValue ptr
declare sub JsonAppend(byval parent as JsonValue ptr, byval child as JsonValue ptr)
declare sub JsonSet( _
  byval parent as JsonValue ptr, _
  byref memberKey as string, _
  byval child as JsonValue ptr)
declare function JsonMember( _
  byval node as JsonValue ptr, _
  byref memberKey as string) as JsonValue ptr
declare function JsonAt(byval node as JsonValue ptr, byval index as uinteger) as JsonValue ptr
declare function JsonClone(byval node as JsonValue ptr) as JsonValue ptr
declare function JsonEqual( _
  byval first as JsonValue ptr, _
  byval second as JsonValue ptr) as boolean

declare function JsonParse( _
  byref text as string, _
  byref reason as string) as JsonValue ptr
declare function JsonRender(byval node as JsonValue ptr) as string
declare sub JsonRenderInto(byval node as JsonValue ptr, byref sink as StrBuf)

' Convenience readers used by the envelope checks. Each returns false rather
' than a default so a missing field can never be confused with a present one.
declare function JsonIsObject(byval node as JsonValue ptr) as boolean
declare function JsonStringField( _
  byval node as JsonValue ptr, _
  byref memberKey as string, _
  byref value as string) as boolean
declare function JsonUnsignedField( _
  byval node as JsonValue ptr, _
  byref memberKey as string, _
  byref value as ulongint) as boolean
declare function JsonWholeNumber(byval node as JsonValue ptr, byref value as longint) as boolean
