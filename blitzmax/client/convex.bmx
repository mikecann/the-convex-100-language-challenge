SuperStrict

' The educational BlitzMax Convex client.
'
' Two transports live here. Queries, mutations, and actions go over Convex's
' documented JSON HTTP endpoints. A Live query is kept current by one owner of
' a WebSocket carrying the pinned /api/sync query-set protocol: that owner is
' the only thing that opens, reads, writes, retires, and reconnects the socket,
' so a subscription never touches the wire itself.

Import BRL.LinkedList

Import "transport.bmx"
Import "jsonvalue.bmx"
Import "websocket.bmx"

Const CONVEX_CLIENT_VERSION:String = "blitzmax-0.1.0"
Const CONVEX_SYNC_PATH:String = "/api/sync"
Const CONVEX_ZERO_TIMESTAMP:String = "AAAAAAAAAAA="

' A Convex reply's headers are small; a peer that never finishes them must not
' be able to make the client buffer without limit.
Const CONVEX_MAX_HTTP_HEADER_BYTES:Int = 16 * 1024

' One HTTP call and one Live handshake each get a single absolute deadline.
Const CONVEX_HTTP_DEADLINE_MS:Int = 15000
Const CONVEX_CONNECT_DEADLINE_MS:Int = 15000
Const CONVEX_SEND_DEADLINE_MS:Int = 5000

' A relay holds at most this many events, and at most this many bytes of
' retained value, error, log, and runtime representation, counting whichever
' event is currently in a consumer's hands. The byte bound is the retained-JSON
' document bound plus a fixed allowance, so one value that was accepted at the
' maximum can always be held once, and never more than once.
Const CONVEX_MAX_PENDING_UPDATES:Int = 16
Const CONVEX_MAX_PENDING_BYTES:Int = CONVEX_MAX_RETAINED_JSON_BYTES + 64 * 1024
Const CONVEX_DELIVERY_OVERHEAD_BYTES:Int = 256

Const CONVEX_RECONNECT_MIN_MS:Int = 100
Const CONVEX_RECONNECT_MAX_MS:Int = 15000

Rem
bbdoc: A successful Convex function result.
End Rem
Type TConvexResult

	Field value:TJSON
	Field logs:String[]

	Function Create:TConvexResult(value:TJSON, logs:String[])
		Local this:TConvexResult = New TConvexResult
		this.value = value
		this.logs = logs
		Return this
	End Function

End Type

Rem
bbdoc: A structured failure that a subscriber or caller can inspect.
about: A Convex function that throws is reported with its message, its
application error data, and its log lines intact. Protocol and transport
failures reuse the same shape so a subscriber has one thing to handle.
End Rem
Type TConvexFunctionError

	Field name:String
	Field message:String
	Field data:TJSON
	Field logs:String[]
	Field charge:Int

	Function Create:TConvexFunctionError(name:String, message:String, data:TJSON = Null, logs:String[] = Null)
		Local this:TConvexFunctionError = New TConvexFunctionError
		this.name = name
		this.message = message
		this.data = data
		If logs Then
			this.logs = logs
		Else
			this.logs = New String[0]
		End If
		Return this
	End Function

End Type

Rem
bbdoc: Receives Live updates for one subscription.
about: BlitzMax has no signal mechanism, so a subscriber implements this and
hands it to Subscribe. The owner calls it from its own dispatch step, never
from inside frame parsing, so a slow subscriber cannot reorder protocol work.
End Rem
Type TConvexObserver Abstract

	Method OnUpdate(subscription:TConvexSubscription, value:TJSON, failure:TConvexFunctionError) Abstract

End Type

Rem
bbdoc: One queued Live delivery, tagged with the relay generation that made it.
End Rem
Type TConvexUpdate

	Field value:TJSON
	Field failure:TConvexFunctionError
	Field generation:Int
	Field charge:Int

End Type

Rem
bbdoc: Test-only hook that runs after an update is dequeued but before it is delivered.
about: This exists so a deterministic test can pause a relay in exactly the
window where a stale event could otherwise cross an unsubscribe or same-id
replacement acknowledgement. It is never set by the client or the example.
End Rem
Global ConvexBeforeDeliveryHook:Int(subscription:TConvexSubscription)

Rem
bbdoc: A Live query whose value the owner keeps current.
End Rem
Type TConvexSubscription

	Field queryId:Int
	Field path:String
	Field args:String
	Field observer:TConvexObserver
	Field active:Int

	Field queue:TList
	Field reserved:Int
	Field queuedBytes:Int
	Field generation:Int
	' The dequeued update stays charged while its consumer runs. Holding it
	' here rather than inferring the release makes the reservation released
	' exactly once on every path, including a callback that revokes the relay.
	Field inFlight:TConvexUpdate
	' A subscriber is allowed to call back into the client, which pumps the Live
	' owner again. Without this a relay could start delivering its next event
	' from inside the callback for the current one, and a subscriber written as
	' a state machine would see its steps out of order.
	Field delivering:Int
	Field lastSignature:String
	Field hasSignature:Int
	' A reconnect snapshot may repeat the last value once. Later same-value
	' server transitions are still observable events.
	Field suppressNextUnchanged:Int

	Function Create:TConvexSubscription(queryId:Int, path:String, args:String, observer:TConvexObserver)
		Local this:TConvexSubscription = New TConvexSubscription
		this.queryId = queryId
		this.path = path
		this.args = args
		this.observer = observer
		this.active = True
		this.generation = 1
		this.queue = New TList
		Return this
	End Function

	Method PendingCount:Int()
		Return reserved
	End Method

	Method PendingBytes:Int()
		Return queuedBytes
	End Method

	Rem
	bbdoc: Retires this relay so nothing queued or in flight can still be delivered.
	about: Called before an unsubscribe or same-id replacement is acknowledged,
	which is what makes the acknowledgement a barrier rather than a hope.
	End Rem
	Method Invalidate()
		If Not active Then
			Return
		End If
		active = False
		generation :+ 1
		ReleaseEverything()
	End Method

	Method ReleaseEverything()
		queue.Clear()
		inFlight = Null
		queuedBytes = 0
		reserved = 0
	End Method

	Method ReleaseReservation(update:TConvexUpdate)
		If queuedBytes >= update.charge Then
			queuedBytes :- update.charge
		Else
			queuedBytes = 0
		End If
		If reserved > 0 Then
			reserved :- 1
		End If
	End Method

	Method PrepareRehydration()
		suppressNextUnchanged = hasSignature
	End Method

	Rem
	bbdoc: A stable identity for a delivery, used to suppress a repeated snapshot.
	about: Every part is JSON-quoted before it is joined. Raw concatenation would
	let two genuinely different failures collide and silently swallow one.
	End Rem
	Method Signature:String(value:TJSON, failure:TConvexFunctionError)
		If Not failure Then
			Return "V:" + ConvexEncode(value)
		End If
		Local encodedLogs:String = ""
		For Local line:String = EachIn failure.logs
			encodedLogs :+ ":" + ConvexQuote(line)
		Next
		Local encodedData:String = ""
		If failure.data Then
			encodedData = ConvexQuote(ConvexEncode(failure.data))
		End If
		Return "E:" + ConvexQuote(failure.name) + ":" + ConvexQuote(failure.message) + ":" + encodedData + ":L" + encodedLogs
	End Method

	Rem
	bbdoc: Charges what a delivery costs while it is held.
	about: @retained is the bound the JSON scanner already computed for the
	document this value came out of, which is an upper bound on the value alone.
	End Rem
	Method DeliveryCharge:Int(value:TJSON, failure:TConvexFunctionError, retained:Int)
		Local charge:Int = CONVEX_DELIVERY_OVERHEAD_BYTES + retained
		If failure Then
			charge :+ failure.name.length + failure.message.length
			For Local line:String = EachIn failure.logs
				charge :+ CONVEX_JSON_UNIT_BYTES + line.length
			Next
		End If
		Return charge
	End Method

	Rem
	bbdoc: Offers one update to this relay, dropping oldest first when full.
	End Rem
	Method Publish(value:TJSON, failure:TConvexFunctionError, retained:Int)
		If Not active Then
			Return
		End If
		Local deliverySignature:String = Signature(value, failure)
		If hasSignature And deliverySignature = lastSignature And suppressNextUnchanged Then
			suppressNextUnchanged = False
			Return
		End If
		suppressNextUnchanged = False
		Local charge:Int = DeliveryCharge(value, failure, retained)
		' Make room by discarding the oldest queued events. An event already in
		' a consumer's hands is never evicted; its bytes stay charged.
		While (reserved >= CONVEX_MAX_PENDING_UPDATES Or charge > CONVEX_MAX_PENDING_BYTES - queuedBytes) And Not queue.IsEmpty()
			Local dropped:TConvexUpdate = TConvexUpdate(queue.RemoveFirst())
			If dropped Then
				ReleaseReservation(dropped)
			End If
		Wend
		If charge > CONVEX_MAX_PENDING_BYTES Then
			' A tree-shaped value can exceed the whole budget on its own, so
			' report the refusal rather than quietly delivering nothing.
			ReleaseQueued()
			failure = TConvexFunctionError.Create("ProtocolError", "a Live update exceeded the bounded delivery byte budget")
			value = Null
			charge = DeliveryCharge(Null, failure, 0)
			deliverySignature = Signature(value, failure)
		End If
		If reserved >= CONVEX_MAX_PENDING_UPDATES Or charge > CONVEX_MAX_PENDING_BYTES - queuedBytes Then
			Return
		End If
		lastSignature = deliverySignature
		hasSignature = True
		Local update:TConvexUpdate = New TConvexUpdate
		update.value = value
		update.failure = failure
		update.generation = generation
		update.charge = charge
		queue.AddLast(update)
		reserved :+ 1
		queuedBytes :+ charge
	End Method

	Method ReleaseQueued()
		While Not queue.IsEmpty()
			Local dropped:TConvexUpdate = TConvexUpdate(queue.RemoveFirst())
			If dropped Then
				ReleaseReservation(dropped)
			End If
		Wend
	End Method

	Rem
	bbdoc: Delivers at most one queued update to the observer.
	returns: True when an update was delivered.
	End Rem
	Method Dispatch:Int()
		If Not active Or delivering Or queue.IsEmpty() Then
			Return False
		End If
		inFlight = TConvexUpdate(queue.RemoveFirst())
		If Not inFlight Then
			Return False
		End If
		delivering = True
		Local delivered:Int = False
		' A subscriber that raises must not leave the relay charged or wedged,
		' and BlitzMax has no Finally, so both exits release explicitly.
		Try
			If ConvexBeforeDeliveryHook Then
				ConvexBeforeDeliveryHook(Self)
			End If
			' Re-read the reservation: the hook, or a nested callback, may
			' already have revoked this relay while the update was in flight.
			Local current:TConvexUpdate = inFlight
			If current And current.generation = generation And active And observer Then
				observer.OnUpdate(Self, current.value, current.failure)
				delivered = True
			End If
		Catch problem:Object
			ReleaseInFlight()
			delivering = False
			Throw problem
		End Try
		ReleaseInFlight()
		delivering = False
		Return delivered
	End Method

	Method ReleaseInFlight()
		If Not inFlight Then
			Return
		End If
		Local released:TConvexUpdate = inFlight
		inFlight = Null
		ReleaseReservation(released)
	End Method

End Type

Rem
bbdoc: The single owner of the Live WebSocket.
about: Subscribing, unsubscribing, reading frames, writing frames, retiring a
connection, and changing the query-set version all happen here, in one place,
driven from Pump. Nothing else in the client touches the socket.
End Rem
Type TConvexLive

	Field endpoint:TConvexEndpoint
	Field client:TConvexClient
	Field socket:TConvexWebSocket
	Field subscriptions:TList

	Field nextQueryId:Int
	Field querySetVersion:Int
	Field remoteQuerySet:Int
	Field remoteIdentity:Int
	Field remoteTimestamp:String

	Field connectionCount:Int
	Field lastCloseReason:String
	Field maxObservedTimestamp:String
	Field maxObservedValue:Long
	Field sawTimestamp:Int

	Field closing:Int
	Field pumping:Int
	Field backoffMs:Int
	Field reconnectAt:Long
	Field reconnectScheduled:Int

	Function Create:TConvexLive(client:TConvexClient, endpoint:TConvexEndpoint)
		Local this:TConvexLive = New TConvexLive
		this.client = client
		this.endpoint = endpoint
		this.subscriptions = New TList
		this.nextQueryId = 1
		this.remoteTimestamp = CONVEX_ZERO_TIMESTAMP
		this.maxObservedTimestamp = CONVEX_ZERO_TIMESTAMP
		this.lastCloseReason = "InitialConnect"
		this.backoffMs = CONVEX_RECONNECT_MIN_MS
		Return this
	End Function

	Method Add:TConvexSubscription(path:String, args:TJSON, observer:TConvexObserver)
		If nextQueryId = 2147483647 Then
			Throw TConvexError.Protocol("the Live query id space is exhausted")
		End If
		Local subscription:TConvexSubscription = TConvexSubscription.Create(nextQueryId, path, ConvexEncode(args), observer)
		nextQueryId :+ 1
		subscriptions.AddLast(subscription)
		If socket And socket.open Then
			' Already connected, so only the new query joins the query set.
			Local additions:TConvexSubscription[] = New TConvexSubscription[1]
			additions[0] = subscription
			SendAdds(additions, New Int[0])
		Else
			' Otherwise the connection is opened now and replays every active
			' Add, which is the same path a reconnect takes.
			EnsureConnected()
		End If
		Return subscription
	End Method

	Method Remove(subscription:TConvexSubscription)
		If Not subscription.active Then
			Return
		End If
		' Retire the relay first. Everything after this point is bookkeeping,
		' so the caller's acknowledgement can never be overtaken by a stale
		' event that was already queued for this subscription.
		subscription.Invalidate()
		subscriptions.Remove(subscription)
		If socket And socket.open Then
			Local removals:Int[] = New Int[1]
			removals[0] = subscription.queryId
			SendAdds(New TConvexSubscription[0], removals)
		End If
		If subscriptions.IsEmpty() Then
			reconnectScheduled = False
		End If
	End Method

	Rem
	bbdoc: Retires the current connection so the harness can prove a real reconnect.
	returns: False when there is nothing connected to disconnect.
	End Rem
	Method DebugDisconnect:Int()
		If Not socket Then
			Return False
		End If
		' Retiring schedules the replacement before this returns, so the caller
		' may acknowledge immediately and know the old connection is gone.
		RetireAndReconnect("debugDisconnect")
		Return True
	End Method

	Method Close()
		closing = True
		reconnectScheduled = False
		For Local subscription:TConvexSubscription = EachIn subscriptions
			subscription.Invalidate()
		Next
		subscriptions.Clear()
		If socket Then
			socket.Close()
			socket = Null
		End If
	End Method

	Method EnsureConnected()
		If closing Or socket Or subscriptions.IsEmpty() Then
			Return
		End If
		If reconnectScheduled And ConvexNowMs() < reconnectAt Then
			Return
		End If
		reconnectScheduled = False
		Local deadline:TConvexDeadline = TConvexDeadline.Create(CONVEX_CONNECT_DEADLINE_MS)
		Local opened:TConvexWebSocket
		Try
			opened = TConvexWebSocket.Connect(endpoint, CONVEX_SYNC_PATH, client.authToken, deadline)
		Catch problem:TConvexError
			' A failed attempt is still a connection attempt: report it to every
			' subscriber and back off before trying again.
			PublishFailureToAll(problem.Name(), problem.message)
			RetireAndReconnect(problem.message)
			Return
		End Try
		socket = opened
		querySetVersion = 0
		remoteQuerySet = 0
		remoteIdentity = 0
		remoteTimestamp = CONVEX_ZERO_TIMESTAMP
		' A completed handshake proves the path is healthy again, so a later
		' failure starts from the minimum delay instead of inheriting an old
		' maximum from an unrelated outage.
		backoffMs = CONVEX_RECONNECT_MIN_MS
		Try
			SendConnect()
			Local resend:TConvexSubscription[] = ActiveSubscriptions()
			For Local subscription:TConvexSubscription = EachIn resend
				If connectionCount > 0 Then
					subscription.PrepareRehydration()
				End If
			Next
			If resend.length > 0 Then
				SendAdds(resend, New Int[0])
			End If
		Catch problem:TConvexError
			PublishFailureToAll(problem.Name(), problem.message)
			RetireAndReconnect(problem.message)
		End Try
	End Method

	Method ActiveSubscriptions:TConvexSubscription[]()
		Local collected:TConvexSubscription[] = New TConvexSubscription[subscriptions.Count()]
		Local index:Int = 0
		For Local subscription:TConvexSubscription = EachIn subscriptions
			collected[index] = subscription
			index :+ 1
		Next
		Return collected
	End Method

	Method SendConnect()
		Local observed:String = ""
		If sawTimestamp Then
			observed = ",~qmaxObservedTimestamp~q:" + ConvexQuote(maxObservedTimestamp)
		End If
		Local frame:String = "{~qtype~q:~qConnect~q,~qsessionId~q:" + ConvexQuote(ConvexNewUuid())
		frame :+ ",~qconnectionCount~q:" + connectionCount
		frame :+ ",~qlastCloseReason~q:" + ConvexQuote(lastCloseReason)
		frame :+ observed + ",~qclientTs~q:0}"
		socket.SendText(frame, TConvexDeadline.Create(CONVEX_SEND_DEADLINE_MS))
	End Method

	Rem
	bbdoc: Sends one ModifyQuerySet covering the given additions and removals.
	End Rem
	Method SendAdds(additions:TConvexSubscription[], removals:Int[])
		If Not (socket And socket.open) Then
			Return
		End If
		If additions.length = 0 And removals.length = 0 Then
			Return
		End If
		Local parts:String = ""
		For Local subscription:TConvexSubscription = EachIn additions
			If parts.length > 0 Then
				parts :+ ","
			End If
			parts :+ "{~qtype~q:~qAdd~q,~qqueryId~q:" + subscription.queryId
			parts :+ ",~qudfPath~q:" + ConvexQuote(subscription.path)
			parts :+ ",~qargs~q:[" + subscription.args + "]}"
		Next
		For Local queryId:Int = EachIn removals
			If parts.length > 0 Then
				parts :+ ","
			End If
			parts :+ "{~qtype~q:~qRemove~q,~qqueryId~q:" + queryId + "}"
		Next
		Local nextVersion:Int = querySetVersion + 1
		Local frame:String = "{~qtype~q:~qModifyQuerySet~q,~qbaseVersion~q:" + querySetVersion
		frame :+ ",~qnewVersion~q:" + nextVersion + ",~qmodifications~q:[" + parts + "]}"
		socket.SendText(frame, TConvexDeadline.Create(CONVEX_SEND_DEADLINE_MS))
		querySetVersion = nextVersion
	End Method

	Rem
	bbdoc: Advances the owner: connects when needed, reads frames, then delivers.
	End Rem
	Method Pump(timeoutMs:Int)
		If pumping Then
			Return
		End If
		pumping = True
		' Runs even while a reconnect is pending, so cooperative test peers stay
		' serviced across the gap between two connections.
		ConvexIdle()
		Try
			EnsureConnected()
			If socket And socket.open Then
				Local message:String
				Local outcome:Int = socket.NextMessage(timeoutMs, message)
				While outcome = CONVEX_WS_MESSAGE
					HandleFrame(message)
					If Not (socket And socket.open) Then
						Exit
					End If
					outcome = socket.NextMessage(0, message)
				Wend
				If outcome = CONVEX_WS_CLOSED Then
					Local reason:String = "the Live connection closed"
					If socket And socket.closeReason.length > 0 Then
						reason = socket.closeReason
					End If
					PublishFailureToAll("TransportError", reason)
					RetireAndReconnect(reason)
				End If
			End If
		Catch problem:TConvexError
			PublishFailureToAll(problem.Name(), problem.message)
			RetireAndReconnect(problem.message)
		End Try
		pumping = False
		Dispatch()
	End Method

	Rem
	bbdoc: Delivers one queued update per subscription, repeating until quiet.
	End Rem
	Method Dispatch()
		Local delivered:Int = True
		' Each relay holds a bounded queue, so this terminates; the round bound
		' is a backstop against an observer that keeps republishing into itself.
		Local rounds:Int = 0
		While delivered And rounds < CONVEX_MAX_PENDING_UPDATES * 64
			rounds :+ 1
			delivered = False
			Local relays:TConvexSubscription[] = ActiveSubscriptions()
			For Local subscription:TConvexSubscription = EachIn relays
				If subscription.Dispatch() Then
					delivered = True
				End If
			Next
		Wend
	End Method

	Method HandleFrame(text:String)
		' Bound the tree before jansson allocates it, then reuse the same
		' measurement as the memory charge for anything queued out of it.
		Local retained:Int = ConvexScanJson(text, "Live frame")
		Local root:TJSONObject = ConvexParseJsonObject(text, "Live frame")
		Local kind:String = ConvexStringMember(root, "type")
		If kind = "Ping" Or kind = "MutationResponse" Or kind = "ActionResponse" Then
			Return
		End If
		If kind = "FatalError" Or kind = "AuthError" Then
			Local detail:TJSONString = TJSONString(root.Get("error"))
			Local message:String = "the deployment reported " + kind
			If detail Then
				message :+ ": " + detail.Value()
			End If
			Throw TConvexError.Protocol(message)
		End If
		If kind <> "Transition" Then
			Throw TConvexError.Protocol("the peer sent an unexpected Live message " + kind)
		End If
		Local startVersion:TJSONObject = ConvexObjectMember(root, "startVersion")
		If ConvexUInt32Member(startVersion, "querySet") <> remoteQuerySet Or ..
				ConvexUInt32Member(startVersion, "identity") <> remoteIdentity Or ..
				ConvexStringMember(startVersion, "ts") <> remoteTimestamp Then
			Throw TConvexError.Protocol("a Transition did not start from the version this client last acknowledged")
		End If

		' Validate and stage every modification before anything is committed, so
		' a malformed entry halfway through cannot leave half a Transition
		' applied and half rejected.
		Local staged:TList = New TList
		Local modifications:TJSONArray = ConvexArrayMember(root, "modifications")
		For Local index:Int = 0 Until modifications.Size()
			Local modification:TJSONObject = TJSONObject(modifications.Get(index))
			If Not modification Then
				Throw TConvexError.Protocol("a Transition modification is not an object")
			End If
			Local queryId:Long = ConvexUInt32Member(modification, "queryId")
			Local action:String = ConvexStringMember(modification, "type")
			If action <> "QueryUpdated" And action <> "QueryFailed" And action <> "QueryRemoved" Then
				Throw TConvexError.Protocol("a Transition carried an unknown modification " + action)
			End If
			Local target:TConvexSubscription = Lookup(Int(queryId))
			If action = "QueryUpdated" Then
				Local value:TJSON = modification.Get("value")
				If Not value Then
					Throw TConvexError.Protocol("a QueryUpdated modification omitted its value")
				End If
				If target Then
					staged.AddLast(TConvexPublication.Create(target, value, Null, retained))
				End If
			ElseIf action = "QueryFailed" Then
				Local message:String = ConvexStringMember(modification, "errorMessage")
				Local logs:String[] = ConvexLogLines(modification)
				If target Then
					Local failure:TConvexFunctionError = TConvexFunctionError.Create("FunctionError", message, modification.Get("errorData"), logs)
					staged.AddLast(TConvexPublication.Create(target, Null, failure, retained))
				End If
			End If
		Next

		Local endVersion:TJSONObject = ConvexObjectMember(root, "endVersion")
		Local endTimestamp:String = ConvexStringMember(endVersion, "ts")
		Local endValue:Long = ConvexTimestampValue(endTimestamp)
		If endValue < maxObservedValue Then
			Throw TConvexError.Protocol("a Transition moved the sync timestamp backwards")
		End If
		Local endQuerySet:Long = ConvexUInt32Member(endVersion, "querySet")
		If endQuerySet < remoteQuerySet Or endQuerySet > querySetVersion Then
			Throw TConvexError.Protocol("a Transition ended outside the query-set versions this client requested")
		End If
		maxObservedTimestamp = endTimestamp
		maxObservedValue = endValue
		sawTimestamp = True
		remoteTimestamp = endTimestamp
		remoteQuerySet = Int(endQuerySet)
		remoteIdentity = Int(ConvexUInt32Member(endVersion, "identity"))

		' Every piece of connection state is committed before a subscriber can
		' observe the transition that produced it.
		For Local publication:TConvexPublication = EachIn staged
			publication.subscription.Publish(publication.value, publication.failure, publication.retained)
		Next
	End Method

	Method Lookup:TConvexSubscription(queryId:Int)
		For Local subscription:TConvexSubscription = EachIn subscriptions
			If subscription.queryId = queryId Then
				Return subscription
			End If
		Next
		Return Null
	End Method

	Method PublishFailureToAll(name:String, message:String)
		Local relays:TConvexSubscription[] = ActiveSubscriptions()
		For Local subscription:TConvexSubscription = EachIn relays
			subscription.Publish(Null, TConvexFunctionError.Create(name, message), 0)
		Next
	End Method

	Rem
	bbdoc: Drops the current connection and schedules the replacement.
	about: The generation is bumped and the query-set version restarts so a late
	frame from the retired connection can never be mistaken for a valid
	continuation on its replacement.
	End Rem
	Method RetireAndReconnect(reason:String)
		Local retired:TConvexWebSocket = socket
		socket = Null
		querySetVersion = 0
		remoteQuerySet = 0
		remoteIdentity = 0
		remoteTimestamp = CONVEX_ZERO_TIMESTAMP
		connectionCount :+ 1
		lastCloseReason = reason
		If retired Then
			retired.Abort()
		End If
		If closing Or subscriptions.IsEmpty() Then
			reconnectScheduled = False
			Return
		End If
		reconnectAt = ConvexNowMs() + backoffMs
		reconnectScheduled = True
		backoffMs = backoffMs * 2
		If backoffMs > CONVEX_RECONNECT_MAX_MS Then
			backoffMs = CONVEX_RECONNECT_MAX_MS
		End If
	End Method

End Type

Rem
bbdoc: One staged Live delivery, held until its whole Transition validated.
End Rem
Type TConvexPublication

	Field subscription:TConvexSubscription
	Field value:TJSON
	Field failure:TConvexFunctionError
	Field retained:Int

	Function Create:TConvexPublication(subscription:TConvexSubscription, value:TJSON, failure:TConvexFunctionError, retained:Int)
		Local this:TConvexPublication = New TConvexPublication
		this.subscription = subscription
		this.value = value
		this.failure = failure
		this.retained = retained
		Return this
	End Function

End Type

Rem
bbdoc: The Convex client.
End Rem
Type TConvexClient

	Field endpoint:TConvexEndpoint
	Field authToken:String
	Field live:TConvexLive
	Field closed:Int
	Field lastFunctionError:TConvexFunctionError
	' Tests shorten this to prove the deadline rather than wait out a real one.
	Global httpDeadlineMs:Int = CONVEX_HTTP_DEADLINE_MS

	Rem
	bbdoc: Creates a client for one Convex deployment URL.
	End Rem
	Function Create:TConvexClient(url:String)
		Local this:TConvexClient = New TConvexClient
		this.endpoint = TConvexEndpoint.Parse(url)
		this.authToken = ""
		Return this
	End Function

	Rem
	bbdoc: Sets or clears the bearer token sent with later calls.
	End Rem
	Method SetAuth(token:String)
		If closed Then
			Throw TConvexError.Shut("the client is closed")
		End If
		authToken = token
	End Method

	Method Query:TConvexResult(path:String, args:TJSON)
		Return Invoke("query", path, args)
	End Method

	Method Mutation:TConvexResult(path:String, args:TJSON)
		Return Invoke("mutation", path, args)
	End Method

	Method Action:TConvexResult(path:String, args:TJSON)
		Return Invoke("action", path, args)
	End Method

	Rem
	bbdoc: Starts a Live query and returns its subscription.
	End Rem
	Method Subscribe:TConvexSubscription(path:String, args:TJSON, observer:TConvexObserver)
		If closed Then
			Throw TConvexError.Shut("the client is closed")
		End If
		If path.length = 0 Or Not TJSONObject(args) Then
			Throw TConvexError.Protocol("a Live query needs a path and JSON object arguments")
		End If
		If Not live Then
			live = TConvexLive.Create(Self, endpoint)
		End If
		Return live.Add(path, args, observer)
	End Method

	Method Unsubscribe(subscription:TConvexSubscription)
		If live Then
			live.Remove(subscription)
		End If
	End Method

	Rem
	bbdoc: Adapter-only hook that retires the Live connection.
	End Rem
	Method DebugDisconnect:Int()
		If Not live Then
			Return False
		End If
		Return live.DebugDisconnect()
	End Method

	Rem
	bbdoc: Gives the Live owner up to @timeoutMs to make progress.
	End Rem
	Method Pump(timeoutMs:Int)
		If live Then
			live.Pump(timeoutMs)
		End If
	End Method

	Method Close()
		If closed Then
			Return
		End If
		closed = True
		If live Then
			live.Close()
		End If
	End Method

	Rem
	bbdoc: Performs one HTTP call under a single absolute deadline.
	End Rem
	Method Invoke:TConvexResult(operation:String, path:String, args:TJSON)
		lastFunctionError = Null
		If closed Then
			Throw TConvexError.Shut("the client is closed")
		End If
		If path.length = 0 Or Not TJSONObject(args) Then
			Throw TConvexError.Protocol("Convex arguments must be a JSON object")
		End If
		Local body:String = "{~qpath~q:" + ConvexQuote(path) + ",~qargs~q:" + ConvexEncode(args) + ",~qformat~q:~qjson~q}"
		Local payload:TConvexBuffer = TConvexBuffer.Create(body.length + 32)
		payload.AppendString(body)

		Local request:String = "POST /api/" + operation + " HTTP/1.1~r~n"
		request :+ "Host: " + endpoint.Authority() + "~r~n"
		request :+ "User-Agent: " + CONVEX_CLIENT_VERSION + "~r~n"
		request :+ "Convex-Client: " + CONVEX_CLIENT_VERSION + "~r~n"
		request :+ "Accept: application/json~r~n"
		request :+ "Content-Type: application/json~r~n"
		request :+ "Content-Length: " + payload.length + "~r~n"
		' One connection per call keeps framing unambiguous: there is never a
		' second response waiting behind this one to be confused with it.
		request :+ "Connection: close~r~n"
		If authToken.length > 0 Then
			request :+ "Authorization: Bearer " + authToken + "~r~n"
		End If
		request :+ "~r~n"

		Local deadline:TConvexDeadline = TConvexDeadline.Create(httpDeadlineMs)
		Local socket:TConvexSocket = TConvexSocket.Connect(endpoint.host, endpoint.port, endpoint.useTls, deadline)
		Local status:Int
		Local responseBody:String
		' BlitzMax has no Finally, so the connection is retired on both paths
		' explicitly; leaking one per failed call would exhaust the container's
		' file-descriptor limit long before a test finished.
		Try
			socket.WriteText(request, deadline)
			socket.WriteAll(payload.data, payload.length, deadline)
			responseBody = ReadResponse(socket, deadline, status)
		Catch problem:Object
			socket.Close()
			Throw problem
		End Try
		socket.Close()
		Return Interpret(status, responseBody)
	End Method

	Rem
	bbdoc: Reads one HTTP response, enforcing framing and the byte cap.
	End Rem
	Method ReadResponse:String(socket:TConvexSocket, deadline:TConvexDeadline, status:Int Var)
		Local inbound:TConvexBuffer = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		Local headerEnd:Int = -1
		Local ended:Int = False
		Repeat
			headerEnd = FindHeaderEnd(inbound)
			If headerEnd >= 0 Then
				Exit
			End If
			If ended Then
				Throw TConvexError.Transport("the deployment closed before it finished its response headers")
			End If
			If deadline.Expired() Then
				Throw TConvexError.Transport("the HTTP request exceeded its absolute deadline")
			End If
			If inbound.length >= CONVEX_MAX_HTTP_HEADER_BYTES Then
				Throw TConvexError.Transport("the HTTP response headers exceeded their bounded size")
			End If
			If socket.Readable(25) Then
				If socket.ReadInto(inbound, CONVEX_MAX_HTTP_HEADER_BYTES) < 0 Then
					ended = True
				End If
			End If
			Pump(0)
			ConvexIdle()
		Forever

		Local head:String = inbound.TextPrefix(headerEnd)
		inbound.Consume(headerEnd + 4)
		Local lines:String[] = head.Split("~r~n")
		Local statusParts:String[] = lines[0].Split(" ")
		If statusParts.length < 2 Or Not statusParts[0].StartsWith("HTTP/1.") Then
			Throw TConvexError.Transport("the deployment did not return an HTTP response")
		End If
		status = statusParts[1].ToInt()
		If status < 100 Or status > 599 Then
			Throw TConvexError.Transport("the deployment returned an invalid HTTP status")
		End If
		Local headers:String[] = lines[1..]
		Local transferEncoding:String = ConvexHeaderValue(headers, "Transfer-Encoding").ToLower()
		Local contentLength:String = ConvexHeaderValue(headers, "Content-Length")
		If transferEncoding.length > 0 And transferEncoding <> "chunked" Then
			Throw TConvexError.Transport("the deployment used an unsupported transfer encoding")
		End If
		If transferEncoding = "chunked" Then
			Return ReadChunkedBody(socket, inbound, deadline, ended)
		End If
		contentLength = contentLength.Trim()
		If contentLength.length > 0 Then
			Local declared:Int = contentLength.ToInt()
			If declared < 0 Or ("" + declared) <> contentLength Then
				Throw TConvexError.Transport("the deployment declared an invalid Content-Length")
			End If
			If declared > CONVEX_MAX_HTTP_BODY_BYTES Then
				Throw TConvexError.Transport("the deployment declared more than the bounded two MiB response")
			End If
			Return ReadCountedBody(socket, inbound, deadline, declared, ended)
		End If
		' No framing headers at all: the body runs to a clean connection close.
		' This is only sound because a Convex reply is a complete JSON document,
		' so a truncated read fails to parse rather than reading as a value.
		Return ReadUntilClose(socket, inbound, deadline, ended)
	End Method

	Function FindHeaderEnd:Int(inbound:TConvexBuffer)
		For Local index:Int = 0 Until inbound.length - 3
			If inbound.data[index] = 13 And inbound.data[index + 1] = 10 And ..
					inbound.data[index + 2] = 13 And inbound.data[index + 3] = 10 Then
				Return index
			End If
		Next
		Return -1
	End Function

	Method Fill(socket:TConvexSocket, inbound:TConvexBuffer, deadline:TConvexDeadline, ended:Int Var)
		If ended Then
			Return
		End If
		If deadline.Expired() Then
			Throw TConvexError.Transport("the HTTP request exceeded its absolute deadline")
		End If
		If socket.Readable(25) Then
			If socket.ReadInto(inbound, CONVEX_MAX_HTTP_BODY_BYTES + CONVEX_IO_CHUNK_BYTES) < 0 Then
				ended = True
			End If
		End If
		' The Live owner keeps making progress while an HTTP call waits, so a
		' subscription is not starved by a slow query on the same client.
		Pump(0)
		ConvexIdle()
	End Method

	Method ReadCountedBody:String(socket:TConvexSocket, inbound:TConvexBuffer, deadline:TConvexDeadline, declared:Int, ended:Int Var)
		While inbound.length < declared
			If ended Then
				Throw TConvexError.Transport("the response body did not satisfy its declared Content-Length")
			End If
			Fill(socket, inbound, deadline, ended)
		Wend
		Return DecodeBody(inbound, declared)
	End Method

	Method ReadUntilClose:String(socket:TConvexSocket, inbound:TConvexBuffer, deadline:TConvexDeadline, ended:Int Var)
		While Not ended
			If inbound.length > CONVEX_MAX_HTTP_BODY_BYTES Then
				Throw TConvexError.Transport("the response body exceeded the bounded two MiB")
			End If
			Fill(socket, inbound, deadline, ended)
		Wend
		Return DecodeBody(inbound, inbound.length)
	End Method

	Rem
	bbdoc: Decodes a chunked body, insisting on its terminal zero-length chunk.
	about: A connection that drops mid-body is a transport failure, never the
	value that the bytes received so far happen to spell.
	End Rem
	Method ReadChunkedBody:String(socket:TConvexSocket, inbound:TConvexBuffer, deadline:TConvexDeadline, ended:Int Var)
		Local decoded:TConvexBuffer = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		Repeat
			Local lineEnd:Int = FindCrLf(inbound, 0)
			If lineEnd < 0 Then
				If ended Then
					Throw TConvexError.Transport("the chunked response ended without a complete chunk header")
				End If
				If inbound.length > CONVEX_MAX_HTTP_BODY_BYTES Then
					Throw TConvexError.Transport("a chunk header exceeded the bounded response size")
				End If
				Fill(socket, inbound, deadline, ended)
				Continue
			End If
			Local header:String = inbound.TextPrefix(lineEnd)
			Local semicolon:Int = header.Find(";")
			If semicolon >= 0 Then
				header = header[..semicolon]
			End If
			Local size:Int = ConvexParseHex(header.Trim())
			If size < 0 Or size > CONVEX_MAX_HTTP_BODY_BYTES Then
				Throw TConvexError.Transport("the deployment declared an invalid chunk size")
			End If
			If decoded.length + size > CONVEX_MAX_HTTP_BODY_BYTES Then
				Throw TConvexError.Transport("the chunked response exceeded the bounded two MiB")
			End If
			' The chunk line, the chunk body, and its trailing CRLF must all be
			' present before any of it is consumed.
			While inbound.length < lineEnd + 2 + size + 2
				If ended Then
					Throw TConvexError.Transport("the chunked response was truncated inside a chunk")
				End If
				Fill(socket, inbound, deadline, ended)
			Wend
			If size = 0 Then
				Return DecodeBody(decoded, decoded.length)
			End If
			decoded.AppendBytes(Varptr inbound.data[lineEnd + 2], size)
			If inbound.data[lineEnd + 2 + size] <> 13 Or inbound.data[lineEnd + 3 + size] <> 10 Then
				Throw TConvexError.Transport("a chunk was not terminated correctly")
			End If
			inbound.Consume(lineEnd + 2 + size + 2)
		Forever
	End Method

	Function FindCrLf:Int(inbound:TConvexBuffer, from:Int)
		For Local index:Int = from Until inbound.length - 1
			If inbound.data[index] = 13 And inbound.data[index + 1] = 10 Then
				Return index
			End If
		Next
		Return -1
	End Function

	Function DecodeBody:String(inbound:TConvexBuffer, count:Int)
		If inbound.HasInteriorNul(count) Then
			Throw TConvexError.Protocol("the response body contained a NUL byte")
		End If
		If Not ConvexIsValidUtf8(inbound.data, count) Then
			Throw TConvexError.Protocol("the response body was not valid UTF-8")
		End If
		Return inbound.TextPrefix(count)
	End Function

	Rem
	bbdoc: Turns one HTTP status and body into a result or a structured failure.
	about: The body is parsed before it is classified, so a Convex function
	error keeps its message, data, and logs on any status, while a non-2xx reply
	that is not a Convex envelope stays a transport failure.
	End Rem
	Method Interpret:TConvexResult(status:Int, body:String)
		Local decoded:TJSONObject
		Local decodeFailure:String = ""
		Try
			decoded = ConvexParseJsonObject(body, "Convex HTTP response")
		Catch problem:TConvexError
			decodeFailure = problem.message
		End Try
		Local envelope:TConvexFunctionError = FunctionErrorEnvelope(decoded)
		If envelope Then
			lastFunctionError = envelope
			Throw TConvexError.Create(TConvexError.KIND_FUNCTION, envelope.message)
		End If
		If status < 200 Or status >= 300 Then
			Throw TConvexError.Transport("the deployment returned HTTP status " + status)
		End If
		If Not decoded Then
			Throw TConvexError.Protocol(decodeFailure)
		End If
		Local outcome:String = ConvexStringMember(decoded, "status")
		Local logs:String[] = ConvexLogLines(decoded)
		If outcome = "success" Then
			Local value:TJSON = decoded.Get("value")
			If Not value Then
				Throw TConvexError.Protocol("a successful Convex response omitted its value")
			End If
			Return TConvexResult.Create(value, logs)
		End If
		If outcome = "error" Then
			' The envelope check above already rejected this body, so the status
			' says error while some required part of the envelope is missing.
			Throw TConvexError.Protocol("a Convex error response was malformed")
		End If
		Throw TConvexError.Protocol("a Convex response carried an unknown status")
	End Method

	Rem
	bbdoc: Recognises a complete Convex function-error envelope, or nothing.
	about: A body that merely resembles one falls back to the caller's status
	handling, so malformed input can never be promoted into a FunctionError.
	End Rem
	Function FunctionErrorEnvelope:TConvexFunctionError(decoded:TJSONObject)
		If Not decoded Then
			Return Null
		End If
		Try
			If ConvexStringMember(decoded, "status") <> "error" Then
				Return Null
			End If
			Local logs:String[] = ConvexLogLines(decoded)
			Local message:String = ConvexStringMember(decoded, "errorMessage")
			Return TConvexFunctionError.Create("FunctionError", message, decoded.Get("errorData"), logs)
		Catch problem:TConvexError
			Return Null
		End Try
	End Function

End Type

Rem
bbdoc: A random version 4 UUID.
about: Convex uses one to identify a sync session, and a caller needs one for a
mutation's idempotency key so a retry cannot count twice. Both come from the
same seeded generator the TLS stack uses, rather than a second weaker source.
End Rem
Function ConvexNewUuid:String()
	Local bytes:Byte[] = New Byte[16]
	TConvexCrypto.Shared().Fill(bytes, 16)
	bytes[6] = Byte((bytes[6] & $0F) | $40)
	bytes[8] = Byte((bytes[8] & $3F) | $80)
	Local text:String = ""
	For Local index:Int = 0 Until 16
		If index = 4 Or index = 6 Or index = 8 Or index = 10 Then
			text :+ "-"
		End If
		text :+ ConvexHexDigit(bytes[index] Shr 4) + ConvexHexDigit(bytes[index])
	Next
	Return text
End Function

Rem
bbdoc: Parses an unsigned hexadecimal number, returning -1 when it is not one.
End Rem
Function ConvexParseHex:Int(text:String)
	If text.length = 0 Or text.length > 8 Then
		Return -1
	End If
	Local value:Int = 0
	For Local index:Int = 0 Until text.length
		Local code:Int = text[index]
		Local digit:Int = -1
		If code >= 48 And code <= 57 Then
			digit = code - 48
		ElseIf code >= 97 And code <= 102 Then
			digit = code - 87
		ElseIf code >= 65 And code <= 70 Then
			digit = code - 55
		Else
			Return -1
		End If
		value = (value Shl 4) | digit
	Next
	Return value
End Function
