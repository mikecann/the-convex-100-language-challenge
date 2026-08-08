/*
 * RFC 6455 by hand: the HTTP/1.1 Upgrade handshake (with a real
 * Sec-WebSocket-Accept check -- Harbour's hb_bitXor()/hb_bitAnd() and
 * hbssl's EVP SHA-1 make that a real check here, unlike the ALGOL 60
 * client on this roster, which had neither and documented the narrower
 * check it fell back to instead) and RFC 6455 frame encode/decode:
 * FIN, opcode, client-side masking, and the 7/16/64-bit payload length
 * encoding. convextls.prg's buffered stream reader is reused for frame
 * bytes exactly as it is used for HTTP response bytes.
 */

#include "hbclass.ch"
#include "convexws.ch"

FUNCTION ConvexSha1( cData )
   LOCAL ctx, cDigest

   ctx := EVP_MD_CTX_new()
   IF ctx == NIL
      RETURN NIL
   ENDIF
   EVP_DigestInit( ctx, EVP_get_digestbyname( "sha1" ) )
   EVP_DigestUpdate( ctx, cData )
   /* The digest bytes come back through the second (by-reference)
    * parameter; the return value is only OpenSSL's 1-means-success code. */
   EVP_DigestFinal( ctx, @cDigest )
   RETURN cDigest

FUNCTION ConvexWsAcceptValue( cKey )
   RETURN hb_base64Encode( ConvexSha1( cKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )

/* Sends the GET /api/sync Upgrade request and validates the 101 response:
 * an Upgrade: websocket header must be present, and Sec-WebSocket-Accept
 * must equal base64(SHA-1(key + the RFC 6455 magic GUID)) exactly. */
FUNCTION ConvexWsHandshake( conn, cHost, cPath, nDeadlineMs )
   LOCAL cKey, cReq, oStream, cStatusLine, cHeaderLine
   LOCAL lUpgradeOk, cAcceptHeader, nColon, cName, cValue

   cKey := hb_base64Encode( ConvexRandomBytes( 16 ) )
   cReq := "GET " + cPath + " HTTP/1.1" + Chr( 13 ) + Chr( 10 ) + ;
      "Host: " + cHost + Chr( 13 ) + Chr( 10 ) + ;
      "Upgrade: websocket" + Chr( 13 ) + Chr( 10 ) + ;
      "Connection: Upgrade" + Chr( 13 ) + Chr( 10 ) + ;
      "Sec-WebSocket-Key: " + cKey + Chr( 13 ) + Chr( 10 ) + ;
      "Sec-WebSocket-Version: 13" + Chr( 13 ) + Chr( 10 ) + ;
      "Convex-Client: harbour-0.1.0" + Chr( 13 ) + Chr( 10 ) + ;
      Chr( 13 ) + Chr( 10 )

   IF !ConvexSockWrite( conn, cReq )
      RETURN { "ok" => .F., "error" => ConvexTransportError( "failed writing WebSocket handshake" ) }
   ENDIF

   oStream := ConvexStreamNew( conn, nDeadlineMs )
   cStatusLine := ConvexStreamLine( oStream )
   IF cStatusLine == NIL .OR. At( " 101 ", " " + cStatusLine + " " ) == 0
      RETURN { "ok" => .F., "error" => ConvexTransportError( "WebSocket upgrade was refused" ) }
   ENDIF

   lUpgradeOk := .F.
   cAcceptHeader := ""
   DO WHILE .T.
      cHeaderLine := ConvexStreamLine( oStream )
      IF cHeaderLine == NIL
         RETURN { "ok" => .F., "error" => ConvexTransportError( "WebSocket handshake headers truncated" ) }
      ENDIF
      IF Empty( cHeaderLine )
         EXIT
      ENDIF
      nColon := At( ":", cHeaderLine )
      IF nColon > 0
         cName := Lower( AllTrim( Left( cHeaderLine, nColon - 1 ) ) )
         cValue := AllTrim( SubStr( cHeaderLine, nColon + 1 ) )
         IF cName == "upgrade" .AND. Lower( cValue ) == "websocket"
            lUpgradeOk := .T.
         ELSEIF cName == "sec-websocket-accept"
            cAcceptHeader := cValue
         ENDIF
      ENDIF
   ENDDO

   IF !lUpgradeOk
      RETURN { "ok" => .F., "error" => ConvexProtocolError( "WebSocket response is missing Upgrade: websocket" ) }
   ENDIF
   IF cAcceptHeader != ConvexWsAcceptValue( cKey )
      RETURN { "ok" => .F., "error" => ConvexProtocolError( "WebSocket Sec-WebSocket-Accept did not match" ) }
   ENDIF

   RETURN { "ok" => .T., "stream" => oStream }

/* Pure frame-byte construction, split out from sending so it can be
 * exercised directly in client/tests/client_test.prg without a real
 * socket: the caller supplies the mask key rather than this function
 * drawing fresh randomness, so a test can pick a known key and check the
 * exact bytes produced. */
FUNCTION ConvexWsBuildFrame( nOpcode, cPayload, cMask )
   LOCAL nLen, cHeader, cMasked, i

   nLen := Len( cPayload )
   cHeader := Chr( hb_bitOr( 0x80, nOpcode ) )

   IF nLen < 126
      cHeader += Chr( hb_bitOr( 0x80, nLen ) )
   ELSEIF nLen < 65536
      cHeader += Chr( hb_bitOr( 0x80, 126 ) )
      cHeader += Chr( Int( nLen / 256 ) ) + Chr( nLen % 256 )
   ELSE
      cHeader += Chr( hb_bitOr( 0x80, 127 ) )
      cHeader += Replicate( Chr( 0 ), 4 )
      cHeader += Chr( hb_bitAnd( hb_bitShift( nLen, -24 ), 0xFF ) ) + ;
         Chr( hb_bitAnd( hb_bitShift( nLen, -16 ), 0xFF ) ) + ;
         Chr( hb_bitAnd( hb_bitShift( nLen, -8 ), 0xFF ) ) + ;
         Chr( hb_bitAnd( nLen, 0xFF ) )
   ENDIF

   cMasked := ""
   FOR i := 1 TO nLen
      cMasked += Chr( hb_bitXor( Asc( SubStr( cPayload, i, 1 ) ), ;
         Asc( SubStr( cMask, ( ( i - 1 ) % 4 ) + 1, 1 ) ) ) )
   NEXT

   RETURN cHeader + cMask + cMasked

/* Every client-to-server frame is masked, as RFC 6455 requires; the mask
 * key is fresh /dev/urandom bytes on every single frame. */
FUNCTION ConvexWsSendFrame( conn, nOpcode, cPayload )
   LOCAL cMask := ConvexRandomBytes( 4 )

   IF cMask == NIL
      RETURN .F.
   ENDIF
   RETURN ConvexSockWrite( conn, ConvexWsBuildFrame( nOpcode, cPayload, cMask ) )

FUNCTION ConvexWsSendClose( conn )
   RETURN ConvexWsSendFrame( conn, CONVEX_WS_OP_CLOSE, "" )

/* One frame off the stream: header, extended length (16- or 64-bit,
 * rejecting a 64-bit length whose top four bytes are nonzero -- this
 * client only ever needs lengths that fit CONVEX_WS_MAX_FRAME anyway),
 * the server's mask key when the (nonconforming, but tolerated) server
 * sets one, and the payload, unmasked if it was masked. */
FUNCTION ConvexWsReadFrame( oStream )
   LOCAL cBytes, b0, b1, lFin, nOpcode, lMasked, nLen, cExt, cMask, cPayload, cUnmasked, i

   cBytes := ConvexStreamExact( oStream, 2 )
   IF cBytes == NIL
      RETURN NIL
   ENDIF
   b0 := Asc( SubStr( cBytes, 1, 1 ) )
   b1 := Asc( SubStr( cBytes, 2, 1 ) )
   lFin := hb_bitAnd( b0, 0x80 ) != 0
   nOpcode := hb_bitAnd( b0, 0x0F )
   lMasked := hb_bitAnd( b1, 0x80 ) != 0
   nLen := hb_bitAnd( b1, 0x7F )

   IF nLen == 126
      cExt := ConvexStreamExact( oStream, 2 )
      IF cExt == NIL
         RETURN NIL
      ENDIF
      nLen := Asc( SubStr( cExt, 1, 1 ) ) * 256 + Asc( SubStr( cExt, 2, 1 ) )
   ELSEIF nLen == 127
      cExt := ConvexStreamExact( oStream, 8 )
      IF cExt == NIL
         RETURN NIL
      ENDIF
      IF Asc( SubStr( cExt, 1, 1 ) ) != 0 .OR. Asc( SubStr( cExt, 2, 1 ) ) != 0 .OR. ;
         Asc( SubStr( cExt, 3, 1 ) ) != 0 .OR. Asc( SubStr( cExt, 4, 1 ) ) != 0
         RETURN NIL
      ENDIF
      nLen := Asc( SubStr( cExt, 5, 1 ) ) * 16777216 + Asc( SubStr( cExt, 6, 1 ) ) * 65536 + ;
         Asc( SubStr( cExt, 7, 1 ) ) * 256 + Asc( SubStr( cExt, 8, 1 ) )
   ENDIF

   IF nLen > CONVEX_WS_MAX_FRAME
      RETURN NIL
   ENDIF

   IF lMasked
      cMask := ConvexStreamExact( oStream, 4 )
      IF cMask == NIL
         RETURN NIL
      ENDIF
   ENDIF

   cPayload := ConvexStreamExact( oStream, nLen )
   IF cPayload == NIL
      RETURN NIL
   ENDIF

   IF lMasked
      cUnmasked := ""
      FOR i := 1 TO nLen
         cUnmasked += Chr( hb_bitXor( Asc( SubStr( cPayload, i, 1 ) ), ;
            Asc( SubStr( cMask, ( ( i - 1 ) % 4 ) + 1, 1 ) ) ) )
      NEXT
      cPayload := cUnmasked
   ENDIF

   RETURN { "fin" => lFin, "opcode" => nOpcode, "payload" => cPayload }

/* Reassembles continuation frames into one message. A control frame
 * (close/ping/pong) arriving before any data frame is in progress is
 * returned on its own, exactly as RFC 6455 allows a peer to interleave
 * one. A control frame arriving *during* a fragmented data message is
 * a real possibility this simple reader does not resume from -- it is
 * treated as a protocol failure, which is safe because Convex's own
 * sync protocol never actually fragments an application message, so a
 * mid-fragmentation control frame can only mean a broken or hostile
 * peer, and a reconnect is the correct response to either. */
FUNCTION ConvexWsReadMessage( oStream )
   LOCAL oFrame, cAssembled, nMsgType

   cAssembled := ""
   nMsgType := NIL
   DO WHILE .T.
      oFrame := ConvexWsReadFrame( oStream )
      IF oFrame == NIL
         RETURN NIL
      ENDIF
      IF oFrame[ "opcode" ] == CONVEX_WS_OP_CLOSE .OR. oFrame[ "opcode" ] == CONVEX_WS_OP_PING .OR. ;
         oFrame[ "opcode" ] == CONVEX_WS_OP_PONG
         IF nMsgType != NIL
            RETURN NIL
         ENDIF
         RETURN oFrame
      ENDIF
      IF nMsgType == NIL
         nMsgType := oFrame[ "opcode" ]
      ENDIF
      cAssembled += oFrame[ "payload" ]
      IF Len( cAssembled ) > CONVEX_WS_MAX_MESSAGE
         RETURN NIL
      ENDIF
      IF oFrame[ "fin" ]
         RETURN { "opcode" => nMsgType, "payload" => cAssembled }
      ENDIF
   ENDDO
   RETURN NIL
