SuperStrict

' A Convex sync peer for the language-local Live tests.
'
' It answers the upgrade, tracks the client's query set, and produces
' Transitions that a healthy client accepts. Each fault field turns one of
' those steps into the misbehaviour a real deployment must never be trusted not
' to produce, so the same peer serves both the happy-path and hostile cases.

Import BRL.LinkedList

Import "rawpeer.bmx"
Import "../transport.bmx"
Import "../jsonvalue.bmx"
Import "../websocket.bmx"
Import "../convex.bmx"

Rem
bbdoc: A Convex sync peer with a switchable set of misbehaviours.
End Rem
Type TSyncPeerScript Extends TConvexPeerScript

	Field upgraded:Int
	Field queryIds:TList
	Field modifySeen:Int
	Field removeSeen:Int
	Field connectSeen:Int
	Field transitionsSent:Int
	Field serverQuerySet:Int
	Field pendingQuerySet:Int
	Field lastTimestamp:Long
	Field nextTimestamp:Long
	Field counterValue:Int

	' Faults, each off unless a test turns it on.
	Field faultAccept:Int
	Field faultExtension:Int
	Field faultMasked:Int
	Field faultInvalidUtf8:Int
	Field faultOversized:Int
	Field faultBackwardsTimestamp:Int
	Field faultStartVersion:Int
	Field faultQueryFailed:Int
	Field fragmentWithPing:Int
	Field holdBackPayload:Int
	Field pendingTail:TConvexBuffer
	Field tailAt:Long

	Function Create:TSyncPeerScript()
		Local this:TSyncPeerScript = New TSyncPeerScript
		this.queryIds = New TList
		this.nextTimestamp = 16
		Return this
	End Function

	Method OnConnect(peer:TConvexPeer) Override
		' A reconnection starts a fresh handshake and a fresh query set. The
		' timestamp counter deliberately keeps climbing across connections,
		' because the client only rewinds the version it compares against.
		upgraded = False
		serverQuerySet = 0
		pendingQuerySet = 0
		lastTimestamp = 0
		queryIds.Clear()
		pendingTail = Null
	End Method

	Method Serve(peer:TConvexPeer) Override
		If Not upgraded Then
			If peer.HeaderEnd() < 0 Then
				Return
			End If
			If faultAccept Then
				peer.inbound.Reset()
				peer.Queue("HTTP/1.1 101 Switching Protocols~r~nUpgrade: websocket~r~nConnection: Upgrade~r~n")
				peer.Queue("Sec-WebSocket-Accept: not-the-right-digest~r~n~r~n")
			ElseIf faultExtension Then
				peer.AcceptUpgrade("Sec-WebSocket-Extensions: permessage-deflate~r~n")
			Else
				peer.AcceptUpgrade()
			End If
			upgraded = True
			Return
		End If
		If pendingTail And ConvexNowMs() >= tailAt Then
			' The rest of a frame that was deliberately delivered late.
			peer.QueueBytes(pendingTail.data, pendingTail.length)
			pendingTail = Null
		End If
		Local frames:String[] = peer.TakeClientText()
		For Local text:String = EachIn frames
			OnClientFrame(peer, text)
		Next
	End Method

	Method OnClientFrame(peer:TConvexPeer, text:String)
		If text.Find("~qConnect~q") >= 0 Then
			connectSeen :+ 1
			Return
		End If
		If text.Find("~qModifyQuerySet~q") < 0 Then
			Return
		End If
		modifySeen :+ 1
		Local frame:TJSONObject = ConvexParseJsonObject(text, "client frame")
		pendingQuerySet = Int(ConvexUInt32Member(frame, "newVersion"))
		Local modifications:TJSONArray = ConvexArrayMember(frame, "modifications")
		Local added:Int = False
		For Local index:Int = 0 Until modifications.Size()
			Local modification:TJSONObject = TJSONObject(modifications.Get(index))
			If ConvexStringMember(modification, "type") = "Add" Then
				queryIds.AddLast("" + ConvexUInt32Member(modification, "queryId"))
				added = True
			Else
				removeSeen :+ 1
			End If
		Next
		If added Then
			PushTransition(peer)
			If faultBackwardsTimestamp Then
				' A second, valid-looking Transition that claims a moment the
				' client has already passed.
				PushTransition(peer)
			End If
		End If
	End Method

	Rem
	bbdoc: Sends one Transition carrying the current value for every live query.
	End Rem
	Method PushTransition(peer:TConvexPeer)
		transitionsSent :+ 1
		Local modifications:String = ""
		For Local queryId:String = EachIn queryIds
			If modifications.length > 0 Then
				modifications :+ ","
			End If
			If faultQueryFailed Then
				modifications :+ "{~qtype~q:~qQueryFailed~q,~qqueryId~q:" + queryId + ..
					",~qerrorMessage~q:~qroom is empty~q,~qerrorData~q:{~qcode~q:~qROOM_EMPTY~q},~qlogLines~q:[]}"
			Else
				modifications :+ "{~qtype~q:~qQueryUpdated~q,~qqueryId~q:" + queryId + ..
					",~qvalue~q:{~qcount~q:" + counterValue + "}}"
			End If
		Next
		Local endValue:Long = nextTimestamp
		nextTimestamp :+ 1
		If faultBackwardsTimestamp And transitionsSent > 1 Then
			endValue = 1
		End If
		Local startQuerySet:Int = serverQuerySet
		If faultStartVersion Then
			startQuerySet = serverQuerySet + 7
		End If
		Local frame:String = "{~qtype~q:~qTransition~q,~qstartVersion~q:{~qquerySet~q:" + startQuerySet + ..
			",~qidentity~q:0,~qts~q:" + ConvexQuote(ConvexEncodeTimestamp(lastTimestamp)) + "}"
		frame :+ ",~qendVersion~q:{~qquerySet~q:" + pendingQuerySet + ",~qidentity~q:0,~qts~q:" + ..
			ConvexQuote(ConvexEncodeTimestamp(endValue)) + "}"
		frame :+ ",~qmodifications~q:[" + modifications + "]}"
		serverQuerySet = pendingQuerySet
		lastTimestamp = endValue
		Emit(peer, frame)
	End Method

	Rem
	bbdoc: Writes one server frame, applying whichever framing fault is armed.
	End Rem
	Method Emit(peer:TConvexPeer, frame:String)
		If faultOversized Then
			' A header that promises three MiB. The client must refuse on the
			' declared length rather than start buffering toward it.
			peer.outbound.AppendByte($80 | CONVEX_WS_TEXT)
			peer.outbound.AppendByte(127)
			Local declared:Long = 3 * 1024 * 1024
			For Local shift:Int = 56 To 0 Step -8
				peer.outbound.AppendByte(Int((declared Shr shift) & $FF))
			Next
			Return
		End If
		If faultInvalidUtf8 Then
			Local broken:Byte[] = New Byte[3]
			broken[0] = $ED
			broken[1] = $A0
			broken[2] = $80
			peer.QueueFrameBytes(CONVEX_WS_TEXT, broken, 3)
			Return
		End If
		If faultMasked Then
			peer.QueueFrame(CONVEX_WS_TEXT, frame, True, True)
			Return
		End If
		If holdBackPayload Then
			' A complete header and only the first half of the payload. What
			' follows must survive the client's next timeout rather than let it
			' resynchronise on a payload byte that looks like a header.
			Local body:TConvexBuffer = TConvexBuffer.Create(frame.length + 32)
			body.AppendString(frame)
			Local half:Int = body.length / 2
			peer.outbound.AppendByte($80 | CONVEX_WS_TEXT)
			If body.length < 126 Then
				peer.outbound.AppendByte(body.length)
			Else
				peer.outbound.AppendByte(126)
				peer.outbound.AppendByte(body.length Shr 8)
				peer.outbound.AppendByte(body.length)
			End If
			peer.outbound.AppendBytes(body.data, half)
			pendingTail = TConvexBuffer.Create(body.length - half + 32)
			pendingTail.AppendBytes(Varptr body.data[half], body.length - half)
			tailAt = ConvexNowMs() + 400
			holdBackPayload = False
			Return
		End If
		If fragmentWithPing Then
			Local half:Int = frame.length / 2
			peer.QueueFrame(CONVEX_WS_TEXT, frame[..half], False)
			peer.QueueFrame(CONVEX_WS_PING, "keepalive")
			peer.QueueFrame(CONVEX_WS_CONTINUATION, frame[half..], True)
			Return
		End If
		peer.QueueFrame(CONVEX_WS_TEXT, frame)
	End Method

End Type

