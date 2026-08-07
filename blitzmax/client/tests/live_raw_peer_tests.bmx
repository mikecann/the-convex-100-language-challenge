SuperStrict

' Live behaviour proved against a deliberately hostile WebSocket peer.
'
' The peer speaks the pinned Convex sync profile well enough to be believable
' and then misbehaves on demand: it masks a server frame, splits a message
' across fragments with a ping in the middle, promises payload it never sends,
' rewinds the sync timestamp, or simply stops reading. Because it is serviced
' from the client's own idle hook, every one of those sequences happens in the
' same order on every run.

Framework BRL.StandardIO

Import "testing.bmx"
Import "rawpeer.bmx"
Import "syncpeer.bmx"
Import "../transport.bmx"
Import "../jsonvalue.bmx"
Import "../websocket.bmx"
Import "../convex.bmx"

Rem
bbdoc: Records what one Live subscription actually observed.
End Rem
Type TLiveObserver Extends TConvexObserver

	Field updates:Int
	Field values:Int
	Field failures:Int
	Field lastCount:Long
	Field lastFailureName:String
	Field lastFailureMessage:String

	Method OnUpdate(subscription:TConvexSubscription, value:TJSON, failure:TConvexFunctionError) Override
		updates :+ 1
		If failure Then
			failures :+ 1
			lastFailureName = failure.name
			lastFailureMessage = failure.message
			Return
		End If
		values :+ 1
		Local asObject:TJSONObject = TJSONObject(value)
		If asObject Then
			lastCount = ConvexIntegralValue(asObject.Get("count"), "count")
		End If
	End Method

End Type

Rem
bbdoc: Pumps until @observer has seen @target updates, or the budget runs out.
End Rem
Function PumpUntil:Int(client:TConvexClient, observer:TLiveObserver, target:Int, budgetMs:Int = 4000)
	Local deadline:TConvexDeadline = TConvexDeadline.Create(budgetMs)
	While Not deadline.Expired()
		client.Pump(5)
		If observer.updates >= target Then
			Return True
		End If
	Wend
	Return False
End Function

Rem
bbdoc: Pumps until @observer has seen a failure, or the budget runs out.
End Rem
Function PumpUntilFailure:Int(client:TConvexClient, observer:TLiveObserver, budgetMs:Int = 4000)
	Local deadline:TConvexDeadline = TConvexDeadline.Create(budgetMs)
	While Not deadline.Expired()
		client.Pump(5)
		If observer.failures > 0 Then
			Return True
		End If
	Wend
	Return False
End Function

Function PumpFor(client:TConvexClient, budgetMs:Int)
	Local deadline:TConvexDeadline = TConvexDeadline.Create(budgetMs)
	While Not deadline.Expired()
		client.Pump(5)
	Wend
End Function

Function Arguments:TJSONObject()
	Return ConvexParseJsonObject("{~qroom~q:~qraw-peer~q}", "arguments")
End Function

Function TestInitialValueAndExternalUpdate()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:state", Arguments(), observer)
	ConvexCheck(PumpUntil(client, observer, 1), "an initial Live value arrives")
	ConvexCheckEqualInt(observer.lastCount, 0, "the initial Live value is the current count")
	ConvexCheckEqualInt(script.connectSeen, 1, "the client opens the session with one Connect")

	script.counterValue = 1
	script.PushTransition(peer)
	ConvexCheck(PumpUntil(client, observer, 2), "an external update arrives")
	ConvexCheckEqualInt(observer.lastCount, 1, "the external update carries the new count")
	client.Close()
	peer.Stop()
End Function

Function TestQueryFailedThenRecovery()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	script.faultQueryFailed = True
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:requiresNonzero", Arguments(), observer)
	ConvexCheck(PumpUntilFailure(client, observer), "a failing query reports its failure")
	ConvexCheckEqual(observer.lastFailureName, "FunctionError", "a failing query is a function error, not a transport one")
	ConvexCheckEqual(observer.lastFailureMessage, "room is empty", "the function's message survives")

	' The same subscription must still be able to deliver a later valid value.
	script.faultQueryFailed = False
	script.counterValue = 1
	script.PushTransition(peer)
	ConvexCheck(PumpUntil(client, observer, 2), "the same subscription recovers")
	ConvexCheckEqualInt(observer.values, 1, "recovery delivers a value rather than another failure")
	ConvexCheckEqualInt(observer.lastCount, 1, "the recovered value is correct")
	client.Close()
	peer.Stop()
End Function

Function TestFragmentedMessageWithInterleavedPing()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	script.fragmentWithPing = True
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:state", Arguments(), observer)
	ConvexCheck(PumpUntil(client, observer, 1), "a fragmented message with an interleaved ping is reassembled")
	ConvexCheckEqualInt(observer.failures, 0, "reassembly does not look like a protocol failure")
	ConvexCheckEqualInt(observer.lastCount, 0, "the reassembled value is correct")
	' The client owes the peer a pong for the control frame it interleaved.
	PumpFor(client, 200)
	Local sawPong:Int = False
	For Local answer:String = EachIn peer.pongs
		If answer = "keepalive" Then
			sawPong = True
		End If
	Next
	ConvexCheck(sawPong, "the client answers a ping with a pong carrying the same body")
	client.Close()
	peer.Stop()
End Function

Function TestPartialFrameSurvivesATimeout()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	script.holdBackPayload = True
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:state", Arguments(), observer)
	' Several timeouts pass while only half the frame is buffered.
	PumpFor(client, 200)
	ConvexCheckEqualInt(observer.updates, 0, "half a frame delivers nothing")
	ConvexCheck(PumpUntil(client, observer, 1), "the frame completes once its tail arrives")
	ConvexCheckEqualInt(observer.failures, 0, "a resumed frame is not mistaken for a protocol failure")
	ConvexCheckEqualInt(observer.lastCount, 0, "the resumed frame decodes to the right value")
	client.Close()
	peer.Stop()
End Function

Rem
bbdoc: Asserts one framing fault reports a protocol failure to the subscriber.
End Rem
Function CheckFramingFault(script:TSyncPeerScript, fragment:String, description:String)
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:state", Arguments(), observer)
	ConvexCheck(PumpUntilFailure(client, observer), description + " is reported rather than ignored")
	ConvexCheckEqual(observer.lastFailureName, "ProtocolError", description + " is a protocol failure")
	ConvexCheck(observer.lastFailureMessage.Find(fragment) >= 0, ..
		description + " explains itself (got " + observer.lastFailureMessage + ")")
	client.Close()
	peer.Stop()
End Function

Function TestFramingFaults()
	Local badAccept:TSyncPeerScript = TSyncPeerScript.Create()
	badAccept.faultAccept = True
	CheckFramingFault(badAccept, "Sec-WebSocket-Accept", "a forged upgrade digest")

	Local extension:TSyncPeerScript = TSyncPeerScript.Create()
	extension.faultExtension = True
	CheckFramingFault(extension, "extension", "an extension that was never offered")

	Local masked:TSyncPeerScript = TSyncPeerScript.Create()
	masked.faultMasked = True
	CheckFramingFault(masked, "masked", "a masked server frame")

	Local invalid:TSyncPeerScript = TSyncPeerScript.Create()
	invalid.faultInvalidUtf8 = True
	CheckFramingFault(invalid, "UTF-8", "a text frame that is not valid UTF-8")

	Local oversized:TSyncPeerScript = TSyncPeerScript.Create()
	oversized.faultOversized = True
	CheckFramingFault(oversized, "bounded", "a frame that declares more than the bound")

	Local rewound:TSyncPeerScript = TSyncPeerScript.Create()
	rewound.faultBackwardsTimestamp = True
	CheckFramingFault(rewound, "backwards", "a Transition that rewinds the sync timestamp")

	Local mismatched:TSyncPeerScript = TSyncPeerScript.Create()
	mismatched.faultStartVersion = True
	CheckFramingFault(mismatched, "start from the version", "a Transition that starts from the wrong version")
End Function

Rem
bbdoc: Proves five real reconnects, each replaying the active Add operations.
about: The sequence asserted per round is the one the shared harness relies on:
an initial value, a disconnect, an unchanged rehydration snapshot that must be
suppressed, an external change, and only then a second delivered value.
End Rem
Function TestFiveReconnects()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:state", Arguments(), observer)
	ConvexCheck(PumpUntil(client, observer, 1), "the first connection delivers an initial value")

	For Local round:Int = 1 To 5
		Local before:Int = observer.updates
		Local connectsBefore:Int = script.connectSeen
		ConvexCheck(client.DebugDisconnect(), "round " + round + " retires the live connection")
		Local deadline:TConvexDeadline = TConvexDeadline.Create(8000)
		While Not deadline.Expired() And script.connectSeen <= connectsBefore
			client.Pump(5)
		Wend
		ConvexCheckEqualInt(script.connectSeen, connectsBefore + 1, "round " + round + " opens exactly one new session")
		' Let the replayed Add and its unchanged snapshot arrive.
		PumpFor(client, 250)
		ConvexCheckEqualInt(observer.updates, before, "round " + round + " suppresses the unchanged rehydration snapshot")

		script.counterValue = round
		script.PushTransition(peer)
		ConvexCheck(PumpUntil(client, observer, before + 1), "round " + round + " delivers the change made after the disconnect")
		ConvexCheckEqualInt(observer.lastCount, round, "round " + round + " delivers the value produced after the disconnect")
	Next
	ConvexCheckEqualInt(script.connectSeen, 6, "six sessions were opened in total")
	ConvexCheck(script.modifySeen >= 6, "every connection replays the active Add operations")
	client.Close()
	peer.Stop()
End Function

Rem
bbdoc: Proves close is bounded even when the peer has stopped reading.
End Rem
Function TestBoundedClose()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	client.Subscribe("demo:state", Arguments(), observer)
	ConvexCheck(PumpUntil(client, observer, 1), "the connection is established before the peer stalls")
	' From here the peer neither reads nor writes. A close that waited for an
	' acknowledgement would never return.
	peer.stalled = True
	Local started:Long = ConvexNowMs()
	client.Close()
	Local elapsed:Long = ConvexNowMs() - started
	ConvexCheck(elapsed < 2000, "closing against a stalled peer is bounded (took " + elapsed + "ms)")
	peer.Stop()
End Function

Rem
bbdoc: Proves an unsubscribe retires the relay before anything else happens.
End Rem
Function TestUnsubscribeRetiresTheRelay()
	Local script:TSyncPeerScript = TSyncPeerScript.Create()
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local observer:TLiveObserver = New TLiveObserver
	Local subscription:TConvexSubscription = client.Subscribe("demo:state", Arguments(), observer)
	ConvexCheck(PumpUntil(client, observer, 1), "the subscription is live before it is retired")

	client.Unsubscribe(subscription)
	ConvexCheck(Not subscription.active, "the relay is retired as part of the unsubscribe, not after it")
	Local before:Int = observer.updates
	PumpFor(client, 200)
	ConvexCheck(script.removeSeen > 0, "the query is removed from the server's query set")

	' The peer keeps publishing for the retired query id anyway.
	script.counterValue = 5
	script.PushTransition(peer)
	PumpFor(client, 400)
	ConvexCheckEqualInt(observer.updates, before, "an update for a retired subscription is never delivered")
	client.Close()
	peer.Stop()
End Function

TestInitialValueAndExternalUpdate()
TestQueryFailedThenRecovery()
TestFragmentedMessageWithInterleavedPing()
TestPartialFrameSurvivesATimeout()
TestFramingFaults()
TestFiveReconnects()
TestBoundedClose()
TestUnsubscribeRetiresTheRelay()

ConvexTestExit(ConvexTestSummary("live_raw_peer_tests"))
