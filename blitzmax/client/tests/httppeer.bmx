SuperStrict

' An HTTP peer for the language-local tests.
'
' It waits for a complete request and then answers with exactly the bytes a
' test asked for: a whole response, a deliberately truncated one, or the same
' bytes paced one at a time so a deadline has something real to fire against.

Import "rawpeer.bmx"
Import "../transport.bmx"
Import "../convex.bmx"

' Serviced every time the client's idle hook fires, which on a loopback
' connection is again almost as soon as the byte just queued was read back:
' bounding a release to one byte per Service() call does not by itself bound
' how much wall-clock time the whole response takes. Spacing releases by real
' time, the same idiom the Live sync peer uses for its own delayed tail, is
' what actually gives an absolute-deadline test something slower than the
' deadline to fire against.
Const CONVEX_HTTP_PEER_PACE_MS:Int = 40

Rem
bbdoc: A peer that answers one HTTP request from a script.
End Rem
Type THttpPeerScript Extends TConvexPeerScript

	Field response:String
	' -1 sends the whole response; anything else truncates it there.
	Field prefixBytes:Int = -1
	' 0 sends everything at once; anything else paces the bytes.
	Field bytesPerService:Int
	Field closeAfterSend:Int = True
	Field encoded:TConvexBuffer
	Field sent:Int
	Field requestHead:String
	Field requestBody:String
	' -1 means "never yet released a paced byte"; a real timestamp is never
	' negative, so this cannot be mistaken for one.
	Field nextReleaseAt:Long = -1

	Function Create:THttpPeerScript(response:String)
		Local this:THttpPeerScript = New THttpPeerScript
		this.response = response
		Return this
	End Function

	Method Serve(peer:TConvexPeer) Override
		If Not peer.HasCompleteRequest() Then
			Return
		End If
		If Not encoded Then
			requestHead = peer.RequestHead()
			requestBody = peer.RequestBody()
			encoded = TConvexBuffer.Create(response.length + 32)
			encoded.AppendString(response)
			If prefixBytes >= 0 And prefixBytes < encoded.length Then
				encoded.length = prefixBytes
			End If
		End If
		If sent >= encoded.length Then
			If closeAfterSend Then
				peer.DropConnection()
			End If
			Return
		End If
		If bytesPerService > 0 Then
			If nextReleaseAt >= 0 And ConvexNowMs() < nextReleaseAt Then
				Return
			End If
			nextReleaseAt = ConvexNowMs() + CONVEX_HTTP_PEER_PACE_MS
		End If
		Local portion:Int = encoded.length - sent
		If bytesPerService > 0 And bytesPerService < portion Then
			portion = bytesPerService
		End If
		peer.QueueBytes(encoded.data[sent..sent + portion], portion)
		sent :+ portion
	End Method

End Type
