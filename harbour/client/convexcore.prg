/*
 * Small utilities shared by every layer of the native Harbour Convex
 * client: a millisecond clock for deadlines, real randomness read
 * straight from the kernel (not Harbour's seeded PRNG) for WebSocket
 * masks and session identifiers, hex encoding, and the one shared
 * shape every Convex-facing error is built from.
 */

#include "hbclass.ch"

/* hb_MilliSeconds() wraps gettimeofday() -- wall-clock, not a monotonic
 * counter, but every deadline in this client is a short-lived "now plus
 * a few seconds" computed and consumed within one process run, so a
 * clock step during that window is a risk this client accepts rather
 * than pulling in a separate C shim for CLOCK_MONOTONIC. */
FUNCTION ConvexNowMs()
   RETURN hb_MilliSeconds()

/* Cryptographically-relevant bytes (WebSocket masks, the Sec-WebSocket-Key,
 * the Live session id) are read directly from /dev/urandom rather than from
 * Harbour's seeded Mersenne-twister hb_RandomInt(), which is fine for test
 * data but not for anything that stands in for unpredictability. */
FUNCTION ConvexRandomBytes( nLen )
   LOCAL nHandle, cBuf, nGot

   nHandle := FOpen( "/dev/urandom" )
   IF nHandle < 0
      RETURN NIL
   ENDIF
   cBuf := Space( nLen )
   nGot := FRead( nHandle, @cBuf, nLen )
   FClose( nHandle )
   IF nGot != nLen
      RETURN NIL
   ENDIF
   RETURN cBuf

FUNCTION ConvexBytesToHex( cBytes )
   LOCAL cDigits := "0123456789abcdef"
   LOCAL cHex := ""
   LOCAL i, nByte

   FOR i := 1 TO Len( cBytes )
      nByte := Asc( SubStr( cBytes, i, 1 ) )
      cHex += SubStr( cDigits, Int( nByte / 16 ) + 1, 1 ) + ;
         SubStr( cDigits, ( nByte % 16 ) + 1, 1 )
   NEXT
   RETURN cHex

FUNCTION ConvexRandomHex( nLen )
   LOCAL cBytes := ConvexRandomBytes( nLen )
   IF cBytes == NIL
      RETURN NIL
   ENDIF
   RETURN ConvexBytesToHex( cBytes )

/* RFC 4122 version-4 UUID, formatted the way every other native client in
 * this project formats the Live sync protocol's sessionId. */
FUNCTION ConvexUuid4()
   LOCAL cBytes := ConvexRandomBytes( 16 )
   LOCAL cHex

   IF cBytes == NIL
      RETURN NIL
   ENDIF
   /* Version 4: high nibble of byte 6 (0-based) is 0100. */
   cBytes := Left( cBytes, 6 ) + ;
      Chr( hb_bitOr( hb_bitAnd( Asc( SubStr( cBytes, 7, 1 ) ), 0x0F ), 0x40 ) ) + ;
      SubStr( cBytes, 8 )
   /* Variant 10xxxxxx: high two bits of byte 8 (0-based). */
   cBytes := Left( cBytes, 8 ) + ;
      Chr( hb_bitOr( hb_bitAnd( Asc( SubStr( cBytes, 9, 1 ) ), 0x3F ), 0x80 ) ) + ;
      SubStr( cBytes, 10 )
   cHex := ConvexBytesToHex( cBytes )
   RETURN SubStr( cHex, 1, 8 ) + "-" + SubStr( cHex, 9, 4 ) + "-" + ;
      SubStr( cHex, 13, 4 ) + "-" + SubStr( cHex, 17, 4 ) + "-" + SubStr( cHex, 21 )

/* The one shape every structured Convex failure -- ProtocolError,
 * TransportError, FunctionError -- is built from. `data` is only present
 * when the caller actually has structured error data to carry (Convex's
 * ConvexError payloads), matching the adapter protocol's "never serialize
 * an absent field as null" rule. */
FUNCTION ConvexNewError( cName, cMessage, xData )
   LOCAL h := { => }

   h[ "name" ] := cName
   h[ "message" ] := cMessage
   IF xData != NIL
      h[ "data" ] := xData
   ENDIF
   RETURN h

FUNCTION ConvexProtocolError( cMessage )
   RETURN ConvexNewError( "ProtocolError", cMessage, NIL )

FUNCTION ConvexTransportError( cMessage )
   RETURN ConvexNewError( "TransportError", cMessage, NIL )
