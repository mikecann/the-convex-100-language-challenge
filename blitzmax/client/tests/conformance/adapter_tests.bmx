SuperStrict

' Deterministic tests for the NDJSON adapter itself.
'
' The shared controller validates every emitted event against the adapter
' schema, so a shape mistake there shows up as a whole-language failure with
' little explanation. These tests assert the exact serialised events instead,
' driving the real adapter over an in-memory controller channel and a hostile
' peer standing in for the deployment.

Framework BRL.StandardIO

Import BRL.LinkedList

Import "../testing.bmx"
Import "../rawpeer.bmx"
Import "../httppeer.bmx"
Import "../syncpeer.bmx"
Import "../../transport.bmx"
Import "../../jsonvalue.bmx"
Import "adapter.bmx"

' setenv is already declared by <stdlib.h> against "const char *"; see
' convex_glue.c for why this binds to a shim rather than to "setenv" itself.
Extern
	Function convex_setenv:Int(name:Byte Ptr, value:Byte Ptr, overwrite:Int) = "convex_glue_setenv"
End Extern

Rem
bbdoc: Points the adapter's client at a test peer.
End Rem
Function SetDeploymentUrl(url:String)
	Local name:Byte Ptr = "CONVEX_URL".ToUTF8String()
	Local value:Byte Ptr = url.ToUTF8String()
	convex_setenv(name, value, 1)
	MemFree(value)
	MemFree(name)
End Function

Rem
bbdoc: An in-memory controller: scripted commands in, captured events out.
about: The adapter keeps running for a short settling period after the last
command so subscription events, which arrive on their own schedule, are part of
what the assertions can see.
End Rem
Type TMemoryChannel Extends TAdapterChannel

	Field pending:TConvexBuffer
	Field written:TConvexBuffer
	Field settleUntil:Long
	Field settleMs:Int

	Function Create:TMemoryChannel(settleMs:Int = 0)
		Local this:TMemoryChannel = New TMemoryChannel
		this.pending = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.written = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.settleMs = settleMs
		Return this
	End Function

	Method Send:TMemoryChannel(command:String)
		pending.AppendString(command)
		pending.AppendByte(10)
		Return Self
	End Method

	Method PollRead:Int(timeoutMs:Int) Override
		If pending.length > 0 Then
			Return 1
		End If
		If settleUntil = 0 Then
			settleUntil = ConvexNowMs() + settleMs
		End If
		If ConvexNowMs() >= settleUntil Then
			Return -1
		End If
		Return 0
	End Method

	Rem
	bbdoc: Delivers the scripted input in chunks, exactly as a pipe would.
	about: An oversized command has to arrive in pieces for the adapter's
	while-it-arrives byte bound to be the thing under test.
	End Rem
	Method ReadChunk:Int(destination:Byte[]) Override
		Local count:Int = pending.length
		If count > destination.length Then
			count = destination.length
		End If
		MemCopy(destination, pending.data, Size_T(count))
		pending.Consume(count)
		Return count
	End Method

	Method WriteAll(payload:Byte[], count:Int, deadline:TConvexDeadline) Override
		written.AppendBytes(payload, count)
	End Method

	Method Shutdown() Override
	End Method

	Rem
	bbdoc: Every complete NDJSON event the adapter wrote, in order.
	End Rem
	Method Events:String[]()
		Local text:String = written.ToText()
		If text.EndsWith("~n") Then
			text = text[..text.length - 1]
		End If
		If text.length = 0 Then
			Return New String[0]
		End If
		Return text.Split("~n")
	End Method

End Type

Rem
bbdoc: True when exactly one emitted event contains @fragment.
End Rem
Function CountEvents:Int(events:String[], fragment:String)
	Local matches:Int = 0
	For Local event:String = EachIn events
		If event.Find(fragment) >= 0 Then
			matches :+ 1
		End If
	Next
	Return matches
End Function

Function TestProtocolEnvelopes()
	Local channel:TMemoryChannel = TMemoryChannel.Create()
	channel.Send("{~qprotocolVersion~q:1,~qid~q:~qh1~q,~qop~q:~qhello~q}")
	channel.Send("{~qprotocolVersion~q:1,~qid~q:~qh2~q,~qop~q:~qhello~q,~qunexpected~q:true}")
	channel.Send("{~qprotocolVersion~q:2,~qid~q:~qh3~q,~qop~q:~qhello~q}")
	channel.Send("{~qid~q:~qu1~q,~qop~q:~qnonsense~q}")
	channel.Send("{~qid~q:~qm1~q,~qop~q:~qsetAuth~q}")
	channel.Send("not json at all")
	channel.Send("{~qid~q:~qc1~q,~qop~q:~qclose~q}")
	Local adapter:TConvexAdapter = TConvexAdapter.Create(channel)
	ConvexCheckEqualInt(adapter.Run(), 0, "a clean close exits successfully")

	Local events:String[] = channel.Events()
	ConvexCheckEqualInt(events.length, 7, "every command produces exactly one event")
	ConvexCheck(events[0].Find("~qtype~q:~qready~q") >= 0, "hello is answered with ready")
	ConvexCheck(events[0].Find("~qlanguage~q:~qblitzmax~q") >= 0, "ready names this language")
	ConvexCheck(events[0].Find("~qprotocolVersion~q:1") >= 0, "ready carries the protocol version")
	ConvexCheck(events[0].Find("~qimplementation~q") >= 0, "ready declares its provenance")
	ConvexCheck(events[0].Find("~qruntime~q") >= 0, "ready declares its runtime")
	ConvexCheck(events[1].Find("~qtype~q:~qerror~q") >= 0, "an unknown field is refused rather than ignored")
	ConvexCheck(events[2].Find("~qtype~q:~qerror~q") >= 0, "an unsupported protocol version is refused")
	ConvexCheck(events[3].Find("~qtype~q:~qerror~q") >= 0, "an unknown operation is refused")
	ConvexCheck(events[4].Find("~qtype~q:~qerror~q") >= 0, "setAuth without a token is refused")
	ConvexCheck(events[5].Find("~qtype~q:~qerror~q") >= 0, "a malformed command is refused")
	ConvexCheck(events[5].StartsWith("{~qtype~q:~qerror~q"), ..
		"an event with no known id omits the field rather than sending null")
	ConvexCheck(events[6].Find("~qid~q:~qc1~q,~qtype~q:~qclosed~q") >= 0, "close is acknowledged as closed")

	' The schema permits no nulls in these positions; emitting one would fail
	' the shared controller for every test at once.
	For Local event:String = EachIn events
		ConvexCheck(event.Find(":null") < 0, "no adapter event serialises an absent field as null")
	Next
End Function

Rem
bbdoc: Proves every raw byte the adapter writes is LF-terminated NDJSON.
about: Emit builds each event with ConvexEncodeLine, never Print or
WriteLine, because BRL.Stream's WriteLine always appends the platform CRLF
"~r~n" even on Linux. TMemoryChannel.Events() already strips the trailing
newline before assertions run elsewhere, so this checks the raw buffer
Emit actually handed to the channel, before any of that stripping.
End Rem
Function TestOutputIsLfOnly()
	Local channel:TMemoryChannel = TMemoryChannel.Create()
	channel.Send("{~qprotocolVersion~q:1,~qid~q:~qh1~q,~qop~q:~qhello~q}")
	channel.Send("{~qid~q:~qc1~q,~qop~q:~qclose~q}")
	Local adapter:TConvexAdapter = TConvexAdapter.Create(channel)
	adapter.Run()
	ConvexCheck(channel.written.length > 0 And channel.written.data[channel.written.length - 1] = 10, ..
		"the adapter's raw output ends with a bare LF")
	Local hasCr:Int = False
	For Local index:Int = 0 Until channel.written.length
		If channel.written.data[index] = 13 Then
			hasCr = True
		End If
	Next
	ConvexCheck(Not hasCr, "the adapter's raw output never contains a CR byte")
End Function

Function TestResultAndStructuredError()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", ..
		"{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:1},~qlogLines~q:[~q[LOG] demo:echo~q]}"))
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	SetDeploymentUrl(peer.Origin())

	Local channel:TMemoryChannel = TMemoryChannel.Create()
	channel.Send("{~qid~q:~qq1~q,~qop~q:~qquery~q,~qpath~q:~qdemo:state~q,~qargs~q:{}}")
	Local adapter:TConvexAdapter = TConvexAdapter.Create(channel)
	adapter.Run()
	Local events:String[] = channel.Events()
	ConvexCheckEqualInt(events.length, 1, "one call produces one event")
	ConvexCheckEqual(events[0], ..
		"{~qid~q:~qq1~q,~qtype~q:~qresult~q,~qvalue~q:{~qcount~q:1},~qlogs~q:[~q[LOG] demo:echo~q]}", ..
		"a successful call serialises value and logs exactly")
	peer.Stop()

	Local failing:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", ..
		"{~qstatus~q:~qerror~q,~qerrorMessage~q:~qnope~q,~qerrorData~q:{~qcode~q:~qBLITZMAX_EXPECTED~q},~qlogLines~q:[]}"))
	Local second:TConvexPeer = TConvexPeer.Start(failing)
	SetDeploymentUrl(second.Origin())
	Local errorChannel:TMemoryChannel = TMemoryChannel.Create()
	errorChannel.Send("{~qid~q:~qq2~q,~qop~q:~qquery~q,~qpath~q:~qdemo:fail~q,~qargs~q:{}}")
	TConvexAdapter.Create(errorChannel).Run()
	Local errorEvents:String[] = errorChannel.Events()
	ConvexCheckEqualInt(errorEvents.length, 1, "one failing call produces one event")
	ConvexCheckEqual(errorEvents[0], ..
		"{~qid~q:~qq2~q,~qtype~q:~qerror~q,~qerror~q:{~qname~q:~qFunctionError~q,~qmessage~q:~qnope~q," + ..
		"~qdata~q:{~qcode~q:~qBLITZMAX_EXPECTED~q}}}", ..
		"a function failure serialises its name, message, and application data")
	second.Stop()
End Function

Function TestSubscriptionEvents()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	SetDeploymentUrl(peer.Origin())
	Local channel:TMemoryChannel = TMemoryChannel.Create(1500)
	channel.Send("{~qid~q:~qs1~q,~qop~q:~qsubscribe~q,~qsubscriptionId~q:~qlive~q,~qpath~q:~qdemo:state~q,~qargs~q:{}}")
	TConvexAdapter.Create(channel).Run()
	Local events:String[] = channel.Events()
	ConvexCheck(events.length >= 2, "a subscription produces an acknowledgement and at least one event")
	ConvexCheckEqual(events[0], "{~qid~q:~qs1~q,~qtype~q:~qack~q}", "subscribe is acknowledged")
	ConvexCheckEqual(events[1], ..
		"{~qtype~q:~qsubscription~q,~qsubscriptionId~q:~qlive~q,~qvalue~q:{~qcount~q:0},~qlogs~q:[]}", ..
		"a Live value serialises against the subscription identifier, not a request id")
	peer.Stop()
End Function

Function TestSubscriptionFailureEvent()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	script.faultQueryFailed = True
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	SetDeploymentUrl(peer.Origin())
	Local channel:TMemoryChannel = TMemoryChannel.Create(1500)
	channel.Send("{~qid~q:~qs2~q,~qop~q:~qsubscribe~q,~qsubscriptionId~q:~qfailing~q,~qpath~q:~qdemo:requiresNonzero~q,~qargs~q:{}}")
	TConvexAdapter.Create(channel).Run()
	Local events:String[] = channel.Events()
	ConvexCheck(events.length >= 2, "a failing subscription still produces events")
	ConvexCheck(events[1].Find("~qsubscriptionId~q:~qfailing~q") >= 0, "the failure names its subscription")
	ConvexCheck(events[1].Find("~qerror~q:{~qname~q:~qFunctionError~q") >= 0, "the failure keeps its structured shape")
	ConvexCheck(events[1].Find("~qcode~q:~qROOM_EMPTY~q") >= 0, "the application error data survives into the event")
	ConvexCheck(events[1].Find("~qvalue~q") < 0, "a failure event never also carries a value")
	peer.Stop()
End Function

Rem
bbdoc: Proves a same-id replacement retires the previous relay first.
End Rem
Function TestSameIdReplacement()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	SetDeploymentUrl(peer.Origin())
	Local channel:TMemoryChannel = TMemoryChannel.Create(1500)
	channel.Send("{~qid~q:~qs3~q,~qop~q:~qsubscribe~q,~qsubscriptionId~q:~qsame~q,~qpath~q:~qdemo:state~q,~qargs~q:{}}")
	channel.Send("{~qid~q:~qs4~q,~qop~q:~qsubscribe~q,~qsubscriptionId~q:~qsame~q,~qpath~q:~qdemo:state~q,~qargs~q:{}}")
	Local adapter:TConvexAdapter = TConvexAdapter.Create(channel)
	adapter.Run()
	Local events:String[] = channel.Events()
	ConvexCheckEqualInt(CountEvents(events, "~qtype~q:~qack~q"), 2, "both subscribe commands are acknowledged")
	ConvexCheckEqualInt(adapter.observers.Count(), 1, "only one relay remains registered under the shared identifier")
	peer.Stop()
End Function

Rem
bbdoc: Proves an oversized command line is refused rather than buffered.
End Rem
Function TestOversizedCommandRefused()
	Local channel:TMemoryChannel = TMemoryChannel.Create()
	Local huge:String = "{~qid~q:~qbig~q,~qop~q:~qhello~q,~qpad~q:~q"
	' Doubling reaches past the two MiB command bound without paying quadratic
	' string concatenation to build it.
	Local padding:String = "0123456789ABCDEF"
	For Local doubling:Int = 0 Until 18
		padding = padding + padding
	Next
	channel.Send(huge + padding + "~q}")
	channel.Send("{~qid~q:~qc9~q,~qop~q:~qclose~q}")
	Local adapter:TConvexAdapter = TConvexAdapter.Create(channel)
	adapter.Run()
	Local events:String[] = channel.Events()
	ConvexCheck(events.length >= 1, "the oversized command is answered")
	ConvexCheck(events[0].Find("bounded size") >= 0, "the oversized command is refused for its size")
	ConvexCheck(events[events.length - 1].Find("~qtype~q:~qclosed~q") >= 0, ..
		"the adapter still serves the command that follows an oversized one")
End Function

TestProtocolEnvelopes()
TestOutputIsLfOnly()
TestResultAndStructuredError()
TestSubscriptionEvents()
TestSubscriptionFailureEvent()
TestSameIdReplacement()
TestOversizedCommandRefused()

ConvexTestExit(ConvexTestSummary("adapter_tests"))
