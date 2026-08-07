SuperStrict

Framework BRL.StandardIO

Import "../../client/transport.bmx"
Import "../../client/jsonvalue.bmx"
Import "../../client/convex.bmx"

Extern
	Function convex_example_exit(code:Int) = "exit"
End Extern

' The harness compares this example's stdout byte-for-byte against
' _shared/examples/basics.expected.txt, which is LF-only, so the transcript
' is written straight to the file descriptor with ConvexEncodeLine's bare LF
' terminator rather than through Print; see that function's comment in
' transport.bmx for why Print itself cannot be used here.
Function WriteStdoutLine(text:String)
	Local line:TConvexBuffer = ConvexEncodeLine(text)
	Local offset:Int = 0
	While offset < line.length
		Local written:Long = convex_write(1, Varptr line.data[offset], Size_T(line.length - offset))
		If written <= 0 Then
			Throw TConvexError.Transport("could not write the example transcript to stdout")
		End If
		offset :+ Int(written)
	Wend
End Function

' Convex's demo counter lives in a room. Every argument object the example
' sends is built here so the room name is quoted once, correctly, in one place.
Function RoomArguments:TJSONObject(room:String)
	Return ConvexParseJsonObject("{~qroom~q:" + ConvexQuote(room) + "}", "arguments")
End Function

' The mutation also carries a language label and an idempotency key. Convex
' uses that key to make a retried increment count once, so it is generated per
' attempt rather than derived from the room.
Function IncrementArguments:TJSONObject(room:String, idempotencyKey:String)
	Return ConvexParseJsonObject("{~qroom~q:" + ConvexQuote(room) + ",~qlanguage~q:~qBlitzMax~q,~qrunId~q:" + ..
		ConvexQuote(idempotencyKey) + "}", "arguments")
End Function

' Convex may encode an integral JSON number as either 1 or 1.0 depending on how
' it travelled. Accept both spellings of the same integer while refusing a
' fractional, quoted, or out-of-range count, so a wrong value fails loudly
' instead of being rounded into something plausible.
Function CountFrom:Long(value:TJSON, operation:String)
	Local state:TJSONObject = TJSONObject(value)
	If Not state Then
		Throw TConvexError.Protocol(operation + " did not return an object")
	End If
	Local count:Long = ConvexIntegralValue(state.Get("count"), operation + " count")
	If count < 0 Then
		Throw TConvexError.Protocol(operation + " returned a negative count")
	End If
	Return count
End Function

' Reads the mutation's envelope. Both fields are checked before either is used,
' because a mutation that reported success without applying anything would
' otherwise look identical to one that worked.
Function AppliedCountFrom:Long(value:TJSON)
	Local envelope:TJSONObject = TJSONObject(value)
	If Not envelope Then
		Throw TConvexError.Protocol("the mutation did not return an object")
	End If
	Local applied:TJSONBool = TJSONBool(envelope.Get("applied"))
	If Not applied Then
		Throw TConvexError.Protocol("the mutation did not report whether it applied")
	End If
	If Not applied.isTrue Then
		Throw TConvexError.Protocol("the mutation was not applied")
	End If
	Return CountFrom(envelope.Get("state"), "mutation")
End Function

' Live updates arrive here. The example is a small state machine: the first
' update is the initial value Convex already had, and the second is the one the
' mutation caused. Keeping the mutation inside this observer is what proves the
' subscription was established before the value changed.
Type TCounterObserver Extends TConvexObserver

	Field client:TConvexClient
	Field room:String
	Field startingCount:Long
	Field sawInitial:Int
	Field finished:Int
	Field failure:String

	Method OnUpdate(subscription:TConvexSubscription, value:TJSON, problem:TConvexFunctionError) Override
		If finished Or failure.length > 0 Then
			Return
		End If
		Try
			If problem Then
				Throw TConvexError.Protocol(problem.name + ": " + problem.message)
			End If
			If Not sawInitial Then
				OnInitialValue(value)
			Else
				OnUpdatedValue(value)
			End If
		Catch stopped:TConvexError
			failure = stopped.message
		End Try
	End Method

	' The first Live value must agree with what the HTTP query already reported.
	Method OnInitialValue(value:TJSON)
		Local observed:Long = CountFrom(value, "initial Live value")
		If observed <> startingCount Then
			Throw TConvexError.Protocol("the initial Live count disagreed with the HTTP query")
		End If
		WriteStdoutLine("live initial count: " + observed)
		sawInitial = True

		' Only now is it safe to change the room: the subscription is live, so
		' the resulting update cannot be missed.
		Local mutation:TConvexResult = client.Mutation("demo:increment", IncrementArguments(room, ConvexNewUuid()))
		Local applied:Long = AppliedCountFrom(mutation.value)
		If applied <> startingCount + 1 Then
			Throw TConvexError.Protocol("the mutation returned an unexpected count")
		End If
		WriteStdoutLine("mutation applied: true")
		WriteStdoutLine("mutation count: " + applied)
	End Method

	' The second Live value is the reactive proof: Convex pushed the new count
	' without the example asking for it again.
	Method OnUpdatedValue(value:TJSON)
		Local observed:Long = CountFrom(value, "updated Live value")
		If observed <> startingCount + 1 Then
			Throw TConvexError.Protocol("the updated Live count disagreed with the mutation")
		End If
		WriteStdoutLine("live updated count: " + observed)
		WriteStdoutLine("verified count: " + startingCount + " -> " + observed)
		finished = True
	End Method

End Type

Function Run:Int()
	Local url:String = ConvexEnv("CONVEX_URL")
	If url.length = 0 Then
		Throw TConvexError.Protocol("CONVEX_URL is required")
	End If
	' The verifier passes a unique room as the first argument; the environment
	' variable and the literal below only make the image pleasant to run by hand.
	Local room:String = ConvexEnv("EXAMPLE_ROOM")
	If AppArgs.length > 1 And AppArgs[1].length > 0 Then
		room = AppArgs[1]
	End If
	If room.length = 0 Then
		room = "blitzmax-example"
	End If

	' One client serves both transports for this deployment.
	Local client:TConvexClient = TConvexClient.Create(url)

	' Read the room over Convex's documented HTTP query endpoint.
	Local current:Long = CountFrom(client.Query("demo:state", RoomArguments(room)).value, "current query")
	WriteStdoutLine("current count: " + current)

	' Start Live before anything changes the room.
	Local observer:TCounterObserver = New TCounterObserver
	observer.client = client
	observer.room = room
	observer.startingCount = current
	Local subscription:TConvexSubscription = client.Subscribe("demo:state", RoomArguments(room), observer)

	' Drive the Live connection until the journey completes. The deadline exists
	' so a viewer sees a clear failure rather than an example that hangs.
	Local deadline:TConvexDeadline = TConvexDeadline.Create(20000)
	While Not observer.finished And observer.failure.length = 0
		If deadline.Expired() Then
			Throw TConvexError.Transport("the example timed out waiting for a Live update")
		End If
		client.Pump(50)
	Wend

	' Retire the Live query and its transport once the proof is complete.
	client.Unsubscribe(subscription)
	client.Close()
	If observer.failure.length > 0 Then
		Throw TConvexError.Protocol(observer.failure)
	End If
	Return 0
End Function

Local status:Int = 1
Try
	status = Run()
Catch problem:TConvexError
	ErrPrint("BlitzMax example failed: " + problem.message)
Catch other:Object
	ErrPrint("BlitzMax example failed: " + other.ToString())
End Try
convex_example_exit(status)
