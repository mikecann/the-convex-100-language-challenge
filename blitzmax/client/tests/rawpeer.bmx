SuperStrict

' A cooperative, deliberately hostile peer for the language-local tests.
'
' The peer runs in the same thread as the client. Every place the client waits
' for a socket calls the transport's idle hook, and that hook services this
' peer, so a test can say exactly what the server does and when. Nothing races:
' the same sequence of bytes is produced on every run, which is what makes a
' partial-frame, truncated-body, or stalled-close assertion meaningful rather
' than flaky.

Import BRL.Base64
Import BRL.LinkedList
Import Crypto.SHA1Digest

Import "../transport.bmx"
Import "../jsonvalue.bmx"
Import "../websocket.bmx"

Rem
bbdoc: The behaviour one peer performs when it is serviced.
End Rem
Type TConvexPeerScript Abstract

	Method Serve(peer:TConvexPeer) Abstract

	Rem
	bbdoc: Called once for every accepted connection, including reconnections.
	End Rem
	Method OnConnect(peer:TConvexPeer)
	End Method

End Type

Global ConvexActivePeer:TConvexPeer
Global ConvexNextPeerPort:Int = 34500

Rem
bbdoc: Services the peer that the running test installed.
End Rem
Function ConvexServiceActivePeer:Int()
	If ConvexActivePeer Then
		ConvexActivePeer.Service()
	End If
	Return 0
End Function

Rem
bbdoc: One loopback TCP server driven entirely by the client's idle hook.
End Rem
Type TConvexPeer

	Field listener:TNetContext
	Field connection:TNetContext
	Field script:TConvexPeerScript
	Field inbound:TConvexBuffer
	Field outbound:TConvexBuffer
	Field port:Int
	Field connected:Int
	Field connections:Int
	Field finished:Int
	Field servicing:Int
	' Scripts use these as their own state; keeping them here means a script can
	' stay a small, readable Serve method.
	Field stage:Int
	Field counter:Int
	' When set the peer stops reading entirely, so the client's socket buffer
	' is the only thing absorbing what it writes.
	Field stalled:Int
	Field notes:TList
	Field pongs:TList

	Rem
	bbdoc: Binds the next free loopback port and installs itself as the active peer.
	End Rem
	Function Start:TConvexPeer(script:TConvexPeerScript)
		Local this:TConvexPeer = New TConvexPeer
		this.script = script
		this.inbound = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.outbound = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.notes = New TList
		this.pongs = New TList
		For Local attempt:Int = 0 Until 200
			Local candidate:Int = ConvexNextPeerPort
			ConvexNextPeerPort :+ 1
			Local listener:TNetContext = New TNetContext.Create()
			If listener.Bind("127.0.0.1", "" + candidate, MBEDTLS_NET_PROTO_TCP) = 0 Then
				listener.SetNonBlock()
				this.listener = listener
				this.port = candidate
				ConvexActivePeer = this
				ConvexIdleHook = ConvexServiceActivePeer
				Return this
			End If
			listener.Free()
		Next
		Throw TConvexError.Transport("no free loopback port for the test peer")
	End Function

	Method Origin:String()
		Return "http://127.0.0.1:" + port
	End Method

	Rem
	bbdoc: Accepts, reads, runs the script, and flushes, all without blocking.
	End Rem
	Method Service()
		' A script may itself call something that waits, which would re-enter
		' here; one level of servicing at a time keeps the byte order defined.
		If servicing Or finished Then
			Return
		End If
		servicing = True
		If Not connected Then
			If listener.Poll(MBEDTLS_NET_POLL_READ, 0) > 0 Then
				connection = New TNetContext.Create()
				Local peerAddress:String
				If listener.Accept(connection, peerAddress) = 0 Then
					connection.SetNonBlock()
					connected = True
					connections :+ 1
					inbound.Reset()
					outbound.Reset()
					script.OnConnect(Self)
				Else
					connection = Null
				End If
			End If
		End If
		If connected Then
			Drain()
		End If
		' Drain may have discovered that the client hung up, in which case there
		' is nothing left for the script to answer on this connection.
		If connected Then
			script.Serve(Self)
			Flush()
		End If
		servicing = False
	End Method

	Method Drain()
		If Not connection Or stalled Then
			Return
		End If
		Local chunk:Byte[] = New Byte[CONVEX_IO_CHUNK_BYTES]
		Repeat
			Local received:Int = connection.Recv(chunk, Size_T(chunk.length))
			If received > 0 Then
				inbound.AppendBytes(chunk, received)
				Continue
			End If
			If received = 0 Then
				' The client hung up. Release this connection so the listener
				' can accept the reconnection the test is about to provoke.
				DropConnection()
			End If
			Return
		Forever
	End Method

	Method Flush()
		If Not connection Then
			Return
		End If
		While outbound.length > 0
			Local sent:Int = connection.Send(outbound.data, Size_T(outbound.length))
			If sent <= 0 Then
				Return
			End If
			outbound.Consume(sent)
		Wend
	End Method

	Method Queue(text:String)
		outbound.AppendString(text)
	End Method

	Method QueueBytes(data:Byte[], count:Int)
		outbound.AppendBytes(data, count)
	End Method

	Rem
	bbdoc: Queues only the first @count bytes of @text, for truncation tests.
	End Rem
	Method QueuePrefix(text:String, count:Int)
		Local encoded:TConvexBuffer = TConvexBuffer.Create(text.length + 32)
		encoded.AppendString(text)
		If count > encoded.length Then
			count = encoded.length
		End If
		outbound.AppendBytes(encoded.data, count)
	End Method

	Rem
	bbdoc: Stops serving and drops the connection.
	End Rem
	Method Stop()
		finished = True
		If connection Then
			connection.Free()
			connection = Null
		End If
		connected = False
		If listener Then
			listener.Free()
			listener = Null
		End If
		If ConvexActivePeer = Self Then
			ConvexActivePeer = Null
			ConvexIdleHook = Null
		End If
	End Method

	Rem
	bbdoc: Closes only the accepted connection, leaving the listener bound.
	End Rem
	Method DropConnection()
		Flush()
		If connection Then
			connection.Free()
			connection = Null
		End If
		connected = False
		inbound.Reset()
		outbound.Reset()
	End Method

	Rem
	bbdoc: Index of the end of the buffered request headers, or -1.
	End Rem
	Method HeaderEnd:Int()
		For Local index:Int = 0 Until inbound.length - 3
			If inbound.data[index] = 13 And inbound.data[index + 1] = 10 And ..
					inbound.data[index + 2] = 13 And inbound.data[index + 3] = 10 Then
				Return index
			End If
		Next
		Return -1
	End Method

	Rem
	bbdoc: True once a complete HTTP request, including its body, has arrived.
	End Rem
	Method HasCompleteRequest:Int()
		Local ending:Int = HeaderEnd()
		If ending < 0 Then
			Return False
		End If
		Local head:String = inbound.TextPrefix(ending)
		Local lines:String[] = head.Split("~r~n")
		Local declared:String = ConvexHeaderValue(lines[1..], "Content-Length").Trim()
		Local expected:Int = 0
		If declared.length > 0 Then
			expected = declared.ToInt()
		End If
		Return inbound.length >= ending + 4 + expected
	End Method

	Rem
	bbdoc: The request body of the buffered request.
	End Rem
	Method RequestBody:String()
		Local ending:Int = HeaderEnd()
		If ending < 0 Then
			Return ""
		End If
		Local body:TConvexBuffer = TConvexBuffer.Create(inbound.length)
		body.AppendBytes(Varptr inbound.data[ending + 4], inbound.length - ending - 4)
		Return body.ToText()
	End Method

	Rem
	bbdoc: The buffered request headers.
	End Rem
	Method RequestHead:String()
		Local ending:Int = HeaderEnd()
		If ending < 0 Then
			Return ""
		End If
		Return inbound.TextPrefix(ending)
	End Method

	Rem
	bbdoc: Answers a WebSocket upgrade request with a correct 101 response.
	End Rem
	Method AcceptUpgrade(extraHeaders:String = "")
		Local head:String = RequestHead()
		Local lines:String[] = head.Split("~r~n")
		Local key:String = ConvexHeaderValue(lines[1..], "Sec-WebSocket-Key")
		inbound.Reset()
		Queue("HTTP/1.1 101 Switching Protocols~r~n")
		Queue("Upgrade: websocket~r~n")
		Queue("Connection: Upgrade~r~n")
		Queue("Sec-WebSocket-Accept: " + TConvexWebSocket.ExpectedAccept(key) + "~r~n")
		Queue(extraHeaders)
		Queue("~r~n")
	End Method

	Rem
	bbdoc: Queues one unmasked server frame.
	End Rem
	Method QueueFrame(opcode:Int, payload:String, fin:Int = True, masked:Int = False)
		Local body:TConvexBuffer = TConvexBuffer.Create(payload.length + 32)
		body.AppendString(payload)
		QueueFrameBytes(opcode, body.data, body.length, fin, masked)
	End Method

	Method QueueFrameBytes(opcode:Int, payload:Byte[], count:Int, fin:Int = True, masked:Int = False)
		Local first:Int = opcode
		If fin Then
			first :| $80
		End If
		outbound.AppendByte(first)
		Local maskBit:Int = 0
		If masked Then
			maskBit = $80
		End If
		If count < 126 Then
			outbound.AppendByte(maskBit | count)
		ElseIf count <= 65535 Then
			outbound.AppendByte(maskBit | 126)
			outbound.AppendByte(count Shr 8)
			outbound.AppendByte(count)
		Else
			outbound.AppendByte(maskBit | 127)
			For Local shift:Int = 56 To 0 Step -8
				outbound.AppendByte(Int((Long(count) Shr shift) & $FF))
			Next
		End If
		If masked Then
			' A server must never mask. Tests use this to prove the client
			' refuses the frame rather than unmasking it anyway.
			For Local index:Int = 0 Until 4
				outbound.AppendByte(0)
			Next
		End If
		outbound.AppendBytes(payload, count)
	End Method

	Rem
	bbdoc: Queues a frame header that promises more payload than will ever arrive.
	End Rem
	Method QueuePartialFrame(opcode:Int, payload:String, delivered:Int)
		Local body:TConvexBuffer = TConvexBuffer.Create(payload.length + 32)
		body.AppendString(payload)
		outbound.AppendByte($80 | opcode)
		outbound.AppendByte(body.length)
		If delivered > body.length Then
			delivered = body.length
		End If
		outbound.AppendBytes(body.data, delivered)
	End Method

	Rem
	bbdoc: Decodes the next complete client frame, unmasking its payload.
	returns: the opcode, or -1 when no complete frame is buffered.
	End Rem
	Method NextClientFrame:Int(payload:TConvexBuffer)
		If inbound.length < 2 Then
			Return -1
		End If
		Local opcode:Int = inbound.data[0] & $0F
		Local masked:Int = (inbound.data[1] & $80) <> 0
		Local declared:Int = inbound.data[1] & $7F
		Local headerBytes:Int = 2
		Local length:Int = declared
		If declared = 126 Then
			If inbound.length < 4 Then
				Return -1
			End If
			length = (inbound.data[2] Shl 8) | inbound.data[3]
			headerBytes = 4
		ElseIf declared = 127 Then
			If inbound.length < 10 Then
				Return -1
			End If
			length = 0
			For Local index:Int = 6 To 9
				length = (length Shl 8) | inbound.data[index]
			Next
			headerBytes = 10
		End If
		Local maskBytes:Int = 0
		If masked Then
			maskBytes = 4
		End If
		If inbound.length < headerBytes + maskBytes + length Then
			Return -1
		End If
		payload.Reset()
		For Local index:Int = 0 Until length
			Local raw:Int = inbound.data[headerBytes + maskBytes + index]
			If masked Then
				raw = raw ~ inbound.data[headerBytes + (index & 3)]
			End If
			payload.AppendByte(raw)
		Next
		inbound.Consume(headerBytes + maskBytes + length)
		Return opcode
	End Method

	Rem
	bbdoc: Consumes every buffered client frame, returning the text ones in order.
	about: Control answers are recorded rather than discarded so a test can
	prove the client really did pong the ping it was sent.
	End Rem
	Method TakeClientText:String[]()
		Local texts:TList = New TList
		Repeat
			Local payload:TConvexBuffer = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
			Local opcode:Int = NextClientFrame(payload)
			If opcode < 0 Then
				Exit
			End If
			If opcode = CONVEX_WS_TEXT Then
				Local text:String = payload.ToText()
				notes.AddLast(text)
				texts.AddLast(text)
			ElseIf opcode = CONVEX_WS_PONG Then
				pongs.AddLast(payload.ToText())
			End If
		Forever
		Local collected:String[] = New String[texts.Count()]
		Local index:Int = 0
		For Local text:String = EachIn texts
			collected[index] = text
			index :+ 1
		Next
		Return collected
	End Method

End Type

Rem
bbdoc: A complete HTTP response with a correct Content-Length.
End Rem
Function ConvexHttpResponse:String(status:String, body:String)
	Local encoded:TConvexBuffer = TConvexBuffer.Create(body.length + 32)
	encoded.AppendString(body)
	Return "HTTP/1.1 " + status + "~r~nContent-Type: application/json~r~nContent-Length: " + encoded.length + ..
		"~r~nConnection: close~r~n~r~n" + body
End Function

Rem
bbdoc: The same response framed as a single chunk plus its terminator.
End Rem
Function ConvexChunkedResponse:String(status:String, body:String, terminate:Int = True)
	Local encoded:TConvexBuffer = TConvexBuffer.Create(body.length + 32)
	encoded.AppendString(body)
	Local head:String = "HTTP/1.1 " + status + "~r~nContent-Type: application/json~r~nTransfer-Encoding: chunked~r~nConnection: close~r~n~r~n"
	Local chunk:String = ConvexHexOf(encoded.length) + "~r~n" + body + "~r~n"
	If terminate Then
		Return head + chunk + "0~r~n~r~n"
	End If
	Return head + chunk
End Function

Rem
bbdoc: Encodes @value as a Convex sync timestamp: little-endian u64 in base64.
End Rem
Function ConvexEncodeTimestamp:String(value:Long)
	Local bytes:Byte[] = New Byte[8]
	Local remaining:Long = value
	For Local index:Int = 0 Until 8
		bytes[index] = Byte(remaining & $FF)
		remaining = remaining Shr 8
	Next
	Return TBase64.Encode(bytes, 0, EBase64Options.DontBreakLines)
End Function

Function ConvexHexOf:String(value:Int)
	If value = 0 Then
		Return "0"
	End If
	Local digits:String = ""
	Local remaining:Int = value
	While remaining > 0
		digits = ConvexHexDigit(remaining & $F) + digits
		remaining = remaining Shr 4
	Wend
	Return digits
End Function
