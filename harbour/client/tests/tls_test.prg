/*
 * A real TLS handshake against a local openssl s_server, driven three
 * ways by TLS_MODE: a certificate the configured trust store actually
 * signs must be accepted ("trusted"); one signed by a different CA must
 * be rejected regardless of hostname ("untrusted"); and a certificate
 * that is chain-trusted but does not name the host being connected to
 * must also be rejected ("wronghost"). The untrusted and wrong-host
 * modes are the ones a client that quietly skipped verification would
 * still pass.
 */

#include "hbclass.ch"

PROCEDURE Main()
   LOCAL cMode, conn

   cMode := GetEnv( "TLS_MODE" )

   DO CASE
   CASE cMode == "trusted"
      conn := ConvexConnect( "127.0.0.1", 44300, .T., 5000, "localhost" )
      IF !conn[ "ok" ]
         OutErr( "trusted connect failed: " + conn[ "error" ][ "message" ] + hb_eol() )
         ErrorLevel( 1 )
         RETURN
      ENDIF
      ConvexClose( conn )
      ? "PASS tls_test trusted"

   CASE cMode == "untrusted"
      conn := ConvexConnect( "127.0.0.1", 44300, .T., 5000, "localhost" )
      IF conn[ "ok" ]
         OutErr( "untrusted connect unexpectedly succeeded" + hb_eol() )
         ErrorLevel( 1 )
         RETURN
      ENDIF
      ? "PASS tls_test untrusted"

   CASE cMode == "wronghost"
      conn := ConvexConnect( "127.0.0.1", 44300, .T., 5000, "wrong-host.example.invalid" )
      IF conn[ "ok" ]
         OutErr( "wrong-host connect unexpectedly succeeded" + hb_eol() )
         ErrorLevel( 1 )
         RETURN
      ENDIF
      ? "PASS tls_test wronghost"

   OTHERWISE
      OutErr( "TLS_MODE must be trusted, untrusted or wronghost" + hb_eol() )
      ErrorLevel( 1 )
   ENDCASE

   RETURN
