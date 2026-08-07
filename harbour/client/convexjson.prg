/*
 * JSON is a normal library dependency here, not something this client
 * reimplements: hb_jsonEncode()/hb_jsonDecode() are part of Harbour's own
 * core runtime (src/rtl/hbjson.c), not a contrib add-on. What belongs to
 * this client is Convex-specific: validating the JSON-safe numeric subset
 * Convex actually sends, structural equality for Live rehydration
 * suppression, and turning Convex's `logLines` into the array-of-strings
 * the adapter protocol requires.
 */

#include "hbclass.ch"

/* Compact (no indentation) JSON text for an already-decoded Harbour value. */
FUNCTION ConvexJsonEncode( xValue )
   RETURN hb_jsonEncode( xValue )

/* Returns { .T., xValue } on success or { .F., NIL } on any malformed or
 * partially-consumed input. Convex bodies are always exactly one JSON
 * value with nothing trailing, so a decode that stops short of the full
 * text is treated the same as a decode that fails outright. */
FUNCTION ConvexJsonDecode( cText )
   LOCAL xValue, nBytes

   IF ValType( cText ) != "C" .OR. Len( cText ) == 0
      RETURN { .F., NIL }
   ENDIF
   nBytes := hb_jsonDecode( cText, @xValue )
   IF nBytes == 0 .OR. nBytes != Len( cText )
      RETURN { .F., NIL }
   ENDIF
   RETURN { .T., xValue }

/* Convex's JSON encoding represents a whole number as either `1` or `1.0`;
 * this client's job is to accept both without silently truncating a
 * fractional value, and to reject anything that is not actually a
 * mathematically-integral, in-range JSON number: a quoted number (decodes
 * to a Harbour string, so ValType() alone already rejects it), a fraction,
 * or a magnitude outside what fits in a signed 64-bit integer. */
FUNCTION ConvexWholeNumber( xValue )
   IF ValType( xValue ) != "N"
      RETURN .F.
   ENDIF
   IF xValue != Int( xValue )
      RETURN .F.
   ENDIF
   RETURN xValue >= -9223372036854775807 .AND. xValue <= 9223372036854775807

/* Structural equality over the JSON-safe value shapes hb_jsonDecode()
 * produces (NIL, logical, numeric, string, array, hash). Used only to
 * decide whether a Live value delivered right after a reconnect is the
 * same one the subscriber already has, so a resubscribe's replayed
 * snapshot does not print a spurious duplicate update. */
FUNCTION ConvexDeepEqual( a, b )
   LOCAL cType, i, aKeys, cKey

   cType := ValType( a )
   IF cType != ValType( b )
      RETURN .F.
   ENDIF
   DO CASE
   CASE cType == "A"
      IF Len( a ) != Len( b )
         RETURN .F.
      ENDIF
      FOR i := 1 TO Len( a )
         IF !ConvexDeepEqual( a[ i ], b[ i ] )
            RETURN .F.
         ENDIF
      NEXT
      RETURN .T.
   CASE cType == "H"
      aKeys := hb_HKeys( a )
      IF Len( aKeys ) != Len( b )
         RETURN .F.
      ENDIF
      FOR i := 1 TO Len( aKeys )
         cKey := aKeys[ i ]
         IF !hb_HHasKey( b, cKey ) .OR. !ConvexDeepEqual( a[ cKey ], b[ cKey ] )
            RETURN .F.
         ENDIF
      NEXT
      RETURN .T.
   CASE cType == "U"
      RETURN .T.
   OTHERWISE
      RETURN a == b
   ENDCASE

/* The adapter schema requires `logs` (when present at all) to be an array
 * of strings. Convex's own logLines are already strings; anything that
 * somehow were not is re-encoded as JSON text rather than dropped, so no
 * diagnostic silently disappears. Returns NIL (meaning "omit the key")
 * when there are no logs to report, never an empty-but-present array. */
FUNCTION ConvexLogsToStrings( xLogs )
   LOCAL aOut, i, xLine

   IF ValType( xLogs ) != "A" .OR. Len( xLogs ) == 0
      RETURN NIL
   ENDIF
   aOut := {}
   FOR i := 1 TO Len( xLogs )
      xLine := xLogs[ i ]
      IF ValType( xLine ) == "C"
         AAdd( aOut, xLine )
      ELSE
         AAdd( aOut, ConvexJsonEncode( xLine ) )
      ENDIF
   NEXT
   RETURN aOut
