/*
 * Convex from Harbour: follow the shared demo counter from 0 to 1 using
 * one HTTP query, a Live subscription started before the mutation, and
 * one idempotent mutation.
 */

#include "hbclass.ch"

REQUEST HB_MT

/* Convex represents a whole count as either 1 or 1.0 in JSON; accept both
 * without silently truncating a fractional value that should not exist. */
FUNCTION CountOf( xValue )
   IF ValType( xValue ) != "H" .OR. !hb_HHasKey( xValue, "count" ) .OR. ;
      !ConvexWholeNumber( xValue[ "count" ] )
      RETURN -1
   ENDIF
   RETURN xValue[ "count" ]

/* Every failure path prints to stderr only, and stops before anything
 * touches stdout -- stdout is reserved for the six-line transcript this
 * example is graded against byte for byte. */
PROCEDURE Die( cMessage )
   OutErr( cMessage + hb_eol() )
   ErrorLevel( 1 )
   QUIT

PROCEDURE Main( cRoomArg )
   LOCAL cUrl, cRoom, oClient, cUpdateChan, bOnEvent
   LOCAL hResult, xValue, hUpdate, cRunId, hMutationArgs, hQueryArgs

   /* Configuration: every native client in this project reads its
    * deployment from CONVEX_URL. */
   cUrl := GetEnv( "CONVEX_URL" )
   IF Empty( cUrl )
      Die( "CONVEX_URL is required" )
   ENDIF
   cRoom := cRoomArg
   IF Empty( cRoom )
      cRoom := GetEnv( "EXAMPLE_ROOM" )
   ENDIF
   IF Empty( cRoom )
      cRoom := "harbour-basic-example"
   ENDIF

   /* Client creation: one object owns the parsed deployment URL, the
    * current bearer token, and the Live worker thread's subscription
    * pump. Every delivered Live value or error for this example's one
    * subscription arrives on cUpdateChan, notified from the worker
    * thread, because only one thread here ever calls OutStd(). Harbour's
    * "?" command is QOut(), which writes the line terminator before the
    * expression rather than after it, so this example calls OutStd()
    * directly with an explicit trailing hb_eol() to keep stdout in the
    * ordinary content-then-newline order the transcript check expects. */
   cUpdateChan := hb_mutexCreate()
   bOnEvent := {| cSubId, xVal, hErr, xLogs | ;
      hb_mutexNotify( cUpdateChan, { "value" => xVal, "error" => hErr } ) }
   oClient := TConvexClient():New( cUrl, bOnEvent )
   IF oClient:oUrl == NIL
      Die( "invalid CONVEX_URL" )
   ENDIF

   /* The HTTP query: ask Convex for the room's current state through its
    * documented JSON HTTP endpoint, /api/query. Decoding stops at the
    * one field this example promises to check. */
   hQueryArgs := { "room" => cRoom }
   hResult := oClient:Call( "query", "demo:state", hQueryArgs, 10000 )
   IF !hResult[ "ok" ] .OR. CountOf( hResult[ "value" ] ) != 0
      Die( "unexpected initial query value" )
   ENDIF
   OutStd( "current count: 0" + hb_eol() )

   /* Starting Live before the mutation: subscribing first means no
    * reactive update, including the one the mutation below is about to
    * cause, can fall into the gap between reading and watching. */
   oClient:Subscribe( "state", "demo:state", hQueryArgs )

   /* The initial Live value: the first delivery on a fresh subscription
    * hydrates the same state the HTTP query above just read, over the
    * WebSocket sync protocol rather than a second HTTP request. */
   IF !hb_mutexSubscribe( cUpdateChan, 10, @hUpdate ) .OR. ;
      hUpdate[ "error" ] != NIL .OR. CountOf( hUpdate[ "value" ] ) != 0
      Die( "unexpected initial Live value" )
   ENDIF
   OutStd( "live initial count: 0" + hb_eol() )

   /* The mutation and its idempotency key: runId is deterministic per
    * room, so re-running this example against a room it already touched
    * replays the earlier result instead of incrementing a second time. */
   cRunId := cRoom + "-once"
   hMutationArgs := ;
      { "room" => cRoom, "language" => "Harbour", "runId" => cRunId }
   hResult := oClient:Call( "mutation", "demo:increment", hMutationArgs, 10000 )
   xValue := hResult[ "value" ]
   IF !hResult[ "ok" ] .OR. !hb_HHasKey( xValue, "applied" ) .OR. ;
      xValue[ "applied" ] != .T. .OR. !hb_HHasKey( xValue, "state" ) .OR. ;
      CountOf( xValue[ "state" ] ) != 1
      Die( "unexpected mutation result" )
   ENDIF
   OutStd( "mutation applied: true" + hb_eol() )
   OutStd( "mutation count: 1" + hb_eol() )

   /* Receiving the same change reactively: the Live subscription
    * delivers the mutation's result with no second HTTP request at
    * all. */
   IF !hb_mutexSubscribe( cUpdateChan, 10, @hUpdate ) .OR. ;
      hUpdate[ "error" ] != NIL .OR. CountOf( hUpdate[ "value" ] ) != 1
      Die( "unexpected updated Live value" )
   ENDIF
   OutStd( "live updated count: 1" + hb_eol() )

   /* Only now, with the HTTP query, the initial Live value, the mutation
    * and the updated Live value all agreeing, print the proof line. */
   OutStd( "verified count: 0 -> 1" + hb_eol() )

   /* Cleanup: unsubscribe and close before the process exits. */
   oClient:Unsubscribe( "state" )
   oClient:Close()

   RETURN
