/*
 * Convex's documented JSON HTTP functions: POST a { path, args, format }
 * envelope to /api/query, /api/mutation or /api/action and decode the
 * { status, value|errorMessage, logLines } envelope it returns. The
 * request/response framing (status line, headers, Content-Length and
 * chunked bodies) is hand-built over the raw socket from convextls.prg --
 * Harbour has no HTTP client of its own to delegate to -- while the
 * connection is always closed after one exchange (`Connection: close`),
 * which is what makes reading the body without a framing library honest:
 * no other request can ever share this socket's byte stream.
 */

#include "hbclass.ch"

FUNCTION ConvexParseUrl( cUrl )
   LOCAL lTls, cRest, nSlash, nColon, cHost, nPort

   IF Lower( Left( cUrl, 8 ) ) == "https://"
      lTls := .T.
      cRest := SubStr( cUrl, 9 )
   ELSEIF Lower( Left( cUrl, 7 ) ) == "http://"
      lTls := .F.
      cRest := SubStr( cUrl, 8 )
   ELSE
      RETURN NIL
   ENDIF

   nSlash := At( "/", cRest )
   IF nSlash > 0
      cRest := Left( cRest, nSlash - 1 )
   ENDIF
   nColon := At( ":", cRest )
   IF nColon > 0
      cHost := Left( cRest, nColon - 1 )
      nPort := Val( SubStr( cRest, nColon + 1 ) )
   ELSE
      cHost := cRest
      nPort := IIf( lTls, 443, 80 )
   ENDIF
   IF Empty( cHost ) .OR. nPort <= 0
      RETURN NIL
   ENDIF
   RETURN { "tls" => lTls, "host" => cHost, "port" => nPort }

/* A small buffered reader over one HTTP response, refilled from the raw
 * socket in convextls.prg. Harbour hashes are reference types, so every
 * helper below mutates the same stream hash the caller holds -- there is
 * no by-reference parameter juggling anywhere in this file. */
FUNCTION ConvexStreamNew( conn, nDeadlineMs )
   RETURN { "conn" => conn, "buf" => "", "deadline" => nDeadlineMs, "eof" => .F. }

FUNCTION ConvexStreamFill( oStream )
   LOCAL cChunk

   cChunk := ConvexSockRead( oStream[ "conn" ], 8192, oStream[ "deadline" ] )
   IF cChunk == NIL
      RETURN .F.
   ENDIF
   IF Len( cChunk ) == 0
      oStream[ "eof" ] := .T.
      RETURN .F.
   ENDIF
   oStream[ "buf" ] += cChunk
   RETURN .T.

/* One CRLF- or LF-terminated line, terminator stripped. NIL if the stream
 * ends, errors, or a single line grows past a defensive 16 KiB cap before
 * a terminator ever shows up -- a well-behaved HTTP/1.1 server never
 * sends a status or header line anywhere near that long. */
FUNCTION ConvexStreamLine( oStream )
   LOCAL nPos, cLine

   DO WHILE .T.
      nPos := At( Chr( 10 ), oStream[ "buf" ] )
      IF nPos > 0
         cLine := Left( oStream[ "buf" ], nPos - 1 )
         oStream[ "buf" ] := SubStr( oStream[ "buf" ], nPos + 1 )
         IF Right( cLine, 1 ) == Chr( 13 )
            cLine := Left( cLine, Len( cLine ) - 1 )
         ENDIF
         RETURN cLine
      ENDIF
      IF Len( oStream[ "buf" ] ) > 16384 .OR. !ConvexStreamFill( oStream )
         RETURN NIL
      ENDIF
   ENDDO
   RETURN NIL

/* Exactly nLen bytes, or NIL if the stream ends first. */
FUNCTION ConvexStreamExact( oStream, nLen )
   LOCAL cResult

   DO WHILE Len( oStream[ "buf" ] ) < nLen
      IF !ConvexStreamFill( oStream )
         RETURN NIL
      ENDIF
   ENDDO
   cResult := Left( oStream[ "buf" ], nLen )
   oStream[ "buf" ] := SubStr( oStream[ "buf" ], nLen + 1 )
   RETURN cResult

/* Everything up to a clean EOF, bounded by nCap; NIL if the connection
 * broke instead of reaching EOF, or the body would exceed the cap. */
FUNCTION ConvexStreamToEnd( oStream, nCap )
   DO WHILE ConvexStreamFill( oStream )
      IF Len( oStream[ "buf" ] ) > nCap
         RETURN NIL
      ENDIF
   ENDDO
   IF !oStream[ "eof" ]
      RETURN NIL
   ENDIF
   RETURN oStream[ "buf" ]

/* RFC 7230 chunked transfer-encoding. Chunk sizes are capped at six hex
 * digits (16 MiB), matching the ALGOL 60 client's same defensive bound,
 * and the assembled body is capped by nCap regardless of how many small
 * chunks it takes to get there. */
FUNCTION ConvexStreamChunked( oStream, nCap )
   LOCAL cBody, cSizeLine, nSize, cChunk, cTrailer

   cBody := ""
   DO WHILE .T.
      cSizeLine := ConvexStreamLine( oStream )
      IF cSizeLine == NIL .OR. Len( cSizeLine ) == 0 .OR. Len( cSizeLine ) > 6
         RETURN NIL
      ENDIF
      nSize := hb_HexToNum( cSizeLine )
      IF nSize == NIL .OR. nSize < 0
         RETURN NIL
      ENDIF
      IF nSize == 0
         DO WHILE .T.
            cTrailer := ConvexStreamLine( oStream )
            IF cTrailer == NIL
               RETURN NIL
            ENDIF
            IF Empty( cTrailer )
               EXIT
            ENDIF
         ENDDO
         RETURN cBody
      ENDIF
      cBody += Space( nSize )
      cChunk := ConvexStreamExact( oStream, nSize )
      IF cChunk == NIL .OR. ConvexStreamLine( oStream ) == NIL
         RETURN NIL
      ENDIF
      cBody := Left( cBody, Len( cBody ) - nSize ) + cChunk
      IF Len( cBody ) > nCap
         RETURN NIL
      ENDIF
   ENDDO
   RETURN NIL

/* Convex's response envelope. cStatus is the HTTP status line's numeric
 * code; the envelope's own JSON "status" field ("success"/"error") is
 * what actually decides whether this is a FunctionError, not the HTTP
 * status code, matching every other client in this project. */
FUNCTION ConvexHttpReadResponse( conn, nDeadlineMs )
   LOCAL oStream, cStatusLine

   oStream := ConvexStreamNew( conn, nDeadlineMs )
   cStatusLine := ConvexStreamLine( oStream )
   IF cStatusLine == NIL .OR. Left( cStatusLine, 5 ) != "HTTP/"
      RETURN { "ok" => .F., "error" => ConvexTransportError( "no HTTP status line" ) }
   ENDIF
   RETURN ConvexHttpParseHeadersAndBody( oStream )

/* Everything after the status line: headers, the body (Content-Length,
 * chunked, or read-to-EOF), and Convex's own JSON envelope. Split out
 * from ConvexHttpReadResponse() so client/tests/client_test.prg can drive
 * it from a stream whose buffer was filled by hand, with no socket or
 * status line involved. */
FUNCTION ConvexHttpParseHeadersAndBody( oStream )
   LOCAL cHeaderLine, nContentLength, lChunked
   LOCAL nColon, cName, cValue, cBody, aDecoded, xEnvelope
   LOCAL cStatus, xValue, hasValue, xLogs, cErrorMessage, xErrorData

   nContentLength := -1
   lChunked := .F.
   DO WHILE .T.
      cHeaderLine := ConvexStreamLine( oStream )
      IF cHeaderLine == NIL
         RETURN { "ok" => .F., "error" => ConvexTransportError( "HTTP headers truncated" ) }
      ENDIF
      IF Empty( cHeaderLine )
         EXIT
      ENDIF
      nColon := At( ":", cHeaderLine )
      IF nColon > 0
         cName := Lower( AllTrim( Left( cHeaderLine, nColon - 1 ) ) )
         cValue := AllTrim( SubStr( cHeaderLine, nColon + 1 ) )
         IF cName == "content-length"
            nContentLength := Val( cValue )
         ELSEIF cName == "transfer-encoding"
            lChunked := Lower( cValue ) == "chunked"
         ENDIF
      ENDIF
   ENDDO

   IF lChunked
      cBody := ConvexStreamChunked( oStream, 8388608 )
   ELSEIF nContentLength >= 0
      cBody := ConvexStreamExact( oStream, nContentLength )
   ELSE
      cBody := ConvexStreamToEnd( oStream, 8388608 )
   ENDIF
   IF cBody == NIL
      RETURN { "ok" => .F., "error" => ConvexTransportError( "HTTP response body was truncated" ) }
   ENDIF

   aDecoded := ConvexJsonDecode( cBody )
   IF !aDecoded[ 1 ] .OR. ValType( aDecoded[ 2 ] ) != "H"
      RETURN { "ok" => .F., "error" => ConvexProtocolError( "HTTP response was not a valid Convex JSON envelope" ) }
   ENDIF
   xEnvelope := aDecoded[ 2 ]

   IF !hb_HHasKey( xEnvelope, "status" ) .OR. ValType( xEnvelope[ "status" ] ) != "C"
      RETURN { "ok" => .F., "error" => ConvexProtocolError( "Convex response is missing status" ) }
   ENDIF
   cStatus := xEnvelope[ "status" ]
   xLogs := ConvexLogsToStrings( IIf( hb_HHasKey( xEnvelope, "logLines" ), xEnvelope[ "logLines" ], NIL ) )

   IF cStatus == "success"
      hasValue := hb_HHasKey( xEnvelope, "value" )
      IF !hasValue
         RETURN { "ok" => .F., "error" => ConvexProtocolError( "Convex success response is missing value" ) }
      ENDIF
      xValue := xEnvelope[ "value" ]
      RETURN { "ok" => .T., "value" => xValue, "logs" => xLogs }
   ELSEIF cStatus == "error"
      cErrorMessage := IIf( hb_HHasKey( xEnvelope, "errorMessage" ) .AND. ;
         ValType( xEnvelope[ "errorMessage" ] ) == "C", ;
         xEnvelope[ "errorMessage" ], "Convex function failed" )
      xErrorData := IIf( hb_HHasKey( xEnvelope, "errorData" ), xEnvelope[ "errorData" ], NIL )
      RETURN { "ok" => .F., "error" => ConvexNewError( "FunctionError", cErrorMessage, xErrorData ), "logs" => xLogs }
   ENDIF
   RETURN { "ok" => .F., "error" => ConvexProtocolError( "Convex response has an unknown status" ) }

/* One HTTP/1.1 exchange against <deployment>/api/<opName>. cToken may be
 * empty (no Authorization header sent at all, not an empty Bearer). */
FUNCTION ConvexHttpCall( oUrl, cToken, cOpName, cPath, xArgs, nDeadlineMs )
   LOCAL conn, cHostHeader, cAuthHeader, cBody, cReq, aResult

   conn := ConvexConnect( oUrl[ "host" ], oUrl[ "port" ], oUrl[ "tls" ], nDeadlineMs - ConvexNowMs() )
   IF !conn[ "ok" ]
      RETURN { "ok" => .F., "error" => conn[ "error" ] }
   ENDIF

   cHostHeader := oUrl[ "host" ]
   IF ( oUrl[ "tls" ] .AND. oUrl[ "port" ] != 443 ) .OR. ( !oUrl[ "tls" ] .AND. oUrl[ "port" ] != 80 )
      cHostHeader += ":" + hb_ntos( oUrl[ "port" ] )
   ENDIF

   cAuthHeader := ""
   IF !Empty( cToken )
      cAuthHeader := "Authorization: Bearer " + cToken + Chr( 13 ) + Chr( 10 )
   ENDIF

   cBody := ConvexJsonEncode( { "path" => cPath, "args" => xArgs, "format" => "json" } )

   cReq := "POST /api/" + cOpName + " HTTP/1.1" + Chr( 13 ) + Chr( 10 ) + ;
      "Host: " + cHostHeader + Chr( 13 ) + Chr( 10 ) + ;
      "Content-Type: application/json" + Chr( 13 ) + Chr( 10 ) + ;
      "Accept: application/json" + Chr( 13 ) + Chr( 10 ) + ;
      "Connection: close" + Chr( 13 ) + Chr( 10 ) + ;
      "Convex-Client: harbour-0.1.0" + Chr( 13 ) + Chr( 10 ) + ;
      cAuthHeader + ;
      "Content-Length: " + hb_ntos( Len( cBody ) ) + Chr( 13 ) + Chr( 10 ) + ;
      Chr( 13 ) + Chr( 10 ) + ;
      cBody

   IF !ConvexSockWrite( conn, cReq )
      ConvexClose( conn )
      RETURN { "ok" => .F., "error" => ConvexTransportError( "failed writing HTTP request" ) }
   ENDIF

   aResult := ConvexHttpReadResponse( conn, nDeadlineMs )
   ConvexClose( conn )
   RETURN aResult
