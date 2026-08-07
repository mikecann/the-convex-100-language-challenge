SuperStrict

' Language-local unit tests that need no socket.
'
' These cover the decisions a Convex client gets wrong quietly: what counts as
' an integer, what counts as a canonical timestamp, what a bounded relay does
' when it is full, and whether an acknowledgement really is a barrier.

Framework BRL.StandardIO

Import "testing.bmx"
Import "../transport.bmx"
Import "../jsonvalue.bmx"
Import "../websocket.bmx"
Import "../convex.bmx"

Rem
bbdoc: Records what a relay actually delivered.
End Rem
Type TRecordingObserver Extends TConvexObserver

	Field values:Int
	Field failures:Int
	Field lastFailureName:String
	Field lastCount:Long

	Method OnUpdate(subscription:TConvexSubscription, value:TJSON, failure:TConvexFunctionError) Override
		If failure Then
			failures :+ 1
			lastFailureName = failure.name
			Return
		End If
		values :+ 1
		Local asObject:TJSONObject = TJSONObject(value)
		If asObject Then
			lastCount = ConvexIntegralValue(asObject.Get("count"), "count")
		End If
	End Method

End Type

Global DeliveryProbeBytes:Int

Rem
bbdoc: Observes the byte reservation while an update is in a consumer's hands.
End Rem
Function ProbeInFlightBytes:Int(subscription:TConvexSubscription)
	DeliveryProbeBytes = subscription.PendingBytes()
	Return 0
End Function

Rem
bbdoc: Retires the relay in the exact window a stale event could cross an ack.
End Rem
Function InvalidateDuringDelivery:Int(subscription:TConvexSubscription)
	subscription.Invalidate()
	Return 0
End Function

Function CountValue:TJSONObject(count:Int)
	Return ConvexParseJsonObject("{~qcount~q:" + count + "}", "test value")
End Function

Function ExpectPathRejected:Int()
	TConvexEndpoint.Parse("https://example.convex.cloud/api/query")
	Return 0
End Function

Function ExpectSchemeRejected:Int()
	TConvexEndpoint.Parse("ws://example.convex.cloud")
	Return 0
End Function

Function ExpectDeepJsonRejected:Int()
	Local nested:String = ""
	For Local depth:Int = 0 Until 80
		nested :+ "["
	Next
	For Local depth:Int = 0 Until 80
		nested :+ "]"
	Next
	ConvexScanJson(nested, "value")
	Return 0
End Function

Function ExpectDenseJsonRejected:Int()
	' Every comma is one more retained value; this stays small on the wire and
	' enormous in memory, which is exactly the shape the budget exists for.
	' Doubling builds a quarter of a million elements without paying quadratic
	' string concatenation to do it.
	Local dense:String = "0"
	For Local doubling:Int = 0 Until 18
		dense = dense + "," + dense
	Next
	ConvexScanJson("[" + dense + "]", "value")
	Return 0
End Function

Function ExpectFractionRejected:Int()
	ConvexIntegralValue(CountValue(0).Get("count"), "count")
	Local fractional:TJSONObject = ConvexParseJsonObject("{~qcount~q:1.5}", "test value")
	ConvexIntegralValue(fractional.Get("count"), "count")
	Return 0
End Function

Function ExpectStringCountRejected:Int()
	Local quoted:TJSONObject = ConvexParseJsonObject("{~qcount~q:~q1~q}", "test value")
	ConvexIntegralValue(quoted.Get("count"), "count")
	Return 0
End Function

Function ExpectNonCanonicalTimestampRejected:Int()
	' The same eight bytes spelled with a different final character. A lenient
	' decoder accepts it, which would let a peer send a value that compares
	' unequal to the timestamp the client echoes back.
	ConvexTimestampValue("AAAAAAAAAAB=")
	Return 0
End Function

Function ExpectShortTimestampRejected:Int()
	ConvexTimestampValue("AAAA")
	Return 0
End Function

Function TestEndpoints()
	Local secure:TConvexEndpoint = TConvexEndpoint.Parse("https://example.convex.cloud")
	ConvexCheckEqual(secure.host, "example.convex.cloud", "https host")
	ConvexCheckEqualInt(secure.port, 443, "https default port")
	ConvexCheck(secure.useTls, "https selects TLS")
	ConvexCheckEqual(secure.Authority(), "example.convex.cloud", "default port is omitted from Host")

	Local plain:TConvexEndpoint = TConvexEndpoint.Parse("http://backend:3210/")
	ConvexCheckEqualInt(plain.port, 3210, "explicit port")
	ConvexCheck(Not plain.useTls, "http does not select TLS")
	ConvexCheckEqual(plain.Authority(), "backend:3210", "non-default port stays in Host")
	ConvexCheckEqual(plain.origin, "http://backend:3210", "a trailing slash is trimmed from the origin")

	ConvexCheckRaises(ExpectPathRejected, "path", "a deployment URL with a path is rejected")
	ConvexCheckRaises(ExpectSchemeRejected, "http or https", "a non-HTTP scheme is rejected")
End Function

Function TestJsonBounds()
	ConvexCheckRaises(ExpectDeepJsonRejected, "nests deeper", "deeply nested JSON is refused before it is parsed")
	ConvexCheckRaises(ExpectDenseJsonRejected, "retained JSON budget", "node-dense JSON is refused before it is parsed")
	Local retained:Int = ConvexScanJson("{~qa~q:1}", "value")
	ConvexCheck(retained > 0, "the scanner reports a retained-byte estimate")
End Function

Rem
bbdoc: A one-character string for a code point BlitzMax cannot write literally.
End Rem
Function SingleByte:String(value:Int)
	Local raw:Byte[] = New Byte[1]
	raw[0] = Byte(value)
	Return String.FromBytes(raw, 1)
End Function

Function TestQuoting()
	' BlitzMax escapes with a tilde, so a backslash below is a literal one.
	ConvexCheckEqual(ConvexQuote("plain"), "~qplain~q", "plain text is quoted unchanged")
	ConvexCheckEqual(ConvexQuote("a~qb"), "~qa\~qb~q", "a quote is escaped")
	ConvexCheckEqual(ConvexQuote("a\b"), "~qa\\b~q", "a backslash is escaped")
	ConvexCheckEqual(ConvexQuote("a~nb"), "~qa\nb~q", "a newline is escaped")
	ConvexCheckEqual(ConvexQuote(SingleByte(1)), "~q\u0001~q", "an unnamed control character escapes numerically")
	ConvexCheckEqual(ConvexQuote("héllo 👋"), "~qhéllo 👋~q", "non-ASCII text survives unescaped")
End Function

Function TestNumbers()
	ConvexCheckEqualInt(ConvexIntegralValue(CountValue(7).Get("count"), "count"), 7, "an integer decodes")
	Local integral:TJSONObject = ConvexParseJsonObject("{~qcount~q:1.0}", "test value")
	ConvexCheckEqualInt(ConvexIntegralValue(integral.Get("count"), "count"), 1, "an integral real decodes")
	ConvexCheckRaises(ExpectFractionRejected, "not an integer", "a fractional number is refused")
	ConvexCheckRaises(ExpectStringCountRejected, "not a number", "a quoted number is refused")
End Function

Function TestTimestamps()
	ConvexCheckEqualInt(ConvexTimestampValue("AAAAAAAAAAA="), 0, "the zero timestamp decodes")
	' Little-endian 1.
	ConvexCheckEqualInt(ConvexTimestampValue("AQAAAAAAAAA="), 1, "a little-endian timestamp decodes")
	ConvexCheckRaises(ExpectNonCanonicalTimestampRejected, "canonical", "a non-canonical timestamp is refused")
	ConvexCheckRaises(ExpectShortTimestampRejected, "eight bytes", "a short timestamp is refused")
End Function

Function TestUtf8()
	Local valid:TConvexBuffer = TConvexBuffer.Create(64)
	valid.AppendString("Καλημέρα 🟨")
	ConvexCheck(ConvexIsValidUtf8(valid.data, valid.length), "well-formed UTF-8 is accepted")

	Local overlong:Byte[] = New Byte[2]
	overlong[0] = $C0
	overlong[1] = $AF
	ConvexCheck(Not ConvexIsValidUtf8(overlong, 2), "an overlong encoding is rejected")

	Local surrogate:Byte[] = New Byte[3]
	surrogate[0] = $ED
	surrogate[1] = $A0
	surrogate[2] = $80
	ConvexCheck(Not ConvexIsValidUtf8(surrogate, 3), "an encoded surrogate half is rejected")

	Local truncated:Byte[] = New Byte[2]
	truncated[0] = $E2
	truncated[1] = $82
	ConvexCheck(Not ConvexIsValidUtf8(truncated, 2), "a truncated sequence is rejected")
End Function

Rem
bbdoc: Proves ConvexEncodeLine never reproduces Print's platform CRLF.
about: BRL.Stream's WriteLine always appends the bytes 13 and 10, even on
Linux, which once corrupted the canonical example's byte-exact transcript.
This is the one place that regression can be caught in isolation, without
capturing a real file descriptor.
End Rem
Function TestLineEncodingIsLfOnly()
	Local encoded:TConvexBuffer = ConvexEncodeLine("sample")
	ConvexCheck(encoded.length > 0 And encoded.data[encoded.length - 1] = 10, ..
		"an encoded line ends with a bare LF")
	Local hasCr:Int = False
	For Local index:Int = 0 Until encoded.length
		If encoded.data[index] = 13 Then
			hasCr = True
		End If
	Next
	ConvexCheck(Not hasCr, "an encoded line never contains a CR byte")
End Function

Function TestHex()
	ConvexCheckEqualInt(ConvexParseHex("1f"), 31, "lowercase hex parses")
	ConvexCheckEqualInt(ConvexParseHex("1F"), 31, "uppercase hex parses")
	ConvexCheckEqualInt(ConvexParseHex(""), -1, "an empty chunk size is refused")
	ConvexCheckEqualInt(ConvexParseHex("1g"), -1, "a non-hex chunk size is refused")
End Function

Function TestWebSocketAccept()
	' The worked example from RFC 6455 section 1.3.
	ConvexCheckEqual(TConvexWebSocket.ExpectedAccept("dGhlIHNhbXBsZSBub25jZQ=="), ..
		"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "the Sec-WebSocket-Accept digest matches RFC 6455")
End Function

Function TestRelayBounds()
	Local observer:TRecordingObserver = New TRecordingObserver
	Local relay:TConvexSubscription = TConvexSubscription.Create(1, "demo:state", "{}", observer)
	For Local index:Int = 0 Until 64
		relay.Publish(CountValue(index), Null, 1024)
	Next
	ConvexCheck(relay.PendingCount() <= CONVEX_MAX_PENDING_UPDATES, "the relay never holds more than its event bound")
	ConvexCheck(relay.PendingBytes() <= CONVEX_MAX_PENDING_BYTES, "the relay never holds more than its byte bound")

	Local delivered:Int = 0
	While relay.Dispatch()
		delivered :+ 1
	Wend
	ConvexCheckEqualInt(delivered, CONVEX_MAX_PENDING_UPDATES, "the relay delivers exactly what it reserved")
	ConvexCheckEqualInt(relay.PendingBytes(), 0, "every reservation is released once delivery finishes")
	' Oldest-first eviction means the newest value survives.
	ConvexCheckEqualInt(observer.lastCount, 63, "the most recent value is the one that survives eviction")
End Function

Function TestRelayRejectsOversizedValue()
	Local observer:TRecordingObserver = New TRecordingObserver
	Local relay:TConvexSubscription = TConvexSubscription.Create(2, "demo:state", "{}", observer)
	relay.Publish(CountValue(1), Null, CONVEX_MAX_PENDING_BYTES + 1)
	relay.Dispatch()
	ConvexCheckEqualInt(observer.failures, 1, "a value beyond the whole byte budget is reported, not dropped silently")
	ConvexCheckEqual(observer.lastFailureName, "ProtocolError", "the refusal is a protocol error")
	ConvexCheckEqualInt(observer.values, 0, "the oversized value itself is never delivered")
End Function

Function TestInFlightIsCharged()
	Local observer:TRecordingObserver = New TRecordingObserver
	Local relay:TConvexSubscription = TConvexSubscription.Create(3, "demo:state", "{}", observer)
	relay.Publish(CountValue(1), Null, 4096)
	DeliveryProbeBytes = 0
	ConvexBeforeDeliveryHook = ProbeInFlightBytes
	relay.Dispatch()
	ConvexBeforeDeliveryHook = Null
	ConvexCheck(DeliveryProbeBytes >= 4096, "an update in a consumer's hands is still charged to the budget")
	ConvexCheckEqualInt(relay.PendingBytes(), 0, "the in-flight charge is released exactly once")
End Function

Function TestInvalidationIsABarrier()
	Local observer:TRecordingObserver = New TRecordingObserver
	Local relay:TConvexSubscription = TConvexSubscription.Create(4, "demo:state", "{}", observer)
	relay.Publish(CountValue(1), Null, 1024)
	relay.Publish(CountValue(2), Null, 1024)
	' Retire the relay after the first update has been dequeued but before it
	' reaches the observer: nothing may cross the acknowledgement.
	ConvexBeforeDeliveryHook = InvalidateDuringDelivery
	relay.Dispatch()
	ConvexBeforeDeliveryHook = Null
	ConvexCheckEqualInt(observer.values, 0, "a dequeued event cannot cross an invalidation")
	ConvexCheckEqualInt(relay.PendingBytes(), 0, "invalidation releases the queued and in-flight reservations")
	ConvexCheck(Not relay.Dispatch(), "a retired relay delivers nothing later either")
End Function

Function TestRehydrationSuppression()
	Local observer:TRecordingObserver = New TRecordingObserver
	Local relay:TConvexSubscription = TConvexSubscription.Create(5, "demo:state", "{}", observer)
	relay.Publish(CountValue(0), Null, 1024)
	relay.Dispatch()
	ConvexCheckEqualInt(observer.values, 1, "the initial value is delivered")

	relay.PrepareRehydration()
	relay.Publish(CountValue(0), Null, 1024)
	ConvexCheck(Not relay.Dispatch(), "an unchanged reconnect snapshot is suppressed once")

	relay.Publish(CountValue(0), Null, 1024)
	ConvexCheck(relay.Dispatch(), "a later identical server transition is still an observable event")
End Function

Function TestSignatureCannotCollide()
	Local observer:TRecordingObserver = New TRecordingObserver
	Local relay:TConvexSubscription = TConvexSubscription.Create(6, "demo:state", "{}", observer)
	Local left:TConvexFunctionError = TConvexFunctionError.Create("A", "B:C")
	Local right:TConvexFunctionError = TConvexFunctionError.Create("A:B", "C")
	ConvexCheck(relay.Signature(Null, left) <> relay.Signature(Null, right), ..
		"two different failures cannot share a delivery signature")
End Function

TestEndpoints()
TestJsonBounds()
TestQuoting()
TestNumbers()
TestTimestamps()
TestUtf8()
TestLineEncodingIsLfOnly()
TestHex()
TestWebSocketAccept()
TestRelayBounds()
TestRelayRejectsOversizedValue()
TestInFlightIsCharged()
TestInvalidationIsABarrier()
TestRehydrationSuppression()
TestSignatureCannotCollide()

ConvexTestExit(ConvexTestSummary("client_tests"))
