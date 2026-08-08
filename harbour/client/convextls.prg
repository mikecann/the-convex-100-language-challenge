/*
 * The one place this client opens a socket. hb_inet*() (Harbour's own
 * core sockets, src/rtl/hbinet.c) supplies the TCP transport and
 * contrib/hbssl binds OpenSSL directly onto it: once hb_inetSSL_CONNECT()
 * completes, every later hb_inet* read/write on that same socket handle
 * is transparently routed through the TLS session, so the HTTP and
 * WebSocket layers above never need to know whether they are talking
 * TLS or plain TCP.
 */

#include "hbclass.ch"

/* SSL_VERIFY_PEER. Not in hbssl.ch (only the SSL_CTX_NEW_METHOD_* and
 * error/option families are), but it is OpenSSL's own stable ABI constant,
 * not a Harbour invention. */
#define CONVEX_SSL_VERIFY_PEER 1

/* Opens host:port, and when lTls is .T. completes a real TLS handshake:
 * SNI is set from the host, the peer's certificate chain is verified
 * against the system trust store (or $SSL_CERT_FILE, matching every
 * other native client in this project), and the peer's certificate name
 * is checked per RFC 6125: subjectAltName DNS entries when the
 * certificate carries any (contrib/hbssl exposes no accessor for X.509
 * extensions, so convextls_native.c reaches libssl's own
 * X509_get_ext_d2i() directly for this), falling back to the legacy
 * Subject CN only when the certificate has no subjectAltName at all.
 * Real certificates commonly carry a CN unrelated to any name they
 * actually authorise (this project's own hosted Convex deployment does:
 * CN "convex.cloud", subjectAltName "convex.cloud" and
 * "*.convex.cloud"), so checking SAN first is not just more standards-
 * correct than CN-only, it is required for this client to interoperate
 * with the real hosted deployment at all. Chain verification is always
 * full strength and rejects an untrusted or self-signed peer outright,
 * independent of which name check applies.
 *
 * cVerifyHost, when given, is checked against the certificate instead of
 * cHost for SNI and the CN comparison, while cHost is still what is
 * actually dialed; every real call site leaves it NIL (dial address and
 * verified name are the same host), and client/tests/tls_test.prg is the
 * only caller that ever passes a different one, to prove the wrong-host
 * case is rejected without needing a second real hostname to dial.
 *
 * Returns { "ok" => .T., "sock" => ..., "ssl" => ...|NIL } or
 * { "ok" => .F., "error" => <ConvexNewError hash> }.
 */
FUNCTION ConvexConnect( cHost, nPort, lTls, nTimeoutMs, cVerifyHost )
   LOCAL sock, ctx, ssl, nResult, cCertFile

   IF Empty( cVerifyHost )
      cVerifyHost := cHost
   ENDIF

   sock := hb_inetCreate()
   hb_inetTimeout( sock, nTimeoutMs )

   /* hb_inetConnect() (unlike hb_inetConnectIP()) resolves cHost through
    * DNS first, which every real Convex deployment hostname needs. */
   IF Empty( hb_inetConnect( cHost, nPort, sock ) )
      RETURN { "ok" => .F., "error" => ;
         ConvexTransportError( "could not connect to " + cHost + ": " + hb_inetErrorDesc( sock ) ) }
   ENDIF

   IF !lTls
      RETURN { "ok" => .T., "sock" => sock, "ssl" => NIL }
   ENDIF

   ctx := SSL_CTX_new( HB_SSL_CTX_NEW_METHOD_TLS_CLIENT )
   IF ctx == NIL
      RETURN { "ok" => .F., "error" => ConvexTransportError( "could not create TLS context" ) }
   ENDIF

   cCertFile := GetEnv( "SSL_CERT_FILE" )
   IF !Empty( cCertFile )
      SSL_CTX_load_verify_locations( ctx, cCertFile )
   ELSE
      SSL_CTX_set_default_verify_paths( ctx )
   ENDIF

   ssl := SSL_new( ctx )
   SSL_set_tlsext_host_name( ssl, cVerifyHost )
   SSL_set_verify( ssl, CONVEX_SSL_VERIFY_PEER, NIL )

   nResult := hb_inetSSL_CONNECT( sock, ssl )
   IF nResult != 1
      RETURN { "ok" => .F., "error" => ;
         ConvexTransportError( "TLS handshake failed: " + ConvexSslErrorText() ) }
   ENDIF

   /* X509_V_OK is 0 in OpenSSL's own ABI. */
   IF SSL_get_verify_result( ssl ) != 0
      RETURN { "ok" => .F., "error" => ConvexTransportError( "TLS certificate is not trusted" ) }
   ENDIF

   IF !ConvexCertNameOk( ssl, cVerifyHost )
      RETURN { "ok" => .F., "error" => ;
         ConvexTransportError( "TLS certificate does not name " + cVerifyHost ) }
   ENDIF

   RETURN { "ok" => .T., "sock" => sock, "ssl" => ssl }

FUNCTION ConvexSslErrorText()
   LOCAL nErr := ERR_get_error()

   IF nErr == 0
      RETURN "unknown TLS error"
   ENDIF
   RETURN ERR_error_string( nErr )

/* RFC 6125 order of preference: when the certificate carries any
 * subjectAltName DNS entry, only those count, even if none of them
 * happen to match -- a certificate authority-issued SAN list is the
 * actual scope the certificate was issued for, and a leftover or
 * unrelated CN (this project's own hosted deployment has exactly this
 * shape) must not silently override that. Only a certificate with no
 * subjectAltName at all falls back to the legacy Subject CN, and only
 * a certificate with neither is treated as a best-effort skip: chain
 * verification (always full strength, checked separately) is the only
 * thing standing between such a certificate and rejection. */
FUNCTION ConvexCertNameOk( ssl, cHost )
   LOCAL cert, cSanList, aSan, i, cLine, nPos, cCn, nEnd

   cert := SSL_get_peer_certificate( ssl )
   IF cert == NIL
      RETURN .F.
   ENDIF
   cHost := Lower( cHost )

   cSanList := ConvexX509SanDnsNames( cert )
   IF !Empty( cSanList )
      aSan := hb_ATokens( cSanList, "," )
      FOR i := 1 TO Len( aSan )
         IF ConvexHostNameMatches( Lower( aSan[ i ] ), cHost )
            RETURN .T.
         ENDIF
      NEXT
      RETURN .F.
   ENDIF

   cLine := X509_name_oneline( X509_get_subject_name( cert ), 0, 0 )
   nPos := At( "/CN=", cLine )
   IF nPos == 0
      RETURN .T.
   ENDIF
   cCn := SubStr( cLine, nPos + 4 )
   nEnd := At( "/", cCn )
   IF nEnd > 0
      cCn := Left( cCn, nEnd - 1 )
   ENDIF
   RETURN ConvexHostNameMatches( Lower( cCn ), cHost )

/* .T. when cName (already lowercased) equals cHost (already lowercased)
 * exactly, or is a single leading wildcard label ("*.example.com")
 * covering cHost's own first label. Shared by both the subjectAltName
 * and Subject CN checks above so a wildcard means the same thing in
 * either place. */
FUNCTION ConvexHostNameMatches( cName, cHost )
   IF cName == cHost
      RETURN .T.
   ENDIF
   IF Left( cName, 2 ) == "*." .AND. At( ".", cHost ) > 0
      RETURN SubStr( cName, 3 ) == SubStr( cHost, At( ".", cHost ) + 1 )
   ENDIF
   RETURN .F.

/* Sends the whole buffer, retrying short writes; .T. only if every byte
 * was accepted before the socket's own timeout elapsed. */
FUNCTION ConvexSockWrite( conn, cData )
   RETURN hb_inetSendAll( conn[ "sock" ], cData ) == Len( cData )

/* One read of up to nMaxLen bytes, whatever is available before either
 * the socket's configured timeout or nDeadlineMs elapses. Returns "" on
 * a clean EOF and NIL on a transport error or timeout so callers can
 * tell "the peer is done" from "something went wrong" without probing a
 * separate status call. */
FUNCTION ConvexSockRead( conn, nMaxLen, nDeadlineMs )
   LOCAL cBuf, nGot, nBudget

   nBudget := nDeadlineMs - ConvexNowMs()
   IF nBudget <= 0
      RETURN NIL
   ENDIF
   hb_inetTimeout( conn[ "sock" ], nBudget )
   cBuf := Space( nMaxLen )
   nGot := hb_inetRecv( conn[ "sock" ], @cBuf, nMaxLen )
   IF nGot < 0
      IF hb_inetErrorCode( conn[ "sock" ] ) == 0
         RETURN ""
      ENDIF
      RETURN NIL
   ENDIF
   RETURN Left( cBuf, nGot )

FUNCTION ConvexClose( conn )
   IF conn != NIL .AND. conn[ "sock" ] != NIL
      hb_inetClose( conn[ "sock" ] )
   ENDIF
   RETURN NIL
