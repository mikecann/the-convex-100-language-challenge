/*
 * NDJSON adapter protocol v1: one command per input line, one event per
 * output line, stdout reserved entirely for protocol events with every
 * diagnostic going to stderr instead. This file is test infrastructure,
 * not public client code -- it exists to let the shared black-box
 * conformance harness drive client/convex.prg the same way any real
 * Harbour program would.
 *
 * The command loop runs on the main thread and only ever performs
 * synchronous work: HTTP calls, and RPCs into the Live worker thread
 * that convex.prg's TConvexClient already owns. Every line this process
 * writes -- a command's own response, and any asynchronous "subscription"
 * event the Live worker delivers on its own thread -- goes through
 * ConvexAdapterEmitEvent(), which holds one shared mutex for the
 * duration of the write so two threads can never interleave partial
 * JSON lines on stdout.
 */

#include "hbclass.ch"

REQUEST HB_MT

PROCEDURE Main()
   LOCAL cUrl, oClient, oTransport, gWriteMutex, bEmit
   LOCAL cLine, aDecoded, hCmd, lClosed

   oTransport := ConvexAdapterOpenTransport()
   IF oTransport == NIL
      OutErr( "could not open adapter transport" + hb_eol() )
      ErrorLevel( 1 )
      RETURN
   ENDIF

   gWriteMutex := hb_mutexCreate()
   bEmit := {| cSubId, xValue, hError, xLogs | ;
      ConvexAdapterEmitSubscription( oTransport, gWriteMutex, cSubId, xValue, hError, xLogs ) }

   cUrl := GetEnv( "CONVEX_URL" )
   IF !Empty( cUrl ) .AND. ConvexParseUrl( cUrl ) != NIL
      oClient := TConvexClient():New( cUrl, bEmit )
   ELSE
      oClient := NIL
   ENDIF

   lClosed := .F.
   DO WHILE !lClosed
      cLine := ConvexAdapterReadLine( oTransport )
      IF cLine == NIL
         EXIT
      ENDIF
      IF Empty( AllTrim( cLine ) )
         LOOP
      ENDIF
      aDecoded := ConvexJsonDecode( cLine )
      IF !aDecoded[ 1 ] .OR. ValType( aDecoded[ 2 ] ) != "H"
         ConvexAdapterEmitEvent( oTransport, gWriteMutex, ;
            { "type" => "error", "error" => ConvexProtocolError( "malformed adapter command" ) } )
         LOOP
      ENDIF
      hCmd := aDecoded[ 2 ]
      lClosed := ConvexAdapterHandle( oTransport, gWriteMutex, oClient, hCmd )
   ENDDO

   IF oClient != NIL
      oClient:Close()
   ENDIF
   IF oTransport[ "kind" ] == "tcp"
      hb_inetClose( oTransport[ "sock" ] )
   ENDIF

   RETURN

/* stdin/stdout when ADAPTER_LISTEN is unset; otherwise a listening socket
 * on host:port that accepts exactly one controller connection and then
 * stops listening, matching every other native client's adapter in this
 * project. */
FUNCTION ConvexAdapterOpenTransport()
   LOCAL cListen, nColon, cHost, nPort, sockSrv, sockConn

   cListen := GetEnv( "ADAPTER_LISTEN" )
   IF Empty( cListen )
      RETURN { "kind" => "stdin", "buf" => "", "eof" => .F. }
   ENDIF

   nColon := RAt( ":", cListen )
   IF nColon <= 1
      RETURN NIL
   ENDIF
   cHost := Left( cListen, nColon - 1 )
   nPort := Val( SubStr( cListen, nColon + 1 ) )

   sockSrv := hb_inetServer( nPort, NIL, cHost )
   IF Empty( sockSrv )
      RETURN NIL
   ENDIF
   hb_inetTimeout( sockSrv, 60000 )
   sockConn := hb_inetAccept( sockSrv )
   hb_inetClose( sockSrv )
   IF Empty( sockConn )
      RETURN NIL
   ENDIF
   RETURN { "kind" => "tcp", "sock" => sockConn }

FUNCTION ConvexAdapterStdinLine( oSrc )
   LOCAL nPos, cLine, cBuf, nGot

   DO WHILE .T.
      nPos := At( Chr( 10 ), oSrc[ "buf" ] )
      IF nPos > 0
         cLine := Left( oSrc[ "buf" ], nPos - 1 )
         oSrc[ "buf" ] := SubStr( oSrc[ "buf" ], nPos + 1 )
         IF Right( cLine, 1 ) == Chr( 13 )
            cLine := Left( cLine, Len( cLine ) - 1 )
         ENDIF
         RETURN cLine
      ENDIF
      IF oSrc[ "eof" ]
         RETURN NIL
      ENDIF
      cBuf := Space( 4096 )
      nGot := FRead( 0, @cBuf, 4096 )
      IF nGot <= 0
         oSrc[ "eof" ] := .T.
      ELSE
         oSrc[ "buf" ] += Left( cBuf, nGot )
      ENDIF
   ENDDO
   RETURN NIL

FUNCTION ConvexAdapterReadLine( oTransport )
   LOCAL cLine

   IF oTransport[ "kind" ] == "stdin"
      RETURN ConvexAdapterStdinLine( oTransport )
   ENDIF
   cLine := hb_inetRecvLine( oTransport[ "sock" ] )
   IF hb_inetErrorCode( oTransport[ "sock" ] ) != 0
      RETURN NIL
   ENDIF
   RETURN cLine

FUNCTION ConvexAdapterEmitEvent( oTransport, gWriteMutex, h )
   LOCAL cLine

   cLine := ConvexJsonEncode( h )
   hb_mutexLock( gWriteMutex )
   IF oTransport[ "kind" ] == "stdin"
      FWrite( 1, cLine + Chr( 10 ) )
   ELSE
      hb_inetSendAll( oTransport[ "sock" ], cLine + Chr( 10 ) )
   ENDIF
   hb_mutexUnlock( gWriteMutex )
   RETURN NIL

FUNCTION ConvexAdapterBuildEvent( cId, cType )
   LOCAL h := { "type" => cType }

   IF !Empty( cId )
      h[ "id" ] := cId
   ENDIF
   RETURN h

FUNCTION ConvexAdapterErrorEvent( cId, hError, xLogs )
   LOCAL h := ConvexAdapterBuildEvent( cId, "error" )

   h[ "error" ] := hError
   IF xLogs != NIL
      h[ "logs" ] := xLogs
   ENDIF
   RETURN h

FUNCTION ConvexAdapterEmitSubscription( oTransport, gWriteMutex, cSubId, xValue, hError, xLogs )
   LOCAL h := { "type" => "subscription", "subscriptionId" => cSubId }

   IF hError != NIL
      h[ "error" ] := hError
   ELSE
      h[ "value" ] := xValue
   ENDIF
   IF xLogs != NIL
      h[ "logs" ] := xLogs
   ENDIF
   ConvexAdapterEmitEvent( oTransport, gWriteMutex, h )
   RETURN NIL

/* Returns .T. only for "close", so the caller's command loop can stop
 * reading once the "closed" event for it has already been written. */
FUNCTION ConvexAdapterHandle( oTransport, gWriteMutex, oClient, hCmd )
   LOCAL cOp, cId, h

   cOp := IIf( hb_HHasKey( hCmd, "op" ), hCmd[ "op" ], "" )
   cId := IIf( hb_HHasKey( hCmd, "id" ), hCmd[ "id" ], "" )

   DO CASE
   CASE cOp == "hello"
      h := ConvexAdapterBuildEvent( cId, "ready" )
      h[ "protocolVersion" ] := 1
      h[ "language" ] := "harbour"
      h[ "implementation" ] := "native-harbour-3.2.0-hbssl"
      h[ "runtime" ] := "Harbour 3.2.0"
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, h )
      RETURN .F.

   CASE cOp == "query" .OR. cOp == "mutation" .OR. cOp == "action"
      ConvexAdapterHandleCall( oTransport, gWriteMutex, oClient, cId, cOp, hCmd )
      RETURN .F.

   CASE cOp == "setAuth"
      IF oClient != NIL
         oClient:SetAuth( IIf( hb_HHasKey( hCmd, "token" ), hCmd[ "token" ], "" ) )
      ENDIF
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ConvexAdapterBuildEvent( cId, "ack" ) )
      RETURN .F.

   CASE cOp == "subscribe"
      IF oClient != NIL .AND. hb_HHasKey( hCmd, "subscriptionId" ) .AND. hb_HHasKey( hCmd, "path" )
         oClient:Subscribe( hCmd[ "subscriptionId" ], hCmd[ "path" ], ;
            IIf( hb_HHasKey( hCmd, "args" ), hCmd[ "args" ], { => } ) )
      ENDIF
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ConvexAdapterBuildEvent( cId, "ack" ) )
      RETURN .F.

   CASE cOp == "unsubscribe"
      IF oClient != NIL .AND. hb_HHasKey( hCmd, "subscriptionId" )
         oClient:Unsubscribe( hCmd[ "subscriptionId" ] )
      ENDIF
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ConvexAdapterBuildEvent( cId, "ack" ) )
      RETURN .F.

   CASE cOp == "debugDisconnect"
      IF oClient != NIL
         oClient:DebugDisconnect()
      ENDIF
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ConvexAdapterBuildEvent( cId, "ack" ) )
      RETURN .F.

   CASE cOp == "close"
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ConvexAdapterBuildEvent( cId, "closed" ) )
      RETURN .T.

   OTHERWISE
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ;
         ConvexAdapterErrorEvent( cId, ConvexProtocolError( "unknown adapter operation" ), NIL ) )
      RETURN .F.
   ENDCASE

FUNCTION ConvexAdapterHandleCall( oTransport, gWriteMutex, oClient, cId, cOp, hCmd )
   LOCAL cPath, xArgs, hResult, h

   IF oClient == NIL
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ;
         ConvexAdapterErrorEvent( cId, ConvexTransportError( "no Convex deployment configured" ), NIL ) )
      RETURN NIL
   ENDIF

   cPath := IIf( hb_HHasKey( hCmd, "path" ), hCmd[ "path" ], "" )
   xArgs := IIf( hb_HHasKey( hCmd, "args" ), hCmd[ "args" ], NIL )
   IF ValType( xArgs ) != "H"
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ;
         ConvexAdapterErrorEvent( cId, ConvexProtocolError( "Convex arguments must be a JSON object" ), NIL ) )
      RETURN NIL
   ENDIF

   hResult := oClient:Call( cOp, cPath, xArgs, 30000 )
   IF hResult[ "ok" ]
      h := ConvexAdapterBuildEvent( cId, "result" )
      h[ "value" ] := hResult[ "value" ]
      IF hb_HHasKey( hResult, "logs" ) .AND. hResult[ "logs" ] != NIL
         h[ "logs" ] := hResult[ "logs" ]
      ENDIF
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, h )
   ELSE
      ConvexAdapterEmitEvent( oTransport, gWriteMutex, ;
         ConvexAdapterErrorEvent( cId, hResult[ "error" ], ;
            IIf( hb_HHasKey( hResult, "logs" ), hResult[ "logs" ], NIL ) ) )
   ENDIF
   RETURN NIL
