' Byte, text, time, and failure primitives for the native FreeBASIC Convex
' client. Nothing in this module knows about Convex. Keeping it separate lets
' the adversarial tests drive base64, SHA-1, and UTF-8 edge cases directly
' instead of inferring them from a network transcript.

#pragma once

' Every failure carries a kind so the conformance adapter can emit a structured
' event instead of flattening a protocol bug into a successful value.
const FAULT_NONE = ""
const FAULT_FUNCTION = "FunctionError"
const FAULT_PROTOCOL = "ProtocolError"
const FAULT_TRANSPORT = "TransportError"
const FAULT_CLIENT = "Error"

type ConvexFault
  kind as string
  message as string
  ' errorData is optional in the Convex envelope, so presence is tracked
  ' separately from the payload; an absent value must never serialize as null.
  hasData as boolean
  dataJson as string
end type

declare sub FaultClear(byref fault as ConvexFault)
declare sub FaultSet( _
  byref fault as ConvexFault, _
  byref kind as string, _
  byref message as string)

' A growable byte buffer. FreeBASIC strings are length counted rather than NUL
' terminated, so they hold arbitrary bytes; the explicit count avoids the
' quadratic reallocation that repeated concatenation would cause on the
' WebSocket read path.
type StrBuf
  store as string
  count as uinteger
  declare sub Reserve(byval extra as uinteger)
  declare sub AppendByte(byval octet as ubyte)
  declare sub Append(byref chunk as string)
  declare sub AppendRaw(byval source as ubyte ptr, byval length as uinteger)
  declare sub Clear()
  declare sub DropFront(byval length as uinteger)
  declare function Take() as string
  declare function Slice(byval offset as uinteger, byval length as uinteger) as string
end type

declare function MonotonicMs() as longint
declare sub SleepMs(byval milliseconds as long)
declare function RandomBytes(byval length as long) as string
declare function RandomHex(byval length as long) as string
declare function SessionId() as string

declare function HexDigit(byval nibble as long) as ubyte
declare function ToHex(byref raw as string) as string
declare function Base64Encode(byref raw as string) as string
declare function Base64Decode(byref encoded as string, byref decoded as string) as boolean
declare function Sha1(byref message as string) as string

declare function IsValidUtf8(byref text as string) as boolean
declare function AsciiLower(byref text as string) as string
declare function AsciiTrim(byref text as string) as string
declare function DecimalToUlong(byref text as string, byref parsed as ulongint) as boolean
declare function FormatInteger(byval value as longint) as string
declare function FormatDouble(byval value as double, byref rendered as string) as boolean
declare function ParseDouble(byref text as string, byref parsed as double) as boolean
