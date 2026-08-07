SuperStrict

' A client-owned RFC 6455 WebSocket, written for the Convex sync endpoint.
'
' The parser is incremental on purpose. A frame is only removed from the
' inbound buffer once every one of its bytes has arrived, so a timeout in the
' middle of a frame leaves the parser exactly where it was rather than letting
' a later read resynchronise on a payload byte that happens to look like a
' header.

Import BRL.Base64
Import Crypto.SHA1Digest

Import "transport.bmx"

Const CONVEX_WS_CONTINUATION:Int = $0
Const CONVEX_WS_TEXT:Int = $1
Const CONVEX_WS_BINARY:Int = $2
Const CONVEX_WS_CLOSE:Int = $8
Const CONVEX_WS_PING:Int = $9
Const CONVEX_WS_PONG:Int = $A

' The handshake response is small; a peer that never finishes its headers must
' not be able to make the client buffer without limit.
Const CONVEX_WS_MAX_HANDSHAKE_BYTES:Int = 16 * 1024
Const CONVEX_WS_GUID:String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

Rem
bbdoc: The result of asking a socket for the next application message.
End Rem
Const CONVEX_WS_NOTHING:Int = 0
Const CONVEX_WS_MESSAGE:Int = 1
Const CONVEX_WS_CLOSED:Int = 2

Rem
bbdoc: Case-insensitive lookup of one response header.
End Rem
Function ConvexHeaderValue:String(headers:String[], name:String)
	Local wanted:String = name.ToLower()
	For Local line:String = EachIn headers
		Local colon:Int = line.Find(":")
		If colon <= 0 Then
			Continue
		End If
		If line[..colon].Trim().ToLower() = wanted Then
			Return line[colon + 1..].Trim()
		End If
	Next
	Return ""
End Function

Rem
bbdoc: True when a comma-separated header list contains @token, ignoring case.
End Rem
Function ConvexHeaderListHas:Int(value:String, token:String)
	Local wanted:String = token.ToLower()
	Local parts:String[] = value.Split(",")
	For Local part:String = EachIn parts
		If part.Trim().ToLower() = wanted Then
			Return True
		End If
	Next
	Return False
End Function

Rem
bbdoc: A connected WebSocket carrying Convex sync frames.
End Rem
Type TConvexWebSocket

	Field socket:TConvexSocket
	Field inbound:TConvexBuffer
	Field assembled:TConvexBuffer
	Field assembling:Int
	Field open:Int
	Field closeReason:String

	Rem
	bbdoc: Performs the upgrade handshake against @path on an open @endpoint.
	End Rem
	Function Connect:TConvexWebSocket(endpoint:TConvexEndpoint, path:String, authToken:String, deadline:TConvexDeadline)
		Local this:TConvexWebSocket = New TConvexWebSocket
		this.inbound = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.assembled = TConvexBuffer.Create(CONVEX_IO_CHUNK_BYTES)
		this.socket = TConvexSocket.Connect(endpoint.host, endpoint.port, endpoint.useTls, deadline)
		Try
			this.Upgrade(endpoint, path, authToken, deadline)
		Catch problem:Object
			this.socket.Close()
			Throw problem
		End Try
		this.open = True
		Return this
	End Function

	Method Upgrade(endpoint:TConvexEndpoint, path:String, authToken:String, deadline:TConvexDeadline)
		' The nonce proves the response was produced for this request rather
		' than replayed from a cache or a confused intermediary.
		Local nonce:Byte[] = New Byte[16]
		TConvexCrypto.Shared().Fill(nonce, 16)
		Local key:String = TBase64.Encode(nonce, 0, EBase64Options.DontBreakLines)
		Local request:String = "GET " + path + " HTTP/1.1~r~n"
		request :+ "Host: " + endpoint.Authority() + "~r~n"
		request :+ "Upgrade: websocket~r~n"
		request :+ "Connection: Upgrade~r~n"
		request :+ "Sec-WebSocket-Key: " + key + "~r~n"
		request :+ "Sec-WebSocket-Version: 13~r~n"
		request :+ "Convex-Client: blitzmax-0.1.0~r~n"
		If authToken.length > 0 Then
			request :+ "Authorization: Bearer " + authToken + "~r~n"
		End If
		request :+ "~r~n"
		socket.WriteText(request, deadline)

		Local headerEnd:Int = -1
		Repeat
			headerEnd = FindHeaderEnd()
			If headerEnd >= 0 Then
				Exit
			End If
			If deadline.Expired() Then
				Throw TConvexError.Transport("the WebSocket handshake exceeded its absolute deadline")
			End If
			If inbound.length >= CONVEX_WS_MAX_HANDSHAKE_BYTES Then
				Throw TConvexError.Protocol("the WebSocket handshake response exceeded its bounded size")
			End If
			If socket.Readable(25) Then
				If socket.ReadInto(inbound, CONVEX_WS_MAX_HANDSHAKE_BYTES) < 0 Then
					Throw TConvexError.Transport("the peer closed during the WebSocket handshake")
				End If
			End If
			ConvexIdle()
		Forever

		Local head:String = inbound.TextPrefix(headerEnd)
		inbound.Consume(headerEnd + 4)
		Local lines:String[] = head.Split("~r~n")
		If lines.length < 1 Then
			Throw TConvexError.Protocol("the WebSocket handshake response had no status line")
		End If
		Local status:String[] = lines[0].Split(" ")
		If status.length < 2 Or Not status[0].StartsWith("HTTP/1.") Or status[1] <> "101" Then
			Throw TConvexError.Protocol("the WebSocket upgrade was refused with " + lines[0])
		End If
		Local headers:String[] = lines[1..]
		If ConvexHeaderValue(headers, "Upgrade").ToLower() <> "websocket" Then
			Throw TConvexError.Protocol("the WebSocket upgrade response did not name the websocket protocol")
		End If
		If Not ConvexHeaderListHas(ConvexHeaderValue(headers, "Connection"), "upgrade") Then
			Throw TConvexError.Protocol("the WebSocket upgrade response did not confirm the connection upgrade")
		End If
		' Nothing was offered, so nothing may be selected: an extension the
		' client cannot decode would silently corrupt every later frame.
		If ConvexHeaderValue(headers, "Sec-WebSocket-Extensions").length > 0 Then
			Throw TConvexError.Protocol("the WebSocket upgrade response selected an extension that was never offered")
		End If
		If ConvexHeaderValue(headers, "Sec-WebSocket-Protocol").length > 0 Then
			Throw TConvexError.Protocol("the WebSocket upgrade response selected a subprotocol that was never offered")
		End If
		If ConvexHeaderValue(headers, "Sec-WebSocket-Accept") <> ExpectedAccept(key) Then
			Throw TConvexError.Protocol("the WebSocket upgrade response failed its Sec-WebSocket-Accept check")
		End If
	End Method

	Rem
	bbdoc: The Sec-WebSocket-Accept value the peer must return for @key.
	End Rem
	Function ExpectedAccept:String(key:String)
		Local material:String = key + CONVEX_WS_GUID
		Local encoded:Byte Ptr = material.ToUTF8String()
		Local digest:TSHA1 = New TSHA1
		digest.Update(encoded, Int(convex_strlen(encoded)))
		MemFree(encoded)
		Local hashed:Byte[] = New Byte[20]
		digest.Finish(hashed)
		Return TBase64.Encode(hashed, 0, EBase64Options.DontBreakLines)
	End Function

	Method FindHeaderEnd:Int()
		For Local index:Int = 0 Until inbound.length - 3
			If inbound.data[index] = 13 And inbound.data[index + 1] = 10 And ..
					inbound.data[index + 2] = 13 And inbound.data[index + 3] = 10 Then
				Return index
			End If
		Next
		Return -1
	End Method

	Rem
	bbdoc: Reads up to @timeoutMs for the next complete text message.
	returns: #CONVEX_WS_MESSAGE, #CONVEX_WS_NOTHING, or #CONVEX_WS_CLOSED.
	End Rem
	Method NextMessage:Int(timeoutMs:Int, message:String Var)
		If Not open Then
			Return CONVEX_WS_CLOSED
		End If
		Local deadline:TConvexDeadline = TConvexDeadline.Create(timeoutMs)
		Repeat
			Local decoded:Int = DrainFrames(message)
			If decoded <> CONVEX_WS_NOTHING Then
				Return decoded
			End If
			If deadline.Expired() Then
				Return CONVEX_WS_NOTHING
			End If
			Local slice:Int = deadline.RemainingMs()
			If slice > 25 Then
				slice = 25
			End If
			If socket.Readable(slice) Then
				' The frame cap plus a maximum header is the most the parser can
				' ever need to hold before it either completes a frame or
				' rejects the declared length.
				If socket.ReadInto(inbound, CONVEX_MAX_FRAME_BYTES + 32) < 0 Then
					open = False
					If closeReason.length = 0 Then
						closeReason = "the peer closed the connection"
					End If
					Return CONVEX_WS_CLOSED
				End If
			End If
			ConvexIdle()
		Forever
	End Method

	Rem
	bbdoc: Consumes every complete frame that is already buffered.
	End Rem
	Method DrainFrames:Int(message:String Var)
		While open
			If inbound.length < 2 Then
				Return CONVEX_WS_NOTHING
			End If
			Local first:Int = inbound.data[0]
			Local second:Int = inbound.data[1]
			Local fin:Int = (first & $80) <> 0
			If (first & $70) <> 0 Then
				Throw TConvexError.Protocol("a Live frame set a reserved bit")
			End If
			Local opcode:Int = first & $0F
			If (second & $80) <> 0 Then
				' RFC 6455 forbids a server from masking. Accepting one would
				' mean silently reading a different payload than was sent.
				Throw TConvexError.Protocol("the peer masked a server-to-client frame")
			End If
			Local declared:Int = second & $7F
			Local headerBytes:Int = 2
			Local payloadLength:Long = declared
			If declared = 126 Then
				If inbound.length < 4 Then
					Return CONVEX_WS_NOTHING
				End If
				payloadLength = (Long(inbound.data[2]) Shl 8) | Long(inbound.data[3])
				headerBytes = 4
			ElseIf declared = 127 Then
				If inbound.length < 10 Then
					Return CONVEX_WS_NOTHING
				End If
				payloadLength = 0
				For Local index:Int = 2 To 9
					payloadLength = (payloadLength Shl 8) | Long(inbound.data[index])
				Next
				headerBytes = 10
			End If
			If payloadLength < 0 Or payloadLength > CONVEX_MAX_FRAME_BYTES Then
				Throw TConvexError.Protocol("a Live frame declared more than the bounded " + CONVEX_MAX_FRAME_BYTES + " bytes")
			End If
			Local total:Int = headerBytes + Int(payloadLength)
			If inbound.length < total Then
				' Keep every byte received so far. Restarting the parse at a
				' later read must not be able to find a false frame boundary.
				Return CONVEX_WS_NOTHING
			End If
			Local isControl:Int = (opcode & $08) <> 0
			If isControl Then
				If Not fin Then
					Throw TConvexError.Protocol("the peer fragmented a control frame")
				End If
				If payloadLength > 125 Then
					Throw TConvexError.Protocol("the peer sent an oversized control frame")
				End If
				Local outcome:Int = HandleControl(opcode, headerBytes, Int(payloadLength))
				inbound.Consume(total)
				If outcome <> CONVEX_WS_NOTHING Then
					Return outcome
				End If
				Continue
			End If
			If opcode = CONVEX_WS_BINARY Then
				Throw TConvexError.Protocol("the Convex sync protocol is text, but the peer sent a binary frame")
			End If
			If opcode = CONVEX_WS_TEXT Then
				If assembling Then
					Throw TConvexError.Protocol("the peer started a new message before finishing the previous one")
				End If
				assembling = True
				assembled.Reset()
			ElseIf opcode = CONVEX_WS_CONTINUATION Then
				If Not assembling Then
					Throw TConvexError.Protocol("the peer sent a continuation frame with no message to continue")
				End If
			Else
				Throw TConvexError.Protocol("the peer sent an unknown WebSocket opcode " + opcode)
			End If
			If assembled.length + Int(payloadLength) > CONVEX_MAX_FRAME_BYTES Then
				Throw TConvexError.Protocol("a fragmented Live message exceeded the bounded " + CONVEX_MAX_FRAME_BYTES + " bytes")
			End If
			assembled.AppendBytes(Varptr inbound.data[headerBytes], Int(payloadLength))
			inbound.Consume(total)
			If Not fin Then
				Continue
			End If
			assembling = False
			' UTF-8 is validated across the reassembled message, not per frame:
			' a multi-byte character may legitimately straddle a fragment.
			If Not ConvexIsValidUtf8(assembled.data, assembled.length) Then
				Throw TConvexError.Protocol("a Live text message was not valid UTF-8")
			End If
			If assembled.HasInteriorNul(assembled.length) Then
				Throw TConvexError.Protocol("a Live text message contained a NUL byte")
			End If
			message = assembled.ToText()
			Return CONVEX_WS_MESSAGE
		Wend
		Return CONVEX_WS_CLOSED
	End Method

	Rem
	bbdoc: Answers a buffered control frame.
	returns: #CONVEX_WS_CLOSED when the peer asked to close, otherwise #CONVEX_WS_NOTHING.
	End Rem
	Method HandleControl:Int(opcode:Int, headerBytes:Int, payloadLength:Int)
		If opcode = CONVEX_WS_PING Then
			' A pong must echo the ping body, and it is sent immediately so a
			' peer's liveness check cannot fail while a Transition is pending.
			Local body:Byte[] = New Byte[payloadLength]
			If payloadLength > 0 Then
				MemCopy(Varptr body[0], Varptr inbound.data[headerBytes], Size_T(payloadLength))
			End If
			SendFrame(CONVEX_WS_PONG, body, payloadLength, TConvexDeadline.Create(1000))
			Return CONVEX_WS_NOTHING
		End If
		If opcode = CONVEX_WS_PONG Then
			Return CONVEX_WS_NOTHING
		End If
		' Close: record why, answer once, and stop. The echo is best effort
		' because the peer may already be gone.
		Local code:Int = 1005
		Local reason:String = ""
		If payloadLength = 1 Then
			Throw TConvexError.Protocol("the peer sent a truncated close status")
		End If
		If payloadLength >= 2 Then
			code = (inbound.data[headerBytes] Shl 8) | inbound.data[headerBytes + 1]
			If payloadLength > 2 Then
				Local body:TConvexBuffer = TConvexBuffer.Create(payloadLength)
				body.AppendBytes(Varptr inbound.data[headerBytes + 2], payloadLength - 2)
				If Not ConvexIsValidUtf8(body.data, body.length) Then
					Throw TConvexError.Protocol("the peer sent a close reason that was not valid UTF-8")
				End If
				reason = body.ToText()
			End If
		End If
		closeReason = "the peer closed with status " + code
		If reason.length > 0 Then
			closeReason :+ " (" + reason + ")"
		End If
		open = False
		Try
			SendCloseFrame(1000, "", TConvexDeadline.Create(250))
		Catch problem:Object
			' The peer has already gone; the close reason above is the evidence.
		End Try
		socket.Close()
		Return CONVEX_WS_CLOSED
	End Method

	Rem
	bbdoc: Sends one masked client frame.
	End Rem
	Method SendFrame(opcode:Int, payload:Byte[], count:Int, deadline:TConvexDeadline)
		Local frame:TConvexBuffer = TConvexBuffer.Create(count + 32)
		frame.AppendByte($80 | opcode)
		If count < 126 Then
			frame.AppendByte($80 | count)
		ElseIf count <= 65535 Then
			frame.AppendByte($80 | 126)
			frame.AppendByte(count Shr 8)
			frame.AppendByte(count)
		Else
			frame.AppendByte($80 | 127)
			For Local shift:Int = 56 To 0 Step -8
				frame.AppendByte(Int((Long(count) Shr shift) & $FF))
			Next
		End If
		' Every client frame is masked with fresh generator output, as RFC 6455
		' requires; the key is never reused across frames.
		Local mask:Byte[] = New Byte[4]
		TConvexCrypto.Shared().Fill(mask, 4)
		frame.AppendBytes(mask, 4)
		For Local index:Int = 0 Until count
			frame.AppendByte(payload[index] ~ mask[index & 3])
		Next
		socket.WriteAll(frame.data, frame.length, deadline)
	End Method

	Method SendText(text:String, deadline:TConvexDeadline)
		If Not open Then
			Throw TConvexError.Transport("the Live socket is closed")
		End If
		Local body:TConvexBuffer = TConvexBuffer.Create(text.length + 32)
		body.AppendString(text)
		SendFrame(CONVEX_WS_TEXT, body.data, body.length, deadline)
	End Method

	Method SendCloseFrame(code:Int, reason:String, deadline:TConvexDeadline)
		Local body:TConvexBuffer = TConvexBuffer.Create(64)
		body.AppendByte(code Shr 8)
		body.AppendByte(code)
		body.AppendString(reason)
		SendFrame(CONVEX_WS_CLOSE, body.data, body.length, deadline)
	End Method

	Rem
	bbdoc: Closes the socket within a bounded time, whatever the peer does.
	about: The close frame is attempted once under a short absolute deadline and
	the peer's echo is never awaited. An idle, chatty, or half-frame-stalled
	peer therefore cannot delay a shutdown.
	End Rem
	Method Close(code:Int = 1000, reason:String = "client closed")
		If Not open Then
			Return
		End If
		open = False
		Try
			SendCloseFrame(code, reason, TConvexDeadline.Create(250))
		Catch problem:Object
			' A peer that will not accept the courtesy frame is still closed.
		End Try
		socket.Close()
	End Method

	Rem
	bbdoc: Drops the connection immediately, sending nothing.
	about: Used when a connection is being retired because it already
	misbehaved, and for the adapter-only disconnect the shared harness drives.
	End Rem
	Method Abort()
		open = False
		socket.Close()
	End Method

End Type
