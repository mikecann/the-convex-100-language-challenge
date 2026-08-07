SuperStrict

' HTTP behaviour proved against a deliberately hostile peer.
'
' A cooperative server would only ever show that the happy path works. These
' cases are the ones that decide whether a truncated body reads as a value,
' whether a function error survives a non-2xx status, and whether a peer that
' drips one byte at a time can hold a call open forever.

Framework BRL.StandardIO

Import "testing.bmx"
Import "rawpeer.bmx"
Import "httppeer.bmx"
Import "../transport.bmx"
Import "../jsonvalue.bmx"
Import "../convex.bmx"

Global LastResult:TConvexResult

Rem
bbdoc: Runs one call and returns the failure message, or an empty string.
End Rem
Function Attempt:String(client:TConvexClient, operation:String, path:String, args:String)
	LastResult = Null
	Try
		LastResult = client.Invoke(operation, path, ConvexParseJsonObject(args, "arguments"))
	Catch problem:TConvexError
		Return problem.message
	Catch other:Object
		Return other.ToString()
	End Try
	Return ""
End Function

Function TestContentLengthSuccess()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", ..
		"{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:1},~qlogLines~q:[~q[LOG] demo:echo~q]}"))
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{~qroom~q:~qa~q}")
	ConvexCheckEqual(failure, "", "a well-framed response succeeds")
	If LastResult Then
		ConvexCheckEqual(ConvexEncode(LastResult.value), "{~qcount~q:1}", "the value is decoded")
		ConvexCheckEqualInt(LastResult.logs.length, 1, "log lines are carried back to the caller")
	End If
	ConvexCheck(script.requestHead.Find("POST /api/query ") >= 0, "the call posts to the documented endpoint")
	ConvexCheck(script.requestBody.Find("~qformat~q:~qjson~q") >= 0, "the request declares the JSON value format")
	peer.Stop()
End Function

Function TestChunkedSuccess()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexChunkedResponse("200 OK", ..
		"{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:2},~qlogLines~q:[]}"))
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	ConvexCheckEqual(failure, "", "a complete chunked response succeeds")
	If LastResult Then
		ConvexCheckEqual(ConvexEncode(LastResult.value), "{~qcount~q:2}", "the chunked value is decoded")
	End If
	peer.Stop()
End Function

Function TestTruncatedContentLength()
	Local body:String = "{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:1},~qlogLines~q:[]}"
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", body))
	' Stop eight bytes short of the promised body and then close.
	script.prefixBytes = ConvexHttpResponse("200 OK", body).length - 8
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	ConvexCheck(failure.Find("Content-Length") >= 0, ..
		"a body that never satisfied its Content-Length is a transport failure, not a value")
	peer.Stop()
End Function

Function TestUnterminatedChunked()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexChunkedResponse("200 OK", ..
		"{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:1},~qlogLines~q:[]}", False))
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	ConvexCheck(failure.Find("chunk") >= 0, ..
		"a chunked body without its terminal chunk is a transport failure")
	peer.Stop()
End Function

Function TestFunctionErrorSurvivesNon2xx()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("500 Internal Server Error", ..
		"{~qstatus~q:~qerror~q,~qerrorMessage~q:~qroom is empty~q,~qerrorData~q:{~qcode~q:~qROOM_EMPTY~q},~qlogLines~q:[~q[LOG] demo:fail~q]}"))
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:fail", "{}")
	ConvexCheckEqual(failure, "room is empty", "a complete error envelope is authoritative on any status")
	Local recorded:TConvexFunctionError = client.lastFunctionError
	If recorded Then
		ConvexCheckEqual(recorded.name, "FunctionError", "the failure is classified as a function error")
		ConvexCheckEqual(ConvexEncode(recorded.data), "{~qcode~q:~qROOM_EMPTY~q}", "the application error data survives")
		ConvexCheckEqualInt(recorded.logs.length, 1, "the function's log lines survive")
	Else
		ConvexCheck(False, "the structured failure is retained for the caller")
	End If
	peer.Stop()
End Function

Function TestNonEnvelopeNon2xxStaysTransport()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("503 Service Unavailable", ..
		"{~qmessage~q:~qtry again~q}"))
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	ConvexCheck(failure.Find("HTTP status 503") >= 0, ..
		"a non-2xx body that is not a Convex envelope stays a transport failure")
	Local invented:TConvexFunctionError = client.lastFunctionError
	ConvexCheck(Not invented, "no function error is invented from a non-envelope body")
	peer.Stop()
End Function

Function TestMalformedBodyThenRecovery()
	Local broken:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", "{~qstatus~q:"))
	Local peer:TConvexPeer = TConvexPeer.Start(broken)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	ConvexCheck(failure.Find("malformed") >= 0, "a malformed body is a protocol failure")
	peer.Stop()

	' The client must not be poisoned by the failure: a later call on a healthy
	' deployment has to succeed on the same object.
	Local healthy:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", ..
		"{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:3},~qlogLines~q:[]}"))
	Local second:TConvexPeer = TConvexPeer.Start(healthy)
	Local recovered:TConvexClient = TConvexClient.Create(second.Origin())
	ConvexCheckEqual(Attempt(recovered, "query", "demo:state", "{}"), "", "a later call recovers")
	If LastResult Then
		ConvexCheckEqual(ConvexEncode(LastResult.value), "{~qcount~q:3}", "the recovered value is decoded")
	End If
	second.Stop()
End Function

Function TestOversizedBodyIsRefused()
	Local script:THttpPeerScript = THttpPeerScript.Create( ..
		"HTTP/1.1 200 OK~r~nContent-Type: application/json~r~nContent-Length: 4194304~r~nConnection: close~r~n~r~n{}")
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	ConvexCheck(failure.Find("two MiB") >= 0, "a response larger than the bound is refused before it is read")
	peer.Stop()
End Function

Rem
bbdoc: Proves the deadline is absolute rather than an inactivity timeout.
about: The peer sends one byte every time it is serviced and never stops, so an
inactivity-based reader would wait forever. The assertion is on the elapsed
time, not merely on the fact that the peer eventually gave up.
End Rem
Function TestAbsoluteDeadline()
	Local script:THttpPeerScript = THttpPeerScript.Create(ConvexHttpResponse("200 OK", ..
		"{~qstatus~q:~qsuccess~q,~qvalue~q:{~qcount~q:1},~qlogLines~q:[]}"))
	script.bytesPerService = 1
	script.closeAfterSend = False
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local previous:Int = TConvexClient.httpDeadlineMs
	TConvexClient.httpDeadlineMs = 600
	Local started:Long = ConvexNowMs()
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	Local elapsed:Long = ConvexNowMs() - started
	TConvexClient.httpDeadlineMs = previous
	ConvexCheck(failure.Find("absolute deadline") >= 0, "a continuously dripping peer trips the absolute deadline")
	ConvexCheck(elapsed < 3000, "the deadline fires close to its budget rather than eventually (took " + elapsed + "ms)")
	peer.Stop()
End Function

Rem
bbdoc: Proves a silent peer cannot hold a call open past its deadline.
End Rem
Function TestSilentPeerDeadline()
	Local script:THttpPeerScript = THttpPeerScript.Create("")
	script.closeAfterSend = False
	Local peer:TConvexPeer = TConvexPeer.Start(script)
	Local client:TConvexClient = TConvexClient.Create(peer.Origin())
	Local previous:Int = TConvexClient.httpDeadlineMs
	TConvexClient.httpDeadlineMs = 500
	Local started:Long = ConvexNowMs()
	Local failure:String = Attempt(client, "query", "demo:state", "{}")
	Local elapsed:Long = ConvexNowMs() - started
	TConvexClient.httpDeadlineMs = previous
	ConvexCheck(failure.Find("absolute deadline") >= 0, "a silent peer trips the absolute deadline")
	ConvexCheck(elapsed < 3000, "the silent-peer deadline is bounded (took " + elapsed + "ms)")
	peer.Stop()
End Function

TestContentLengthSuccess()
TestChunkedSuccess()
TestTruncatedContentLength()
TestUnterminatedChunked()
TestFunctionErrorSurvivesNon2xx()
TestNonEnvelopeNon2xxStaysTransport()
TestMalformedBodyThenRecovery()
TestOversizedBodyIsRefused()
TestAbsoluteDeadline()
TestSilentPeerDeadline()

ConvexTestExit(ConvexTestSummary("http_raw_peer_tests"))
