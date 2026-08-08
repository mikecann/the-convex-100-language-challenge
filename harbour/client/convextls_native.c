/*
 * contrib/hbssl wraps enough of OpenSSL's X509 API for a Subject CN
 * check (see x509.c: X509_GET_SUBJECT_NAME, X509_NAME_ONELINE), but it
 * has no accessor at all for X.509 extensions, so there is no Harbour
 * route to a certificate's subjectAltName -- the field real-world TLS
 * verification (RFC 6125) actually keys hostname checks on. Real
 * certificates routinely carry a Subject CN that does not match the
 * dialed host at all (this project's own hosted Convex deployment does:
 * CN "convex.cloud", subjectAltName DNS:convex.cloud and
 * DNS:*.convex.cloud), so CN-only verification rejects perfectly valid
 * connections.
 *
 * This file adds exactly one missing accessor, reached directly through
 * libssl's own C API -- the same library hbssl itself links against, so
 * this adds no new dependency, just the one function contrib/hbssl never
 * wrapped. hb_X509_par() is hbssl's own public C entry point
 * (contrib/hbssl/hbssl.h) for unwrapping the garbage-collected X509
 * pointer a Harbour hbssl call such as SSL_GET_PEER_CERTIFICATE()
 * returns, so the certificate object this file receives is the exact
 * same one convextls.prg's Harbour code is already holding.
 */

#include "hbapi.h"
#include <openssl/x509v3.h>
#include <string.h>

extern X509 * hb_X509_par( int iParam );

/* Returns the peer certificate's subjectAltName DNS entries, comma
 * separated, or "" when the extension is absent or every entry was
 * rejected below. A DNS name can never legitimately contain a NUL byte
 * or a comma; an entry that does is skipped rather than trusted, so a
 * crafted certificate cannot use one to forge an extra delimiter or
 * truncate a Harbour-side comparison early. */
HB_FUNC( CONVEXX509SANDNSNAMES )
{
   X509 * cert = hb_X509_par( 1 );
   GENERAL_NAMES * names;
   char buf[ 4096 ];
   size_t used = 0;
   int i, count;

   if( cert == NULL )
   {
      hb_retc( "" );
      return;
   }

   names = ( GENERAL_NAMES * ) X509_get_ext_d2i( cert, NID_subject_alt_name, NULL, NULL );
   if( names == NULL )
   {
      hb_retc( "" );
      return;
   }

   count = sk_GENERAL_NAME_num( names );
   for( i = 0; i < count; i++ )
   {
      GENERAL_NAME * name = sk_GENERAL_NAME_value( names, i );

      if( name != NULL && name->type == GEN_DNS )
      {
         const unsigned char * data = ASN1_STRING_get0_data( name->d.dNSName );
         int len = ASN1_STRING_length( name->d.dNSName );

         if( data != NULL && len > 0 && ( size_t ) len < sizeof( buf ) - used - 2 &&
             memchr( data, '\0', ( size_t ) len ) == NULL &&
             memchr( data, ',', ( size_t ) len ) == NULL )
         {
            if( used > 0 )
               buf[ used++ ] = ',';
            memcpy( buf + used, data, ( size_t ) len );
            used += ( size_t ) len;
         }
      }
   }

   GENERAL_NAMES_free( names );

   hb_retclen( buf, ( HB_ISIZ ) used );
}
