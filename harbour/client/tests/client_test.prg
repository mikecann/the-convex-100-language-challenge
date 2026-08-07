/*
 * Language-local unit coverage for the pieces of this client that do not
 * need a real Convex deployment: JSON validation, URL parsing, HTTP
 * response framing, RFC 6455 frame encode/decode, and the Live state
 * machine's subscription bookkeeping. HTTP and WebSocket parsing are
 * exercised against a "stream" hash whose buffer is pre-filled by hand,
 * exactly the shape a real socket read would have produced, so these
 * tests need no network at all; client/tests/tls_test.prg and the
 * canonical example against a real deployment cover this client's real
 * socket and TLS round trips.
 */

#include "hbclass.ch"

STATIC s_nFailures := 0

FUNCTION ConvexAssert( lCond, cMsg )
   IF !lCond
      s_nFailures++
      OutErr( "FAIL: " + cMsg + hb_eol() )
   ENDIF
   RETURN NIL

FUNCTION ConvexAssertEqual( xGot, xWant, cMsg )
   RETURN ConvexAssert( xGot == xWant, ;
      cMsg + " (got " + hb_ValToExp( xGot ) + ", want " + hb_ValToExp( xWant ) + ")" )

PROCEDURE Main()
   TestJson()
   TestUrl()
   TestHttpFraming()
   TestWsFrames()
   TestLiveStateMachine()

   IF s_nFailures > 0
      OutErr( hb_ntos( s_nFailures ) + " test(s) failed" + hb_eol() )
      ErrorLevel( 1 )
   ELSE
      ? "PASS client_test (" + hb_ntos( s_nFailures ) + " failures)"
   ENDIF

   RETURN

PROCEDURE TestJson()
   LOCAL aResult

   ConvexAssert( ConvexWholeNumber( 0 ), "0 is whole" )
   aResult := ConvexJsonDecode( "0.0" )
   ConvexAssert( aResult[ 1 ] .AND. ConvexWholeNumber( aResult[ 2 ] ), "decoded 0.0 is whole" )
   aResult := ConvexJsonDecode( "1.5" )
   ConvexAssert( aResult[ 1 ] .AND. !ConvexWholeNumber( aResult[ 2 ] ), "1.5 is not whole" )
   aResult := ConvexJsonDecode( '"1"' )
   ConvexAssert( aResult[ 1 ] .AND. !ConvexWholeNumber( aResult[ 2 ] ), "a quoted number is not whole" )
   ConvexAssert( !ConvexWholeNumber( 99999999999999999999.0 ), "an out-of-range magnitude is not whole" )

   aResult := ConvexJsonDecode( '{"a":1}trailing' )
   ConvexAssert( !aResult[ 1 ], "trailing bytes after the JSON value are rejected" )
   aResult := ConvexJsonDecode( "{not json" )
   ConvexAssert( !aResult[ 1 ], "malformed JSON is rejected" )

   ConvexAssert( ConvexDeepEqual( { "a" => 1, "b" => { 1, 2 } }, { "a" => 1, "b" => { 1, 2 } } ), ;
      "structurally equal hashes and arrays compare equal" )
   ConvexAssert( !ConvexDeepEqual( { "a" => 1 }, { "a" => 2 } ), "differing values compare unequal" )
   ConvexAssert( !ConvexDeepEqual( { 1, 2 }, { 1, 2, 3 } ), "differing array lengths compare unequal" )
   ConvexAssert( ConvexDeepEqual( NIL, NIL ), "NIL equals NIL" )

   ConvexAssert( ConvexLogsToStrings( {} ) == NIL, "an empty logs array is omitted, not emitted empty" )
   ConvexAssert( ConvexLogsToStrings( NIL ) == NIL, "absent logs are omitted" )
   ConvexAssertEqual( Len( ConvexLogsToStrings( { "a", "b" } ) ), 2, "string log lines pass through" )

   RETURN

PROCEDURE TestUrl()
   LOCAL oUrl

   oUrl := ConvexParseUrl( "https://example.convex.cloud" )
   ConvexAssert( oUrl[ "tls" ] .AND. oUrl[ "port" ] == 443, "https with no port defaults to 443" )
   oUrl := ConvexParseUrl( "http://127.0.0.1:8080/ignored/path" )
   ConvexAssertEqual( oUrl[ "port" ], 8080, "an explicit port is honored" )
   ConvexAssert( !oUrl[ "tls" ], "http is not tls" )
   ConvexAssert( ConvexParseUrl( "ftp://example.com" ) == NIL, "an unsupported scheme is rejected" )
   ConvexAssert( ConvexParseUrl( "https://" ) == NIL, "a missing host is rejected" )

   RETURN

PROCEDURE TestHttpFraming()
   LOCAL oStream, aResult

   /* A Content-Length success envelope. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := "HTTP/1.1 200 OK" + Chr( 13 ) + Chr( 10 ) + ;
      "Content-Type: application/json" + Chr( 13 ) + Chr( 10 ) + ;
      "Content-Length: 30" + Chr( 13 ) + Chr( 10 ) + Chr( 13 ) + Chr( 10 ) + ;
      '{"status":"success","value":1}'
   aResult := ConvexHttpParseEnvelope( oStream )
   ConvexAssert( aResult[ "ok" ], "Content-Length success envelope parses" )
   ConvexAssertEqual( aResult[ "value" ], 1, "success value decodes" )

   /* Chunked transfer-encoding, two chunks plus a zero-length terminator
    * and a blank trailer line. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := "HTTP/1.1 200 OK" + Chr( 13 ) + Chr( 10 ) + ;
      "Transfer-Encoding: chunked" + Chr( 13 ) + Chr( 10 ) + Chr( 13 ) + Chr( 10 ) + ;
      "f" + Chr( 13 ) + Chr( 10 ) + '{"status":"succ' + Chr( 13 ) + Chr( 10 ) + ;
      "12" + Chr( 13 ) + Chr( 10 ) + 'ess","value":true}' + Chr( 13 ) + Chr( 10 ) + ;
      "0" + Chr( 13 ) + Chr( 10 ) + Chr( 13 ) + Chr( 10 )
   aResult := ConvexHttpParseEnvelope( oStream )
   ConvexAssert( aResult[ "ok" ], "chunked success envelope parses" )
   ConvexAssertEqual( aResult[ "value" ], .T., "chunked success value decodes" )

   /* A FunctionError envelope carrying structured error data. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := "HTTP/1.1 200 OK" + Chr( 13 ) + Chr( 10 ) + ;
      "Content-Length: 65" + Chr( 13 ) + Chr( 10 ) + Chr( 13 ) + Chr( 10 ) + ;
      '{"status":"error","errorMessage":"boom","errorData":{"code":"X"}}'
   aResult := ConvexHttpParseEnvelope( oStream )
   ConvexAssert( !aResult[ "ok" ], "an error envelope is not ok" )
   ConvexAssertEqual( aResult[ "error" ][ "name" ], "FunctionError", "error envelope names FunctionError" )
   ConvexAssertEqual( aResult[ "error" ][ "data" ][ "code" ], "X", "errorData survives" )

   /* An unrecognized status string is a ProtocolError, not a silent pass. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := "HTTP/1.1 200 OK" + Chr( 13 ) + Chr( 10 ) + ;
      "Content-Length: 16" + Chr( 13 ) + Chr( 10 ) + Chr( 13 ) + Chr( 10 ) + ;
      '{"status":"huh"}'
   aResult := ConvexHttpParseEnvelope( oStream )
   ConvexAssert( !aResult[ "ok" ] .AND. aResult[ "error" ][ "name" ] == "ProtocolError", ;
      "an unknown status is a ProtocolError" )

   /* A non-HTTP response line is rejected rather than misparsed. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := "not an http response" + Chr( 10 )
   aResult := ConvexHttpParseEnvelope( oStream )
   ConvexAssert( !aResult[ "ok" ], "a malformed status line is rejected" )

   RETURN

/* The header/body parsing half of ConvexHttpReadResponse(), factored out
 * so tests can drive it from a pre-filled stream instead of a socket. */
FUNCTION ConvexHttpParseEnvelope( oStream )
   LOCAL cStatusLine

   cStatusLine := ConvexStreamLine( oStream )
   IF cStatusLine == NIL .OR. Left( cStatusLine, 5 ) != "HTTP/"
      RETURN { "ok" => .F., "error" => ConvexTransportError( "no HTTP status line" ) }
   ENDIF
   RETURN ConvexHttpParseHeadersAndBody( oStream )

PROCEDURE TestWsFrames()
   LOCAL cMask, cFrame, oStream, oFrame, oMsg

   cMask := Chr( 1 ) + Chr( 2 ) + Chr( 3 ) + Chr( 4 )

   /* A small (< 126 byte) text frame round trip. */
   cFrame := ConvexWsBuildFrame( 1, "hello", cMask )
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := cFrame
   oFrame := ConvexWsReadFrame( oStream )
   ConvexAssertEqual( oFrame[ "payload" ], "hello", "a small masked frame decodes back to its payload" )
   ConvexAssertEqual( oFrame[ "opcode" ], 1, "the text opcode survives" )
   ConvexAssert( oFrame[ "fin" ], "FIN is set on an unfragmented frame" )

   /* A 126-length-prefix (16-bit extended length) frame. */
   cFrame := ConvexWsBuildFrame( 2, Replicate( "x", 200 ), cMask )
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := cFrame
   oFrame := ConvexWsReadFrame( oStream )
   ConvexAssertEqual( Len( oFrame[ "payload" ] ), 200, "a 16-bit extended length frame decodes" )

   /* A 127-length-prefix (64-bit extended length) frame. */
   cFrame := ConvexWsBuildFrame( 2, Replicate( "y", 70000 ), cMask )
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := cFrame
   oFrame := ConvexWsReadFrame( oStream )
   ConvexAssertEqual( Len( oFrame[ "payload" ] ), 70000, "a 64-bit extended length frame decodes" )

   /* Two continuation frames reassemble into one message. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := Chr( 0x01 ) + Chr( hb_bitOr( 0x80, 3 ) ) + cMask + ;
      Chr( hb_bitXor( Asc( "a" ), Asc( cMask ) ) ) + ;
      Chr( hb_bitXor( Asc( "b" ), Asc( SubStr( cMask, 2, 1 ) ) ) ) + ;
      Chr( hb_bitXor( Asc( "c" ), Asc( SubStr( cMask, 3, 1 ) ) ) ) + ;
      Chr( hb_bitOr( 0x80, 0x00 ) ) + Chr( hb_bitOr( 0x80, 2 ) ) + cMask + ;
      Chr( hb_bitXor( Asc( "d" ), Asc( cMask ) ) ) + Chr( hb_bitXor( Asc( "e" ), Asc( SubStr( cMask, 2, 1 ) ) ) )
   oMsg := ConvexWsReadMessage( oStream )
   ConvexAssertEqual( oMsg[ "payload" ], "abcde", "continuation frames reassemble in order" )

   /* An oversized declared length is rejected rather than allocated. */
   oStream := ConvexStreamNew( NIL, 0 )
   oStream[ "buf" ] := Chr( 0x82 ) + Chr( 127 ) + Chr( 0 ) + Chr( 0 ) + Chr( 0 ) + Chr( 0 ) + ;
      Chr( 0x7F ) + Chr( 0xFF ) + Chr( 0xFF ) + Chr( 0xFF )
   ConvexAssert( ConvexWsReadFrame( oStream ) == NIL, "a frame far larger than the shared cap is rejected" )

   RETURN

PROCEDURE TestLiveStateMachine()
   LOCAL oLive, aKeys

   oLive := TConvexLive():New( { "host" => "127.0.0.1", "port" => 1, "tls" => .F. }, NIL )

   /* Subscribing while not connected only updates local bookkeeping --
    * there is no socket to send an Add over yet. */
   oLive:HandleCommand( { "cmd" => "subscribe", "subscriptionId" => "s1", "path" => "demo:state", ;
      "args" => { "room" => "x" }, "reply" => hb_mutexCreate() } )
   ConvexAssertEqual( Len( oLive:aSubs ), 1, "subscribe adds one tracked subscription" )
   ConvexAssertEqual( oLive:FindSubByQueryId( oLive:aSubs[ "s1" ][ "queryId" ] ), "s1", ;
      "a subscription is found back by its queryId" )

   /* A Transition whose startVersion does not match local state is
    * rejected before anything is applied. */
   ConvexAssert( !oLive:ProcessTransition( { ;
      "startVersion" => { "querySet" => 9, "identity" => 0, "ts" => "" }, ;
      "endVersion" => { "querySet" => 1, "identity" => 0, "ts" => "AAAAAAAAAAA=" }, ;
      "modifications" => {} } ), "a Transition with the wrong startVersion is rejected" )

   /* A matching Transition applies and delivers a QueryUpdated. */
   ConvexAssert( oLive:ProcessTransition( { ;
      "startVersion" => { "querySet" => 0, "identity" => 0, "ts" => "" }, ;
      "endVersion" => { "querySet" => 1, "identity" => 0, "ts" => "AAAAAAAAAAA=" }, ;
      "modifications" => { { "type" => "QueryUpdated", "queryId" => oLive:aSubs[ "s1" ][ "queryId" ], ;
         "value" => { "count" => 0 } } } } ), "a valid Transition is accepted" )
   ConvexAssert( oLive:aSubs[ "s1" ][ "haveLastValue" ], "the delivered value is cached" )

   /* Retiring marks every still-tracked subscription for rehydration
    * suppression without forgetting it. */
   oLive:Retire( "test" )
   ConvexAssertEqual( Len( oLive:aSubs ), 1, "retire does not drop subscriptions" )
   ConvexAssert( oLive:aSubs[ "s1" ][ "rehydrating" ], "retire marks the subscription rehydrating" )

   /* Re-delivering the same value while rehydrating is suppressed; a
    * genuinely different value is not. */
   oLive:ProcessTransition( { "startVersion" => { "querySet" => 0, "identity" => 0, "ts" => "" }, ;
      "endVersion" => { "querySet" => 1, "identity" => 0, "ts" => "AAAAAAAAAAA=" }, ;
      "modifications" => { { "type" => "QueryUpdated", "queryId" => oLive:aSubs[ "s1" ][ "queryId" ], ;
         "value" => { "count" => 0 } } } } )
   ConvexAssert( !oLive:aSubs[ "s1" ][ "rehydrating" ], ;
      "rehydration ends once a Transition is applied, suppressed or not" )

   /* Unsubscribing removes the tracked subscription entirely. */
   oLive:HandleCommand( { "cmd" => "unsubscribe", "subscriptionId" => "s1", "reply" => hb_mutexCreate() } )
   ConvexAssertEqual( Len( oLive:aSubs ), 0, "unsubscribe removes the tracked subscription" )

   /* Backoff doubles from 100ms (100, 200, 400, 800, 1600, 3200, 6400,
    * 12800 -- the doubling check looks at the value *before* doubling, so
    * 6400 still doubles once more before the cap takes effect), then
    * flattens at 15s and stays there. */
   ConvexAssertEqual( oLive:nBackoffMs, 100, "backoff starts at 100ms" )
   oLive:ScheduleReconnect()
   ConvexAssertEqual( oLive:nBackoffMs, 200, "backoff doubles once" )
   oLive:ScheduleReconnect()
   oLive:ScheduleReconnect()
   oLive:ScheduleReconnect()
   oLive:ScheduleReconnect()
   ConvexAssertEqual( oLive:nBackoffMs, 3200, "backoff keeps doubling under the flat-cap threshold" )
   oLive:ScheduleReconnect()
   ConvexAssertEqual( oLive:nBackoffMs, 6400, "backoff keeps doubling right up to the threshold" )
   oLive:ScheduleReconnect()
   ConvexAssertEqual( oLive:nBackoffMs, 12800, "one more doubling is allowed past the threshold" )
   oLive:ScheduleReconnect()
   ConvexAssertEqual( oLive:nBackoffMs, 15000, "backoff flattens once doubling would exceed the threshold" )
   oLive:ScheduleReconnect()
   ConvexAssertEqual( oLive:nBackoffMs, 15000, "backoff stays at the flat cap" )

   RETURN
