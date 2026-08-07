/*
 * The Live sync protocol: one background thread (hb_threadStart(), part
 * of core Harbour, REQUEST HB_MT'd in by whichever program links this
 * file) owns the WebSocket exclusively -- every read, every write, every
 * reconnect and every query-set version change happens only inside
 * TConvexLive:RunLoop(), running on that one thread. The controller
 * thread (the adapter's command loop, or the canonical example's main
 * line) never touches the socket directly; it hands subscribe/
 * unsubscribe/debugDisconnect requests to the worker over an
 * hb_mutexNotify()/hb_mutexSubscribe() channel and blocks for the
 * worker's reply, so by the time that reply arrives the worker has
 * already applied the state change -- there is no separate "relay" to
 * invalidate before an acknowledgement, because nothing but the worker
 * ever reads a subscription's state in the first place.
 *
 * Delivered values and errors are handed to the caller through a plain
 * codeblock (bOnEvent), invoked directly on the worker thread. This
 * client keeps no delivery queue at all: the codeblock's own write (to a
 * mutex-guarded stdout in the adapter, or to a per-subscription
 * rendezvous in the example) is the only buffering, and it is bounded by
 * the OS itself -- a stdout pipe's kernel buffer, or a single mailbox
 * slot -- rather than by anything this client allocates. A slow or
 * stopped consumer therefore blocks the worker thread's very next write,
 * not this process's memory; see client/tests/live_backpressure_test.prg
 * for the fixture that proves it under a stopped reader.
 */

#include "hbclass.ch"

#define CONVEX_LIVE_INITIAL_BACKOFF_MS 100
#define CONVEX_LIVE_MAX_BACKOFF_MS 15000
#define CONVEX_LIVE_CONNECT_BUDGET_MS 8000
#define CONVEX_LIVE_TICK_SECONDS 0.05

CREATE CLASS TConvexLive

   VAR cUrl
   VAR bOnEvent
   VAR cmdMutex
   VAR oThread
   VAR lRunning INIT .F.

   /* Touched only from inside RunLoop(), which is to say only ever from
    * the one worker thread once Start() has been called. */
   VAR conn
   VAR oStream
   VAR lConnected INIT .F.
   VAR nConnectionCount INIT 0
   VAR cLastCloseReason INIT ""
   VAR cMaxObservedTs INIT ""
   VAR nRemoteQuerySet INIT 0
   VAR nRemoteIdentity INIT 0
   VAR cRemoteTs INIT ""
   VAR aSubs
   VAR nNextQueryId INIT 1
   VAR nLocalQuerySetVersion INIT 0
   VAR nBackoffMs INIT 100
   VAR nNextConnectAtMs INIT 0
   VAR cSessionId

   METHOD New( cUrl, bOnEvent )
   METHOD Start()
   METHOD Stop()
   METHOD Subscribe( cSubId, cPath, xArgs )
   METHOD Unsubscribe( cSubId )
   METHOD DebugDisconnect()
   METHOD ConnectionCount()
   METHOD RunLoop()

   METHOD SendCommand( h )
   METHOD NextTickWaitSeconds()
   METHOD ServiceTick()
   METHOD HandleServerMessage( cText )
   METHOD ProcessTransition( h )
   METHOD ApplyQueryUpdated( cSubId, oSub, hMod )
   METHOD ApplyQueryFailed( cSubId, oSub, hMod )
   METHOD FindSubByQueryId( nQueryId )
   METHOD DeliverValue( cSubId, xValue, xLogs )
   METHOD DeliverError( cSubId, hError, xLogs )
   METHOD Retire( cReason )
   METHOD ScheduleReconnect()
   METHOD ConnectNow()
   METHOD SendFullQuerySet()
   METHOD HandleCommand( h )
   METHOD DoSubscribe( h )
   METHOD DoUnsubscribe( h )
   METHOD DoDebugDisconnect( h )
   METHOD HandleStop( h )

ENDCLASS

METHOD New( cUrl, bOnEvent ) CLASS TConvexLive
   ::cUrl := cUrl
   ::bOnEvent := bOnEvent
   ::cmdMutex := hb_mutexCreate()
   ::aSubs := { => }
   ::cSessionId := ConvexUuid4()
   RETURN Self

/* Top-level function required as the thread entry point; hb_threadStart()
 * needs a plain function symbol, not a bound method. */
FUNCTION ConvexLiveWorkerEntry( oLive )
   oLive:RunLoop()
   RETURN NIL

METHOD Start() CLASS TConvexLive
   ::lRunning := .T.
   ::oThread := hb_threadStart( @ConvexLiveWorkerEntry(), Self )
   RETURN Self

METHOD Stop() CLASS TConvexLive
   IF !::lRunning
      RETURN Self
   ENDIF
   ::SendCommand( { "cmd" => "stop" } )
   hb_threadJoin( ::oThread )
   ::lRunning := .F.
   RETURN Self

METHOD ConnectionCount() CLASS TConvexLive
   RETURN ::nConnectionCount

/* A one-shot reply mutex makes this a synchronous call into the worker
 * thread: notify the command, then block until the worker's handler for
 * it notifies the reply back. */
METHOD SendCommand( h ) CLASS TConvexLive
   LOCAL cReply, xReply

   cReply := hb_mutexCreate()
   h[ "reply" ] := cReply
   hb_mutexNotify( ::cmdMutex, h )
   hb_mutexSubscribe( cReply, 30, @xReply )
   RETURN xReply

METHOD Subscribe( cSubId, cPath, xArgs ) CLASS TConvexLive
   ::SendCommand( { "cmd" => "subscribe", "subscriptionId" => cSubId, "path" => cPath, "args" => xArgs } )
   RETURN Self

METHOD Unsubscribe( cSubId ) CLASS TConvexLive
   ::SendCommand( { "cmd" => "unsubscribe", "subscriptionId" => cSubId } )
   RETURN Self

METHOD DebugDisconnect() CLASS TConvexLive
   ::SendCommand( { "cmd" => "debugDisconnect" } )
   RETURN Self

/* The worker's own loop: wait for either a controller command or the next
 * moment it needs to act on its own (a reconnect coming due, or a poll of
 * the open socket), then act. Nothing outside this method, running
 * outside this one thread, ever reads oStream or aSubs. */
METHOD RunLoop() CLASS TConvexLive
   LOCAL hCmd

   DO WHILE .T.
      IF hb_mutexSubscribe( ::cmdMutex, ::NextTickWaitSeconds(), @hCmd )
         IF hCmd[ "cmd" ] == "stop"
            ::HandleStop( hCmd )
            EXIT
         ENDIF
         ::HandleCommand( hCmd )
      ENDIF
      ::ServiceTick()
   ENDDO
   RETURN Self

/* While connected, a short fixed tick keeps socket-readability polling
 * responsive; while waiting out a reconnect backoff, wait no longer than
 * the backoff itself needs (capped at one second so a shutdown request
 * is never more than a second from being noticed even without the
 * mutex's own immediate wakeup on notify). */
METHOD NextTickWaitSeconds() CLASS TConvexLive
   LOCAL nRemainMs

   IF ::lConnected
      RETURN CONVEX_LIVE_TICK_SECONDS
   ENDIF
   nRemainMs := ::nNextConnectAtMs - ConvexNowMs()
   IF nRemainMs <= 50
      RETURN CONVEX_LIVE_TICK_SECONDS
   ENDIF
   IF nRemainMs > 1000
      RETURN 1
   ENDIF
   RETURN nRemainMs / 1000

METHOD ServiceTick() CLASS TConvexLive
   LOCAL oMsg

   IF !::lConnected
      IF ConvexNowMs() >= ::nNextConnectAtMs
         ::ConnectNow()
      ENDIF
      RETURN Self
   ENDIF

   IF !hb_inetDataReady( ::conn[ "sock" ], 0 )
      RETURN Self
   ENDIF

   ::oStream[ "deadline" ] := ConvexNowMs() + 5000
   oMsg := ConvexWsReadMessage( ::oStream )
   IF oMsg == NIL
      ::Retire( "Live connection failed" )
      ::ScheduleReconnect()
      RETURN Self
   ENDIF
   IF oMsg[ "opcode" ] == CONVEX_WS_OP_CLOSE
      ::Retire( "Live server closed the WebSocket" )
      ::ScheduleReconnect()
      RETURN Self
   ENDIF
   IF oMsg[ "opcode" ] == CONVEX_WS_OP_PING .OR. oMsg[ "opcode" ] == CONVEX_WS_OP_PONG
      RETURN Self
   ENDIF
   IF oMsg[ "opcode" ] != CONVEX_WS_OP_TEXT
      ::Retire( "Live connection received a non-text frame" )
      ::ScheduleReconnect()
      RETURN Self
   ENDIF

   ::HandleServerMessage( oMsg[ "payload" ] )
   RETURN Self

METHOD HandleServerMessage( cText ) CLASS TConvexLive
   LOCAL aDecoded, h, cType

   aDecoded := ConvexJsonDecode( cText )
   IF !aDecoded[ 1 ] .OR. ValType( aDecoded[ 2 ] ) != "H" .OR. !hb_HHasKey( aDecoded[ 2 ], "type" )
      ::Retire( "Live received a malformed message" )
      ::ScheduleReconnect()
      RETURN Self
   ENDIF
   h := aDecoded[ 2 ]
   cType := h[ "type" ]
   DO CASE
   CASE cType == "Transition"
      IF ::ProcessTransition( h )
         ::nBackoffMs := CONVEX_LIVE_INITIAL_BACKOFF_MS
      ELSE
         ::Retire( "Live received an invalid Transition" )
         ::ScheduleReconnect()
      ENDIF
   CASE cType == "Ping" .OR. cType == "MutationResponse" .OR. cType == "ActionResponse"
      /* Recognized, and irrelevant to a client that never mutates or
       * acts over the socket -- see the manifest's limitations. */
   OTHERWISE
      ::Retire( "Live received an unrecognized message type" )
      ::ScheduleReconnect()
   ENDCASE
   RETURN Self

/* Validates every modification before applying any of them, so a
 * malformed Transition never leaves the subscription table half
 * updated. */
METHOD ProcessTransition( h ) CLASS TConvexLive
   LOCAL hStart, hEnd, aMods, i, hMod, cModType, cSubId, oSub

   IF !hb_HHasKey( h, "startVersion" ) .OR. !hb_HHasKey( h, "endVersion" ) .OR. ;
      !hb_HHasKey( h, "modifications" )
      RETURN .F.
   ENDIF
   hStart := h[ "startVersion" ]
   hEnd := h[ "endVersion" ]
   aMods := h[ "modifications" ]
   IF ValType( hStart ) != "H" .OR. ValType( hEnd ) != "H" .OR. ValType( aMods ) != "A"
      RETURN .F.
   ENDIF
   IF !hb_HHasKey( hStart, "querySet" ) .OR. !hb_HHasKey( hStart, "identity" ) .OR. !hb_HHasKey( hStart, "ts" )
      RETURN .F.
   ENDIF
   IF hStart[ "querySet" ] != ::nRemoteQuerySet .OR. hStart[ "identity" ] != ::nRemoteIdentity .OR. ;
      hStart[ "ts" ] != ::cRemoteTs
      RETURN .F.
   ENDIF

   FOR i := 1 TO Len( aMods )
      hMod := aMods[ i ]
      IF ValType( hMod ) != "H" .OR. !hb_HHasKey( hMod, "type" ) .OR. !hb_HHasKey( hMod, "queryId" )
         RETURN .F.
      ENDIF
      cModType := hMod[ "type" ]
      IF cModType == "QueryUpdated"
         IF !hb_HHasKey( hMod, "value" )
            RETURN .F.
         ENDIF
      ELSEIF cModType == "QueryFailed"
         IF !hb_HHasKey( hMod, "errorMessage" )
            RETURN .F.
         ENDIF
      ELSEIF cModType != "QueryRemoved"
         RETURN .F.
      ENDIF
   NEXT

   FOR i := 1 TO Len( aMods )
      hMod := aMods[ i ]
      cSubId := ::FindSubByQueryId( hMod[ "queryId" ] )
      IF cSubId != NIL
         oSub := ::aSubs[ cSubId ]
         cModType := hMod[ "type" ]
         IF cModType == "QueryUpdated"
            ::ApplyQueryUpdated( cSubId, oSub, hMod )
         ELSEIF cModType == "QueryFailed"
            ::ApplyQueryFailed( cSubId, oSub, hMod )
         ENDIF
      ENDIF
   NEXT

   ::nRemoteQuerySet := hEnd[ "querySet" ]
   ::nRemoteIdentity := hEnd[ "identity" ]
   ::cRemoteTs := hEnd[ "ts" ]
   ::cMaxObservedTs := hEnd[ "ts" ]
   RETURN .T.

/* Suppresses only a value that is byte-for-byte the same as the value
 * this subscription already delivered before its connection dropped --
 * the resend-everything resubscribe after a reconnect would otherwise
 * print a spurious duplicate for every subscription whose value simply
 * did not change while disconnected. */
METHOD ApplyQueryUpdated( cSubId, oSub, hMod ) CLASS TConvexLive
   LOCAL xValue, xLogs, lSuppress

   xValue := hMod[ "value" ]
   xLogs := IIf( hb_HHasKey( hMod, "logLines" ), hMod[ "logLines" ], NIL )
   lSuppress := oSub[ "rehydrating" ] .AND. oSub[ "haveLastValue" ] .AND. ;
      ConvexDeepEqual( oSub[ "lastValue" ], xValue )
   oSub[ "rehydrating" ] := .F.
   oSub[ "haveLastValue" ] := .T.
   oSub[ "lastValue" ] := xValue
   IF !lSuppress
      ::DeliverValue( cSubId, xValue, xLogs )
   ENDIF
   RETURN Self

METHOD ApplyQueryFailed( cSubId, oSub, hMod ) CLASS TConvexLive
   LOCAL hErr, xLogs, xData

   xData := IIf( hb_HHasKey( hMod, "errorData" ), hMod[ "errorData" ], NIL )
   hErr := ConvexNewError( "FunctionError", hMod[ "errorMessage" ], xData )
   xLogs := IIf( hb_HHasKey( hMod, "logLines" ), hMod[ "logLines" ], NIL )
   oSub[ "rehydrating" ] := .F.
   oSub[ "haveLastValue" ] := .F.
   ::DeliverError( cSubId, hErr, xLogs )
   RETURN Self

METHOD FindSubByQueryId( nQueryId ) CLASS TConvexLive
   LOCAL aKeys, i

   aKeys := hb_HKeys( ::aSubs )
   FOR i := 1 TO Len( aKeys )
      IF ::aSubs[ aKeys[ i ] ][ "queryId" ] == nQueryId
         RETURN aKeys[ i ]
      ENDIF
   NEXT
   RETURN NIL

METHOD DeliverValue( cSubId, xValue, xLogs ) CLASS TConvexLive
   IF ::bOnEvent != NIL
      Eval( ::bOnEvent, cSubId, xValue, NIL, xLogs )
   ENDIF
   RETURN Self

METHOD DeliverError( cSubId, hError, xLogs ) CLASS TConvexLive
   IF ::bOnEvent != NIL
      Eval( ::bOnEvent, cSubId, NIL, hError, xLogs )
   ENDIF
   RETURN Self

/* Tears the connection down and marks every still-active subscription
 * for rehydration-suppression, but never touches the subscription table
 * itself -- a caller's earlier subscribe/unsubscribe is not undone by a
 * transport failure. */
METHOD Retire( cReason ) CLASS TConvexLive
   LOCAL aKeys, i

   IF ::conn != NIL
      ConvexClose( ::conn )
   ENDIF
   ::conn := NIL
   ::oStream := NIL
   ::lConnected := .F.
   ::nConnectionCount++
   ::cLastCloseReason := cReason
   ::nRemoteQuerySet := 0
   ::nRemoteIdentity := 0
   ::cRemoteTs := ""
   aKeys := hb_HKeys( ::aSubs )
   FOR i := 1 TO Len( aKeys )
      ::aSubs[ aKeys[ i ] ][ "rehydrating" ] := .T.
   NEXT
   RETURN Self

METHOD ScheduleReconnect() CLASS TConvexLive
   ::nNextConnectAtMs := ConvexNowMs() + ::nBackoffMs
   ::nBackoffMs := IIf( ::nBackoffMs < 7500, ::nBackoffMs * 2, CONVEX_LIVE_MAX_BACKOFF_MS )
   RETURN Self

METHOD ConnectNow() CLASS TConvexLive
   LOCAL conn, hHandshake, hConnectMsg, nBudget

   nBudget := ConvexNowMs() + CONVEX_LIVE_CONNECT_BUDGET_MS
   conn := ConvexConnect( ::cUrl[ "host" ], ::cUrl[ "port" ], ::cUrl[ "tls" ], nBudget )
   IF !conn[ "ok" ]
      ::ScheduleReconnect()
      RETURN Self
   ENDIF

   hHandshake := ConvexWsHandshake( conn, ::cUrl[ "host" ], "/api/sync", nBudget )
   IF !hHandshake[ "ok" ]
      ConvexClose( conn )
      ::ScheduleReconnect()
      RETURN Self
   ENDIF

   ::conn := conn
   ::oStream := hHandshake[ "stream" ]
   ::lConnected := .T.

   hConnectMsg := { "type" => "Connect", "sessionId" => ::cSessionId, ;
      "connectionCount" => ::nConnectionCount, "lastCloseReason" => ::cLastCloseReason, "clientTs" => 0 }
   IF !Empty( ::cMaxObservedTs )
      hConnectMsg[ "maxObservedTimestamp" ] := ::cMaxObservedTs
   ENDIF
   IF !ConvexWsSendFrame( ::conn, CONVEX_WS_OP_TEXT, ConvexJsonEncode( hConnectMsg ) )
      ::Retire( "failed sending Connect" )
      ::ScheduleReconnect()
      RETURN Self
   ENDIF

   ::SendFullQuerySet()
   ::nBackoffMs := CONVEX_LIVE_INITIAL_BACKOFF_MS
   RETURN Self

/* One full resnapshot Add for every currently-tracked subscription --
 * simpler than trying to replay the exact incremental history, and safe
 * because ApplyQueryUpdated() already suppresses an unchanged value. */
METHOD SendFullQuerySet() CLASS TConvexLive
   LOCAL aKeys, i, oSub, aMods, hMsg

   aKeys := hb_HKeys( ::aSubs )
   IF Len( aKeys ) == 0
      RETURN Self
   ENDIF
   aMods := {}
   FOR i := 1 TO Len( aKeys )
      oSub := ::aSubs[ aKeys[ i ] ]
      AAdd( aMods, { "type" => "Add", "queryId" => oSub[ "queryId" ], ;
         "udfPath" => oSub[ "path" ], "args" => { oSub[ "args" ] } } )
   NEXT
   ::nLocalQuerySetVersion := 1
   hMsg := { "type" => "ModifyQuerySet", "baseVersion" => 0, "newVersion" => 1, "modifications" => aMods }
   ConvexWsSendFrame( ::conn, CONVEX_WS_OP_TEXT, ConvexJsonEncode( hMsg ) )
   RETURN Self

METHOD HandleCommand( h ) CLASS TConvexLive
   DO CASE
   CASE h[ "cmd" ] == "subscribe"
      ::DoSubscribe( h )
   CASE h[ "cmd" ] == "unsubscribe"
      ::DoUnsubscribe( h )
   CASE h[ "cmd" ] == "debugDisconnect"
      ::DoDebugDisconnect( h )
   ENDCASE
   RETURN Self

METHOD DoSubscribe( h ) CLASS TConvexLive
   LOCAL cSubId, oSub, hMod, hMsg

   cSubId := h[ "subscriptionId" ]
   oSub := { "queryId" => ::nNextQueryId, "path" => h[ "path" ], "args" => h[ "args" ], ;
      "rehydrating" => .F., "haveLastValue" => .F., "lastValue" => NIL }
   ::nNextQueryId++
   ::aSubs[ cSubId ] := oSub

   IF ::lConnected
      ::nLocalQuerySetVersion++
      hMod := { "type" => "Add", "queryId" => oSub[ "queryId" ], "udfPath" => oSub[ "path" ], ;
         "args" => { oSub[ "args" ] } }
      hMsg := { "type" => "ModifyQuerySet", "baseVersion" => ::nLocalQuerySetVersion - 1, ;
         "newVersion" => ::nLocalQuerySetVersion, "modifications" => { hMod } }
      ConvexWsSendFrame( ::conn, CONVEX_WS_OP_TEXT, ConvexJsonEncode( hMsg ) )
   ENDIF

   hb_mutexNotify( h[ "reply" ], .T. )
   RETURN Self

METHOD DoUnsubscribe( h ) CLASS TConvexLive
   LOCAL cSubId, oSub, hMod, hMsg

   cSubId := h[ "subscriptionId" ]
   IF hb_HHasKey( ::aSubs, cSubId )
      oSub := ::aSubs[ cSubId ]
      hb_HDel( ::aSubs, cSubId )
      IF ::lConnected
         ::nLocalQuerySetVersion++
         hMod := { "type" => "Remove", "queryId" => oSub[ "queryId" ] }
         hMsg := { "type" => "ModifyQuerySet", "baseVersion" => ::nLocalQuerySetVersion - 1, ;
            "newVersion" => ::nLocalQuerySetVersion, "modifications" => { hMod } }
         ConvexWsSendFrame( ::conn, CONVEX_WS_OP_TEXT, ConvexJsonEncode( hMsg ) )
      ENDIF
   ENDIF
   hb_mutexNotify( h[ "reply" ], .T. )
   RETURN Self

/* Retiring the connection before replying is what makes debugDisconnect's
 * acknowledgement mean what the harness needs it to mean: by the time the
 * caller sees the ack, the old connection is already gone and a
 * reconnect is already scheduled, so nothing the old connection could
 * still deliver can race the ack across the wire. */
METHOD DoDebugDisconnect( h ) CLASS TConvexLive
   IF ::lConnected
      ::Retire( "DebugDisconnect" )
   ENDIF
   ::nNextConnectAtMs := ConvexNowMs() + CONVEX_LIVE_INITIAL_BACKOFF_MS
   ::nBackoffMs := CONVEX_LIVE_INITIAL_BACKOFF_MS * 2
   hb_mutexNotify( h[ "reply" ], .T. )
   RETURN Self

METHOD HandleStop( h ) CLASS TConvexLive
   IF ::lConnected
      ConvexWsSendClose( ::conn )
      ::Retire( "shutdown" )
   ENDIF
   hb_mutexNotify( h[ "reply" ], .T. )
   RETURN Self
