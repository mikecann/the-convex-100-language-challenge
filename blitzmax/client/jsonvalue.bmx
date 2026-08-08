SuperStrict

' Bounded JSON handling for the BlitzMax Convex client.
'
' Text.Json (jansson) does the parsing and serialising. What this file adds is
' the part a Convex client actually needs: a refusal to allocate a tree for a
' document that is wire-legal but ruinously expensive, and strict accessors
' that never promote a missing or mistyped member into a plausible value.

Import Text.Json
Import BRL.Base64

Import "transport.bmx"

' A parsed document is not its serialised text. jansson allocates one heap
' value per JSON value, plus hash-table bookkeeping for every object member and
' pointer-array bookkeeping for every array element, so a dense document
' retains far more than it weighs on the wire. Every budget below charges the
' retained runtime representation rather than the encoded length.
Const CONVEX_JSON_UNIT_BYTES:Int = 128
Const CONVEX_MAX_RETAINED_JSON_BYTES:Int = 8 * 1024 * 1024
Const CONVEX_MAX_RETAINED_JSON_UNITS:Int = CONVEX_MAX_RETAINED_JSON_BYTES / CONVEX_JSON_UNIT_BYTES
' jansson's parser recurses, so deep nesting is a C stack hazard rather than a
' heap one and needs its own bound.
Const CONVEX_MAX_JSON_DEPTH:Int = 64

' Encode compactly, allow a bare scalar at the top level because a Convex value
' is frequently a string or a number, and keep seventeen significant digits so
' every double survives a round trip.
Const CONVEX_JSON_ENCODE_FLAGS:Int = JSON_COMPACT | JSON_ENCODE_ANY
Const CONVEX_JSON_DECODE_FLAGS:Int = JSON_REJECT_DUPLICATES

Rem
bbdoc: Scans untrusted JSON text and returns the bytes its tree would retain.
about: The bound has to be applied before jansson allocates anything, because
once the parser has run the memory is already committed. This walks the raw
text without allocating, counting the structural positions that must each
become a retained value, and refuses a document whose tree could exceed the
budget or whose nesting could exhaust the parser's stack.
End Rem
Function ConvexScanJson:Int(source:String, subject:String)
	Local units:Int = 1
	Local depth:Int = 0
	Local inString:Int = False
	Local escaped:Int = False
	For Local index:Int = 0 Until source.length
		Local current:Int = source[index]
		If inString Then
			' Separators inside a string are literal text on a single value, so
			' an escaped quote must not be mistaken for the end of that string.
			If escaped Then
				escaped = False
			ElseIf current = 92 Then
				escaped = True
			ElseIf current = 34 Then
				inString = False
			End If
			Continue
		End If
		If current = 34 Then
			inString = True
		ElseIf current = 91 Or current = 123 Then
			depth :+ 1
			If depth > CONVEX_MAX_JSON_DEPTH Then
				Throw TConvexError.Protocol(subject + " nests deeper than the bounded JSON depth")
			End If
		ElseIf current = 93 Or current = 125 Then
			If depth > 0 Then
				depth :- 1
			End If
		ElseIf current = 44 Then
			' Every separator introduces one more array element or member value.
			units :+ 1
		ElseIf current = 58 Then
			' An object member retains its name as well as its value.
			units :+ 2
		End If
		If units > CONVEX_MAX_RETAINED_JSON_UNITS Then
			Throw TConvexError.Protocol(subject + " exceeds the bounded retained JSON budget")
		End If
	Next
	Local retained:Int = units * CONVEX_JSON_UNIT_BYTES
	If source.length > CONVEX_MAX_RETAINED_JSON_BYTES - retained Then
		Throw TConvexError.Protocol(subject + " exceeds the bounded retained JSON budget")
	End If
	Return retained + source.length
End Function

Rem
bbdoc: Parses @source after bounding what its tree may cost.
End Rem
Function ConvexParseJson:TJSON(source:String, subject:String)
	ConvexScanJson(source, subject)
	Local failure:TJSONError
	Local parsed:TJSON = TJSON.Load(source, CONVEX_JSON_DECODE_FLAGS, failure)
	If Not parsed Then
		Local detail:String = "no JSON value"
		If failure And failure.Text.length > 0 Then
			detail = failure.Text
		End If
		Throw TConvexError.Protocol("malformed " + subject + ": " + detail)
	End If
	Return parsed
End Function

Rem
bbdoc: Parses @source and insists the result is a JSON object.
End Rem
Function ConvexParseJsonObject:TJSONObject(source:String, subject:String)
	Local parsed:TJSON = ConvexParseJson(source, subject)
	Local asObject:TJSONObject = TJSONObject(parsed)
	If Not asObject Then
		Throw TConvexError.Protocol(subject + " is not a JSON object")
	End If
	Return asObject
End Function

Rem
bbdoc: Serialises @node exactly as it will travel back to a caller.
End Rem
Function ConvexEncode:String(node:TJSON)
	If Not node Then
		Return "null"
	End If
	Local encoded:String = node.SaveString(CONVEX_JSON_ENCODE_FLAGS, 0, 17)
	If encoded.length = 0 Then
		Throw TConvexError.Protocol("could not serialise a JSON value")
	End If
	Return encoded
End Function

Rem
bbdoc: Renders @text as a JSON string literal.
about: Used wherever the client composes protocol text by hand, so that a room
name, function path, or error message containing a quote or a control character
cannot break out of the field it belongs to.
End Rem
Function ConvexQuote:String(text:String)
	Local encoded:TConvexBuffer = TConvexBuffer.Create(text.length + 32)
	encoded.AppendByte(34)
	Local runStart:Int = 0
	For Local index:Int = 0 Until text.length
		Local code:Int = text[index]
		If code >= 32 And code <> 34 And code <> 92 Then
			Continue
		End If
		' Copy the run of characters that need no escaping in one piece. Cuts
		' only ever land on ASCII, so this never splits a surrogate pair.
		If index > runStart Then
			encoded.AppendString(text[runStart..index])
		End If
		runStart = index + 1
		encoded.AppendByte(92)
		Select code
			Case 34
				encoded.AppendByte(34)
			Case 92
				encoded.AppendByte(92)
			Case 8
				encoded.AppendByte(98)
			Case 9
				encoded.AppendByte(116)
			Case 10
				encoded.AppendByte(110)
			Case 12
				encoded.AppendByte(102)
			Case 13
				encoded.AppendByte(114)
			Default
				encoded.AppendString("u00")
				encoded.AppendString(ConvexHexDigit(code Shr 4) + ConvexHexDigit(code))
		End Select
	Next
	If text.length > runStart Then
		encoded.AppendString(text[runStart..text.length])
	End If
	encoded.AppendByte(34)
	Return encoded.ToText()
End Function

Function ConvexHexDigit:String(value:Int)
	Local digits:String = "0123456789abcdef"
	Local digit:Int = value & $F
	Return digits[digit..digit + 1]
End Function

Rem
bbdoc: Reads a required string member.
End Rem
Function ConvexStringMember:String(owner:TJSONObject, memberName:String)
	Local member:TJSONString = TJSONString(owner.Get(memberName))
	If Not member Then
		Throw TConvexError.Protocol(memberName + " is missing or is not a string")
	End If
	Return member.Value()
End Function

Rem
bbdoc: Reads a required object member.
End Rem
Function ConvexObjectMember:TJSONObject(owner:TJSONObject, memberName:String)
	Local member:TJSONObject = TJSONObject(owner.Get(memberName))
	If Not member Then
		Throw TConvexError.Protocol(memberName + " is missing or is not an object")
	End If
	Return member
End Function

Rem
bbdoc: Reads a required array member.
End Rem
Function ConvexArrayMember:TJSONArray(owner:TJSONObject, memberName:String)
	Local member:TJSONArray = TJSONArray(owner.Get(memberName))
	If Not member Then
		Throw TConvexError.Protocol(memberName + " is missing or is not an array")
	End If
	Return member
End Function

Rem
bbdoc: Reads a JSON number that must be mathematically an integer.
about: Convex encodes an integral number as either 1 or 1.0 depending on how it
travelled, so both forms are accepted while fractional, non-finite, and
out-of-range values are refused.
End Rem
Function ConvexIntegralValue:Long(node:TJSON, subject:String)
	If Not node Then
		Throw TConvexError.Protocol(subject + " is missing")
	End If
	Local whole:TJSONInteger = TJSONInteger(node)
	If whole Then
		Return whole.Value()
	End If
	Local real:TJSONReal = TJSONReal(node)
	If Not real Then
		Throw TConvexError.Protocol(subject + " is not a number")
	End If
	Local value:Double = real.Value()
	' A NaN is the only value that differs from itself, and the bounds keep the
	' conversion below inside the signed 64-bit range.
	If value <> value Then
		Throw TConvexError.Protocol(subject + " is not a finite number")
	End If
	' Stay comfortably inside the signed 64-bit range so the conversion below
	' cannot be undefined; Convex counters never approach this magnitude.
	If value < -9.0e18 Or value > 9.0e18 Then
		Throw TConvexError.Protocol(subject + " is outside the 64-bit integer range")
	End If
	Local truncated:Long = Long(value)
	If Double(truncated) <> value Then
		Throw TConvexError.Protocol(subject + " is not an integer")
	End If
	Return truncated
End Function

Rem
bbdoc: Reads an unsigned 32-bit protocol counter.
End Rem
Function ConvexUInt32Member:Long(owner:TJSONObject, memberName:String)
	Local value:Long = ConvexIntegralValue(owner.Get(memberName), memberName)
	If value < 0 Or (value Shr 32) <> 0 Then
		Throw TConvexError.Protocol(memberName + " is outside the unsigned 32-bit range")
	End If
	Return value
End Function

Rem
bbdoc: Reads Convex's optional logLines array as plain strings.
End Rem
Function ConvexLogLines:String[](owner:TJSONObject)
	Local node:TJSON = owner.Get("logLines")
	If Not node Then
		Return New String[0]
	End If
	Local lines:TJSONArray = TJSONArray(node)
	If Not lines Then
		Throw TConvexError.Protocol("logLines is not an array")
	End If
	Local collected:String[] = New String[lines.Size()]
	For Local index:Int = 0 Until lines.Size()
		Local line:TJSONString = TJSONString(lines.Get(index))
		If Not line Then
			Throw TConvexError.Protocol("logLines contains a value that is not a string")
		End If
		collected[index] = line.Value()
	Next
	Return collected
End Function

Rem
bbdoc: Decodes a Convex sync timestamp.
about: The wire form is a little-endian unsigned 64-bit integer in base64. The
re-encoding check rejects a non-canonical spelling of the same bytes, so a peer
cannot slip a different string past the equality checks that use it.
End Rem
Function ConvexTimestampValue:Long(encoded:String)
	Local decoded:Byte[]
	Try
		decoded = TBase64.Decode(encoded)
	Catch problem:Object
		Throw TConvexError.Protocol("timestamp is not valid base64")
	End Try
	If decoded.length <> 8 Then
		Throw TConvexError.Protocol("timestamp is not eight bytes")
	End If
	If TBase64.Encode(decoded, 0, EBase64Options.DontBreakLines) <> encoded Then
		Throw TConvexError.Protocol("timestamp is not a canonical base64 encoding")
	End If
	Local value:Long = 0
	For Local index:Int = 7 To 0 Step -1
		value = (value Shl 8) | Long(decoded[index])
	Next
	If value < 0 Then
		Throw TConvexError.Protocol("timestamp does not fit a signed 64-bit comparison")
	End If
	Return value
End Function
