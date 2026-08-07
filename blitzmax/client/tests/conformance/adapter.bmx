SuperStrict

' Test-only conformance adapter for the shared black-box harness.
'
' This is not part of the educational client API. It speaks NDJSON adapter
' protocol v1 on stdin/stdout, or over one TCP controller connection when
' ADAPTER_LISTEN is set, and it calls the real client for every operation.
' stdout carries protocol events only; diagnostics go to stderr.

Import BRL.LinkedList
Import BRL.StandardIO

Import "../../transport.bmx"
Import "../../jsonvalue.bmx"
Import "../../convex.bmx"

Extern
	Function convex_adapter_exit(code:Int) = "exit"
End Extern

Const ADAPTER_LANGUAGE:String = "blitzmax"
Const ADAPTER_IMPLEMENTATION:String = "native-blitzmax-ng-mbedtls-jansson"

' One command line and one emitted event are both bounded. The controller never
' sends anything close to this; a hostile one must not be able to make the
' adapter allocate without limit.
Const ADAPTER_MAX_COMMAND_BYTES:Int = 2 * 1024 * 1024
Const ADAPTER_MAX_EVENT_BYTES:Int = 2 * 1024 * 1024
Const ADAPTER_MAX_OUTPUT_BYTES:Int = 8 * 1024 * 1024
Const ADAPTER_MAX_OUTPUT_EVENTS:Int = 64
Const ADAPTER_OUTPUT_OVERHEAD_BYTES:Int = 256

Rem
bbdoc: The controller transport, which is either stdio or one TCP connection.
End Rem
Type TAdapterChannel Abstract

	Method PollRead:Int(timeoutMs:Int) Abstract
	Method ReadChunk:Int(destination:Byte[]) Abstract
	Method WriteAll(payload:Byte[], count:Int, deadline:TConvexDeadline) Abstract
	Method Shutdown() Abstract

End Type

Rem
bbdoc: The default controller transport: NDJSON on stdin and stdout.
End Rem
Type TAdapterStdio Extends TAdapterChannel

	Method PollRead:Int(timeoutMs:Int) Override
		Return ConvexPollFd(0, CONVEX_POLLIN, timeoutMs)
	End Method

	Method ReadChunk:Int(destination:Byte[]) Override
		Local received:Long = convex_read(0, destination, Size_T(destination.length))
		If received > 0 Then
			Return Int(received)
		End If
		If received = 0 Then
			Return -1
		End If
		Return 0
	End Method

	Method WriteAll(payload:Byte[], count:Int, deadline:TConvexDeadline) Override
		Local offset:Int = 0
		While offset < count
			If deadline.Expired() Then
				Throw TConvexError.Transport("adapter output exceeded its absolute deadline")
			End If
			Local written:Long = convex_write(1, Varptr payload[offset], Size_T(count - offset))
			If written > 0 Then
				offset :+ Int(written)
				Continue
			End If
			' A stopped reader leaves the pipe full. Wait for writability inside
			' the same absolute deadline rather than blocking indefinitely.
			Local slice:Int = deadline.RemainingMs()
			If slice > 25 Then
				slice = 25
			End If
			If ConvexPollFd(1, CONVEX_POLLOUT, slice) < 0 Then
				Throw TConvexError.Transport("adapter output failed")
			End If
		Wend
	End Method

	Method Shutdown() Override
	End Method

End Type

Rem
bbdoc: The controller transport used when ADAPTER_LISTEN names an address.
End Rem
Type TAdapterSocket Extends TAdapterChannel

	Field listener:TNetContext
	Field connection:TNetContext

	Rem
	bbdoc: Binds @address, accepts exactly one controller, and serves it.
	End Rem
	Function Listen:TAdapterSocket(address:String)
		Local separator:Int = address.FindLast(":")
		If separator < 1 Then
			Throw TConvexError.Protocol("ADAPTER_LISTEN must be host:port")
		End If
		Local this:TAdapterSocket = New TAdapterSocket
		this.listener = New TNetContext.Create()
		Local bound:Int = this.listener.Bind(address[..separator], address[separator + 1..], MBEDTLS_NET_PROTO_TCP)
		If bound <> 0 Then
			Throw TConvexError.Transport("could not listen on " + address + ": " + MBEDTLSError(bound))
		End If
		this.connection = New TNetContext.Create()
		Local peer:String
		Local accepted:Int = this.listener.Accept(this.connection, peer)
		If accepted <> 0 Then
			Throw TConvexError.Transport("could not accept a controller: " + MBEDTLSError(accepted))
		End If
		this.connection.SetNonBlock()
		Return this
	End Function

	Method PollRead:Int(timeoutMs:Int) Override
		Local ready:Int = connection.Poll(MBEDTLS_NET_POLL_READ, timeoutMs)
		If ready < 0 Then
			Return -1
		End If
		If ready = 0 Then
			Return 0
		End If
		Return 1
	End Method

	Method ReadChunk:Int(destination:Byte[]) Override
		Local received:Int = connection.Recv(destination, Size_T(destination.length))
		If received > 0 Then
			Return received
		End If
		If received = 0 Then
			Return -1
		End If
		If received = MBEDTLS_ERR_SSL_WANT_READ Or received = MBEDTLS_ERR_SSL_WANT_WRITE Then
			Return 0
		End If
		Return -1
	End Method

	Method WriteAll(payload:Byte[], count:Int, deadline:TConvexDeadline) Override
		Local offset:Int = 0
		While offset < count
			If deadline.Expired() Then
				Throw TConvexError.Transport("adapter output exceeded its absolute deadline")
			End If
			Local sent:Int = connection.Send(Varptr payload[offset], Size_T(count - offset))
			If sent > 0 Then
				offset :+ sent
				Continue
			End If
			If sent <> MBEDTLS_ERR_SSL_WANT_WRITE And sent <> MBEDTLS_ERR_SSL_WANT_READ And sent <> 0 Then
				Throw TConvexError.Transport("adapter output failed: " + MBEDTLSError(sent))
			End If
			Local slice:Int = deadline.RemainingMs()
			If slice > 25 Then
				slice = 25
			End If
			connection.Poll(MBEDTLS_NET_POLL_WRITE, slice)
		Wend
	End Method

	Method Shutdown() Override
		If connection Then
			connection.Free()
		End If
		If listener Then
			listener.Free()
		End If
	End Method

End Type

Rem
bbdoc: One registered subscription, and the relay that feeds it.
End Rem
Type TAdapterObserver Extends TConvexObserver

	Field adapter:TConvexAdapter
	Field subscriptionId:String
	Field subscription:TConvexSubscription

	Method OnUpdate(subscription:TConvexSubscription, value:TJSON, failure:TConvexFunctionError) Override
		' A same-id replacement retires the old relay before its acknowledgement
		' is written, and this second check makes the barrier explicit: a
		' retired observer can never publish under the live identifier.
		If adapter.Registered(subscriptionId) <> Self Then
			Return
		End If
		adapter.EmitSubscription(subscriptionId, value, failure)
	End Method

End Type

Rem
bbdoc: The NDJSON adapter.
End Rem
Type TConvexAdapter

	Field channel:TAdapterChannel
	Field client:TConvexClient
	Field observers:TList
	Field command:TConvexBuffer
	Field discarding:Int
	Field closed:Int
	Field failed:Int
	Field outFlightEvents:Int
	Field outFlightBytes:Int
	' Language-local tests set this to capture the exact NDJSON that is written,
	' without redirecting or reading back the real output stream. It stays off
	' in the shipped adapter so a long conformance run retains nothing.
	Field recording:Int
	Field recorded:TList

	Function Create:TConvexAdapter(channel:TAdapterChannel)
		Local this:TConvexAdapter = New TConvexAdapter
		this.channel = channel
		this.observers = New TList
		this.command = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.recorded = New TList
		Return this
	End Function

	Method OutputDeadlineMs:Int()
		Local configured:String = ConvexEnv("ADAPTER_OUTPUT_DEADLINE_MS")
		If configured.length = 0 Then
			Return 1000
		End If
		Local parsed:Int = configured.ToInt()
		If parsed <= 0 Or parsed > 60000 Then
			Return 1000
		End If
		Return parsed
	End Method

	Rem
	bbdoc: Writes one protocol event, charging it against the output budget.
	End Rem
	Method Emit(event:String)
		Local payload:TConvexBuffer = TConvexBuffer.Create(event.length + 32)
		payload.AppendString(event)
		payload.AppendByte(10)
		If payload.length > ADAPTER_MAX_EVENT_BYTES Then
			StopWithFailure("an adapter event exceeded its bounded size")
			Return
		End If
		Local charge:Int = payload.length + ADAPTER_OUTPUT_OVERHEAD_BYTES
		If outFlightEvents >= ADAPTER_MAX_OUTPUT_EVENTS Or charge > ADAPTER_MAX_OUTPUT_BYTES - outFlightBytes Then
			StopWithFailure("the adapter output budget was exhausted")
			Return
		End If
		outFlightEvents :+ 1
		outFlightBytes :+ charge
		If recording Then
			recorded.AddLast(event)
		End If
		Try
			channel.WriteAll(payload.data, payload.length, TConvexDeadline.Create(OutputDeadlineMs()))
		Catch problem:TConvexError
			outFlightEvents :- 1
			outFlightBytes :- charge
			StopWithFailure(problem.message)
			Return
		End Try
		outFlightEvents :- 1
		outFlightBytes :- charge
	End Method

	Method StopWithFailure(message:String)
		failed = True
		closed = True
		ErrPrint("adapter failed: " + message)
		If client Then
			client.Close()
		End If
	End Method

	Method EmitError(id:String, name:String, message:String, data:TJSON = Null, logs:String[] = Null)
		Local body:String = "{~qname~q:" + ConvexQuote(name) + ",~qmessage~q:" + ConvexQuote(message)
		If data Then
			body :+ ",~qdata~q:" + ConvexEncode(data)
		End If
		body :+ "}"
		Local event:String = "{"
		If id.length > 0 Then
			event :+ "~qid~q:" + ConvexQuote(id) + ","
		End If
		event :+ "~qtype~q:~qerror~q,~qerror~q:" + body
		If logs And logs.length > 0 Then
			event :+ ",~qlogs~q:" + EncodeLogs(logs)
		End If
		Emit(event + "}")
	End Method

	Method EmitSubscription(subscriptionId:String, value:TJSON, failure:TConvexFunctionError)
		Local event:String = "{~qtype~q:~qsubscription~q,~qsubscriptionId~q:" + ConvexQuote(subscriptionId)
		If failure Then
			event :+ ",~qerror~q:{~qname~q:" + ConvexQuote(failure.name) + ",~qmessage~q:" + ConvexQuote(failure.message)
			If failure.data Then
				event :+ ",~qdata~q:" + ConvexEncode(failure.data)
			End If
			event :+ "}"
			If failure.logs.length > 0 Then
				event :+ ",~qlogs~q:" + EncodeLogs(failure.logs)
			End If
		Else
			event :+ ",~qvalue~q:" + ConvexEncode(value) + ",~qlogs~q:[]"
		End If
		Emit(event + "}")
	End Method

	Function EncodeLogs:String(logs:String[])
		Local encoded:String = "["
		For Local index:Int = 0 Until logs.length
			If index > 0 Then
				encoded :+ ","
			End If
			encoded :+ ConvexQuote(logs[index])
		Next
		Return encoded + "]"
	End Function

	Rem
	bbdoc: The observer currently registered under @subscriptionId, if any.
	End Rem
	Method Registered:TAdapterObserver(subscriptionId:String)
		For Local observer:TAdapterObserver = EachIn observers
			If observer.subscriptionId = subscriptionId Then
				Return observer
			End If
		Next
		Return Null
	End Method

	Method Service:TConvexClient()
		If client Then
			Return client
		End If
		Local url:String = ConvexEnv("CONVEX_URL")
		If url.length = 0 Then
			Throw TConvexError.Protocol("CONVEX_URL is required")
		End If
		client = TConvexClient.Create(url)
		Local token:String = ConvexEnv("CONVEX_AUTH_TOKEN")
		If token.length > 0 Then
			client.SetAuth(token)
		End If
		Return client
	End Method

	Rem
	bbdoc: Handles one complete NDJSON command line.
	End Rem
	Method Handle(line:String)
		Local root:TJSONObject
		Try
			root = ConvexParseJsonObject(line, "adapter command")
		Catch problem:TConvexError
			EmitError("", "ProtocolError", problem.message)
			Return
		End Try
		' Read the identifier before validating, so a rejected command still
		' correlates with the request the controller is waiting on. An absent or
		' empty one leaves the field off the event entirely.
		Local id:String = ""
		Local identifier:TJSONString = TJSONString(root.Get("id"))
		If identifier Then
			id = identifier.Value()
		End If
		Try
			Validate(root)
			Local operation:String = ConvexStringMember(root, "op")
			Select operation
				Case "hello"
					Emit("{~qprotocolVersion~q:1,~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qready~q,~qlanguage~q:" + ..
						ConvexQuote(ADAPTER_LANGUAGE) + ",~qimplementation~q:" + ConvexQuote(ADAPTER_IMPLEMENTATION) + ..
						",~qruntime~q:" + ConvexQuote(RuntimeDescription()) + "}")
				Case "query", "mutation", "action"
					Local result:TConvexResult = Service().Invoke(operation, ConvexStringMember(root, "path"), root.Get("args"))
					Emit("{~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qresult~q,~qvalue~q:" + ConvexEncode(result.value) + ..
						",~qlogs~q:" + EncodeLogs(result.logs) + "}")
				Case "setAuth"
					Service().SetAuth(ConvexStringMember(root, "token"))
					Emit("{~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qack~q}")
				Case "subscribe"
					Subscribe(id, ConvexStringMember(root, "subscriptionId"), ConvexStringMember(root, "path"), root.Get("args"))
				Case "unsubscribe"
					Unsubscribe(id, ConvexStringMember(root, "subscriptionId"))
				Case "debugDisconnect"
					If Not client Or Not client.DebugDisconnect() Then
						Throw TConvexError.Protocol("the Live WebSocket is not connected")
					End If
					Emit("{~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qack~q}")
				Case "close"
					closed = True
					observers.Clear()
					If client Then
						client.Close()
					End If
					Emit("{~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qclosed~q}")
				Default
					Throw TConvexError.Protocol("unknown adapter operation")
			End Select
		Catch problem:TConvexError
			If problem.kind = TConvexError.KIND_FUNCTION And client And client.lastFunctionError Then
				Local failure:TConvexFunctionError = client.lastFunctionError
				EmitError(id, failure.name, failure.message, failure.data, failure.logs)
			Else
				EmitError(id, problem.Name(), problem.message)
			End If
		End Try
	End Method

	Method Subscribe(id:String, subscriptionId:String, path:String, args:TJSON)
		Local previous:TAdapterObserver = Registered(subscriptionId)
		If previous Then
			' Retire the old relay before the new registration or the
			' acknowledgement below, so a queued event cannot cross either.
			observers.Remove(previous)
			Service().Unsubscribe(previous.subscription)
		End If
		Local observer:TAdapterObserver = New TAdapterObserver
		observer.adapter = Self
		observer.subscriptionId = subscriptionId
		observer.subscription = Service().Subscribe(path, args, observer)
		observers.AddLast(observer)
		Emit("{~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qack~q}")
	End Method

	Method Unsubscribe(id:String, subscriptionId:String)
		Local observer:TAdapterObserver = Registered(subscriptionId)
		If observer Then
			observers.Remove(observer)
			Service().Unsubscribe(observer.subscription)
		End If
		Emit("{~qid~q:" + ConvexQuote(id) + ",~qtype~q:~qack~q}")
	End Method

	Rem
	bbdoc: Rejects any command that is not exactly protocol v1.
	about: Unknown fields are refused rather than ignored so a controller typo
	shows up as an error instead of a silently different operation.
	End Rem
	Method Validate(root:TJSONObject)
		' Both are read for their length rules; the operation also selects which
		' other fields the command is allowed to carry.
		RequiredString(root, "id", 1, 128)
		Local operation:String = RequiredString(root, "op", 1, 64)
		Local permitted:String
		Select operation
			Case "hello"
				permitted = "id op protocolVersion"
			Case "query", "mutation", "action"
				permitted = "id op path args"
			Case "setAuth"
				permitted = "id op token"
			Case "subscribe"
				permitted = "id op subscriptionId path args"
			Case "unsubscribe"
				permitted = "id op subscriptionId"
			Case "debugDisconnect", "close"
				permitted = "id op"
			Default
				Throw TConvexError.Protocol("unknown adapter operation")
		End Select
		' Counting the permitted fields that are actually present and comparing
		' with the object's size rejects any extra field without depending on
		' how the JSON binding exposes member names.
		Local present:Int = 0
		Local allowed:String[] = permitted.Split(" ")
		For Local name:String = EachIn allowed
			If root.Get(name) Then
				present :+ 1
			End If
		Next
		If present <> root.Size() Then
			Throw TConvexError.Protocol("the adapter command carried an unknown field")
		End If
		Select operation
			Case "hello"
				If ConvexUInt32Member(root, "protocolVersion") <> 1 Then
					Throw TConvexError.Protocol("unsupported adapter protocol version")
				End If
			Case "query", "mutation", "action"
				RequiredString(root, "path", 3, 1024)
				RequireObjectArgs(root)
			Case "setAuth"
				RequiredString(root, "token", 0, 8192)
			Case "subscribe"
				RequiredString(root, "subscriptionId", 1, 128)
				RequiredString(root, "path", 1, 1024)
				RequireObjectArgs(root)
			Case "unsubscribe"
				RequiredString(root, "subscriptionId", 1, 128)
		End Select
	End Method

	Function RequireObjectArgs(root:TJSONObject)
		If Not TJSONObject(root.Get("args")) Then
			Throw TConvexError.Protocol("args must be a JSON object")
		End If
	End Function

	Function RequiredString:String(root:TJSONObject, memberName:String, minimum:Int, maximum:Int)
		Local member:TJSONString = TJSONString(root.Get(memberName))
		If Not member Then
			Throw TConvexError.Protocol(memberName + " must be a string")
		End If
		Local value:String = member.Value()
		If value.length < minimum Or value.length > maximum Then
			Throw TConvexError.Protocol(memberName + " has an invalid length")
		End If
		Return value
	End Function

	Function RuntimeDescription:String()
		Local configured:String = ConvexEnv("BLITZMAX_RUNTIME")
		If configured.length > 0 Then
			Return configured
		End If
		Return "blitzmax-ng"
	End Function

	Rem
	bbdoc: Feeds one chunk of controller input through the NDJSON line splitter.
	about: The command bound is applied while the bytes arrive, so an oversized
	line is refused at the byte that crosses the limit and the rest of it is
	discarded up to the next newline rather than buffered.
	End Rem
	Method Ingest(chunk:Byte[], count:Int)
		Local segmentStart:Int = 0
		For Local index:Int = 0 Until count
			If chunk[index] <> 10 Then
				Continue
			End If
			If Not discarding Then
				If AppendCommand(chunk, segmentStart, index - segmentStart) Then
					HandleBufferedCommand()
				End If
			End If
			command.Reset()
			discarding = False
			segmentStart = index + 1
			If closed Then
				Return
			End If
		Next
		If segmentStart < count And Not discarding Then
			If Not AppendCommand(chunk, segmentStart, count - segmentStart) Then
				discarding = True
			End If
		End If
	End Method

	Method AppendCommand:Int(chunk:Byte[], offset:Int, count:Int)
		If count > ADAPTER_MAX_COMMAND_BYTES - command.length Then
			EmitError("", "ProtocolError", "an adapter command exceeded its bounded size")
			command.Reset()
			Return False
		End If
		If count > 0 Then
			command.AppendBytes(Varptr chunk[offset], count)
		End If
		Return True
	End Method

	Method HandleBufferedCommand()
		Local length:Int = command.length
		If length > 0 And command.data[length - 1] = 13 Then
			length :- 1
		End If
		If length = 0 Then
			EmitError("", "ProtocolError", "an adapter command was empty")
			Return
		End If
		Handle(command.TextPrefix(length))
	End Method

	Rem
	bbdoc: Runs the adapter until the controller closes it.
	returns: the process exit code.
	End Rem
	Method Run:Int()
		Local chunk:Byte[] = New Byte[CONVEX_IO_CHUNK_BYTES]
		While Not closed
			' The Live owner and the controller are serviced in the same loop,
			' in short slices, so a subscription still delivers while the
			' controller is quiet and a command is still read while frames flow.
			If client Then
				client.Pump(5)
			End If
			Local ready:Int = channel.PollRead(5)
			If ready < 0 Then
				Exit
			End If
			If ready = 0 Then
				Continue
			End If
			Local received:Int = channel.ReadChunk(chunk)
			If received < 0 Then
				Exit
			End If
			If received > 0 Then
				Ingest(chunk, received)
			End If
		Wend
		If client Then
			client.Close()
		End If
		channel.Shutdown()
		If failed Then
			Return 1
		End If
		Return 0
	End Method

End Type

Rem
bbdoc: Builds the adapter for its configured transport and runs it.
End Rem
Function ConvexAdapterMain:Int()
	Local listen:String = ConvexEnv("ADAPTER_LISTEN")
	Local channel:TAdapterChannel
	Try
		If listen.length > 0 Then
			channel = TAdapterSocket.Listen(listen)
		Else
			channel = New TAdapterStdio
		End If
	Catch problem:TConvexError
		ErrPrint("adapter could not start: " + problem.message)
		Return 1
	End Try
	Return TConvexAdapter.Create(channel).Run()
End Function

Rem
bbdoc: Ends the process with @code.
about: BlitzMax's End always reports success, and the harness distinguishes a
clean close from a failed one by the exit status.
End Rem
Function ConvexAdapterExit(code:Int)
	convex_adapter_exit(code)
End Function
